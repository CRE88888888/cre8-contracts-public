// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { CashSwapperBase } from "./CashSwapperBase.sol";
import { IAtpBorrowCashSwapper as ISwapper } from "../../../../src/atp/borrow/v2/IAtpBorrowCashSwapper.sol";
import { IAtpBorrowExecutorV2 as IExec } from "../../../../src/atp/borrow/v2/IAtpBorrowExecutorV2.sol";
import { IAtpBorrowLensV2 as ILens } from "../../../../src/atp/borrow/v2/IAtpBorrowLensV2.sol";

/// @notice Fourth review (docs/borrow-routing-v2.zh-TW.md §18) of `AtpBorrowCashSwapper`, on the unit fixture:
/// the reviewer's probes turned around (each held before the fix), and the rules that replaced what they
/// broke. M-1's gas-starved read needs a real Lista vault: test/atp/fork/BorrowCashSwapperFork.t.sol.
contract CashSwapperReviewTest is CashSwapperBase {
    uint256 internal constant DAY = 1 days;

    /// @dev The debt in USDC after accrual (what the swapper reads).
    function _owed() internal returns (uint256) {
        lens.syncToken(address(this), address(usdc));
        return lens.tokenDebt(address(this), address(usdc));
    }

    function _window() internal view returns (uint64 start, uint192 bought, uint256 peakDebt) {
        return swapper.topUpWindowOf(address(this), address(usdc));
    }

    /// @dev Borrow again into the Venus vault (a session key may: `executeOpen`), rates freshly reported.
    function _borrow(uint256 amount) internal {
        _report(uint256(VAULT_APR) * 1e14, 0, 0.05e18);
        _open(V_NVDA_C, K_VC, 0, amount);
    }

    // ------------------------------------------------------------------------------------------------
    // M-3. The reviewer's probe (R4SwapperPoC.test_R4_limit_vaultReadsFullButCannotPay...): the vault
    // reads full and cannot pay. Before: only the organic gap could be bought, then the close and the
    // third-party deleverage both failed with 100,000 USDT in the account. Now the account buys what
    // the repayment needs, the keeper gets the position back inside its budget, and the close goes
    // through; the vault's holding waits in the box for `executeRelease`.
    // ------------------------------------------------------------------------------------------------
    function test_M3_vaultReadsFullButCannotPay_topUpServesTheDeleverageAndTheClose() public {
        _openNegativeCarry(2_900e18);
        skip(30 days);
        _freezeVenusVault();
        uint256 owed = _owed();
        (uint256 gap, uint256 cap) = _gap();
        assertLt(gap, owed / 100, "the reader's gap is the organic one: the vault reads full");
        assertEq(cap, _withBuffer(owed), "what may be bought is the debt, whatever the vault reads");
        vm.expectPartialRevert(IExec.VaultShortfall.selector);
        _reduce(V_NVDA_C, K_VC, MAX, MAX, 0);

        // Prices fall past the deleverage line. The keeper finds nothing it can take from the vault...
        oracle.setPrice(address(nvda), 60e8);
        uint256 excess = lens.deleverageAmount(V_NVDA_C, address(this));
        assertGt(excess, 1_000e18);
        vm.prank(KEEPER);
        vm.expectPartialRevert(ILens.VaultShortfall.selector);
        lend.executeDeleverage(address(this), V_NVDA_C, K_VC, MAX);
        // ...until the account buys the excess (it was refused as NoShortfall / AboveShortfall before).
        swapper.topUp(address(usdc), excess, MAX, block.timestamp);
        vm.prank(KEEPER);
        uint256 repaid = lend.executeDeleverage(address(this), V_NVDA_C, K_VC, MAX);
        assertEq(repaid, excess);
        assertEq(lens.deleverageAmount(V_NVDA_C, address(this)), 0, "back inside the budget");

        // The rest of the debt, then the ordinary close with no account cash.
        uint256 rest = _withBuffer(_owed());
        swapper.topUp(address(usdc), rest, MAX, block.timestamp);
        _reduce(V_NVDA_C, K_VC, MAX, MAX, 0);
        assertEq(_owed(), 0, "debt closed");
        assertEq(nvda.balanceOf(address(this)), 1_000e18, "collateral back");
        assertEq(lens.idleOf(address(this), address(usdc)), 0);
        assertApproxEqAbs(usdc.balanceOf(address(this)), rest - (owed - excess), 1e12, "the buffer came back");
        (, uint192 bought, uint256 peak) = _window();
        assertEq(bought, excess + rest);
        assertLe(bought, _withBuffer(peak), "all of it inside one window's allowance");

        // The vault pays again: its holding returns to the account and everything ends as USDT.
        vm.clearMockedCalls();
        lend.executeRelease(address(this), K_VC, block.timestamp);
        assertApproxEqRel(usdc.balanceOf(address(this)), 2_900e18, 0.02e18, "the vault's holding");
        swapper.cashOut(address(usdc), MAX, 0, block.timestamp);
        assertEq(usdc.balanceOf(address(this)), 0);
        _swapperHoldsNothing();
        _noResidue();
    }

    // ------------------------------------------------------------------------------------------------
    // M-2. One lap per window: top up the whole debt, close, cash out, borrow again. The second lap is
    // refused until the window that the first top-up opened is over.
    // ------------------------------------------------------------------------------------------------
    function test_M2_window_oneLapPerWindow_borrowingAgainDoesNotReopenIt() public {
        _openNegativeCarry(2_000e18);
        skip(1 hours);
        uint256 owed = _owed();
        (, uint256 cap) = _gap();
        assertEq(cap, _withBuffer(owed));
        uint256 opened = vm.getBlockTimestamp();
        swapper.topUp(address(usdc), cap, MAX, block.timestamp);
        (uint64 start, uint192 bought, uint256 peak) = _window();
        assertEq(start, opened);
        assertEq(bought, cap);
        assertEq(peak, owed);

        _reduce(V_NVDA_C, K_VC, MAX, 0, 0);
        assertEq(_owed(), 0);
        swapper.cashOut(address(usdc), MAX, 0, block.timestamp);
        _borrow(2_000e18);

        // The box is short of the new debt again, and nothing more may be bought.
        (, cap) = _gap();
        assertEq(cap, 0, "the window is used up");
        vm.expectRevert(abi.encodeWithSelector(ISwapper.WindowExceeded.selector, bought + 1, bought));
        swapper.topUp(address(usdc), 1, MAX, block.timestamp);
        // Not by waiting less than the window. The debt's own interest raises the highest debt, and with it
        // the allowance, by that interest: a fraction of one token here.
        skip(DAY - 1);
        (, cap) = _gap();
        assertEq(cap, _withBuffer(_owed()) - bought);
        assertLt(cap, 0.2e18);
        vm.expectPartialRevert(ISwapper.WindowExceeded.selector);
        swapper.topUp(address(usdc), 1e18, MAX, block.timestamp);
        // Cashing out is never limited, and finds nothing to sell: only a top-up brings loan token back.
        vm.expectRevert(ISwapper.ZeroAmount.selector);
        swapper.cashOut(address(usdc), MAX, 0, block.timestamp);

        // At `start + TOP_UP_WINDOW` the next top-up opens a fresh window.
        skip(1);
        assertEq(vm.getBlockTimestamp(), opened + DAY);
        owed = _owed();
        (, cap) = _gap();
        assertEq(cap, _withBuffer(owed));
        swapper.topUp(address(usdc), cap, MAX, block.timestamp);
        (start, bought, peak) = _window();
        assertEq(start, opened + DAY);
        assertEq(bought, cap);
        assertEq(peak, owed);
    }

    /// The allowance is the highest debt a top-up of the window found: borrowing more inside the window adds
    /// only the new debt to it, and the window's purchases never pass that debt plus the buffer.
    function test_M2_window_allowanceFollowsTheHighestDebtOfTheWindow() public {
        _openNegativeCarry(1_000e18);
        skip(1 hours);
        uint256 first = _withBuffer(_owed());
        swapper.topUp(address(usdc), first, MAX, block.timestamp);
        _reduce(V_NVDA_C, K_VC, MAX, 0, 0);
        swapper.cashOut(address(usdc), MAX, 0, block.timestamp);
        _borrow(2_500e18);
        uint256 owed = _owed();
        (, uint256 cap) = _gap();
        assertEq(cap, _withBuffer(owed) - first, "only what the higher debt adds");
        vm.expectRevert(
            abi.encodeWithSelector(ISwapper.WindowExceeded.selector, first + cap + 1, _withBuffer(owed))
        );
        swapper.topUp(address(usdc), cap + 1, MAX, block.timestamp);
        swapper.topUp(address(usdc), cap, MAX, block.timestamp);
        (, uint192 bought, uint256 peak) = _window();
        assertEq(peak, owed);
        assertEq(bought, _withBuffer(peak));
        // Repaying part of it (the box's idle loan token pays first) and borrowing it again makes no room.
        _reduce(V_NVDA_C, K_VC, 500e18, 0, 0);
        _borrow(500e18);
        assertLt(lens.idleOf(address(this), address(usdc)), _owed());
        vm.expectRevert(abi.encodeWithSelector(ISwapper.WindowExceeded.selector, bought + 1, bought));
        swapper.topUp(address(usdc), 1, MAX, block.timestamp);
    }

    /// Why the allowance is the window's highest debt and not the debt of the moment: a top-up that is
    /// repaid lowers the debt, and the account must still be able to buy the rest (a staged deleverage on a
    /// vault that cannot pay). Total bought stays within the debt the window started from, plus the buffer.
    function test_M2_window_partialTopUpsAndRepaymentsNeverBlockTheExit() public {
        _openNegativeCarry(2_000e18);
        skip(1 hours);
        _freezeVenusVault();
        uint256 owed = _owed();
        swapper.topUp(address(usdc), 1_200e18, MAX, block.timestamp);
        _reduce(V_NVDA_C, K_VC, 1_200e18, 0, 0);
        assertEq(_owed(), owed - 1_200e18);
        // 1,200 bought already is more than the 800 still owed: the rest is still allowed.
        uint256 rest = _withBuffer(_owed());
        (, uint256 cap) = _gap();
        assertEq(cap, rest);
        swapper.topUp(address(usdc), rest, MAX, block.timestamp);
        _reduce(V_NVDA_C, K_VC, MAX, MAX, 0);
        assertEq(_owed(), 0);
        assertEq(nvda.balanceOf(address(this)), 1_000e18, "collateral back");
        (, uint192 bought, uint256 peak) = _window();
        assertEq(peak, owed);
        assertLe(bought, _withBuffer(owed));
    }

    /// The window is the account's and the token's: another account's purchases, or the same account's in
    /// another token, do not touch it.
    function test_M2_window_isPerAccountAndPerToken() public {
        _openNegativeCarry(2_000e18);
        skip(1 hours);
        swapper.topUp(address(usdc), 10e18, MAX, block.timestamp);
        (uint64 start, uint192 bought,) = _window();
        assertEq(bought, 10e18);
        assertEq(start, vm.getBlockTimestamp());
        (start, bought,) = swapper.topUpWindowOf(address(this), address(usdt));
        assertEq(uint256(start) + bought, 0);
        (start, bought,) = swapper.topUpWindowOf(STRANGER, address(usdc));
        assertEq(uint256(start) + bought, 0);
    }

    // ------------------------------------------------------------------------------------------------
    // M-2, in money. Whoever holds the key runs the lap as often as the contract lets it, every leg at the
    // edge of the peg bound (USDC dear when the account buys it, cheap when it sells: a sandwiched pool).
    // Over three days, tried every six hours: three laps go through, and the account's loss on the swaps
    // stays below laps x 2 x maxPegBps x (1 + bufferBps) x debt.
    // ------------------------------------------------------------------------------------------------
    function test_M2_roundTripWear_isBoundedByOneLapPerWindow() public {
        _openNegativeCarry(2_000e18);
        skip(1 hours);
        uint256 laps;
        uint256 refused;
        uint256 wear;
        uint256 peak;
        for (uint256 i; i < 12; ++i) {
            uint256 owed = _owed();
            if (owed > peak) peak = owed;
            (, uint256 cap) = _gap();
            _setPremium(23); // + the pool's 0.01% fee: just inside the 0.25% bound
            if (cap < 1e18) {
                // Inside a used window: only the interest the debt earned since may still be bought.
                vm.expectPartialRevert(ISwapper.WindowExceeded.selector);
                swapper.topUp(address(usdc), 1e18, MAX, block.timestamp);
                ++refused;
            } else {
                assertEq(cap, _withBuffer(owed), "a fresh window: the whole debt");
                (uint256 usdtIn, uint256 out) = swapper.topUp(address(usdc), cap, MAX, block.timestamp);
                _reduce(V_NVDA_C, K_VC, MAX, 0, 0);
                _setPremium(-23);
                (uint256 sold, uint256 usdtOut) = swapper.cashOut(address(usdc), MAX, 0, block.timestamp);
                wear += usdtIn - out + sold - usdtOut;
                ++laps;
                _borrow(2_000e18);
            }
            skip(6 hours);
        }
        assertEq(laps, 3, "one lap per 24-hour window");
        assertEq(refused, 9);
        // Per lap: a top-up of debt x 1.01 and a cash-out of about as much (plus the vault's holding beyond
        // the debt, here nothing), each at most 0.25% away from parity.
        uint256 perLap = 2 * _withBuffer(peak) * swapper.maxPegBps() / 10_000;
        assertLe(wear, laps * perLap, "wear above one lap per window at the peg bound");
        assertGt(wear, laps * perLap * 90 / 100, "the laps really ran at the edge of the bound");
        emit log_named_decimal_uint("wear over 3 days, USDT", wear, 18);
        emit log_named_decimal_uint("wear per day, bps of the debt (x100)", wear * 1_000_000 / (3 * peak), 2);
    }

    // ------------------------------------------------------------------------------------------------
    // I-1. The reviewer's probe: `amountIn` >= 2^255 (other than MAX) was cast unchecked and became an
    // exact-OUTPUT swap of (2^256 - amountIn) USDT. Now it is refused.
    // ------------------------------------------------------------------------------------------------
    function test_I1_cashOut_amountAboveInt256Max_isRefused() public {
        usdc.mint(address(this), 1_000e18);
        uint256 weird = MAX - 5e18 + 1; // int256(weird) == -5e18
        vm.expectRevert(abi.encodeWithSelector(SafeCast.SafeCastOverflowedUintToInt.selector, weird));
        swapper.cashOut(address(usdc), weird, 0, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(SafeCast.SafeCastOverflowedUintToInt.selector, 1 << 255));
        swapper.cashOut(address(usdc), 1 << 255, 0, block.timestamp);
        assertEq(usdc.balanceOf(address(this)), 1_000e18);
        // MAX still means the whole balance.
        (uint256 sold,) = swapper.cashOut(address(usdc), MAX, 0, block.timestamp);
        assertEq(sold, 1_000e18);
    }
}
