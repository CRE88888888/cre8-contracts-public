// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

interface ISwapCallback {
    function pancakeV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external;
}

/// @dev Calls the swapper's callback as somebody who is not the pool of the swap in flight.
contract CallbackAccomplice {
    function call(address swapper, int256 amount0, int256 amount1, bytes calldata data) external {
        ISwapCallback(swapper).pancakeV3SwapCallback(amount0, amount1, data);
    }
}

/// @dev A two-token pool with the swap surface of a PancakeSwap V3 pool, a fixed price and a fee, for the
/// `AtpBorrowCashSwapper` tests. It pays out of its own balance (the test funds it). `mode` makes it misbehave
/// the ways a wrongly allowlisted pool could.
contract MockStablePool {
    enum Mode {
        HONEST,
        PARTIAL, // fills half of an exact output and charges for that half (a V3 pool at its price limit)
        SKIM, // charges in full, delivers 90%
        OVERFILL, // trades twice the size asked for, at its price
        DOUBLE_CHARGE, // asks the callback for the input twice
        WRONG_PAYER, // hands the callback another payer
        WRONG_TOKEN, // hands the callback another token to pull
        REENTER, // calls back into the swapper's entry points in the middle of the swap
        ACCOMPLICE // lets a third contract call the callback in the middle of the swap
    }

    address public immutable token0;
    address public immutable token1;
    /// @dev token1 raw units per token0 raw unit, 18 decimals.
    uint256 public priceE18;
    /// @dev Hundredths of a bip, like a V3 pool: 100 = 0.01%.
    uint256 public feePips = 100;
    Mode public mode;
    address public victim;
    address public otherToken;
    CallbackAccomplice public immutable accomplice = new CallbackAccomplice();
    bytes public reentry;
    bytes public reentryResult;

    constructor(address a, address b, uint256 priceE18_) {
        (token0, token1) = a < b ? (a, b) : (b, a);
        priceE18 = priceE18_;
    }

    function setPrice(uint256 priceE18_) external {
        priceE18 = priceE18_;
    }

    function setMode(Mode mode_, address victim_, address otherToken_, bytes calldata reentry_) external {
        (mode, victim, otherToken, reentry) = (mode_, victim_, otherToken_, reentry_);
    }

    function swap(address recipient, bool zeroForOne, int256 amount, uint160, bytes calldata data)
        external
        returns (int256 amount0, int256 amount1)
    {
        uint256 amountIn;
        uint256 amountOut;
        if (amount > 0) {
            amountIn = uint256(amount) * (mode == Mode.OVERFILL ? 2 : 1);
            uint256 net = amountIn - Math.mulDiv(amountIn, feePips, 1e6, Math.Rounding.Ceil);
            amountOut = zeroForOne ? net * priceE18 / 1e18 : net * 1e18 / priceE18;
        } else {
            amountOut = uint256(-amount);
            if (mode == Mode.PARTIAL) amountOut /= 2;
            if (mode == Mode.OVERFILL) amountOut *= 2;
            uint256 net = zeroForOne
                ? Math.mulDiv(amountOut, 1e18, priceE18, Math.Rounding.Ceil)
                : Math.mulDiv(amountOut, priceE18, 1e18, Math.Rounding.Ceil);
            amountIn = Math.mulDiv(net, 1e6, 1e6 - feePips, Math.Rounding.Ceil);
        }
        (address tokenIn, address tokenOut) = zeroForOne ? (token0, token1) : (token1, token0);
        IERC20(tokenOut).transfer(recipient, mode == Mode.SKIM ? amountOut * 9 / 10 : amountOut);
        (amount0, amount1) =
            zeroForOne ? (int256(amountIn), -int256(amountOut)) : (-int256(amountOut), int256(amountIn));

        uint256 before = IERC20(tokenIn).balanceOf(address(this));
        bytes memory handed = data;
        if (mode == Mode.WRONG_PAYER) handed = abi.encode(victim, tokenIn);
        if (mode == Mode.WRONG_TOKEN) handed = abi.encode(abi.decode(data, (address)), otherToken);
        if (mode == Mode.REENTER) {
            (bool ok, bytes memory ret) = msg.sender.call(reentry);
            require(!ok, "re-entry went through");
            reentryResult = ret;
        }
        if (mode == Mode.ACCOMPLICE) {
            try accomplice.call(msg.sender, amount0, amount1, data) {
                revert("accomplice was paid");
            } catch (bytes memory ret) {
                reentryResult = ret;
            }
        }
        ISwapCallback(msg.sender).pancakeV3SwapCallback(amount0, amount1, handed);
        if (mode == Mode.DOUBLE_CHARGE) {
            ISwapCallback(msg.sender).pancakeV3SwapCallback(amount0, amount1, handed);
        }
        require(IERC20(tokenIn).balanceOf(address(this)) >= before + amountIn, "IIA");
    }
}
