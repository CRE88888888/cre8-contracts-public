// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { RoutingBase } from "./RoutingBase.sol";
import { AtpBorrowCashSwapper } from "../../../../src/atp/borrow/v2/AtpBorrowCashSwapper.sol";
import { IAtpBorrowCashSwapper as ISwapper } from "../../../../src/atp/borrow/v2/IAtpBorrowCashSwapper.sol";
import { MockStablePool } from "./mocks/MockStablePool.sol";

/// @dev `RoutingBase` (the test contract is the portfolio account and the registry owner) plus the cash
/// swapper and a mock USDT / USDC pool at parity with a 0.01% fee. `_openNegativeCarry` opens the position
/// the swapper exists for: NVDA on Venus, USDC borrowed at 2.5% into the Venus vUSDC vault, which earns
/// almost nothing (borrow rate x utilization); only the reported borrow incentive makes the carry positive.
abstract contract CashSwapperBase is RoutingBase {
    AtpBorrowCashSwapper internal swapper;
    MockStablePool internal pool;
    address internal constant STRANGER = address(0x57A6);

    function setUp() public virtual override {
        super.setUp();
        swapper = new AtpBorrowCashSwapper(address(lend));
        pool = new MockStablePool(address(usdt), address(usdc), 1e18);
        usdt.mint(address(pool), 10_000_000e18);
        usdc.mint(address(pool), 10_000_000e18);
        swapper.setPool(address(usdc), address(pool));
        // The account owner's two extra grants.
        usdt.approve(address(swapper), MAX);
        usdc.approve(address(swapper), MAX);
        usdt.mint(address(this), 100_000e18);
    }

    function _openNegativeCarry(uint256 borrow) internal {
        _report(uint256(VAULT_APR) * 1e14, 0, 0.05e18);
        _open(V_NVDA_C, K_VC, 100e18, borrow); // 100 NVDA = 10,000 USD, budget 3,000
    }

    /// @dev USDC costs (1 + bps / 10000) USDT in the pool (before its fee).
    function _setPremium(int256 bps) internal {
        uint256 ratio = uint256(10_000 + bps);
        pool.setPrice(pool.token0() == address(usdt) ? 1e18 * 10_000 / ratio : 1e18 * ratio / 10_000);
    }

    function _mode(MockStablePool.Mode mode) internal {
        pool.setMode(mode, address(0), address(0), "");
    }

    function _gap() internal returns (uint256 gap, uint256 cap) {
        return swapper.shortfall(address(this), address(usdc));
    }

    function _withBuffer(uint256 amount) internal view returns (uint256) {
        return amount + (amount * swapper.bufferBps() + 9_999) / 10_000;
    }

    /// @dev What the backend buys before a repayment: the gap the vaults leave, plus the buffer (the debt
    /// grows until the repayment lands), never above what a top-up may buy now.
    function _want() internal returns (uint256 amount) {
        (uint256 gap, uint256 cap) = _gap();
        amount = _withBuffer(gap);
        if (amount > cap) amount = cap;
    }

    function _topUpGap() internal returns (uint256 usdtIn, uint256 tokenOut) {
        return swapper.topUp(address(usdc), _want(), MAX, block.timestamp);
    }

    /// @dev The Venus vUSDC supply market has no cash: every redemption fails, every read still works.
    function _freezeVenusVault() internal {
        vm.mockCallRevert(address(vUsdc), abi.encodeWithSignature("redeem(uint256)"), "no cash");
        vm.mockCallRevert(address(vUsdc), abi.encodeWithSignature("redeemUnderlying(uint256)"), "no cash");
    }

    function _swapperHoldsNothing() internal view {
        assertEq(usdt.balanceOf(address(swapper)), 0, "swapper holds USDT");
        assertEq(usdc.balanceOf(address(swapper)), 0, "swapper holds USDC");
        assertEq(usdt.allowance(address(swapper), address(pool)), 0, "swapper left an allowance");
        assertEq(usdc.allowance(address(swapper), address(pool)), 0, "swapper left an allowance");
    }
}
