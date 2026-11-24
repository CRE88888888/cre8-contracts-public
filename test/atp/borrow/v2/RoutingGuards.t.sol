// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { RoutingBase } from "./RoutingBase.sol";
import { RoutingTypes as R } from "../../../../src/atp/borrow/v2/RoutingTypes.sol";
import { IAtpBorrowExecutorV2 as IExec } from "../../../../src/atp/borrow/v2/IAtpBorrowExecutorV2.sol";
import { IAtpBorrowRegistryV2 as IReg } from "../../../../src/atp/borrow/v2/IAtpBorrowRegistryV2.sol";
import { AtpBorrowRegistryV2 } from "../../../../src/atp/borrow/v2/AtpBorrowRegistryV2.sol";
import { AtpBorrowExecutorV2 } from "../../../../src/atp/borrow/v2/AtpBorrowExecutorV2.sol";
import { AtpBorrowLensV2 } from "../../../../src/atp/borrow/v2/AtpBorrowLensV2.sol";
import { Erc4626VaultAdapter } from "../../../../src/atp/borrow/v2/VaultAdapters.sol";
import { VaultAdapterBase } from "../../../../src/atp/borrow/v2/VaultAdapters.sol";
import { MockEarnVault } from "../../../../src/testnet/lending/MockEarnVault.sol";
import { TestnetToken } from "../../../../src/testnet/TestnetToken.sol";

/// @notice Open gates, consent, caps, pauses, the rate reports and the owner-only configuration.
contract RoutingGuardsTest is RoutingBase {
    function _gate(bytes32 route, bytes32 vault) internal returns (R.Gate) {
        return lens.quote(route, vault).gate;
    }

    function _expectGate(R.Gate gate) internal {
        vm.expectRevert(abi.encodeWithSelector(IExec.GateClosed.selector, uint8(gate)));
    }

    // ---- carry ----

    function test_carry_exactlyZero_opens_negative_closes() public {
        // Vault rate equal to the borrow rate = carry 0: open. One unit less: closed.
        uint256 rate = lens.quote(L_TSLA_T, K_T).borrowRate;
        assertApproxEqRel(rate, 0.025e18, 1e12);
        _report(rate, 0, 0);
        R.Quote memory q = lens.quote(L_TSLA_T, K_T);
        assertEq(q.carry, 0);
        assertEq(uint8(q.gate), uint8(R.Gate.OPEN));
        _report(rate - 1, 0, 0);
        q = lens.quote(L_TSLA_T, K_T);
        assertEq(q.carry, -1);
        assertEq(uint8(q.gate), uint8(R.Gate.NEGATIVE_CARRY));
        _expectGate(R.Gate.NEGATIVE_CARRY);
        _open(L_TSLA_T, K_T, 10e18, 100e18);
        // Incentives on either side count.
        _report(0.02e18, 0.005e18, 0);
        assertEq(uint8(_gate(L_TSLA_T, K_T)), uint8(R.Gate.OPEN));
        _report(0.02e18, 0, 0.005e18);
        assertEq(uint8(_gate(L_TSLA_T, K_T)), uint8(R.Gate.OPEN));
        q = lens.quote(L_TSLA_T, K_T);
        assertEq(q.borrowRate, rate);
        assertEq(q.vaultRate, 0.02e18);
        assertEq(q.borrowIncentiveRate, 0.005e18);
        assertEq(q.targetLtv, 0.3e18);
    }

    function test_carry_onChainRates_aaveAndVenus() public {
        // Aave publishes 3.5% on chain: open without any report.
        skip(3 days);
        assertEq(uint8(_gate(L_TSLA_T, K_AT)), uint8(R.Gate.OPEN));
        R.VaultStatus memory s = lens.vaultStatus(K_AT, address(this));
        assertTrue(s.rateOnChain && s.rateKnown && s.utilizationKnown);
        assertEq(s.supplyRate, 0.035e18);
        // Venus vUSDC supply rate is on chain too, and below the borrow rate.
        s = lens.vaultStatus(K_VC, address(0));
        assertTrue(s.rateOnChain);
        assertLt(s.supplyRate, 0.025e18);
        assertEq(uint8(_gate(L_QQQ_C, K_VC)), uint8(R.Gate.NEGATIVE_CARRY));
        // The ERC4626 vault has no on-chain rate: the report expired with the 3 days.
        s = lens.vaultStatus(K_T, address(0));
        assertFalse(s.rateOnChain);
        assertFalse(s.rateKnown);
        assertFalse(s.utilizationKnown);
        assertEq(uint8(_gate(L_TSLA_T, K_T)), uint8(R.Gate.VAULT_UNREADABLE));
    }

    function test_report_expiresAfter48Hours_exactly() public {
        skip(48 hours);
        assertEq(uint8(_gate(L_TSLA_T, K_T)), uint8(R.Gate.OPEN));
        skip(1);
        assertEq(uint8(_gate(L_TSLA_T, K_T)), uint8(R.Gate.VAULT_UNREADABLE));
        _expectGate(R.Gate.VAULT_UNREADABLE);
        _open(L_TSLA_T, K_T, 10e18, 100e18);
    }

    function test_reportRates_onlyReporter_bounded_andBatchGas() public {
        IReg.RouteReport[] memory routes = new IReg.RouteReport[](1);
        IReg.VaultReport[] memory vaults = new IReg.VaultReport[](0);
        routes[0] = IReg.RouteReport(L_TSLA_T, 0.01e18, 0);
        vm.expectRevert(IReg.Unauthorized.selector);
        credit.reportRates(routes, vaults);
        routes[0].borrowIncentive = 0.5e18 + 1;
        vm.prank(REPORTER);
        vm.expectRevert(IReg.BadParameter.selector);
        credit.reportRates(routes, vaults);
        routes[0] = IReg.RouteReport(bytes32(uint256(1)), 0, 0);
        vm.prank(REPORTER);
        vm.expectRevert(IReg.UnknownRoute.selector);
        credit.reportRates(routes, vaults);

        // 40 routes + 10 vaults in one transaction (entries may repeat an id).
        routes = new IReg.RouteReport[](40);
        vaults = new IReg.VaultReport[](10);
        for (uint256 i; i < 40; ++i) {
            routes[i] = IReg.RouteReport(credit.routeIds(i % credit.routeCount()), 0.01e18, 0.002e18);
        }
        for (uint256 i; i < 10; ++i) {
            vaults[i] = IReg.VaultReport(credit.vaultIds(i % credit.vaultCount()), 0.03e18, 0.01e18);
        }
        vm.prank(REPORTER);
        uint256 gas = gasleft();
        credit.reportRates(routes, vaults);
        gas -= gasleft();
        emit log_named_uint("reportRates(40 routes, 10 vaults) gas", gas);
        assertLt(gas, 1_000_000);
        (bool fresh, uint256 a, uint256 b) = credit.freshReport(L_TSLA_T);
        assertTrue(fresh);
        assertEq(a, 0.01e18);
        assertEq(b, 0.002e18);
        R.RouteStatus memory s = lens.routeStatus(L_TSLA_T, address(0));
        assertEq(s.borrowIncentiveRate, 0.01e18);
        assertEq(s.collateralIncentiveRate, 0.002e18);
    }

    // ---- utilization ----

    /// @dev Another borrower takes `amount` USDT out of the Lista TSLA/USDT market (1,000,000 supplied).
    function _otherBorrows(uint256 amount) internal {
        tsla.mint(LIQUIDATOR, 100_000e18);
        vm.startPrank(LIQUIDATOR);
        tsla.approve(address(moolah), MAX);
        moolah.supplyCollateral(_params(usdt, tsla, 0.7e18), 100_000e18, LIQUIDATOR, "");
        moolah.borrow(_params(usdt, tsla, 0.7e18), amount, 0, LIQUIDATOR, LIQUIDATOR);
        vm.stopPrank();
    }

    function test_borrowUtilization_default95_openAt927_blockedAbove95_exitsUnaffected() public {
        assertEq(credit.MAX_BORROW_UTILIZATION_BPS(), 9_500);
        assertEq(credit.route(L_TSLA_T).maxUtilizationBps, 9_500);
        // The market sits at 92.67%, like Lista's NVDAB/USD1 on mainnet: opening is allowed (92.7% after).
        _otherBorrows(926_700e18);
        _open(L_TSLA_T, bytes32(0), 1_000e18, 0);
        _open(L_TSLA_T, K_T, 0, 300e18);
        (uint256 utilization,) = lens.borrowMarket(L_TSLA_T);
        assertEq(utilization, 9_270);
        assertEq(uint8(_gate(L_TSLA_T, K_T)), uint8(R.Gate.OPEN));
        // Up to exactly 95% is allowed; one raw unit above is closed.
        _expectGate(R.Gate.BORROW_UTILIZATION);
        _open(L_TSLA_T, K_T, 0, 23_000e18 + 1);
        _open(L_TSLA_T, K_T, 0, 1_000e18);
        // Someone else pushes the market past 95%: no new borrowing...
        vm.prank(LIQUIDATOR);
        moolah.borrow(_params(usdt, tsla, 0.7e18), 30_000e18, 0, LIQUIDATOR, LIQUIDATOR);
        (utilization,) = lens.borrowMarket(L_TSLA_T);
        assertGt(utilization, 9_500);
        assertEq(uint8(_gate(L_TSLA_T, K_T)), uint8(R.Gate.BORROW_UTILIZATION));
        _expectGate(R.Gate.BORROW_UTILIZATION);
        _open(L_TSLA_T, K_T, 0, 1e18);
        // ...while collateral top-ups and every exit are unaffected: partial repay, anyone's deleverage,
        // collateral return, full close with the payout.
        tsla.mint(address(this), 1e18);
        _open(L_TSLA_T, bytes32(0), 1e18, 0);
        _reduce(L_TSLA_T, K_T, 300e18, 0, 0);
        oracle.setPrice(address(tsla), 2e8);
        vm.prank(KEEPER);
        assertGt(lend.executeDeleverage(address(this), L_TSLA_T, K_T, MAX), 0);
        oracle.setPrice(address(tsla), PRICE_E8);
        _reduce(L_TSLA_T, K_T, 0, 10e18, 0);
        _reduce(L_TSLA_T, K_T, MAX, MAX, 0);
        assertEq(lens.debt(L_TSLA_T, address(this)), 0);
        assertEq(tsla.balanceOf(address(this)), 1_001e18);
        assertEq(credit.accountRoutes(address(this)).length, 0);
    }

    function test_borrowUtilization_gate_exactBoundary_andPerRoute() public {
        _otherBorrows(949_900e18);
        _open(L_TSLA_T, bytes32(0), 10e18, 0);
        // 100 more is exactly 95%: allowed. One raw unit above: closed.
        _expectGate(R.Gate.BORROW_UTILIZATION);
        _open(L_TSLA_T, K_T, 0, 100e18 + 1);
        _open(L_TSLA_T, K_T, 0, 100e18);
        (uint256 utilization,) = lens.borrowMarket(L_TSLA_T);
        assertEq(utilization, 9_500);
        _expectGate(R.Gate.BORROW_UTILIZATION);
        _open(L_TSLA_T, K_T, 0, 1e18);
        // The owner may give one route its own limit, looser or tighter.
        vm.prank(KEEPER);
        vm.expectRevert(IReg.Unauthorized.selector);
        credit.setRouteMaxUtilization(L_TSLA_T, 9_800);
        vm.expectRevert(IReg.BadParameter.selector);
        credit.setRouteMaxUtilization(L_TSLA_T, 10_001);
        vm.expectRevert(IReg.BadParameter.selector);
        credit.setRouteMaxUtilization(L_TSLA_T, 0);
        credit.setRouteMaxUtilization(L_TSLA_T, 9_800);
        _open(L_TSLA_T, K_T, 0, 1e18);
        assertEq(credit.route(L_TSLA_T).maxUtilizationBps, 9_800);
        credit.setRouteMaxUtilization(L_TSLA_T, 8_500);
        _expectGate(R.Gate.BORROW_UTILIZATION);
        _open(L_TSLA_T, K_T, 0, 1e18);
        // Other routes keep the default.
        assertEq(credit.route(L_TSLA_C).maxUtilizationBps, 9_500);
    }

    function test_vaultUtilization_gate_whereReadable() public {
        // Aave USDT pool: 1,000,000 supplied. Park 900,000 as borrows -> 90% exactly: open; above: closed.
        aaveT.setLiquidity(100_000e18);
        assertEq(uint8(_gate(L_TSLA_T, K_AT)), uint8(R.Gate.OPEN));
        aaveT.setLiquidity(100_000e18 - 1e18);
        assertEq(uint8(_gate(L_TSLA_T, K_AT)), uint8(R.Gate.VAULT_UTILIZATION));
        _expectGate(R.Gate.VAULT_UTILIZATION);
        _open(L_TSLA_T, K_AT, 10e18, 100e18);
    }

    // ---- pauses, switches, caps ----

    function test_pauses_onlyStopNewRisk() public {
        _open(L_TSLA_T, K_T, 10e18, 150e18);
        credit.setPaused(true);
        assertEq(uint8(_gate(L_TSLA_T, K_T)), uint8(R.Gate.CLOSED));
        vm.expectRevert(IReg.AdmissionClosed.selector);
        _open(L_TSLA_T, K_T, 1e18, 0);
        vm.expectRevert(IReg.AdmissionClosed.selector);
        lend.executeSwitchVault(address(this), K_T, K_AT, 1e18, block.timestamp);
        credit.setPaused(false);
        atp.setGlobalPaused(true);
        vm.expectRevert(IReg.AdmissionClosed.selector);
        _open(L_TSLA_T, K_T, 0, 10e18);
        assertFalse(credit.routeOpen(L_TSLA_T));
        assertFalse(credit.vaultOpen(K_T));
        credit.setRoute(L_TSLA_T, false, true);
        credit.setVault(K_T, false, true);
        credit.setLoanToken(address(usdt), false);
        credit.setAssetTier(address(tsla), R.Tier.NONE);
        // Everything is shut and retired; repayment, collateral return and payout still work. An asset
        // without a tier has no budget: its collateral comes back only once the debt is gone.
        _reduce(L_TSLA_T, K_T, 50e18, 0, 0);
        vm.expectRevert();
        _reduce(L_TSLA_T, K_T, 0, 1e18, 0);
        _reduce(L_TSLA_T, K_T, MAX, MAX, 0);
        assertEq(tsla.balanceOf(address(this)), 1_000e18);
        assertEq(credit.accountRoutes(address(this)).length, 0);
        // Retiring is permanent.
        vm.expectRevert(IReg.BadRoute.selector);
        credit.setRoute(L_TSLA_T, true, false);
        vm.expectRevert(IReg.BadVault.selector);
        credit.setVault(K_T, true, false);
    }

    function test_routeAndVaultSwitches() public {
        credit.setRoute(L_TSLA_T, false, false);
        vm.expectRevert(IReg.AdmissionClosed.selector);
        _open(L_TSLA_T, K_T, 1e18, 0);
        credit.setRoute(L_TSLA_T, true, false);
        credit.setVault(K_T, false, false);
        vm.expectRevert(IReg.AdmissionClosed.selector);
        _open(L_TSLA_T, K_T, 10e18, 100e18);
        _open(L_TSLA_T, K_AT, 10e18, 100e18); // another vault of the same token still works
        credit.setAssetTier(address(tsla), R.Tier.NONE);
        vm.expectRevert(IReg.AdmissionClosed.selector);
        _open(L_TSLA_T, K_AT, 1e18, 0);
        credit.setAssetTier(address(tsla), R.Tier.CRYPTO_LINKED);
        assertEq(lens.targetLtv(L_TSLA_T), 0.2e18);
        credit.setLoanToken(address(usdt), false);
        vm.expectRevert(IReg.AdmissionClosed.selector);
        _open(L_TSLA_T, K_AT, 1e18, 0);
    }

    function test_routeCap_and_tokenMismatch() public {
        credit.setRouteCap(L_TSLA_T, 100e18);
        _open(L_TSLA_T, bytes32(0), 10e18, 0);
        vm.expectRevert(abi.encodeWithSelector(IReg.BorrowCapExceeded.selector, 100e18 + 1, 100e18));
        _open(L_TSLA_T, K_T, 0, 100e18 + 1);
        _open(L_TSLA_T, K_T, 0, 100e18);
        assertEq(credit.totalPrincipal(L_TSLA_T), 100e18);
        vm.expectRevert(abi.encodeWithSelector(IReg.BorrowCapExceeded.selector, 1, 0));
        _open(L_TSLA_T, K_T, 0, 1);
        // Repaying frees the cap again.
        _reduce(L_TSLA_T, K_T, 40e18, 0, 0);
        _open(L_TSLA_T, K_T, 0, 40e18);
        // Borrow X, deposit X: a USDC vault cannot take a USDT loan.
        credit.setRouteCap(L_TSLA_T, 1_000e18);
        _expectGate(R.Gate.TOKEN_MISMATCH);
        _open(L_TSLA_T, K_C, 0, 10e18);
    }

    // ---- consent ----

    function test_consent_requiredAndDebtCeiling() public {
        credit.setStrategyPolicy(100e18, WALLET, true);
        _open(L_TSLA_T, bytes32(0), 10e18, 0);
        vm.expectRevert(abi.encodeWithSelector(IReg.DebtAboveConsent.selector, 100e18 + 1, 100e18));
        _open(L_TSLA_T, K_T, 0, 100e18 + 1);
        _open(L_TSLA_T, K_T, 0, 60e18);
        // The ceiling is over all routes and tokens together.
        vm.expectRevert(abi.encodeWithSelector(IReg.DebtAboveConsent.selector, 100e18 + 1, 100e18));
        _open(L_QQQ_C, K_C, 10e18, 40e18 + 1);
        _open(L_QQQ_C, K_C, 10e18, 40e18);
        assertEq(credit.accountPrincipalUsd(address(this)), 100e18);
        credit.setStrategyPolicy(100e18, WALLET, false);
        vm.expectRevert(IReg.ConsentRequired.selector);
        _open(L_TSLA_T, K_T, 1e18, 0);
        vm.expectRevert(IReg.ConsentRequired.selector);
        credit.setStrategyPolicy(0, WALLET, true);
        vm.prank(KEEPER);
        vm.expectRevert(IReg.ConsentRequired.selector);
        credit.setStrategyPolicy(1e18, WALLET, true);
        R.Policy memory p = credit.policy(address(this));
        assertEq(p.maxDebt, 100e18);
        assertEq(p.rewardRecipient, WALLET);
        assertEq(p.strategyId, strategy);
        assertFalse(p.enabled);
    }

    function test_consent_voidAfterReEnroll_everyExitStillWorks_thenReconsent() public {
        _open(L_TSLA_T, K_T, 10e18, 300e18);
        _open(V_NVDA_T, K_T, 10e18, 300e18);
        lista.mint(_box(), 5e18);
        // A My-mix weight edit enrolls the account into a new private strategy.
        uint256 next = _newStrategy();
        registry.enroll(address(this), next, 1);
        vm.expectRevert(IReg.ConsentRequired.selector);
        _open(L_TSLA_T, K_T, 1e18, 0);
        vm.expectRevert(IReg.ConsentRequired.selector);
        _open(L_QQQ_C, K_C, 10e18, 100e18);
        vm.expectRevert(IReg.ConsentRequired.selector);
        _migrate(L_TSLA_T, K_T, V_TSLA_T, K_T, 100e18, 0);
        vm.expectRevert(IReg.AdmissionClosed.selector);
        lend.executeSwitchVault(address(this), K_T, K_AT, 1e18, block.timestamp);

        // Every exit: deleverage (anyone), repay, partial close, close, release, collect, sweep.
        oracle.setPrice(address(tsla), 60e8);
        vm.prank(KEEPER);
        lend.executeDeleverage(address(this), L_TSLA_T, K_T, MAX);
        oracle.setPrice(address(tsla), PRICE_E8);
        _reduce(L_TSLA_T, K_T, 50e18, 1e18, 0);
        _reduce(L_TSLA_T, K_T, MAX, MAX, 0);
        vm.prank(KEEPER);
        assertEq(lend.collectRewards(address(this), address(lista)), 5e18);
        lista.mint(_box(), 2e18);
        lend.executeSweepRewards(address(this), address(lista), 0, block.timestamp);
        assertEq(lista.balanceOf(WALLET), 2e18);
        usdt.mint(address(this), 400e18);
        usdt.approve(address(lend), MAX);
        _reduce(V_NVDA_T, bytes32(0), MAX, MAX, 400e18);
        lend.executeRelease(address(this), K_T, block.timestamp);
        assertEq(credit.accountRoutes(address(this)).length, 0);
        assertEq(credit.accountVaults(address(this)).length, 0);
        assertEq(nvda.balanceOf(address(this)), 1_000e18);
        assertEq(tsla.balanceOf(address(this)), 1_000e18);

        // Fresh consent (same batch as the enrollment in production) reopens new risk.
        credit.setStrategyPolicy(1_000e18, WALLET, true);
        _open(L_TSLA_T, K_T, 10e18, 100e18);
        assertEq(credit.policy(address(this)).strategyId, next);
    }

    function test_consent_pausedEnrollment_blocksNewRiskOnly() public {
        _open(L_TSLA_T, K_T, 10e18, 100e18);
        registry.setPaused(address(this), true);
        vm.expectRevert(IReg.ConsentRequired.selector);
        _open(L_TSLA_T, K_T, 0, 10e18);
        _reduce(L_TSLA_T, K_T, MAX, MAX, 0);
    }

    function test_tooManyPositions_bounded() public view {
        assertEq(credit.MAX_POSITIONS(), 24);
    }

    // ---- configuration ----

    function test_ids_matchTheDocumentedDerivation() public view {
        bytes32 listaId = _id(usdt, tsla, 0.7e18);
        assertEq(L_TSLA_T, keccak256(abi.encode(uint8(2), address(tsla), address(usdt), listaId)));
        assertEq(V_NVDA_C, keccak256(abi.encode(uint8(1), address(nvda), address(usdc), bytes32(0))));
        assertEq(K_T, keccak256(abi.encode(uint8(1), address(usdt), address(vaultT))));
        assertEq(K_VC, keccak256(abi.encode(uint8(2), address(usdc), address(vUsdc))));
        assertEq(K_AT, keccak256(abi.encode(uint8(3), address(usdt), address(aaveT))));
        assertEq(credit.routeIdOf(R.Venue.LISTA, address(tsla), address(usdt), listaId), L_TSLA_T);
        assertEq(credit.vaultIdOf(R.VaultKind.AAVE, address(usdt), address(aaveT)), K_AT);
        assertEq(credit.routeCount(), 7);
        assertEq(credit.vaultCount(), 4);
        R.Route memory r = credit.route(V_NVDA_C);
        assertEq(r.collateralVToken, address(vNvda));
        assertEq(r.loanVToken, address(vUsdc));
        assertEq(r.maxUtilizationBps, 9_500);
        R.Vault memory v = credit.vault(K_AT);
        assertEq(v.receipt, aaveT.receipt());
        assertEq(v.target, address(aaveT));
    }

    function test_admin_onlyOwner() public {
        vm.startPrank(KEEPER);
        vm.expectRevert(IReg.Unauthorized.selector);
        credit.setLoanToken(address(usdt), false);
        vm.expectRevert(IReg.Unauthorized.selector);
        credit.setAssetTier(address(nvda), R.Tier.NONE);
        vm.expectRevert(IReg.Unauthorized.selector);
        credit.setVenusMarket(address(usdt), address(vUsdt));
        vm.expectRevert(IReg.Unauthorized.selector);
        credit.setAdapter(R.VaultKind.ERC4626, address(erc4626Adapter));
        vm.expectRevert(IReg.Unauthorized.selector);
        credit.registerRoute(R.Venue.VENUS, address(qqq), address(usdt), bytes32(0), 1);
        vm.expectRevert(IReg.Unauthorized.selector);
        credit.setRoute(L_TSLA_T, false, false);
        vm.expectRevert(IReg.Unauthorized.selector);
        credit.setRouteCap(L_TSLA_T, 1);
        vm.expectRevert(IReg.Unauthorized.selector);
        credit.registerVault(R.VaultKind.ERC4626, address(usdt), address(vaultT));
        vm.expectRevert(IReg.Unauthorized.selector);
        credit.setVault(K_T, false, false);
        vm.expectRevert(IReg.Unauthorized.selector);
        credit.setPaused(true);
        vm.expectRevert(IReg.Unauthorized.selector);
        credit.setLtvConfig(L_TSLA_T, 0.1e18, 0.2e18);
        vm.expectRevert(IReg.Unauthorized.selector);
        credit.setRateReporter(KEEPER);
        vm.expectRevert(IReg.Unauthorized.selector);
        credit.setRewardToken(address(lista), false);
        vm.expectRevert(IReg.Unauthorized.selector);
        credit.setVenusBlocksPerYear(42_048_000);
        vm.expectRevert(IReg.Unauthorized.selector);
        credit.setRewardProofSuffix("");
        // Executor hooks.
        vm.expectRevert(IReg.Unauthorized.selector);
        credit.beforeOpen(address(this), L_TSLA_T, K_T, 1);
        vm.expectRevert(IReg.Unauthorized.selector);
        credit.beforeSwitch(address(this), K_T);
        vm.expectRevert(IReg.Unauthorized.selector);
        credit.recordOpen(address(this), L_TSLA_T, 1);
        vm.expectRevert(IReg.Unauthorized.selector);
        credit.recordReduce(address(this), L_TSLA_T, 1);
        vm.expectRevert(IReg.Unauthorized.selector);
        credit.recordVault(address(this), K_T, true);
        vm.stopPrank();
    }

    function test_registerRoute_validation() public {
        // Duplicate, loan token not allowed, collateral == loan, unknown Lista market, Venus without vToken.
        bytes32 listaId = _id(usdt, tsla, 0.7e18);
        vm.expectRevert(IReg.BadRoute.selector);
        credit.registerRoute(R.Venue.LISTA, address(tsla), address(usdt), listaId, 1);
        vm.expectRevert(IReg.BadRoute.selector);
        credit.registerRoute(R.Venue.VENUS, address(usdt), address(nvda), bytes32(0), 1);
        vm.expectRevert(IReg.BadRoute.selector);
        credit.registerRoute(R.Venue.VENUS, address(usdt), address(usdt), bytes32(0), 1);
        vm.expectRevert(IReg.BadRoute.selector);
        credit.registerRoute(R.Venue.LISTA, address(nvda), address(usdt), listaId, 1);
        vm.expectRevert(IReg.BadRoute.selector);
        credit.registerRoute(R.Venue.VENUS, address(qqq), address(usdt), bytes32(0), 1);
        vm.expectRevert(IReg.BadRoute.selector);
        credit.registerRoute(R.Venue.VENUS, address(nvda), address(usdt), bytes32(uint256(1)), 1);
        vm.expectRevert(IReg.BadRoute.selector);
        credit.registerRoute(R.Venue.NONE, address(nvda), address(usdt), bytes32(0), 1);
        vm.expectRevert(IReg.UnknownRoute.selector);
        credit.route(bytes32(uint256(7)));
        vm.expectRevert(IReg.UnknownVault.selector);
        credit.vault(bytes32(uint256(7)));
    }

    function test_registerVault_validation_andAdapterSetOnce() public {
        vm.expectRevert(IReg.BadParameter.selector);
        credit.setAdapter(R.VaultKind.ERC4626, address(erc4626Adapter)); // already set
        vm.expectRevert(IReg.BadVault.selector);
        credit.registerVault(R.VaultKind.ERC4626, address(usdt), address(vaultT)); // duplicate
        vm.expectRevert(VaultAdapterBase.BadVault.selector);
        credit.registerVault(R.VaultKind.ERC4626, address(usdt), address(vaultC)); // asset mismatch
        vm.expectRevert(VaultAdapterBase.BadVault.selector);
        credit.registerVault(R.VaultKind.VENUS, address(usdt), address(vUsdc));
        vm.expectRevert();
        credit.registerVault(R.VaultKind.AAVE, address(usdc), address(aaveT));
        vm.expectRevert(IReg.BadVault.selector);
        credit.registerVault(R.VaultKind.ERC4626, address(nvda), address(vaultT)); // not a loan token
        // Tokens keep a single role: a reward token is never a loan token or a receipt, and the reverse.
        vm.expectRevert(IReg.BadParameter.selector);
        credit.setRewardToken(address(usdt), true);
        vm.expectRevert(IReg.BadParameter.selector);
        credit.setRewardToken(address(vaultT), true);
        address aToken = aaveT.receipt();
        vm.expectRevert(IReg.BadParameter.selector);
        credit.setRewardToken(aToken, true);
        vm.expectRevert(IReg.BadParameter.selector);
        credit.setLoanToken(address(lista), true);
        MockEarnVault rewardVault = new MockEarnVault(lista, address(this), 0);
        vm.expectRevert(IReg.BadVault.selector);
        credit.registerVault(R.VaultKind.ERC4626, address(lista), address(rewardVault));
        vm.expectRevert(IReg.BadParameter.selector);
        credit.setVenusBlocksPerYear(1);
        credit.setVenusBlocksPerYear(42_048_000);
        assertEq(credit.venusBlocksPerYear(), 42_048_000);
        // A second vToken for an already mapped underlying is refused.
        vm.expectRevert(IReg.BadParameter.selector);
        credit.setVenusMarket(address(usdt), address(vUsdc));
    }

    function test_constructors_rejectBadWiring() public {
        vm.expectRevert(IReg.InvalidConstructor.selector);
        new AtpBorrowRegistryV2(registry, address(atp), address(0), address(comptroller), address(moolah));
        vm.expectRevert(IReg.InvalidConstructor.selector);
        new AtpBorrowRegistryV2(registry, address(atp), address(1), address(0), address(0));
        vm.expectRevert(IReg.InvalidConstructor.selector);
        new AtpBorrowRegistryV2(registry, address(0xdead), address(1), address(comptroller), address(moolah));
        // An executor must be the one its registry names, with the lens of that registry.
        vm.expectRevert(IExec.InvalidConfig.selector);
        new AtpBorrowExecutorV2(credit, lens, address(extension));
        AtpBorrowRegistryV2 other = new AtpBorrowRegistryV2(
            registry, address(atp), address(1), address(comptroller), address(moolah)
        );
        AtpBorrowLensV2 otherLens = new AtpBorrowLensV2(other);
        vm.expectRevert(IExec.InvalidConfig.selector);
        new AtpBorrowExecutorV2(other, otherLens, address(extension));
        vm.expectRevert(VaultAdapterBase.BadVault.selector);
        new Erc4626VaultAdapter(address(0xdead));
    }

    function test_status_snapshots() public {
        _open(V_NVDA_T, K_T, 10e18, 200e18);
        _open(V_TSLA_T, K_T, 10e18, 100e18);
        R.RouteStatus memory s = lens.routeStatus(V_NVDA_T, address(this));
        assertTrue(s.open);
        assertFalse(s.shouldDeleverage);
        assertApproxEqRel(s.borrowRate, 0.025e18, 1e12);
        assertEq(s.targetLtv, 0.3e18);
        assertEq(s.deleverageLtv, 0.4e18);
        assertEq(s.liquidationLtv, 0.6e18);
        assertEq(s.debt, 300e18, "Venus: whole USDT debt");
        assertEq(s.routeDebt, 200e18);
        assertEq(s.principal, 200e18);
        assertApproxEqAbs(s.collateral, 10e18, 1e10);
        assertApproxEqAbs(s.collateralValue, 1_000e18, 1e12);
        assertEq(s.ltv, 0.15e18);
        assertEq(s.borrowCapLeft, 1_000_000e18 - 200e18);
        assertEq(s.openedAt, block.timestamp);
        assertEq(s.health.budgetValue, 600e18);
        assertGt(s.availableLiquidity, 0);
        s = lens.routeStatus(L_QQQ_C, address(0));
        assertEq(s.debt, 0);
        assertEq(s.targetLtv, 0.35e18);
        R.VaultStatus memory v = lens.vaultStatus(K_T, address(this));
        assertTrue(v.open && v.rateKnown && !v.rateOnChain);
        assertEq(v.supplyRate, 0.045e18);
        assertApproxEqAbs(v.assets, 300e18, 3);
        assertEq(v.since, block.timestamp);
        assertEq(lens.minLoan(L_QQQ_C), 0);
    }
}
