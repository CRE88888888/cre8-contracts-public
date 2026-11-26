// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { RoutingBase } from "./RoutingBase.sol";
import { RoutingTypes as R } from "../../../../src/atp/borrow/v2/RoutingTypes.sol";
import { IAtpBorrowExecutorV2 as IExec } from "../../../../src/atp/borrow/v2/IAtpBorrowExecutorV2.sol";
import { IAtpBorrowRegistryV2 as IReg } from "../../../../src/atp/borrow/v2/IAtpBorrowRegistryV2.sol";

/// @notice Open -> accrue -> partial repay -> close on every venue x vault kind, the safety lines, the Venus
/// account-wide budget and closing several Venus positions.
contract RoutingFlowTest is RoutingBase {
    // ---- open / close per route ----

    function test_open_venus_usdt_intoErc4626Vault_thenClose() public {
        _open(V_NVDA_T, K_T, 10e18, 300e18); // 1000 USD collateral, 30% target
        assertEq(lens.debt(V_NVDA_T, address(this)), 300e18);
        assertEq(usdt.balanceOf(address(this)), 0, "borrowed USDT reached the account");
        assertGt(vaultT.balanceOf(_box()), 0, "box holds the shares");
        assertApproxEqAbs(_held(K_T), 300e18, 2);
        _accountHoldsNoStrategyMoney();
        _noResidue();
        assertEq(credit.principal(address(this), V_NVDA_T), 300e18);
        assertEq(credit.accountPrincipalUsd(address(this)), 300e18);
        assertEq(credit.openedAt(address(this), V_NVDA_T), block.timestamp);
        assertEq(credit.vaultSince(address(this), K_T), block.timestamp);
        assertEq(credit.accountRoutes(address(this)).length, 1);
        assertEq(credit.accountVaults(address(this)).length, 1);

        skip(30 days);
        // Vault earns 4.5%, debt costs 2.5%: closing from the vault leaves a profit in the account.
        _reduce(V_NVDA_T, K_T, MAX, MAX, 0);
        assertEq(lens.debt(V_NVDA_T, address(this)), 0);
        assertEq(nvda.balanceOf(address(this)), 1_000e18, "collateral back");
        assertGt(usdt.balanceOf(address(this)), 0.4e18, "carry paid out");
        assertEq(vaultT.balanceOf(_box()), 0, "box emptied");
        assertEq(credit.principal(address(this), V_NVDA_T), 0);
        assertEq(credit.accountPrincipalUsd(address(this)), 0);
        assertEq(credit.openedAt(address(this), V_NVDA_T), 0);
        assertEq(credit.vaultSince(address(this), K_T), 0);
        assertEq(credit.accountRoutes(address(this)).length, 0);
        assertEq(credit.accountVaults(address(this)).length, 0);
        _noResidue();
    }

    function test_open_lista_usdc_intoVenusVault_partialRepay_thenClose() public {
        // vUSDC supply pays less than the borrow costs; a reported borrow incentive makes the carry positive.
        vm.expectRevert(abi.encodeWithSelector(IExec.GateClosed.selector, uint8(R.Gate.NEGATIVE_CARRY)));
        _open(L_QQQ_C, K_VC, 10e18, 350e18);
        _report(0.045e18, 0, 0.03e18);
        _open(L_QQQ_C, K_VC, 10e18, 350e18); // index: 35%
        assertEq(lens.debt(L_QQQ_C, address(this)), 350e18);
        assertGt(vUsdc.balanceOf(_box()), 0);
        assertEq(vUsdc.balanceOf(address(this)), 0);
        assertEq(usdc.balanceOf(address(this)), 0);
        _noResidue();

        skip(7 days);
        _reduce(L_QQQ_C, K_VC, 100e18, 0, 0);
        assertApproxEqAbs(
            lens.debt(L_QQQ_C, address(this)),
            uint256(250e18) + uint256(350e18) * 250 * 7 / (10_000 * 365),
            1e15
        );
        assertEq(usdc.balanceOf(address(this)), 0, "partial repay pays nothing out");
        _noResidue();

        // Partial close: half the collateral back while staying inside the target.
        _reduce(L_QQQ_C, K_VC, 100e18, 5e18, 0);
        assertEq(qqq.balanceOf(address(this)), 995e18);
        R.Health memory h = _health(L_QQQ_C);
        assertLe(h.debtValue, h.budgetValue);

        // The Venus supply rate here is below the borrow rate, so the vault is short of the debt at close:
        // the rest comes from the account's own USDC, capped by maxCashIn.
        usdc.mint(address(this), 10e18);
        usdc.approve(address(lend), MAX);
        _reduce(L_QQQ_C, K_VC, MAX, MAX, 10e18);
        assertEq(lens.debt(L_QQQ_C, address(this)), 0);
        assertEq(qqq.balanceOf(address(this)), 1_000e18);
        assertEq(vUsdc.balanceOf(_box()), 0);
        assertEq(credit.accountRoutes(address(this)).length, 0);
        _noResidue();
    }

    function test_open_lista_usdt_intoAave_thenClose() public {
        _open(L_TSLA_T, K_AT, 10e18, 300e18);
        assertApproxEqAbs(IERC20(aaveT.receipt()).balanceOf(_box()), 300e18, 2);
        assertEq(IERC20(aaveT.receipt()).balanceOf(address(this)), 0);
        _noResidue();
        skip(30 days);
        _reduce(L_TSLA_T, K_AT, MAX, MAX, 0);
        assertEq(lens.debt(L_TSLA_T, address(this)), 0);
        assertEq(tsla.balanceOf(address(this)), 1_000e18);
        assertGt(usdt.balanceOf(address(this)), 0.2e18, "3.5% - 2.5% carry");
        assertLe(IERC20(aaveT.receipt()).balanceOf(_box()), 1, "box emptied");
        _noResidue();
    }

    function test_open_collateralOnly_thenBorrowLater() public {
        _open(L_TSLA_C, bytes32(0), 10e18, 0);
        assertEq(lens.collateral(L_TSLA_C, address(this)), 10e18);
        assertEq(credit.accountRoutes(address(this)).length, 1);
        _open(L_TSLA_C, K_C, 0, 250e18); // 50% LLTV -> 25%
        assertEq(lens.debt(L_TSLA_C, address(this)), 250e18);
        vm.expectRevert(IExec.ZeroAmount.selector);
        _open(L_TSLA_C, K_C, 0, 0);
    }

    // ---- target line ----

    function test_borrow_exactlyAtTarget_passes_oneOver_reverts() public {
        _open(L_TSLA_T, bytes32(0), 10e18, 0);
        vm.expectRevert(abi.encodeWithSelector(IExec.LtvTooHigh.selector, 300e18 + 1, 300e18));
        _open(L_TSLA_T, K_T, 0, 300e18 + 1);
        _open(L_TSLA_T, K_T, 0, 300e18);
        assertEq(lens.targetLtv(L_TSLA_T), 0.3e18);
        assertEq(lens.targetLtv(L_TSLA_C), 0.25e18);
        assertEq(lens.targetLtv(L_QQQ_C), 0.35e18);
        assertEq(lens.targetLtv(V_NVDA_T), 0.3e18);
        assertEq(lens.deleverageLtv(V_NVDA_T), 0.4e18);
        assertEq(lens.deleverageLtv(L_QQQ_C), 0.5e18);
        assertEq(lens.liquidationLtv(L_QQQ_C), 0.75e18);
    }

    function test_withdrawCollateral_mustStayInsideTarget() public {
        _open(L_TSLA_T, K_T, 10e18, 150e18);
        // 150 debt needs 500 USD of collateral at 30%: 5 TSLA may leave, one raw unit more may not.
        vm.expectRevert();
        _reduce(L_TSLA_T, bytes32(0), 0, 5e18 + 1, 0);
        _reduce(L_TSLA_T, bytes32(0), 0, 5e18, 0);
        assertEq(tsla.balanceOf(address(this)), 995e18);
    }

    function test_ownerLtvConfig_onlyMoreConservative() public {
        vm.expectRevert(IReg.BadParameter.selector);
        credit.setLtvConfig(L_TSLA_T, 0.31e18, 0);
        credit.setLtvConfig(L_TSLA_T, 0.2e18, 0.3e18);
        assertEq(lens.targetLtv(L_TSLA_T), 0.2e18);
        assertEq(lens.deleverageLtv(L_TSLA_T), 0.3e18);
        // Venus: the override follows the collateral onto every Venus route of it.
        credit.setLtvConfig(V_NVDA_T, 0.1e18, 0.2e18);
        assertEq(lens.targetLtv(V_NVDA_C), 0.1e18);
        _open(V_NVDA_C, bytes32(0), 10e18, 0);
        vm.expectRevert();
        _open(V_NVDA_C, K_C, 0, 100e18 + 1);
        _open(V_NVDA_C, K_C, 0, 100e18);
    }

    // ---- Venus: one account, one budget ----

    function test_venus_budgetIsAccountWide() public {
        _open(V_NVDA_T, K_T, 10e18, 0);
        _open(V_TSLA_C, K_C, 10e18, 0);
        // 2000 USD collateral at 30% = 600 USD budget, whichever token is borrowed against whichever asset.
        _open(V_NVDA_T, K_T, 0, 400e18);
        vm.expectRevert(abi.encodeWithSelector(IExec.LtvTooHigh.selector, 600e18 + 1, 600e18));
        _open(V_TSLA_C, K_C, 0, 200e18 + 1);
        _open(V_TSLA_C, K_C, 0, 200e18);
        R.Health memory h = _health(V_NVDA_T);
        assertEq(h.collateralValue, 2_000e18);
        assertEq(h.debtValue, 600e18);
        assertEq(h.budgetValue, 600e18);
        assertEq(h.deleverageValue, 800e18);
        assertEq(h.liquidationValue, 1_200e18);
        // Same numbers through either route.
        assertEq(_health(V_TSLA_C).debtValue, 600e18);
        // Collateral without a tier adds no budget.
        credit.setAssetTier(address(tsla), R.Tier.NONE);
        assertEq(_health(V_NVDA_T).budgetValue, 300e18);
    }

    function test_venus_closeTwoPositions_sameLoanToken_anyOrder() public {
        _open(V_NVDA_T, K_T, 10e18, 300e18);
        _open(V_TSLA_T, K_T, 10e18, 300e18);
        assertEq(lens.debt(V_NVDA_T, address(this)), 600e18, "one shared USDT debt");
        assertEq(lens.routeDebt(V_NVDA_T, address(this)), 300e18);
        assertEq(lens.routeDebt(V_TSLA_T, address(this)), 300e18);
        skip(30 days);

        // First close repays its share of the shared debt from the pooled vault and frees its collateral.
        _reduce(V_TSLA_T, K_T, MAX, MAX, 0);
        assertEq(tsla.balanceOf(address(this)), 1_000e18);
        assertEq(usdt.balanceOf(address(this)), 0, "debt remains: nothing paid out yet");
        // Interest pushed both a hair past the target; the one that stays is no worse off than before.
        assertApproxEqRel(lens.debt(V_NVDA_T, address(this)), 300.6e18, 0.001e18);
        assertEq(credit.accountRoutes(address(this)).length, 1);

        // Second close pays the rest (interest included) and releases what the vault earned.
        _reduce(V_NVDA_T, K_T, MAX, MAX, 0);
        assertEq(lens.debt(V_NVDA_T, address(this)), 0);
        assertEq(nvda.balanceOf(address(this)), 1_000e18);
        assertGt(usdt.balanceOf(address(this)), 0.9e18, "both positions' carry");
        assertEq(vaultT.balanceOf(_box()), 0);
        assertEq(credit.accountRoutes(address(this)).length, 0);
        assertEq(credit.accountPrincipalUsd(address(this)), 0);
        _noResidue();
    }

    function test_venus_closeTwoPositions_differentLoanTokens() public {
        _open(V_NVDA_T, K_T, 10e18, 300e18);
        _open(V_TSLA_C, K_C, 10e18, 300e18);
        skip(10 days);
        _reduce(V_NVDA_T, K_T, MAX, MAX, 0);
        assertEq(nvda.balanceOf(address(this)), 1_000e18);
        assertGt(usdt.balanceOf(address(this)), 0, "USDT debt is gone: USDT vault released");
        assertEq(lens.debt(V_TSLA_C, address(this)), lens.tokenDebt(address(this), address(usdc)));
        _reduce(V_TSLA_C, K_C, MAX, MAX, 0);
        assertEq(tsla.balanceOf(address(this)), 1_000e18);
        assertGt(usdc.balanceOf(address(this)), 0);
        assertEq(credit.accountRoutes(address(this)).length, 0);
        _noResidue();
    }

    function test_venus_closeOneOfThree_keepsOthersInsideBudget() public {
        _open(V_NVDA_T, K_T, 10e18, 300e18);
        _open(V_TSLA_T, K_T, 10e18, 100e18);
        _open(V_TSLA_C, K_C, 0, 200e18);
        skip(3 days);
        // Closing TSLA's USDT route alone cannot take TSLA out: its USDC debt still needs the collateral.
        vm.expectRevert();
        _reduce(V_TSLA_T, K_T, MAX, MAX, 0);
        // TSLA's USDT route carries a quarter of the USDT principal; with only that share repaid, NVDA would be
        // left a hair over its budget (interest), which is worse than before, so MAX is refused...
        _reduce(V_TSLA_C, K_C, MAX, 0, 0);
        vm.expectRevert();
        _reduce(V_TSLA_T, K_T, MAX, MAX, 0);
        // ...and an explicit amount that also covers that interest passes. NVDA stays inside its budget.
        _reduce(V_TSLA_T, K_T, 101e18, MAX, 0);
        assertEq(tsla.balanceOf(address(this)), 1_000e18);
        assertApproxEqRel(lens.debt(V_NVDA_T, address(this)), 300e18, 0.01e18);
        // An explicit amount above the route's share pays down the shared debt further.
        _reduce(V_NVDA_T, K_T, 1_000e18, 0, 0);
        assertEq(lens.debt(V_NVDA_T, address(this)), 0);
    }

    // ---- repay sources ----

    function test_repay_cashOnly_whenNoVaultGiven() public {
        _open(L_TSLA_T, K_T, 10e18, 300e18);
        usdt.mint(address(this), 100e18);
        usdt.approve(address(lend), MAX);
        vm.expectRevert(abi.encodeWithSelector(IExec.VaultShortfall.selector, 100e18, 50e18));
        _reduce(L_TSLA_T, bytes32(0), 100e18, 0, 50e18);
        _reduce(L_TSLA_T, bytes32(0), 100e18, 0, 100e18);
        assertEq(usdt.balanceOf(address(this)), 0);
        assertEq(lens.debt(L_TSLA_T, address(this)), 200e18);
        assertApproxEqAbs(_held(K_T), 300e18, 2, "vault untouched");
    }

    function test_repay_wrongTokenVault_reverts() public {
        _open(L_TSLA_T, K_T, 10e18, 300e18);
        vm.expectRevert(IExec.TokenMismatch.selector);
        _reduce(L_TSLA_T, K_C, 100e18, 0, 0);
    }

    function test_reduce_nothingToDo_reverts() public {
        vm.expectRevert(IExec.ZeroAmount.selector);
        _reduce(L_TSLA_T, K_T, 0, 0, 0);
        vm.expectRevert(IExec.NothingToRepay.selector);
        _reduce(L_TSLA_T, K_T, MAX, 0, 0);
    }

    function test_pooledVault_servesEveryRouteOfTheToken() public {
        _open(L_TSLA_C, K_C, 10e18, 250e18);
        _open(L_QQQ_C, K_C, 10e18, 350e18);
        assertApproxEqAbs(_held(K_C), 600e18, 3);
        skip(20 days);
        _reduce(L_TSLA_C, K_C, MAX, MAX, 0);
        assertEq(usdc.balanceOf(address(this)), 0, "USDC debt remains on the other route: nothing released");
        assertGt(_held(K_C), 350e18);
        _reduce(L_QQQ_C, K_C, MAX, MAX, 0);
        assertGt(usdc.balanceOf(address(this)), 0.5e18);
        assertEq(credit.accountVaults(address(this)).length, 0);
    }

    function test_release_onlyWithoutDebt() public {
        _open(L_TSLA_T, K_T, 10e18, 300e18);
        vm.expectRevert(abi.encodeWithSelector(IExec.DebtOutstanding.selector, 300e18));
        lend.executeRelease(address(this), K_T, block.timestamp);
        // Repay from cash: the vault holding stays in the box until it is released.
        usdt.mint(address(this), 300e18);
        usdt.approve(address(lend), MAX);
        _reduce(L_TSLA_T, bytes32(0), MAX, 0, 300e18);
        assertApproxEqAbs(_held(K_T), 300e18, 2);
        lend.executeRelease(address(this), K_T, block.timestamp);
        assertApproxEqAbs(usdt.balanceOf(address(this)), 300e18, 2);
        assertEq(vaultT.balanceOf(_box()), 0);
        vm.expectRevert(IExec.NothingToDo.selector);
        lend.executeRelease(address(this), K_T, block.timestamp);
    }

    // ---- caller ----

    function test_onlyTheAccountItself_andDeadline() public {
        vm.prank(KEEPER);
        vm.expectRevert(IExec.NotAccount.selector);
        lend.executeOpen(address(this), L_TSLA_T, K_T, 1e18, 0, block.timestamp);
        vm.prank(KEEPER);
        vm.expectRevert(IExec.NotAccount.selector);
        lend.executeReduce(address(this), L_TSLA_T, K_T, 1, 0, 0, block.timestamp);
        vm.prank(KEEPER);
        vm.expectRevert(IExec.NotAccount.selector);
        lend.executeMigrate(address(this), L_TSLA_T, K_T, V_TSLA_T, K_T, 0, 0, block.timestamp);
        vm.prank(KEEPER);
        vm.expectRevert(IExec.NotAccount.selector);
        lend.executeSwitchVault(address(this), K_T, K_AT, 1, block.timestamp);
        vm.prank(KEEPER);
        vm.expectRevert(IExec.NotAccount.selector);
        lend.executeRelease(address(this), K_T, block.timestamp);
        vm.prank(KEEPER);
        vm.expectRevert(IExec.NotAccount.selector);
        lend.executeSweepRewards(address(this), address(lista), 0, block.timestamp);
        vm.expectRevert(IExec.DeadlineExpired.selector);
        lend.executeOpen(address(this), L_TSLA_T, K_T, 1e18, 0, block.timestamp - 1);
        vm.prank(KEEPER, KEEPER);
        vm.expectRevert(IExec.NotContract.selector);
        lend.executeOpen(KEEPER, L_TSLA_T, K_T, 1e18, 0, block.timestamp);
    }
}
