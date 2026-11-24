// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ERC4626 } from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import { RoutingBase } from "./RoutingBase.sol";
import { RoutingTypes as R } from "../../../../src/atp/borrow/v2/RoutingTypes.sol";
import { IAtpBorrowExecutorV2 as IExec } from "../../../../src/atp/borrow/v2/IAtpBorrowExecutorV2.sol";
import { IAtpBorrowRegistryV2 as IReg } from "../../../../src/atp/borrow/v2/IAtpBorrowRegistryV2.sol";
import { StrategyBox } from "../../../../src/atp/borrow/v2/StrategyBox.sol";
import { AtpBorrowExecutorV2Extension } from "../../../../src/atp/borrow/v2/AtpBorrowExecutorV2Extension.sol";
import { Erc4626VaultAdapter, VaultAdapterBase } from "../../../../src/atp/borrow/v2/VaultAdapters.sol";
import { AtpBorrowExecutorV2 } from "../../../../src/atp/borrow/v2/AtpBorrowExecutorV2.sol";
import { AtpBorrowRegistryV2 } from "../../../../src/atp/borrow/v2/AtpBorrowRegistryV2.sol";
import { AtpBorrowLensV2 } from "../../../../src/atp/borrow/v2/AtpBorrowLensV2.sol";
import { TestnetToken } from "../../../../src/testnet/TestnetToken.sol";

/// @dev A plain ERC4626 vault that counts every state-changing call, can stop paying, can charge an entry
/// fee, and can call back into the executor: the behaviours the review asked to be exercised.
contract ProbeVault is ERC4626 {
    uint256 public calls;
    bool public illiquid;
    uint256 public entryFeeBps;
    address public reenter;
    bytes public reenterData;
    bool public reentered;

    constructor(IERC20 a) ERC4626(a) ERC20("probe vault", "pv") { }

    function set(bool illiquid_, uint256 entryFeeBps_) external {
        illiquid = illiquid_;
        entryFeeBps = entryFeeBps_;
    }

    function setReenter(address target, bytes calldata data) external {
        reenter = target;
        reenterData = data;
    }

    function resetCalls() external {
        calls = 0;
    }

    function _poke() private {
        ++calls;
        if (reenter != address(0)) {
            (bool ok,) = reenter.call(reenterData);
            reentered = ok;
        }
    }

    function deposit(uint256 assets, address receiver) public override returns (uint256 shares) {
        _poke();
        shares = super.deposit(assets, receiver);
        if (entryFeeBps != 0) _burn(receiver, shares * entryFeeBps / 10_000);
    }

    function withdraw(uint256 assets, address receiver, address owner) public override returns (uint256) {
        _poke();
        require(!illiquid, "illiquid");
        return super.withdraw(assets, receiver, owner);
    }

    function redeem(uint256 shares, address receiver, address owner) public override returns (uint256) {
        _poke();
        require(!illiquid, "illiquid");
        return super.redeem(shares, receiver, owner);
    }
}

/// @notice Regression tests for the independent review of PR #69 (2026-11-24). Each test fails on the code the
/// reviewer read and passes on the fix; the finding it covers is in its name.
contract RoutingReviewTest is RoutingBase {
    ProbeVault internal probe;
    bytes32 internal K_PROBE;

    function setUp() public override {
        super.setUp();
        probe = new ProbeVault(IERC20(address(usdt)));
        vm.startPrank(LENDER);
        usdt.approve(address(probe), MAX);
        probe.deposit(100_000e18, LENDER);
        vm.stopPrank();
        probe.resetCalls();
        K_PROBE = credit.registerVault(R.VaultKind.ERC4626, address(usdt), address(probe));
        _reportVault(K_PROBE);
    }

    function _reportVault(bytes32 id) internal {
        IReg.VaultReport[] memory vaults = new IReg.VaultReport[](1);
        vaults[0] = IReg.VaultReport(id, 0.045e18, 0);
        vm.prank(REPORTER);
        credit.reportRates(new IReg.RouteReport[](0), vaults);
    }

    // ---- H1: the relaxed collateral check ----

    function test_H1a_tierRemoved_collateralLeavesOnlyAgainstRepayment_lista() public {
        _open(L_TSLA_T, K_T, 10e18, 300e18);
        credit.setAssetTier(address(tsla), R.Tier.NONE);
        // The reviewer's call: no repayment, collateral out down to the venue limit.
        vm.expectRevert(abi.encodeWithSelector(IExec.LtvTooHigh.selector, 300e18, 0));
        _reduce(L_TSLA_T, bytes32(0), 0, 10e18 - 4.2858e18, 0);
        vm.expectRevert();
        _reduce(L_TSLA_T, bytes32(0), 0, 1, 0);
        // A repayment that does not keep up with the collateral leaving: health factor would drop.
        vm.expectRevert();
        _reduce(L_TSLA_T, K_T, 30e18, 5e18, 0);
        _reduce(L_TSLA_T, K_T, MAX, MAX, 0);
        assertEq(tsla.balanceOf(address(this)), 1_000e18);
    }

    function test_H1a_tierRemoved_collateralLeavesOnlyAgainstRepayment_venus() public {
        _open(V_NVDA_T, K_T, 10e18, 300e18);
        credit.setAssetTier(address(nvda), R.Tier.NONE);
        vm.expectRevert();
        _reduce(V_NVDA_T, bytes32(0), 0, 4.99e18, 0);
        vm.expectRevert();
        _reduce(V_NVDA_T, K_T, 30e18, 5e18, 0);
        R.Health memory h = _health(V_NVDA_T);
        assertEq(h.collateralValue, 1_000e18, "nothing left the venue");
        _reduce(V_NVDA_T, K_T, MAX, MAX, 0);
        assertEq(nvda.balanceOf(address(this)), 1_000e18);
    }

    /// R3: an asset that lost its tier has no budget, but its position can be wound down in steps: every step
    /// must leave the health factor no lower than it found it.
    function test_R3_tierRemoved_positionCanBeWoundDownInSteps() public {
        _open(L_TSLA_T, K_T, 10e18, 300e18);
        _open(V_NVDA_T, K_T, 10e18, 300e18);
        credit.setAssetTier(address(tsla), R.Tier.NONE);
        credit.setAssetTier(address(nvda), R.Tier.NONE);
        bytes32[2] memory ids = [L_TSLA_T, V_NVDA_T];
        for (uint256 i; i < 2; ++i) {
            R.Health memory before = _health(ids[i]);
            assertEq(before.budgetValue, 0, "no budget");
            // The reviewer's probe: repay half, take a tenth of the collateral.
            _reduce(ids[i], K_T, 150e18, 1e18, 0);
            R.Health memory h = _health(ids[i]);
            assertGt(h.healthFactor, before.healthFactor);
            // An exactly proportional step keeps the health factor; one unit of collateral more does not.
            uint256 owed = lens.debt(ids[i], address(this));
            vm.expectRevert();
            lend.executeReduce(address(this), ids[i], K_T, owed / 3, 3e18 + 1e12, 0, block.timestamp);
            _reduce(ids[i], K_T, owed / 3 + 1e12, 3e18, 0);
            assertGe(_health(ids[i]).healthFactor, h.healthFactor);
            // No new debt and no new collateral on a route without a tier.
            vm.expectRevert();
            lend.executeOpen(address(this), ids[i], K_T, 0, 1e18, block.timestamp);
        }
    }

    function test_H1b_venusMixedCollateral_healthFactorMayNotDrop() public {
        comptroller.setCollateralFactor(address(vTsla), 0.9e18);
        credit.setAssetTier(address(tsla), R.Tier.CRYPTO_LINKED); // target 20%, deleverage 60%
        _open(V_TSLA_T, K_T, 10e18, 0);
        _open(V_NVDA_T, K_T, 1e18, 230e18); // budget 200 + 30
        oracle.setPrice(address(tsla), 40e8);
        oracle.setPrice(address(nvda), 40e8);
        R.Health memory before = _health(V_NVDA_T);
        assertGt(before.debtValue, before.budgetValue, "past the budget");
        assertLt(before.debtValue, before.deleverageValue, "not deleverageable");
        // The reviewer's call keeps debt / budget but swaps the mix towards the collateral Venus values less:
        // health factor 1.67 -> 1.07. Refused now.
        vm.expectRevert();
        _reduce(V_TSLA_T, K_T, 189e18, 9.45e18, 0);
        // Taking the low-factor collateral out against the same repayment raises the health factor: allowed.
        _reduce(V_NVDA_T, K_T, 30e18, 1e18, 0);
        R.Health memory h = _health(V_TSLA_T);
        assertGe(h.healthFactor, before.healthFactor);
        assertLe(h.debtValue * before.budgetValue, before.debtValue * h.budgetValue);
        // A proportional cut of the high-factor collateral keeps both measures: allowed.
        before = h;
        _reduce(V_TSLA_T, K_T, 100e18, 5e18, 0);
        h = _health(V_TSLA_T);
        assertGe(h.healthFactor, before.healthFactor);
    }

    // ---- M1: repayment never needs an oracle ----

    function test_M1_repayWorksWhileTheOracleCannotPrice() public {
        _open(L_TSLA_T, K_T, 10e18, 300e18);
        _open(V_NVDA_T, K_T, 10e18, 100e18);
        oracle.setPrice(address(tsla), 0); // the lending oracle now reverts for TSLA
        _reduce(L_TSLA_T, K_T, 100e18, 0, 0);
        assertApproxEqAbs(lens.debt(L_TSLA_T, address(this)), 200e18, 1);
        _reduce(L_TSLA_T, K_T, MAX, 0, 0); // full repayment, still no price
        assertEq(lens.debt(L_TSLA_T, address(this)), 0);
        // With no debt left in this market, its collateral leaves without a price too.
        _reduce(L_TSLA_T, bytes32(0), 0, MAX, 0);
        assertEq(tsla.balanceOf(address(this)), 1_000e18);

        // Venus: an entered market without a price no longer blocks repaying.
        oracle.setPrice(address(tsla), PRICE_E8);
        oracle.setPrice(address(nvda), 0);
        _reduce(V_NVDA_T, K_T, 50e18, 0, 0);
        _reduce(V_NVDA_T, K_T, MAX, 0, 0);
        assertEq(lens.debt(V_NVDA_T, address(this)), 0);
        // What does read prices fails closed: deleverage (it must know the health line) and new borrowing.
        oracle.setPrice(address(nvda), PRICE_E8);
        _open(V_NVDA_T, K_T, 0, 100e18);
        oracle.setPrice(address(nvda), 0);
        vm.prank(KEEPER);
        vm.expectRevert();
        lend.executeDeleverage(address(this), V_NVDA_T, K_T, MAX);
        vm.expectRevert();
        _open(V_NVDA_T, K_T, 0, 1e18);
    }

    // ---- M3: one call into a vault per action ----

    function test_M3_vaultIsCalledOnce_partialRepay_shortHolding_andClose() public {
        _open(L_TSLA_T, K_PROBE, 10e18, 300e18);
        assertEq(probe.calls(), 1, "deposit");
        probe.resetCalls();
        _reduce(L_TSLA_T, K_PROBE, 100e18, 0, 0);
        assertEq(probe.calls(), 1, "partial repay");
        // The holding is smaller than the repayment asked: one call takes all of it, the account's own
        // token covers the rest (no failed attempt followed by a second one).
        probe.resetCalls();
        usdt.mint(address(this), 50e18);
        usdt.approve(address(lend), MAX);
        address box = _box();
        uint256 half = probe.balanceOf(box) / 2;
        vm.prank(box);
        probe.transfer(address(0xdead), half); // half the holding vanishes
        _reduce(L_TSLA_T, K_PROBE, 150e18, 0, 50e18);
        assertEq(probe.calls(), 1, "short holding");
        // Close: everything out in one call, the surplus to the account, no separate release call.
        _open(L_TSLA_T, K_PROBE, 0, 100e18);
        probe.resetCalls();
        usdt.mint(address(this), 60e18);
        _reduce(L_TSLA_T, K_PROBE, MAX, MAX, 60e18);
        assertEq(probe.calls(), 1, "close");
        assertEq(probe.balanceOf(_box()), 0);
        _noResidue();
    }

    function test_M3_vaultThatCannotPay_isNotRetried_closeFallsBackToCash() public {
        _open(L_TSLA_T, K_PROBE, 10e18, 300e18);
        probe.set(true, 0);
        probe.resetCalls();
        usdt.mint(address(this), 300e18);
        usdt.approve(address(lend), MAX);
        // MAX close with a vault that refuses: one failed call, repayment from cash, and no release retry.
        // (Counted over the whole test: this one failed call, plus the release at the end. A retry of the
        // failed vault, or a release attempt inside the close, would make it three.)
        vm.expectCall(address(probe), abi.encodeWithSelector(ERC4626.redeem.selector), 2);
        vm.expectCall(address(probe), abi.encodeWithSelector(ERC4626.withdraw.selector), 0);
        _reduce(L_TSLA_T, K_PROBE, MAX, MAX, 300e18);
        assertEq(lens.debt(L_TSLA_T, address(this)), 0);
        assertEq(tsla.balanceOf(address(this)), 1_000e18);
        assertGt(probe.balanceOf(_box()), 0, "holding waits in the box");
        probe.set(false, 0);
        lend.executeRelease(address(this), K_PROBE, block.timestamp);
        assertApproxEqAbs(usdt.balanceOf(address(this)), 300e18, 2);
    }

    // ---- M4: switch vault passes the deposit gates ----

    function test_M4_switchVault_respectsUtilizationGate_andPausedEnrollment() public {
        _open(L_TSLA_T, K_T, 10e18, 300e18);
        aaveT.setLiquidity(1_000_000e18 / 100); // 99% utilized
        assertEq(uint8(lens.quote(L_TSLA_T, K_AT).gate), uint8(R.Gate.VAULT_UTILIZATION));
        vm.expectRevert(abi.encodeWithSelector(IExec.GateClosed.selector, uint8(R.Gate.VAULT_UTILIZATION)));
        lend.executeSwitchVault(address(this), K_T, K_AT, MAX, block.timestamp);
        aaveT.setLiquidity(1_000_000e18 / 10); // exactly 90%: allowed
        registry.setPaused(address(this), true);
        vm.expectRevert(IReg.AdmissionClosed.selector);
        lend.executeSwitchVault(address(this), K_T, K_AT, MAX, block.timestamp);
        registry.setPaused(address(this), false);
        lend.executeSwitchVault(address(this), K_T, K_AT, MAX, block.timestamp);
        assertGt(IERC20(aaveT.receipt()).balanceOf(_box()), 299e18);
        // Leaving a vault that is over the line stays possible.
        aaveT.setLiquidity(1_000_300e18 / 100);
        lend.executeSwitchVault(address(this), K_AT, K_T, 3_000e18 > 0 ? 100e18 : 0, block.timestamp);
    }

    // ---- M5: rescue and the adapter binding ----

    function test_M5_rescue_sendsReceiptsToTheAccount_onlyWithoutDebt() public {
        _open(L_TSLA_T, K_PROBE, 10e18, 300e18);
        uint256 shares = probe.balanceOf(_box());
        vm.expectRevert(abi.encodeWithSelector(IExec.DebtOutstanding.selector, 300e18));
        lend.executeRescue(address(this), K_PROBE, block.timestamp);
        vm.prank(KEEPER);
        vm.expectRevert(IExec.NotAccount.selector);
        lend.executeRescue(address(this), K_PROBE, block.timestamp);
        // The vault breaks: nothing can be withdrawn through it. The debt is repaid from the account's own
        // token, then the receipts themselves come back without the vault or its adapter being called.
        probe.set(true, 0);
        usdt.mint(address(this), 300e18);
        usdt.approve(address(lend), MAX);
        _reduce(L_TSLA_T, bytes32(0), MAX, MAX, 300e18);
        vm.expectRevert();
        lend.executeRelease(address(this), K_PROBE, block.timestamp);
        probe.resetCalls();
        vm.expectEmit(true, true, false, true, address(lend));
        emit IExec.Rescued(address(this), K_PROBE, address(probe), shares);
        lend.executeRescue(address(this), K_PROBE, block.timestamp);
        assertEq(probe.calls(), 0, "the vault was not called");
        assertEq(probe.balanceOf(address(this)), shares);
        assertEq(probe.balanceOf(_box()), 0);
        assertEq(credit.accountVaults(address(this)).length, 0);
        vm.expectRevert(IExec.NothingToDo.selector);
        lend.executeRescue(address(this), K_PROBE, block.timestamp);
    }

    function test_M5_setAdapter_requiresAnAdapterOfThisExecutor() public {
        // A fresh trio: an adapter built for another executor is refused on chain.
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 2);
        AtpBorrowRegistryV2 other =
            new AtpBorrowRegistryV2(registry, address(atp), predicted, address(comptroller), address(moolah));
        AtpBorrowLensV2 otherLens = new AtpBorrowLensV2(other);
        AtpBorrowExecutorV2 otherLend = new AtpBorrowExecutorV2(other, otherLens, address(extension));
        vm.expectRevert(IReg.BadParameter.selector);
        other.setAdapter(R.VaultKind.ERC4626, address(erc4626Adapter)); // bound to the first executor
        other.setAdapter(R.VaultKind.ERC4626, address(new Erc4626VaultAdapter(address(otherLend))));
    }

    // ---- L3: the box confirms the Lista text, hashed the personal_sign way, and nothing else ----

    function test_L3_box_plainKeccakOfAnEip712Preimage_isRefused() public {
        _open(L_TSLA_T, K_T, 10e18, 100e18);
        StrategyBox box = StrategyBox(_box());
        bytes32 domain = keccak256("some token domain");
        bytes32 structHash = keccak256("Permit(owner=box,spender=attacker,value=max)");
        bytes memory preimage = abi.encodePacked("\x19\x01", domain, structHash);
        bytes32 digest = keccak256(preimage);
        credit.setRewardProofSuffix(abi.encodePacked(structHash)); // even with a hostile suffix
        signed[digest] = true; // and an account that validates the digest
        assertEq(box.isValidSignature(digest, abi.encode(preimage, bytes("x"))), bytes4(0xffffffff));
        // The suffix itself is bounded.
        vm.expectRevert(IReg.BadParameter.selector);
        credit.setRewardProofSuffix(new bytes(65));
        vm.expectRevert(IReg.BadParameter.selector);
        credit.setRewardProofSuffix(new bytes(15));
    }

    // ---- L4: ERC4626 deposits are checked for value ----

    function test_L4_emptyVaultCannotBeListed_andAFeeOnDepositIsRefused() public {
        ProbeVault empty = new ProbeVault(IERC20(address(usdt)));
        vm.expectRevert(VaultAdapterBase.BadVault.selector);
        credit.registerVault(R.VaultKind.ERC4626, address(usdt), address(empty));
        // A listed vault that starts crediting less than what is deposited (here: a 1% entry fee).
        probe.set(false, 100);
        vm.expectRevert(IExec.InexactTransfer.selector);
        _open(L_TSLA_T, K_PROBE, 10e18, 300e18);
        // A donation that inflates the share price of a listed vault costs the depositor nothing.
        probe.set(false, 0);
        usdt.mint(KEEPER, 5_000e18);
        vm.prank(KEEPER);
        usdt.transfer(address(probe), 5_000e18);
        _open(L_TSLA_T, K_PROBE, 10e18, 300e18);
        assertGe(probe.previewRedeem(probe.balanceOf(_box())), 300e18 - 300e18 / 10_000);
    }

    // ---- L5: principal follows the shared Venus debt ----

    function test_L5_repayingThroughASiblingVenusRoute_retiresTheRealPrincipal() public {
        _open(V_NVDA_T, K_T, 10e18, 300e18);
        _open(V_TSLA_T, bytes32(0), 1e18, 0); // a sibling route in the same loan token, nothing borrowed
        oracle.setPrice(address(nvda), 50e8);
        vm.prank(KEEPER);
        uint256 repaid = lend.executeDeleverage(address(this), V_TSLA_T, K_T, MAX);
        assertGt(repaid, 0);
        assertEq(credit.principal(address(this), V_NVDA_T), 300e18 - repaid);
        assertEq(credit.accountPrincipalUsd(address(this)), 300e18 - repaid);
        assertEq(credit.totalPrincipal(V_NVDA_T), 300e18 - repaid);
        // A cash repayment through the sibling does the same, and the ceiling frees up with it.
        usdt.mint(address(this), 100e18);
        usdt.approve(address(lend), MAX);
        _reduce(V_TSLA_T, bytes32(0), 100e18, 0, 100e18);
        assertEq(credit.principal(address(this), V_NVDA_T), 200e18 - repaid);
        assertEq(lens.routeDebt(V_NVDA_T, address(this)), lens.debt(V_NVDA_T, address(this)));
    }

    // ---- L6: debt this registry did not open ----

    function test_L6_accountWithForeignVenusDebt_cannotOpen() public {
        // The account borrows USDT on Venus outside v2 (what a v1 position on the same account looks like).
        nvda.approve(address(vNvda), MAX);
        vNvda.mint(5e18);
        address[] memory markets = new address[](1);
        markets[0] = address(vNvda);
        comptroller.enterMarkets(markets);
        vUsdt.borrow(50e18);
        vm.expectRevert(IReg.ForeignDebt.selector);
        _open(V_NVDA_T, K_T, 5e18, 0);
        vm.expectRevert(IReg.ForeignDebt.selector);
        _open(V_TSLA_T, K_T, 5e18, 100e18);
        // Other loan tokens and Lista are separate debts and stay open.
        _open(V_TSLA_C, K_C, 5e18, 0);
        _open(L_TSLA_T, K_T, 5e18, 100e18);
        // Once the foreign debt is gone the account can use the route.
        usdt.approve(address(vUsdt), MAX);
        vUsdt.repayBorrow(50e18);
        _open(V_NVDA_T, K_T, 1e18, 10e18);
    }

    /// R2: repayments retire principal first, so "principal repaid, interest left" is the account's own v2
    /// debt, not foreign debt: the route stays usable.
    function test_R2_interestLeftAfterThePrincipal_isNotForeignDebt() public {
        _open(V_NVDA_T, K_T, 10e18, 100e18);
        skip(30 days);
        _report(uint256(VAULT_APR) * 1e14, 0, 0);
        _reduce(V_NVDA_T, K_T, 100e18, 0, 0); // exactly the principal
        assertEq(credit.principal(address(this), V_NVDA_T), 0);
        assertEq(credit.venusPrincipal(address(this), address(usdt)), 0);
        assertGt(lens.debt(V_NVDA_T, address(this)), 0, "interest is left");
        _open(V_NVDA_T, bytes32(0), 1e18, 0); // the reviewer's call: collateral only
        _open(V_NVDA_T, K_T, 0, 50e18); // new borrowing
        _open(V_TSLA_T, K_T, 5e18, 20e18); // another Venus route of the token
        _open(L_TSLA_T, K_T, 5e18, 30e18);
        _migrate(L_TSLA_T, K_T, V_TSLA_T, K_T, 30e18, 0); // a migration into the token's Venus routes
    }

    /// R2, the two-routes-one-collateral case: the route whose principal is repaid keeps its place in the
    /// account's list while interest in its token is left, and leaves it once that is repaid.
    function test_R2_sharedCollateral_positionStaysWhileItsTokenIsOwed() public {
        _open(V_NVDA_T, K_T, 10e18, 100e18);
        _open(V_NVDA_C, K_C, 0, 100e18);
        skip(30 days);
        _report(uint256(VAULT_APR) * 1e14, 0, 0);
        _reduce(V_NVDA_T, K_T, 100e18, 0, 0);
        assertGt(lens.debt(V_NVDA_T, address(this)), 0, "interest is left");
        assertEq(credit.accountRoutes(address(this)).length, 2, "USDT debt keeps its position");
        _open(V_NVDA_T, K_T, 0, 10e18);
        _reduce(V_NVDA_T, K_T, MAX, 0, 0);
        bytes32[] memory ids = credit.accountRoutes(address(this));
        assertEq(ids.length, 1);
        assertEq(ids[0], V_NVDA_C);
        // Debt in a token the account holds no Venus position for is still foreign.
        vUsdt.borrow(1e18);
        vm.expectRevert(IReg.ForeignDebt.selector);
        _open(V_NVDA_T, K_T, 0, 10e18);
    }

    // ---- L8 ----

    function test_L8_unlistedVenusCollateral_keepsADeleverageLine() public {
        // QQQ has a Venus market the registry never listed: it adds no budget but its line still counts.
        // (Without the fix the account's deleverage value ignored it.)
        _open(V_NVDA_T, K_T, 10e18, 300e18);
        R.Health memory h = _health(V_NVDA_T);
        assertEq(h.deleverageValue, 400e18);
        credit.setAssetTier(address(nvda), R.Tier.NONE);
        h = _health(V_NVDA_T);
        assertEq(h.budgetValue, 0);
        assertEq(h.deleverageValue, 400e18, "a collateral without a tier keeps its line");
        oracle.setPrice(address(nvda), 70e8); // 300 / 700 = 42.9% >= 40%
        vm.prank(KEEPER);
        uint256 repaid = lend.executeDeleverage(address(this), V_NVDA_T, K_T, MAX);
        assertApproxEqAbs(repaid, 300e18, 2, "no budget: the whole debt is repaid from the box");
    }

    function test_L8_fullVaultList_neverBlocksAnExit() public {
        _open(L_TSLA_T, K_T, 10e18, 300e18);
        // Someone sends the box shares of a vault it never deposited into; exits through it must work even if
        // the account's vault list were full (exit paths only ever remove from the list).
        address box = _box();
        vm.prank(LENDER);
        probe.transfer(box, 10e18);
        assertEq(credit.accountVaults(address(this)).length, 1);
        vm.prank(box);
        probe.approve(address(erc4626Adapter), MAX);
        _reduce(L_TSLA_T, K_PROBE, 5e18, 0, 0);
        assertEq(credit.accountVaults(address(this)).length, 1, "an exit does not add the vault");
        _reduce(L_TSLA_T, K_T, MAX, MAX, 0);
    }

    function test_L8_venusToVenusMigrate_keepsOnePosition_evenWhenTheListIsFull() public {
        // 23 Lista collateral-only positions + the Venus one = 24 (the maximum).
        for (uint256 i; i < 23; ++i) {
            TestnetToken token = new TestnetToken("extra", "X", 18, address(this));
            oracle.setPrice(address(token), PRICE_E8);
            moolah.createMarket(_params(usdt, token, 0.6e18), BORROW_APR);
            credit.setAssetTier(address(token), R.Tier.STOCK);
            bytes32 id = credit.registerRoute(
                R.Venue.LISTA, address(token), address(usdt), _id(usdt, token, 0.6e18), 1e18
            );
            token.mint(address(this), 1e18);
            token.approve(address(lend), MAX);
            _open(id, bytes32(0), 1e18, 0);
        }
        _open(V_NVDA_T, K_T, 10e18, 300e18);
        assertEq(credit.accountRoutes(address(this)).length, 24);
        vm.expectRevert(IReg.TooManyPositions.selector);
        _open(V_TSLA_T, bytes32(0), 1e18, 0);
        _migrate(V_NVDA_T, K_T, V_NVDA_C, K_C, 300e18, 1e18);
        bytes32[] memory routes = credit.accountRoutes(address(this));
        assertEq(routes.length, 24);
        assertEq(routes[23], V_NVDA_C, "the new route took the old one's place");
        assertEq(lens.debt(V_NVDA_C, address(this)), 300e18);
    }

    // ---- the extension is the executor's code, nothing more ----

    function test_extension_onlyRunsAsTheExecutor() public {
        assertEq(lend.extension(), address(extension));
        vm.expectRevert(AtpBorrowExecutorV2Extension.OnlyDelegated.selector);
        extension.collectRewards(address(this), address(lista));
        vm.expectRevert(AtpBorrowExecutorV2Extension.OnlyDelegated.selector);
        extension.executeRescue(address(this), K_T, block.timestamp);
        vm.expectRevert(AtpBorrowExecutorV2Extension.OnlyDelegated.selector);
        extension.executeSwitchVault(address(this), K_T, K_AT, 1, block.timestamp);
        vm.expectRevert(AtpBorrowExecutorV2Extension.OnlyDelegated.selector);
        extension.executeRelease(address(this), K_T, block.timestamp);
        vm.expectRevert(AtpBorrowExecutorV2Extension.OnlyDelegated.selector);
        extension.executeSweepRewards(address(this), address(lista), 0, block.timestamp);
        // A selector neither half implements reverts.
        (bool ok,) = address(lend).call(abi.encodeWithSignature("transferOwnership(address)", KEEPER));
        assertFalse(ok);
        (ok,) = address(lend).call{ value: 0 }("");
        assertFalse(ok);
    }

    function test_reentrancy_fromAVault_isRefusedInBothHalves() public {
        _open(L_TSLA_T, K_T, 10e18, 100e18);
        // During its deposit the vault calls back into the main half...
        probe.setReenter(
            address(lend), abi.encodeCall(IExec.executeDeleverage, (address(this), L_TSLA_T, K_T, MAX))
        );
        _open(L_TSLA_T, K_PROBE, 0, 50e18);
        assertFalse(probe.reentered(), "main half reentered");
        // ...and into the extension half (through the fallback).
        probe.setReenter(address(lend), abi.encodeCall(IExec.collectRewards, (address(this), address(lista))));
        lista.mint(_box(), 1e18);
        _reduce(L_TSLA_T, K_PROBE, 10e18, 0, 0);
        assertFalse(probe.reentered(), "extension half reentered");
        assertEq(lista.balanceOf(_box()), 1e18);
    }
}
