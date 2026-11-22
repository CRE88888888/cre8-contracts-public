// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { AtpBorrowBase } from "./AtpBorrowBase.sol";
import { AtpRegistry } from "../../../src/atp/AtpRegistry.sol";
import { AtpBorrowExecutor } from "../../../src/atp/borrow/AtpBorrowExecutor.sol";
import { BorrowTypes as B } from "../../../src/atp/borrow/BorrowTypes.sol";

/// @notice #64 normal paths (EARN_UX §B): collateral -> borrow straight into the vault -> close (vault -> repay ->
/// collateral back), both protocols; the strategy's USDT never shows up as free cash in the account.
contract AtpBorrowFlowTest is AtpBorrowBase {
    function test_venus_fullCycle() public {
        _fullCycle(VENUS_ID);
        assertEq(vNvda.balanceOf(address(this)), 0, "vToken collateral left");
    }

    function test_lista_fullCycle() public {
        _fullCycle(LISTA_ID);
        (, uint128 shares, uint128 posted) = moolah.position(moolah.marketId(listaParams), address(this));
        assertEq(shares, 0, "borrow shares left");
        assertEq(posted, 0, "collateral left");
    }

    function _fullCycle(bytes32 id) internal {
        uint256 tokenStart = _token(id).balanceOf(address(this));
        uint256 usdtStart = _usdtOf(address(this));

        _post(id, 10e18);
        assertEq(_token(id).balanceOf(address(this)), tokenStart - 10e18);
        assertApproxEqAbs(credit.collateral(id, address(this)), 10e18, 1);
        B.Health memory h = credit.health(id, address(this));
        assertApproxEqAbs(h.collateralValue, 1624.13e18, 1e9);
        assertApproxEqAbs(h.liquidationValue, 812.065e18, 1e9);
        assertEq(h.debtValue, 0);
        assertEq(credit.accountMarkets(address(this)).length, 1);

        _borrow(id, 300e18);
        // Borrowed USDT went straight into the vault for this account: no free cash appeared.
        assertEq(_usdtOf(address(this)), usdtStart, "borrowed USDT surfaced as cash");
        uint256 shares = vault.balanceOf(address(this));
        assertGt(shares, 0);
        assertEq(credit.vaultShares(address(this), id), shares);
        assertApproxEqAbs(vault.previewRedeem(shares), 300e18, 1);
        assertEq(credit.debt(id, address(this)), 300e18);
        assertEq(credit.principal(address(this), id), 300e18);
        assertApproxEqAbs(_ltv(id), uint256(300e18) * 1e18 / 1624.13e18, 1);

        skip(30 days);
        vm.roll(block.number + 1);
        B.Status memory s = credit.status(id, address(this));
        uint256 principal_ = 300e18;
        assertApproxEqAbs(s.debt, principal_ + principal_ * BORROW_APR * 30 days / (10_000 * 365 days), 1e12);
        assertApproxEqAbs(
            s.vaultAssets, principal_ + principal_ * VAULT_APR * 30 days / (10_000 * 365 days), 1e12
        );

        // Close: vault -> repay -> the rest of the vault into the account -> collateral back.
        _repay(id, type(uint256).max, true);
        assertEq(credit.debt(id, address(this)), 0);
        assertEq(credit.principal(address(this), id), 0);
        assertEq(credit.totalPrincipal(id), 0);
        assertEq(vault.balanceOf(address(this)), 0, "strategy shares left");
        assertEq(credit.vaultShares(address(this), id), 0);
        _withdraw(id, type(uint256).max);
        assertEq(_token(id).balanceOf(address(this)), tokenStart, "collateral not returned");
        assertEq(credit.accountMarkets(address(this)).length, 0, "position not closed");
        // Net carry stays in the portfolio account: (4.5% - 2.5%) on 300 USDT for 30 days.
        assertApproxEqAbs(
            _usdtOf(address(this)) - usdtStart,
            principal_ * (VAULT_APR - BORROW_APR) * 30 days / (10_000 * 365 days),
            0.001e18
        );
        _noResidue();
    }

    function test_venus_lendersEarnWhatBorrowersPay() public {
        _post(VENUS_ID, 10e18);
        _borrow(VENUS_ID, 300e18);
        uint256 rateBefore = vUsdt.exchangeRateStored();
        skip(365 days);
        vUsdt.accrueInterest();
        assertEq(vUsdt.borrowBalanceStored(address(this)), 307.5e18, "2.5% APR on 300");
        uint256 claim = vUsdt.balanceOf(LENDER) * vUsdt.exchangeRateStored() / 1e18;
        assertApproxEqAbs(claim, 1_000_007.5e18, 1e9);
        assertGt(vUsdt.exchangeRateStored(), rateBefore);
    }

    function test_partialRepay_fromVault_andFromAccount() public {
        for (uint256 i; i < 2; ++i) {
            bytes32 id = i == 0 ? VENUS_ID : LISTA_ID;
            _post(id, 10e18);
            _borrow(id, 400e18);
            skip(7 days);
            uint256 shares = vault.balanceOf(address(this));
            _repay(id, 100e18, true);
            assertLt(vault.balanceOf(address(this)), shares, "vault shares not used");
            uint256 cash = _usdtOf(address(this));
            _repay(id, 50e18, false);
            assertEq(_usdtOf(address(this)), cash - 50e18, "account cash not used");
            assertEq(credit.principal(address(this), id), 250e18);
            uint256 left = credit.debt(id, address(this));
            assertGt(left, 250e18);
            assertLe(left, 251e18);
            _withdraw(id, 3e18);
            assertLe(_ltv(id), credit.targetLtv(id));
            _repay(id, type(uint256).max, true);
            _withdraw(id, type(uint256).max);
            assertEq(credit.debt(id, address(this)), 0);
            assertEq(credit.collateral(id, address(this)), 0);
            assertEq(vault.balanceOf(address(this)), 0);
        }
        assertEq(nvda.balanceOf(address(this)), 100e18);
        assertEq(tsla.balanceOf(address(this)), 100e18);
        _noResidue();
    }

    function test_repayMoreThanDebt_isCappedAtDebt() public {
        _post(VENUS_ID, 10e18);
        _borrow(VENUS_ID, 100e18);
        uint256 before = _usdtOf(address(this));
        vm.expectEmit(true, true, false, false, address(lend));
        emit AtpBorrowExecutor.Repaid(address(this), VENUS_ID, 100e18, 0, 0);
        _repay(VENUS_ID, 1_000e18, false);
        assertEq(credit.debt(VENUS_ID, address(this)), 0);
        // Pulled exactly the 100 USDT debt, then the strategy's 100 USDT of vault shares came back into the
        // same account now that no debt is left.
        assertEq(vault.balanceOf(address(this)), 0);
        assertApproxEqAbs(_usdtOf(address(this)), before, 1);
    }

    /// @notice Vault worth less than the debt (vault rate dropped): close uses every strategy share, then the
    /// portfolio account's own USDT for the gap.
    function test_closeFromVault_shortVault_topsUpFromAccountCash() public {
        _post(LISTA_ID, 10e18);
        _borrow(LISTA_ID, 300e18);
        vault.setAprBps(0);
        skip(365 days);
        credit.status(LISTA_ID, address(this));
        uint256 owed = credit.debt(LISTA_ID, address(this));
        uint256 worth = vault.previewRedeem(vault.balanceOf(address(this)));
        assertGt(owed, worth);
        uint256 cash = _usdtOf(address(this));
        _repay(LISTA_ID, type(uint256).max, true);
        assertEq(credit.debt(LISTA_ID, address(this)), 0);
        assertEq(vault.balanceOf(address(this)), 0);
        assertApproxEqAbs(cash - _usdtOf(address(this)), owed - worth, 2);
        _noResidue();
    }

    function test_twoCollateralMarkets_trackedSeparately() public {
        _post(VENUS_ID, 10e18);
        _post(LISTA_ID, 10e18);
        _borrow(VENUS_ID, 100e18);
        _borrow(LISTA_ID, 200e18);
        assertEq(credit.accountMarkets(address(this)).length, 2);
        assertEq(credit.totalPrincipal(VENUS_ID), 100e18);
        assertEq(credit.totalPrincipal(LISTA_ID), 200e18);
        uint256 listaShares = credit.vaultShares(address(this), LISTA_ID);
        _repay(VENUS_ID, type(uint256).max, true);
        _withdraw(VENUS_ID, type(uint256).max);
        bytes32[] memory open = credit.accountMarkets(address(this));
        assertEq(open.length, 1);
        assertEq(open[0], LISTA_ID);
        // Closing one route never touches the other route's vault shares.
        assertEq(credit.vaultShares(address(this), LISTA_ID), listaShares);
        assertEq(vault.balanceOf(address(this)), listaShares);
    }

    /// @notice The one "extra APY" number from the status read: (vault - borrow) x ratio + collateral rate.
    function test_status_preBuyQuote_andPositionRatio() public {
        B.Status memory s = credit.status(VENUS_ID, address(0));
        assertEq(uint8(s.gate), uint8(B.Gate.OPEN));
        assertEq(s.liquidationLtv, 0.5e18);
        assertEq(s.targetLtv, 0.25e18);
        assertEq(s.deleverageLtv, 0.333333333333333333e18);
        assertEq(s.vaultRate, 0.045e18);
        assertApproxEqRel(s.borrowRate, 0.025e18, 1e12);
        assertEq(s.collateralRate, 0);
        uint256 extra = (s.vaultRate - s.borrowRate) * s.targetLtv / 1e18 + s.collateralRate;
        assertApproxEqRel(extra, 0.005e18, 1e10); // 0.5% on top of the portfolio's own return

        _post(VENUS_ID, 10e18);
        _borrow(VENUS_ID, 300e18);
        s = credit.status(VENUS_ID, address(this));
        assertApproxEqAbs(s.ltv, uint256(300e18) * 1e18 / 1624.13e18, 1);
        assertEq(s.debt, 300e18);
        assertApproxEqAbs(s.vaultAssets, 300e18, 1);
        assertFalse(s.shouldDeleverage);
        assertFalse(s.shouldUnwind);

        s = credit.status(LISTA_ID, address(0));
        assertApproxEqRel(s.borrowRate, 0.025e18, 1e12);
        assertEq(s.targetLtv, 0.25e18);
    }

    function test_registryIsBoundToExecutor() public view {
        assertEq(credit.executor(), address(lend));
        assertEq(address(credit.registry()), address(registry));
        assertEq(address(credit.yields()), address(yields));
        assertEq(credit.numeraire(), address(usdt));
        assertEq(address(lend.atpExecutor()), address(executor));
        assertEq(credit.marketCount(), 2);
        assertEq(credit.market(VENUS_ID).earnVault, address(vault));
        assertEq(credit.collateralMarket(address(nvda)), VENUS_ID);
        assertEq(credit.collateralMarket(address(tsla)), LISTA_ID);
    }

    function test_constructorRejectsForeignRegistry() public {
        address foreign = address(new Dummy());
        vm.expectRevert(AtpBorrowExecutor.InvalidConfig.selector);
        new AtpBorrowExecutor(AtpRegistry(foreign), address(executor));
    }
}

contract Dummy { }
