// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { AtpBorrowBase } from "./AtpBorrowBase.sol";
import { AtpBorrowExecutor } from "../../../src/atp/borrow/AtpBorrowExecutor.sol";
import { BorrowTypes as B } from "../../../src/atp/borrow/BorrowTypes.sol";

/// @notice #64 price-drop drills as run on chain 97 (EARN_UX §B.6, §C, §D): the owner marks collateral down;
/// at the deleverage line anyone repays from the position's own vault back to the target LTV; negative carry or
/// a 95%+ utilized vault unwinds; protocol liquidation and ledger reconciliation still work underneath.
contract AtpBorrowLiquidationTest is AtpBorrowBase {
    // ---- automatic deleverage at 2/3 of the liquidation line ----

    function test_deleverage_exactlyAtLine_restoresTargetLtv() public {
        for (uint256 i; i < 2; ++i) {
            bytes32 id = i == 0 ? VENUS_ID : LISTA_ID;
            _post(id, 10e18);
            _borrow(id, 400e18); // LTV 24.6%
            // LTV = 400 / (10 x p): p = 120.00001 is just under the 33.33% line, p = 120 is on it.
            oracle.setPrice(address(_token(id)), 120.00001e8);
            assertFalse(credit.status(id, address(this)).shouldDeleverage);
            vm.prank(KEEPER);
            vm.expectRevert(AtpBorrowExecutor.NothingToDo.selector);
            lend.executeDeleverage(address(this), id);

            oracle.setPrice(address(_token(id)), 120e8);
            B.Status memory s = credit.status(id, address(this));
            assertTrue(s.shouldDeleverage);
            assertGe(s.ltv, s.deleverageLtv);
            uint256 cash = _usdtOf(address(this));
            vm.prank(KEEPER); // anyone may trigger it
            lend.executeDeleverage(address(this), id);
            uint256 ltv = _ltv(id);
            assertLe(ltv, credit.targetLtv(id), "not back at target");
            assertGt(ltv, credit.targetLtv(id) - 1e12, "repaid far more than needed");
            // Debt at target: 25% x 1200 USD = 300 USDT; paid from the vault, not from the account's cash.
            assertApproxEqAbs(credit.debt(id, address(this)), 300e18, 1e6);
            assertEq(_usdtOf(address(this)), cash, "deleverage touched free cash");
            assertApproxEqAbs(vault.previewRedeem(vault.balanceOf(address(this))), 300e18 * (i + 1), 1e6);
            _noResidue();
        }
    }

    function test_deleverage_cappedByVaultLiquidity() public {
        _post(VENUS_ID, 10e18);
        _borrow(VENUS_ID, 400e18);
        oracle.setPrice(address(nvda), 100e8); // LTV 40%
        vault.setLiquidity(30e18); // the vault can pay out only 30 now
        lend.executeDeleverage(address(this), VENUS_ID);
        assertApproxEqAbs(credit.debt(VENUS_ID, address(this)), 370e18, 1);
        assertTrue(
            credit.status(VENUS_ID, address(this)).shouldDeleverage, "rest left for the backend to sell"
        );
    }

    // ---- unwind: negative carry or vault utilization above 95% ----

    function test_unwind_onNegativeCarry_closesWholeDebtFromVault() public {
        _post(LISTA_ID, 10e18);
        _borrow(LISTA_ID, 300e18);
        skip(30 days); // vault earned more than the debt grew
        vm.prank(KEEPER);
        vm.expectRevert(AtpBorrowExecutor.NothingToDo.selector);
        lend.executeDeleverage(address(this), LISTA_ID);
        vault.setAprBps(BORROW_APR - 1);
        assertTrue(credit.status(LISTA_ID, address(this)).shouldUnwind);
        uint256 cash = _usdtOf(address(this));
        vm.prank(KEEPER);
        lend.executeDeleverage(address(this), LISTA_ID);
        assertEq(credit.debt(LISTA_ID, address(this)), 0);
        assertEq(vault.balanceOf(address(this)), 0, "leftover strategy shares not redeemed");
        // The surplus stays in the same portfolio account.
        assertGt(_usdtOf(address(this)), cash);
        // Collateral is the account's to take back.
        _withdraw(LISTA_ID, type(uint256).max);
        assertEq(tsla.balanceOf(address(this)), 100e18);
        _noResidue();
    }

    function test_unwind_vaultUtilization_exactly95No_aboveYes() public {
        _post(VENUS_ID, 10e18);
        _borrow(VENUS_ID, 300e18);
        skip(30 days);
        _vaultUtilization(9_500);
        assertFalse(credit.status(VENUS_ID, address(this)).shouldUnwind);
        vm.expectRevert(AtpBorrowExecutor.NothingToDo.selector);
        lend.executeDeleverage(address(this), VENUS_ID);
        vault.setLiquidity(vault.totalAssets() - vault.totalBorrows() - 1);
        assertTrue(credit.status(VENUS_ID, address(this)).shouldUnwind);
        lend.executeDeleverage(address(this), VENUS_ID);
        assertEq(credit.debt(VENUS_ID, address(this)), 0);
    }

    // ---- protocol liquidation still works underneath; the ledger reconciles ----

    function test_venus_liquidationDrill() public {
        _post(VENUS_ID, 10e18);
        _borrow(VENUS_ID, 400e18);
        vm.prank(LIQUIDATOR);
        assertEq(vUsdt.liquidateBorrow(address(this), 100e18, address(vNvda)), 3); // healthy: refused

        oracle.setPrice(address(nvda), 70e8); // liquidation value 350 < debt 400
        assertLt(credit.health(VENUS_ID, address(this)).healthFactor, 1e18);
        vm.prank(LIQUIDATOR);
        assertEq(vUsdt.liquidateBorrow(address(this), 200e18 + 1, address(vNvda)), 3); // close factor 50%
        uint256 vBefore = vNvda.balanceOf(address(this));
        vm.prank(LIQUIDATOR);
        assertEq(vUsdt.liquidateBorrow(address(this), 100e18, address(vNvda)), 0);
        uint256 seized = vBefore - vNvda.balanceOf(address(this));
        assertApproxEqAbs(seized * vNvda.exchangeRateStored() / 1e18, uint256(110e18) * 1e8 / 70e8, 1e10);
        assertEq(credit.debt(VENUS_ID, address(this)), 300e18);

        assertEq(credit.principal(address(this), VENUS_ID), 400e18);
        credit.reconcile(address(this), VENUS_ID);
        assertEq(credit.principal(address(this), VENUS_ID), 300e18);
        assertEq(credit.totalPrincipal(VENUS_ID), 300e18);

        _repay(VENUS_ID, type(uint256).max, true);
        _withdraw(VENUS_ID, type(uint256).max);
        assertEq(credit.accountMarkets(address(this)).length, 0);
        _noResidue();
    }

    function test_lista_liquidationDrill() public {
        _post(LISTA_ID, 10e18);
        _borrow(LISTA_ID, 400e18);
        vm.prank(LIQUIDATOR);
        vm.expectRevert("healthy position");
        moolah.liquidate(listaParams, address(this), 1e18, 0, "");

        oracle.setPrice(address(tsla), 70e8);
        vm.prank(LIQUIDATOR);
        (uint256 seized, uint256 repaid) = moolah.liquidate(listaParams, address(this), 2e18, 0, "");
        assertEq(seized, 2e18);
        // Morpho incentive at LLTV 50%: min(1.15, 1 / (1 - 0.3 x 0.5)) = 1.15.
        assertApproxEqAbs(repaid, uint256(140e18) * 1e18 / 1.15e18, 1e6);
        credit.reconcile(address(this), LISTA_ID);
        assertApproxEqAbs(credit.principal(address(this), LISTA_ID), 400e18 - repaid, 2);
        _repay(LISTA_ID, type(uint256).max, true);
        _withdraw(LISTA_ID, type(uint256).max);
        assertEq(tsla.balanceOf(address(this)), 98e18);
        _noResidue();
    }

    function test_lista_badDebtIsSocialized_andLedgerCloses() public {
        _post(LISTA_ID, 10e18);
        _borrow(LISTA_ID, 400e18);
        oracle.setPrice(address(tsla), 10e8);
        bytes32 mid = moolah.marketId(listaParams);
        uint256 supplyBefore = moolah.market(mid).totalSupplyAssets;
        vm.prank(LIQUIDATOR);
        (, uint256 repaid) = moolah.liquidate(listaParams, address(this), 10e18, 0, "");
        (, uint128 shares, uint128 posted) = moolah.position(mid, address(this));
        assertEq(posted, 0);
        assertEq(shares, 0, "bad debt left on the borrower");
        assertApproxEqAbs(moolah.market(mid).totalSupplyAssets, supplyBefore - (400e18 - repaid), 2);
        credit.reconcile(address(this), LISTA_ID);
        assertEq(credit.principal(address(this), LISTA_ID), 0);
        assertEq(credit.totalPrincipal(LISTA_ID), 0);
        // The vault shares from the borrow are still the strategy's: the position stays listed until they exit.
        assertEq(credit.accountMarkets(address(this)).length, 1);
        uint256 cash = _usdtOf(address(this));
        _repay(LISTA_ID, type(uint256).max, true);
        assertApproxEqAbs(_usdtOf(address(this)), cash + 400e18, 1);
        assertEq(credit.accountMarkets(address(this)).length, 0);
        _noResidue();
    }

    function test_reconcile_neverRaisesPrincipal() public {
        _post(VENUS_ID, 10e18);
        _borrow(VENUS_ID, 100e18);
        skip(365 days);
        credit.status(VENUS_ID, address(this));
        assertGt(credit.debt(VENUS_ID, address(this)), 100e18);
        credit.reconcile(address(this), VENUS_ID);
        assertEq(credit.principal(address(this), VENUS_ID), 100e18);
    }
}
