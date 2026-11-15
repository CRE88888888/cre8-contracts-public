// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Script, console } from "forge-std/Script.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { AtpExecutor } from "../../src/atp/AtpExecutor.sol";
import { IPancakeV3Pool } from "../../src/atp/interfaces/IPancakeV3Pool.sol";
import { TestnetToken } from "../../src/testnet/TestnetToken.sol";
import { TestnetAssets } from "./TestnetAssets.sol";
import { TestnetBook } from "./TestnetBook.sol";

interface IPokeV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address);
}

/// @dev PancakeSwap V3 `SwapRouter` (the one the backend price keeper uses), chain 97.
interface IPokeSwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function factory() external view returns (address);
    function exactInputSingle(ExactInputSingleParams calldata params)
        external
        payable
        returns (uint256 amountOut);
}

/// @title PokePoolsTestnet
/// @notice Chain 97 keeper action (cre8-contracts#39): one tick-moving swap in every `TestnetAssets` pool, as
/// KEEPER, through the same Pancake V3 `SwapRouter` the backend price keeper uses. Since #25 an oracle stops
/// quoting (`TwapUnavailable`) once its pool has gone `maxOracleAge` (1 hour) without a new observation, and a
/// pool only writes one on a swap that moves its tick; so each pool needs at least this one swap an hour. Each
/// swap trades `POKE_USDT` worth toward the `TestnetAssets` baseline (sells the asset when the pool is at or
/// above it, buys otherwise), which moves the price about 4 bps on the 5M-per-side full-range liquidity.
/// @dev Measures the keeper's hourly floor: the first run mints the keeper's inventory and approves the router
/// (one-off), a second run is the steady state of exactly one swap per pool (`fork-e2e.sh` step 4 prints its gas).
/// On a public chain it spends the keeper's tBNB, so there it is a manual fallback until the price keeper covers
/// every pool. `TESTNET_EXECUTOR` locates USDT, like `SmokeTestnet`.
///   forge script script/testnet/PokePoolsTestnet.s.sol --rpc-url <97> --broadcast --private-key <keeper>
contract PokePoolsTestnet is Script {
    address internal constant V3_FACTORY = 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865;
    address internal constant SWAP_ROUTER = 0x1b81D678ffb9C0263b24A97847620C99d213eB14;
    /// @dev Trade size per pool, in USDT: ~4 bps on 5M USDT per side, comfortably more than one tick (1 bp).
    uint256 internal constant POKE_USDT = 1_000e18;
    /// @dev Inventory the keeper keeps, in pokes per token (USDT: rounds of every pool buying), so a steady-state
    /// round is swaps only: the first round stocks and approves both sides of every pool, whichever way it trades.
    uint256 internal constant INVENTORY_POKES = 20;

    function run() external {
        require(block.chainid == 97, "PokePoolsTestnet: chain 97 only");
        require(IPokeSwapRouter(SWAP_ROUTER).factory() == V3_FACTORY, "SwapRouter / factory mismatch");
        address usdt = AtpExecutor(vm.envAddress("TESTNET_EXECUTOR")).numeraire();
        TestnetAssets.AssetSpec[] memory specs = TestnetAssets.specs();

        vm.startBroadcast(TestnetBook.KEEPER);
        _stock(usdt, POKE_USDT * specs.length);
        uint256 sells;
        for (uint256 i; i < specs.length; ++i) {
            if (_poke(specs[i], usdt)) ++sells;
        }
        vm.stopBroadcast();
        console.log("POKE pools (sells, buys)", specs.length, sells, specs.length - sells);
    }

    /// @return sold whether this pool's swap sold the asset (pool at or above the baseline) or bought it.
    function _poke(TestnetAssets.AssetSpec memory spec, address usdt) internal returns (bool sold) {
        address token = TestnetBook.tokenAddress(spec, TestnetBook.DEPLOYER);
        IPancakeV3Pool pool = IPancakeV3Pool(IPokeV3Factory(V3_FACTORY).getPool(token, usdt, spec.fee));
        require(address(pool) != address(0), string.concat(spec.symbol, ": no pool"));
        (uint160 sqrtPriceX96, int24 tickBefore,,,,,) = pool.slot0();

        // Asset price in USDT rises with sqrtPrice when the asset is token0, falls when it is token1.
        bool assetIsToken0 = token < usdt;
        uint160 baseline = _sqrtPriceX96(spec.priceE18, spec.decimals, assetIsToken0);
        sold = assetIsToken0 ? sqrtPriceX96 >= baseline : sqrtPriceX96 <= baseline;
        uint256 assetIn = Math.mulDiv(POKE_USDT, 10 ** spec.decimals, spec.priceE18);
        _stock(token, assetIn);
        uint256 amountIn = sold ? assetIn : POKE_USDT;
        address tokenIn = sold ? token : usdt;

        IPokeSwapRouter(SWAP_ROUTER)
            .exactInputSingle(
                IPokeSwapRouter.ExactInputSingleParams({
                    tokenIn: tokenIn,
                    tokenOut: sold ? usdt : token,
                    fee: spec.fee,
                    recipient: TestnetBook.KEEPER,
                    deadline: block.timestamp + 10 minutes,
                    amountIn: amountIn,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: 0
                })
            );
        (, int24 tickAfter,,,,,) = pool.slot0();
        require(tickAfter != tickBefore, string.concat(spec.symbol, ": the swap did not move the tick"));
    }

    /// @dev Mints the keeper's inventory (it is a minter of every mock) and approves the router, once.
    function _stock(address token, uint256 amount) internal {
        TestnetToken t = TestnetToken(token);
        if (t.balanceOf(TestnetBook.KEEPER) < amount) t.mint(TestnetBook.KEEPER, amount * INVENTORY_POKES);
        if (t.allowance(TestnetBook.KEEPER, SWAP_ROUTER) < amount) t.approve(SWAP_ROUTER, type(uint256).max);
    }

    /// @dev Same as `DeployTestnet.sqrtPriceX96`: the pool price of `priceE18` USDT per whole asset.
    function _sqrtPriceX96(uint256 priceE18, uint8 decimals, bool assetIsToken0)
        internal
        pure
        returns (uint160)
    {
        uint256 ratioX192 = assetIsToken0
            ? Math.mulDiv(priceE18, 1 << 192, 10 ** decimals)
            : Math.mulDiv(10 ** decimals, 1 << 192, priceE18);
        return uint160(Math.sqrt(ratioX192));
    }
}
