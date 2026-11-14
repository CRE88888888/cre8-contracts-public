// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IPancakeV3Pool } from "../../../src/atp/interfaces/IPancakeV3Pool.sol";

/// @dev Minimal Pancake V3 swapper: exact-input swaps straight against a pool (the review's PoC swapper).
contract PoolSwapper {
    function swap(IPancakeV3Pool pool, bool zeroForOne, int256 amount) external {
        uint160 limit =
            zeroForOne ? 4_295_128_740 : 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_341;
        (bool ok, bytes memory ret) = address(pool)
            .call(
                abi.encodeWithSignature(
                    "swap(address,bool,int256,uint160,bytes)",
                    address(this),
                    zeroForOne,
                    amount,
                    limit,
                    bytes("")
                )
            );
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
    }

    function pancakeV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        IPancakeV3Pool pool = IPancakeV3Pool(msg.sender);
        if (amount0Delta > 0) IERC20(pool.token0()).transfer(msg.sender, uint256(amount0Delta));
        if (amount1Delta > 0) IERC20(pool.token1()).transfer(msg.sender, uint256(amount1Delta));
    }
}

/// @dev Fork-only stand-in for "the market traded this pool". A fork has no other traders, so after a
/// `vm.warp` every pool looks idle and the oracle's `maxOracleAge` check (cre8-contracts#25, M-1) correctly
/// refuses it. `_touch` makes the pool write a fresh observation the way a real trade does: buy the asset with
/// USDT, doubling the size until the tick moves (a pool writes an observation only when its tick changes),
/// then sell everything back so the price ends where it started up to fees.
abstract contract ForkPoolHelpers is Test {
    address internal constant FORK_USDT = 0x55d398326f99059fF775485246999027B3197955;

    PoolSwapper internal swapper;

    function _touch(address poolAddress) internal {
        if (address(swapper) == address(0)) swapper = new PoolSwapper();
        IPancakeV3Pool pool = IPancakeV3Pool(poolAddress);
        bool usdtIsToken0 = pool.token0() == FORK_USDT;
        require(usdtIsToken0 || pool.token1() == FORK_USDT, "not a USDT pool");
        IERC20 asset = IERC20(usdtIsToken0 ? pool.token1() : pool.token0());
        (, int24 tickBefore,,,,,) = pool.slot0();
        uint256 size = 1e18; // 1 USDT
        for (uint256 i; i < 24; ++i) {
            deal(FORK_USDT, address(swapper), size);
            swapper.swap(pool, usdtIsToken0, int256(size));
            (, int24 tickAfter,,,,,) = pool.slot0();
            if (tickAfter != tickBefore) {
                swapper.swap(pool, !usdtIsToken0, int256(asset.balanceOf(address(swapper))));
                return;
            }
            size *= 2;
        }
        revert("touch: tick did not move");
    }

    /// @dev Age of the pool's newest observation, as `PancakeV3TwapOracle` measures it.
    function _observationAge(address poolAddress) internal view returns (uint256) {
        IPancakeV3Pool pool = IPancakeV3Pool(poolAddress);
        (,, uint16 index,,,,) = pool.slot0();
        (uint32 observedAt,,,) = pool.observations(index);
        return vm.getBlockTimestamp() - observedAt;
    }
}
