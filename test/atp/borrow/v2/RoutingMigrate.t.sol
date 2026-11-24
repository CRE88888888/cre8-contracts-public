// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { RoutingBase } from "./RoutingBase.sol";
import { RoutingTypes as R } from "../../../../src/atp/borrow/v2/RoutingTypes.sol";
import { IAtpBorrowExecutorV2 as IExec } from "../../../../src/atp/borrow/v2/IAtpBorrowExecutorV2.sol";
import { IAtpBorrowRegistryV2 as IReg } from "../../../../src/atp/borrow/v2/IAtpBorrowRegistryV2.sol";

/// @notice executeMigrate (route -> route in one call), executeSwitchVault, and what must go in two steps.
contract RoutingMigrateTest is RoutingBase {
    function test_migrate_listaToVenus_sameToken_atomic() public {
        _open(L_TSLA_T, K_T, 10e18, 300e18);
        skip(10 days);
        uint256 nvdaBefore = nvda.balanceOf(address(this));
        _migrate(L_TSLA_T, K_T, V_TSLA_T, K_AT, 300e18, 0);
        // Old route is empty, collateral sits on Venus, new debt went into the Aave vault.
        assertEq(lens.debt(L_TSLA_T, address(this)), 0);
        assertEq(lens.collateral(L_TSLA_T, address(this)), 0);
        assertApproxEqAbs(lens.collateral(V_TSLA_T, address(this)), 10e18, 1e10);
        assertEq(lens.debt(V_TSLA_T, address(this)), 300e18);
        assertApproxEqAbs(IERC20(aaveT.receipt()).balanceOf(_box()), 300e18, 2);
        // The old route was the account's only USDT debt at that point, so what its vault earned above the
        // debt was paid to the account; the new debt sits in the new vault.
        assertEq(vaultT.balanceOf(_box()), 0);
        assertGt(usdt.balanceOf(address(this)), 0);
        assertLt(usdt.balanceOf(address(this)), 1e18);
        assertEq(tsla.balanceOf(address(this)), 990e18, "collateral never passed through the account");
        assertEq(nvda.balanceOf(address(this)), nvdaBefore);
        // Accounting moved with it.
        assertEq(credit.principal(address(this), L_TSLA_T), 0);
        assertEq(credit.principal(address(this), V_TSLA_T), 300e18);
        assertEq(credit.accountPrincipalUsd(address(this)), 300e18);
        assertEq(credit.openedAt(address(this), V_TSLA_T), block.timestamp);
        bytes32[] memory routes = credit.accountRoutes(address(this));
        assertEq(routes.length, 1);
        assertEq(routes[0], V_TSLA_T);
        _noResidue();
        _accountHoldsNoStrategyMoney();
    }

    function test_migrate_venusToLista_sameToken_atomic() public {
        _open(V_TSLA_T, K_T, 10e18, 300e18);
        skip(10 days);
        // Reports are stale after 48 hours: the destination vault's rate is unknown until the next report.
        vm.expectRevert(abi.encodeWithSelector(IExec.GateClosed.selector, uint8(R.Gate.VAULT_UNREADABLE)));
        _migrate(V_TSLA_T, K_T, L_TSLA_T, K_T, 300e18, 0);
        _report(0.045e18, 0, 0);
        _migrate(V_TSLA_T, K_T, L_TSLA_T, K_T, 300e18, 0);
        assertEq(lens.debt(V_TSLA_T, address(this)), 0);
        assertEq(vTsla.balanceOf(address(this)), 0);
        assertEq(lens.collateral(L_TSLA_T, address(this)), 10e18);
        assertEq(lens.debt(L_TSLA_T, address(this)), 300e18);
        // Same vault on both sides: emptied for the old debt (surplus to the account), refilled by the new.
        assertApproxEqAbs(_held(K_T), 300e18, 2);
        assertGt(usdt.balanceOf(address(this)), 0);
        assertEq(credit.accountRoutes(address(this)).length, 1);
        _noResidue();
    }

    function test_migrate_acrossLoanTokens_atomic_noSwap() public {
        _open(L_TSLA_T, K_T, 10e18, 300e18); // borrow USDT
        skip(10 days);
        _report(0.045e18, 0, 0);
        // To the USDC market of the same collateral (50% LLTV -> 25%).
        _migrate(L_TSLA_T, K_T, L_TSLA_C, K_C, 250e18, 0);
        assertEq(lens.debt(L_TSLA_T, address(this)), 0);
        assertEq(lens.debt(L_TSLA_C, address(this)), 250e18);
        assertEq(lens.collateral(L_TSLA_C, address(this)), 10e18);
        assertApproxEqAbs(_held(K_C), 250e18, 2);
        assertEq(usdc.balanceOf(address(this)), 0, "new loan token never reaches the account");
        // USDT has no debt left: what the USDT vault earned above the debt was paid out in the same call.
        assertGt(usdt.balanceOf(address(this)), 0.1e18);
        assertEq(vaultT.balanceOf(_box()), 0);
        assertEq(credit.accountVaults(address(this)).length, 1);
        _noResidue();
    }

    function test_migrate_venusToVenus_onlyLoanTokenChanges() public {
        _open(V_NVDA_T, K_T, 10e18, 300e18);
        skip(5 days);
        _report(0.045e18, 0, 0);
        _migrate(V_NVDA_T, K_T, V_NVDA_C, K_C, 300e18, 0);
        assertEq(lens.debt(V_NVDA_T, address(this)), 0);
        assertEq(lens.debt(V_NVDA_C, address(this)), 300e18);
        assertApproxEqAbs(lens.collateral(V_NVDA_C, address(this)), 10e18, 1e10);
        bytes32[] memory routes = credit.accountRoutes(address(this));
        assertEq(routes.length, 1, "one position for the shared Venus collateral");
        assertEq(routes[0], V_NVDA_C);
        _noResidue();
    }

    function test_migrate_fromVenus_withOtherVenusPositions() public {
        _open(V_NVDA_T, K_T, 10e18, 300e18);
        _open(V_TSLA_T, K_T, 10e18, 300e18);
        skip(5 days);
        _report(0.045e18, 0, 0);
        _migrate(V_TSLA_T, K_T, L_TSLA_T, K_T, 300e18, 0);
        // TSLA's share of the shared USDT debt was repaid; NVDA's stays and is no worse off.
        assertApproxEqRel(lens.debt(V_NVDA_T, address(this)), 300.1e18, 0.001e18);
        assertEq(vTsla.balanceOf(address(this)), 0);
        assertEq(lens.debt(L_TSLA_T, address(this)), 300e18);
        assertEq(credit.accountRoutes(address(this)).length, 2);
    }

    function test_migrate_newDebtAboveTarget_revertsWhole() public {
        _open(L_TSLA_T, K_T, 10e18, 300e18);
        vm.expectRevert();
        _migrate(L_TSLA_T, K_T, L_TSLA_C, K_C, 250e18 + 1, 0);
        // Nothing moved.
        assertEq(lens.debt(L_TSLA_T, address(this)), 300e18);
        assertEq(lens.collateral(L_TSLA_T, address(this)), 10e18);
        assertEq(lens.collateral(L_TSLA_C, address(this)), 0);
    }

    function test_migrate_vaultShort_reverts_thenCashOrTwoSteps() public {
        _open(L_TSLA_T, K_T, 10e18, 300e18);
        // The vault lost part of its holding to an earlier deleverage-like repayment.
        _reduce(L_TSLA_T, K_T, 100e18, 0, 0);
        _open(L_TSLA_T, K_AT, 0, 100e18); // debt back to 300, but 100 of it sits in another vault
        vm.expectRevert();
        _migrate(L_TSLA_T, K_T, V_TSLA_T, K_T, 300e18, 0);
        // With the account's own USDT up to maxCashIn the same call goes through...
        uint256 snapshot = vm.snapshotState();
        usdt.mint(address(this), 150e18);
        usdt.approve(address(lend), MAX);
        _migrate(L_TSLA_T, K_T, V_TSLA_T, K_T, 300e18, 150e18);
        assertEq(lens.debt(V_TSLA_T, address(this)), 300e18);
        assertApproxEqAbs(usdt.balanceOf(address(this)), 50e18, 3);
        // ...and without cash it is two steps: close the old route from both vaults, open the new one.
        vm.revertToState(snapshot);
        _reduce(L_TSLA_T, K_T, 200e18, 0, 0);
        _reduce(L_TSLA_T, K_AT, MAX, MAX, 0);
        _open(V_TSLA_T, K_T, 10e18, 300e18);
        assertEq(lens.debt(V_TSLA_T, address(this)), 300e18);
    }

    function test_migrate_guards() public {
        _open(L_TSLA_T, K_T, 10e18, 300e18);
        vm.expectRevert(IExec.SameRoute.selector);
        _migrate(L_TSLA_T, K_T, L_TSLA_T, K_AT, 0, 0);
        vm.expectRevert(IExec.CollateralMismatch.selector);
        _migrate(L_TSLA_T, K_T, L_QQQ_C, K_C, 0, 0);
        // Destination vault must hold the destination's loan token.
        vm.expectRevert(abi.encodeWithSelector(IExec.GateClosed.selector, uint8(R.Gate.TOKEN_MISMATCH)));
        _migrate(L_TSLA_T, K_T, L_TSLA_C, K_T, 100e18, 0);
        // Source vault must hold the source's loan token.
        vm.expectRevert(IExec.TokenMismatch.selector);
        _migrate(L_TSLA_T, K_C, L_TSLA_C, K_C, 100e18, 0);
        // Destination closed (disabled, paused): the whole move reverts, the old position is untouched.
        credit.setRoute(V_TSLA_T, false, false);
        vm.expectRevert(IReg.AdmissionClosed.selector);
        _migrate(L_TSLA_T, K_T, V_TSLA_T, K_T, 300e18, 0);
        credit.setRoute(V_TSLA_T, true, false);
        credit.setPaused(true);
        vm.expectRevert(IReg.AdmissionClosed.selector);
        _migrate(L_TSLA_T, K_T, V_TSLA_T, K_T, 300e18, 0);
        credit.setPaused(false);
        // Destination with a negative carry.
        _report(0.01e18, 0, 0);
        vm.expectRevert(abi.encodeWithSelector(IExec.GateClosed.selector, uint8(R.Gate.NEGATIVE_CARRY)));
        _migrate(L_TSLA_T, K_T, V_TSLA_T, K_T, 300e18, 0);
        assertEq(lens.debt(L_TSLA_T, address(this)), 300e18);
    }

    function test_migrate_oldVenuePaused_orNewVenueDry_revertsWhole() public {
        _open(V_TSLA_T, K_T, 10e18, 300e18);
        comptroller.setActionPaused(address(vTsla), 1, true); // REDEEM
        vm.expectRevert();
        _migrate(V_TSLA_T, K_T, L_TSLA_T, K_T, 300e18, 0);
        comptroller.setActionPaused(address(vTsla), 1, false);
        // New venue out of cash for the loan.
        vm.prank(LENDER);
        moolah.withdraw(_params(usdt, tsla, 0.7e18), 1_000_000e18, 0, LENDER, LENDER);
        vm.expectRevert();
        _migrate(V_TSLA_T, K_T, L_TSLA_T, K_T, 300e18, 0);
        assertEq(lens.debt(V_TSLA_T, address(this)), 300e18);
        assertApproxEqAbs(_held(K_T), 300e18, 2);
        assertApproxEqAbs(lens.collateral(V_TSLA_T, address(this)), 10e18, 1e10);
    }

    function test_migrate_collateralOnly_noNewDebt() public {
        _open(L_TSLA_T, K_T, 10e18, 300e18);
        _migrate(L_TSLA_T, K_T, V_TSLA_T, bytes32(0), 0, 0);
        assertEq(lens.debt(L_TSLA_T, address(this)), 0);
        assertEq(lens.debt(V_TSLA_T, address(this)), 0);
        assertApproxEqAbs(lens.collateral(V_TSLA_T, address(this)), 10e18, 1e10);
    }

    // ---- switch vault ----

    function test_switchVault_sameToken() public {
        _open(L_TSLA_T, K_T, 10e18, 300e18);
        skip(1 days);
        lend.executeSwitchVault(address(this), K_T, K_AT, MAX, block.timestamp);
        assertEq(vaultT.balanceOf(_box()), 0);
        assertGt(IERC20(aaveT.receipt()).balanceOf(_box()), 300e18);
        assertEq(usdt.balanceOf(address(this)), 0);
        assertEq(lens.debt(L_TSLA_T, address(this)), 300e18 + lens.debt(L_TSLA_T, address(this)) - 300e18);
        bytes32[] memory vaults = credit.accountVaults(address(this));
        assertEq(vaults.length, 1);
        assertEq(vaults[0], K_AT);
        assertEq(credit.vaultSince(address(this), K_AT), block.timestamp);
        assertEq(credit.vaultSince(address(this), K_T), 0);
        // Part of it back.
        lend.executeSwitchVault(address(this), K_AT, K_T, 100e18, block.timestamp);
        assertApproxEqAbs(_held(K_T), 100e18, 2);
        _noResidue();
        // The debt is repaid from whichever vault is named.
        _reduce(L_TSLA_T, K_AT, 150e18, 0, 0);
        _reduce(L_TSLA_T, K_T, 50e18, 0, 0);
    }

    function test_switchVault_guards() public {
        _open(L_TSLA_T, K_T, 10e18, 300e18);
        vm.expectRevert(IExec.TokenMismatch.selector);
        lend.executeSwitchVault(address(this), K_T, K_C, 100e18, block.timestamp);
        vm.expectRevert(IExec.SameRoute.selector);
        lend.executeSwitchVault(address(this), K_T, K_T, 100e18, block.timestamp);
        vm.expectRevert(IExec.ZeroAmount.selector);
        lend.executeSwitchVault(address(this), K_T, K_AT, 0, block.timestamp);
        credit.setVault(K_AT, false, false);
        vm.expectRevert(IReg.AdmissionClosed.selector);
        lend.executeSwitchVault(address(this), K_T, K_AT, 100e18, block.timestamp);
        // Leaving a disabled vault is always possible.
        credit.setVault(K_AT, true, false);
        lend.executeSwitchVault(address(this), K_T, K_AT, 100e18, block.timestamp);
        credit.setVault(K_AT, false, true);
        lend.executeSwitchVault(address(this), K_AT, K_T, MAX, block.timestamp);
        assertLe(IERC20(aaveT.receipt()).balanceOf(_box()), 1);
    }
}
