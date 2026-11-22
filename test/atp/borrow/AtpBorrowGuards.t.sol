// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { AtpBorrowBase } from "./AtpBorrowBase.sol";
import { AtpBorrowExecutor } from "../../../src/atp/borrow/AtpBorrowExecutor.sol";
import { AtpBorrowRegistry } from "../../../src/atp/borrow/AtpBorrowRegistry.sol";
import { BorrowTypes as B } from "../../../src/atp/borrow/BorrowTypes.sol";
import { MockLendingOracle } from "../../../src/testnet/lending/MockLendingOracle.sol";
import { MockMoolah } from "../../../src/testnet/lending/MockMoolah.sol";
import { MoolahParams } from "../../../src/atp/yield/YieldInterfaces.sol";
import { TestnetToken } from "../../../src/testnet/TestnetToken.sol";

/// @notice #64 boundaries and failure paths (EARN_UX §D): LTV caps, utilization and carry gates, consent, caps,
/// pauses, liquidity, callers. Every threshold: exactly at it passes, one unit past it is refused.
contract AtpBorrowGuardsTest is AtpBorrowBase {
    // ---- target LTV ----

    function test_borrowExactlyAtTargetLtv_passes_oneMoreRawFails() public {
        for (uint256 i; i < 2; ++i) {
            bytes32 id = i == 0 ? VENUS_ID : LISTA_ID;
            _post(id, 10e18);
            uint256 max = _maxDebtAtTarget(id);
            assertEq(max, 406.0325e18);
            uint256 snap = vm.snapshotState();
            vm.expectRevert(
                abi.encodeWithSelector(AtpBorrowExecutor.LtvTooHigh.selector, 0.25e18 + 1, 0.25e18)
            );
            _borrow(id, max + 1);
            vm.revertToState(snap);
            _borrow(id, max);
            assertEq(_ltv(id), 0.25e18);
        }
    }

    function test_withdrawCollateral_aboveTargetReverts_atTargetPasses() public {
        for (uint256 i; i < 2; ++i) {
            bytes32 id = i == 0 ? VENUS_ID : LISTA_ID;
            _post(id, 10e18);
            _borrow(id, 200e18);
            // LTV 25% needs 800 USD of collateral = 800 / 162.413 tokens.
            uint256 keep = (800e18 * 1e8 + PRICE_E8 - 1) / PRICE_E8;
            uint256 snap = vm.snapshotState();
            vm.expectRevert();
            _withdraw(id, 10e18 - keep + 1e9);
            vm.revertToState(snap);
            _withdraw(id, 10e18 - keep - 1e9);
            assertLe(_ltv(id), 0.25e18);
            assertGt(_ltv(id), 0.2499999e18);
        }
    }

    function test_withdrawAllWithDebt_reverts() public {
        _post(LISTA_ID, 10e18);
        _borrow(LISTA_ID, 100e18);
        vm.expectRevert("insufficient collateral");
        _withdraw(LISTA_ID, type(uint256).max);
        _post(VENUS_ID, 10e18);
        _borrow(VENUS_ID, 100e18);
        vm.expectRevert(abi.encodeWithSelector(AtpBorrowExecutor.ProtocolError.selector, 3));
        _withdraw(VENUS_ID, type(uint256).max);
    }

    function testFuzz_borrow_neverAboveTargetLtv(uint256 amount, bool lista) public {
        bytes32 id = lista ? LISTA_ID : VENUS_ID;
        _post(id, 10e18);
        amount = bound(amount, 1, 900e18);
        uint256 max = _maxDebtAtTarget(id);
        try lend.executeBorrow(address(this), id, amount, block.timestamp) {
            assertLe(_ltv(id), credit.targetLtv(id));
            assertLe(amount, max);
        } catch {
            assertGt(amount, max);
        }
    }

    // ---- LTV configuration: hard caps the owner cannot exceed ----

    function test_setLtvConfig_capsEnforced() public {
        // Caps for F = 50%: target 25%, deleverage 33.33%.
        credit.setLtvConfig(VENUS_ID, 0.25e18, 0.333333333333333333e18);
        vm.expectRevert(AtpBorrowRegistry.BadParameter.selector);
        credit.setLtvConfig(VENUS_ID, 0.25e18 + 1, 0.3e18);
        vm.expectRevert(AtpBorrowRegistry.BadParameter.selector);
        credit.setLtvConfig(VENUS_ID, 0.2e18, 0.333333333333333333e18 + 1);
        vm.expectRevert(AtpBorrowRegistry.BadParameter.selector);
        credit.setLtvConfig(VENUS_ID, 0.3e18, 0.3e18);
        // More conservative per asset applies at once.
        credit.setLtvConfig(VENUS_ID, 0.15e18, 0.25e18);
        assertEq(credit.targetLtv(VENUS_ID), 0.15e18);
        assertEq(credit.deleverageLtv(VENUS_ID), 0.25e18);
        _post(VENUS_ID, 10e18);
        vm.expectRevert();
        _borrow(VENUS_ID, 250e18); // 15.4% > 15%
        _borrow(VENUS_ID, 240e18);
        // 0 restores the cap.
        credit.setLtvConfig(VENUS_ID, 0, 0);
        assertEq(credit.targetLtv(VENUS_ID), 0.25e18);
    }

    function test_capFollowsMarketFactor_whenProtocolLowersIt() public {
        credit.setLtvConfig(VENUS_ID, 0.25e18, 0.3e18);
        comptroller.setCollateralFactor(address(vNvda), 0.4e18);
        // The stored line is above the new cap: the cap wins.
        assertEq(credit.targetLtv(VENUS_ID), 0.2e18);
        assertEq(credit.deleverageLtv(VENUS_ID), 0.266666666666666666e18);
    }

    // ---- borrow-market utilization <= 85% after the borrow ----

    function test_borrowUtilization_exactly85Passes_aboveFails() public {
        nvda.mint(address(this), 50_000e18);
        tsla.mint(address(this), 50_000e18);
        for (uint256 i; i < 2; ++i) {
            bytes32 id = i == 0 ? VENUS_ID : LISTA_ID;
            _post(id, 25_000e18); // 4.06M USD, target allows ~1.01M
            uint256 snap = vm.snapshotState();
            vm.expectRevert(
                abi.encodeWithSelector(AtpBorrowExecutor.BorrowGateClosed.selector, B.Gate.BORROW_UTILIZATION)
            );
            _borrow(id, 850_000e18 + 1);
            vm.revertToState(snap);
            _borrow(id, 850_000e18);
            assertEq(credit.status(id, address(0)).borrowUtilizationBps, 8_500);
            assertEq(uint8(credit.status(id, address(0)).gate), uint8(B.Gate.OPEN));
            // Any further borrow pushes it past 85%.
            vm.expectRevert(
                abi.encodeWithSelector(AtpBorrowExecutor.BorrowGateClosed.selector, B.Gate.BORROW_UTILIZATION)
            );
            _borrow(id, 1e18);
        }
    }

    // ---- earn-vault utilization <= 90% ----

    function test_vaultUtilization_exactly90Passes_aboveFails() public {
        _post(VENUS_ID, 10e18);
        _vaultUtilization(9_000);
        assertEq(credit.status(VENUS_ID, address(0)).vaultUtilizationBps, 9_000);
        uint256 snap = vm.snapshotState();
        _borrow(VENUS_ID, 100e18);
        vm.revertToState(snap);
        vault.setLiquidity(vault.totalAssets() - vault.totalBorrows() - 1);
        B.Status memory s = credit.status(VENUS_ID, address(0));
        assertEq(s.vaultUtilizationBps, 9_001);
        assertEq(uint8(s.gate), uint8(B.Gate.VAULT_UTILIZATION));
        vm.expectRevert(
            abi.encodeWithSelector(AtpBorrowExecutor.BorrowGateClosed.selector, B.Gate.VAULT_UTILIZATION)
        );
        _borrow(VENUS_ID, 100e18);
    }

    // ---- borrow rate <= vault rate ----

    function test_negativeCarry_equalRatePasses_higherBorrowRateFails() public {
        _post(VENUS_ID, 10e18);
        _post(LISTA_ID, 10e18);
        vUsdt.setBorrowAprBps(VAULT_APR);
        moolah.setBorrowAprBps(moolah.marketId(listaParams), VAULT_APR);
        _borrow(VENUS_ID, 100e18);
        _borrow(LISTA_ID, 100e18);
        vUsdt.setBorrowAprBps(VAULT_APR + 1);
        moolah.setBorrowAprBps(moolah.marketId(listaParams), VAULT_APR + 1);
        assertEq(uint8(credit.status(VENUS_ID, address(0)).gate), uint8(B.Gate.NEGATIVE_CARRY));
        vm.expectRevert(
            abi.encodeWithSelector(AtpBorrowExecutor.BorrowGateClosed.selector, B.Gate.NEGATIVE_CARRY)
        );
        _borrow(VENUS_ID, 1e18);
        vm.expectRevert(
            abi.encodeWithSelector(AtpBorrowExecutor.BorrowGateClosed.selector, B.Gate.NEGATIVE_CARRY)
        );
        _borrow(LISTA_ID, 1e18);
        assertTrue(credit.status(VENUS_ID, address(this)).shouldUnwind);
    }

    // ---- one market per asset; leveraged / volatile assets have none ----

    function test_onlyDesignatedMarketAdmitsNewRisk() public {
        TestnetToken tqqq = new TestnetToken("TQQQ", "TQQQB", 18, address(this));
        assertEq(credit.collateralMarket(address(tqqq)), bytes32(0), "leveraged ETF must have no market");

        _post(VENUS_ID, 10e18);
        _borrow(VENUS_ID, 100e18);
        // A second NVDA market on Lista exists but is not designated.
        bytes32 otherId = bytes32(uint256(0xB2));
        B.Market memory other = _listaMarket();
        moolah.createMarket(_params(address(nvda)), BORROW_APR);
        other.collateral = address(nvda);
        other.listaId = moolah.marketId(_params(address(nvda)));
        credit.registerMarket(otherId, other);
        credit.setBorrowPolicy(otherId, 1_000e18, true);
        vm.expectRevert(abi.encodeWithSelector(AtpBorrowRegistry.NotDesignatedMarket.selector, VENUS_ID));
        _post(otherId, 1e18);
        // Moving the designation closes new risk on the old market, never its exits.
        credit.setCollateralMarket(address(nvda), otherId);
        vm.expectRevert(abi.encodeWithSelector(AtpBorrowRegistry.NotDesignatedMarket.selector, otherId));
        _borrow(VENUS_ID, 1e18);
        assertEq(uint8(credit.status(VENUS_ID, address(0)).gate), uint8(B.Gate.CLOSED));
        _repay(VENUS_ID, type(uint256).max, true);
        _withdraw(VENUS_ID, type(uint256).max);
        vm.expectRevert(AtpBorrowRegistry.BadMarket.selector);
        credit.setCollateralMarket(address(tsla), otherId);
    }

    function _params(address collateral) internal view returns (MoolahParams memory p) {
        p = MoolahParams(address(usdt), collateral, address(oracle), address(moolah), 0.5e18);
    }

    // ---- consent ----

    function test_borrowWithoutConsent_reverts() public {
        _post(VENUS_ID, 10e18);
        credit.setBorrowPolicy(VENUS_ID, 0, false);
        vm.expectRevert(AtpBorrowRegistry.ConsentRequired.selector);
        _borrow(VENUS_ID, 1e18);
        vm.expectRevert(AtpBorrowRegistry.ConsentRequired.selector);
        _post(VENUS_ID, 1e18);
    }

    function test_debtCeiling_exactPasses_aboveFails() public {
        _post(LISTA_ID, 10e18);
        credit.setBorrowPolicy(LISTA_ID, 100e18, true);
        vm.expectRevert(
            abi.encodeWithSelector(AtpBorrowExecutor.DebtAboveConsent.selector, 100e18 + 1, 100e18)
        );
        _borrow(LISTA_ID, 100e18 + 1);
        _borrow(LISTA_ID, 100e18);
        assertEq(credit.debt(LISTA_ID, address(this)), 100e18);
    }

    function test_consentPinnedToEnrollment_pausedEnrollmentBlocks() public {
        _post(VENUS_ID, 10e18);
        registry.setPaused(address(this), true);
        vm.expectRevert(AtpBorrowRegistry.ConsentRequired.selector);
        _borrow(VENUS_ID, 1e18);
    }

    function test_setBorrowPolicy_requiresEnrolledContract() public {
        vm.prank(address(0xE0A));
        vm.expectRevert(AtpBorrowRegistry.ConsentRequired.selector);
        credit.setBorrowPolicy(VENUS_ID, 1e18, true);
        vm.expectRevert(AtpBorrowRegistry.ConsentRequired.selector);
        credit.setBorrowPolicy(VENUS_ID, 0, true);
        vm.expectRevert(AtpBorrowRegistry.UnknownMarket.selector);
        credit.setBorrowPolicy(bytes32(uint256(0xDEAD)), 1e18, true);
    }

    // ---- CRE8-wide cap per market ----

    function test_marketCap_exactPasses_aboveFails() public {
        credit.setBorrowCap(VENUS_ID, 300e18);
        _post(VENUS_ID, 10e18);
        _borrow(VENUS_ID, 200e18);
        vm.expectRevert(
            abi.encodeWithSelector(AtpBorrowRegistry.BorrowCapExceeded.selector, 100e18 + 1, 100e18)
        );
        _borrow(VENUS_ID, 100e18 + 1);
        _borrow(VENUS_ID, 100e18);
        assertEq(credit.totalPrincipal(VENUS_ID), 300e18);
        _repay(VENUS_ID, 50e18, true);
        _borrow(VENUS_ID, 50e18);
    }

    // ---- pauses: new risk stops, exits stay open ----

    function test_protocolBorrowPaused_reverts() public {
        _post(VENUS_ID, 10e18);
        comptroller.setActionPaused(address(vUsdt), BORROW_ACTION, true);
        vm.expectRevert("action is paused");
        _borrow(VENUS_ID, 1e18);
        _post(LISTA_ID, 10e18);
        moolah.setPaused(true);
        vm.expectRevert("paused");
        _borrow(LISTA_ID, 1e18);
    }

    function test_cre8Pauses_blockNewRisk_butNotExit() public {
        _post(VENUS_ID, 10e18);
        _borrow(VENUS_ID, 100e18);
        _post(LISTA_ID, 10e18);
        _borrow(LISTA_ID, 100e18);

        credit.setMarketBorrow(VENUS_ID, false, false);
        vm.expectRevert(AtpBorrowRegistry.AdmissionClosed.selector);
        _borrow(VENUS_ID, 1e18);
        credit.setMarketBorrow(VENUS_ID, true, false);

        credit.setBorrowPaused(true);
        vm.expectRevert(AtpBorrowRegistry.AdmissionClosed.selector);
        _borrow(VENUS_ID, 1e18);
        vm.expectRevert(AtpBorrowRegistry.AdmissionClosed.selector);
        _post(VENUS_ID, 1e18);

        executor.setGlobalPaused(true);
        vm.expectRevert(AtpBorrowExecutor.ExecutorPaused.selector);
        _borrow(VENUS_ID, 1e18);

        credit.setMarketBorrow(LISTA_ID, false, true); // retired
        moolah.setPaused(true); // Lista keeps repay and withdrawal open while paused
        _repay(VENUS_ID, type(uint256).max, true);
        _withdraw(VENUS_ID, type(uint256).max);
        _repay(LISTA_ID, type(uint256).max, true);
        _withdraw(LISTA_ID, type(uint256).max);
        assertEq(nvda.balanceOf(address(this)), 100e18);
        assertEq(tsla.balanceOf(address(this)), 100e18);
        assertEq(credit.accountMarkets(address(this)).length, 0);
    }

    function test_retiredMarket_cannotReopen() public {
        credit.setMarketBorrow(VENUS_ID, false, true);
        vm.expectRevert(AtpBorrowRegistry.BadMarket.selector);
        credit.setMarketBorrow(VENUS_ID, true, false);
        vm.expectRevert(AtpBorrowRegistry.AdmissionClosed.selector);
        _post(VENUS_ID, 1e18);
    }

    // ---- protocol liquidity ----

    function test_insufficientProtocolLiquidity_reverts() public {
        nvda.mint(address(this), 100_000e18);
        tsla.mint(address(this), 100_000e18);
        _post(VENUS_ID, 40_000e18);
        _post(LISTA_ID, 40_000e18);
        credit.setBorrowCap(VENUS_ID, 10_000_000e18);
        credit.setBorrowCap(LISTA_ID, 10_000_000e18);
        // Venus returns TOKEN_INSUFFICIENT_CASH (14) instead of reverting; the executor turns it into a revert.
        vm.expectRevert(abi.encodeWithSelector(AtpBorrowExecutor.ProtocolError.selector, 14));
        _borrow(VENUS_ID, 1_000_000e18 + 1);
        vm.expectRevert("insufficient liquidity");
        _borrow(LISTA_ID, 1_000_000e18 + 1);
    }

    function test_repayFromVault_failsWhenVaultIlliquid() public {
        _post(VENUS_ID, 10e18);
        _borrow(VENUS_ID, 100e18);
        vault.setLiquidity(10e18);
        vm.expectRevert();
        _repay(VENUS_ID, type(uint256).max, true);
        // The portfolio's own USDT (e.g. sale proceeds) still repays.
        _repay(VENUS_ID, 100e18, false);
        assertEq(credit.debt(VENUS_ID, address(this)), 0);
        // Vault shares stay tracked until the vault is liquid again, then come back into the account.
        assertGt(credit.vaultShares(address(this), VENUS_ID), 0);
        assertEq(credit.accountMarkets(address(this)).length, 1);
        vault.setLiquidity(usdt.balanceOf(address(vault)));
        _repay(VENUS_ID, type(uint256).max, true);
        assertEq(vault.balanceOf(address(this)), 0);
        _withdraw(VENUS_ID, type(uint256).max);
        assertEq(credit.accountMarkets(address(this)).length, 0);
    }

    // ---- callers and inputs ----

    function test_onlyTheAccountItself() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(AtpBorrowExecutor.NotAccount.selector);
        lend.executeBorrow(address(this), VENUS_ID, 1e18, block.timestamp);
        vm.prank(address(0xBAD));
        vm.expectRevert(AtpBorrowExecutor.NotAccount.selector);
        lend.executeRepay(address(this), VENUS_ID, 1e18, true, block.timestamp);
        vm.prank(address(0xBAD));
        vm.expectRevert(AtpBorrowExecutor.NotAccount.selector);
        lend.executeWithdrawCollateral(address(this), VENUS_ID, 1e18, block.timestamp);
        address eoa = address(0xE0A);
        vm.prank(eoa);
        vm.expectRevert(AtpBorrowExecutor.NotContract.selector);
        lend.executeSupplyCollateral(eoa, VENUS_ID, 1e18, block.timestamp);
    }

    function test_deadlineAndZeroAmounts() public {
        vm.expectRevert(AtpBorrowExecutor.DeadlineExpired.selector);
        lend.executeBorrow(address(this), VENUS_ID, 1e18, block.timestamp - 1);
        vm.expectRevert(AtpBorrowExecutor.ZeroAmount.selector);
        _post(VENUS_ID, 0);
        vm.expectRevert(AtpBorrowExecutor.ZeroAmount.selector);
        _borrow(VENUS_ID, 0);
        vm.expectRevert(AtpBorrowExecutor.NothingToRepay.selector);
        _repay(VENUS_ID, 1e18, true);
        vm.expectRevert(AtpBorrowRegistry.UnknownMarket.selector);
        _borrow(bytes32(uint256(0xDEAD)), 1e18);
    }

    function test_withoutProtocolGrant_reverts() public {
        comptroller.updateDelegate(address(lend), false);
        moolah.setAuthorization(address(lend), false);
        vm.expectRevert("not an approved delegate");
        _post(VENUS_ID, 1e18);
        _post(LISTA_ID, 10e18); // Moolah lets anyone add collateral
        vm.expectRevert("unauthorized");
        _borrow(LISTA_ID, 1e18);
    }

    // ---- admin ----

    function test_adminIsRegistryOwnerOnly() public {
        vm.startPrank(address(0xBAD));
        vm.expectRevert(AtpBorrowRegistry.Unauthorized.selector);
        credit.setBorrowPaused(true);
        vm.expectRevert(AtpBorrowRegistry.Unauthorized.selector);
        credit.setBorrowCap(VENUS_ID, 1);
        vm.expectRevert(AtpBorrowRegistry.Unauthorized.selector);
        credit.setLtvConfig(VENUS_ID, 0.1e18, 0.2e18);
        vm.expectRevert(AtpBorrowRegistry.Unauthorized.selector);
        credit.setCollateralMarket(address(nvda), VENUS_ID);
        vm.expectRevert(AtpBorrowRegistry.Unauthorized.selector);
        credit.registerMarket(bytes32(uint256(9)), _venusMarket());
        vm.expectRevert(AtpBorrowRegistry.Unauthorized.selector);
        credit.recordBorrow(address(this), VENUS_ID, 1, 1);
        vm.stopPrank();
    }

    function test_registerMarket_rejectsMismatches() public {
        B.Market memory m = _venusMarket();
        vm.expectRevert(AtpBorrowRegistry.BadMarket.selector);
        credit.registerMarket(VENUS_ID, m); // duplicate id
        m.loan = address(nvda);
        vm.expectRevert(AtpBorrowRegistry.BadMarket.selector);
        credit.registerMarket(bytes32(uint256(9)), m); // loan must be the numeraire
        m = _venusMarket();
        m.collateralVToken = address(vUsdt); // underlying mismatch
        vm.expectRevert(AtpBorrowRegistry.BadMarket.selector);
        credit.registerMarket(bytes32(uint256(9)), m);
        m = _venusMarket();
        m.vaultMarketId = bytes32(uint256(0xDEAD)); // vault must be an admitted yield market
        vm.expectRevert();
        credit.registerMarket(bytes32(uint256(9)), m);
        m = _venusMarket();
        comptroller.setCollateralFactor(address(vNvda), 0);
        vm.expectRevert(AtpBorrowRegistry.BadMarket.selector);
        credit.registerMarket(bytes32(uint256(9)), m); // zero collateral factor
        m = _listaMarket();
        m.collateral = address(usdt);
        vm.expectRevert(AtpBorrowRegistry.BadMarket.selector);
        credit.registerMarket(bytes32(uint256(9)), m);
        m = _listaMarket();
        m.retired = true;
        vm.expectRevert(AtpBorrowRegistry.BadMarket.selector);
        credit.registerMarket(bytes32(uint256(9)), m);
        m = _listaMarket();
        m.kind = B.Kind.NONE;
        vm.expectRevert(AtpBorrowRegistry.BadMarket.selector);
        credit.registerMarket(bytes32(uint256(9)), m);
    }

    function test_mocksRefuseOtherChains() public {
        vm.chainId(56);
        vm.expectRevert("lending mock: chain 97 only");
        new MockLendingOracle(address(this));
        vm.expectRevert("lending mock: chain 97 only");
        new MockMoolah(address(this));
    }
}

