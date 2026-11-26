// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { console } from "forge-std/Test.sol";
import { ForkPoolHelpers } from "./ForkPoolHelpers.sol";
import { AtpMultiPoolOracle } from "../../../src/atp/AtpMultiPoolOracle.sol";
import { PushFeedPriceSource } from "../../../src/atp/PushFeedPriceSource.sol";
import { IAggregatorV3 } from "../../../src/atp/interfaces/IAggregatorV3.sol";
import { IPriceSource } from "../../../src/atp/interfaces/IPriceSource.sol";

/// @notice The secondary source against live BSC state: the four launch assets with a Chainlink feed
/// (docs#28), each on the same pool and slippage as `DeployAtpMainnet`, quote through the router with the
/// feed agreeing within 200 bps; the floor is never looser than the pool's alone; a feed older than its max
/// age fails the quote closed. Max ages are `AtpMainnetSpecs`' (3 x heartbeat per feed, USDT/USD 2,700 s,
/// cre8-contracts#25). Each pool is traded once first (`_touch`) so a pool that happened to be idle at the fork
/// block does not fail closed on the oracle's `maxOracleAge` before the feed is even read.
/// Skipped (never passed) without `BSC_RPC_URL`.
contract AtpMultiPoolOracleSecondaryForkTest is ForkPoolHelpers {
    address internal constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address internal constant USDT_USD_FEED = 0xB97Ad0E74fa7d920791E90258A6E2085088b4320;
    uint32 internal constant USDT_USD_MAX_AGE = 2_700;

    struct Asset {
        string symbol;
        address token;
        address pool;
        uint16 slippageBps;
        address usdFeed;
        uint32 feedMaxAge;
        uint256 sellAmount; // about 100 USDT worth
    }

    AtpMultiPoolOracle internal router;
    Asset[] internal assets;

    function setUp() public {
        string memory rpc = vm.envOr("BSC_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);

        assets.push(
            Asset(
                "WBNB",
                0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c,
                0x36696169C63e42cd08ce11f5deeBbCeBae652050,
                100,
                0x0567F2323251f0Aab15c8dFb1967E4e8A7D42aeE,
                81,
                0.15e18
            )
        );
        assets.push(
            Asset(
                "DOGE",
                0xbA2aE424d960c26247Dd6c32edC70B295c744C43,
                0x89da4102853C6cf3F4e9979CBb1dC4a166F38E84,
                300,
                0x3AB0A0d137D4F946fBB19eecc6e92E64660231C8,
                141,
                1_500e8
            )
        );
        assets.push(
            Asset(
                "BTCB",
                0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c,
                0x46Cf1cF8c69595804ba91dFdd8d6b960c9B0a7C4,
                100,
                0x264990fbd0A4796A3E3d8E37C4d5F87a3aCa5Ebf,
                180,
                0.0015e18
            )
        );
        assets.push(
            Asset(
                "ETH",
                0x2170Ed0880ac9A755fd29B2688956BD959F933F8,
                0xBe141893E4c6AD9272e8C04BAB7E6a10604501a5,
                100,
                0x9ef1B8c0E4F7dc8bF5719Ea496883DC6401d5b2e,
                180,
                0.05e18
            )
        );

        router = new AtpMultiPoolOracle(USDT);
        for (uint256 i; i < assets.length; ++i) {
            router.setOracle(assets[i].token, assets[i].pool, 30 minutes, assets[i].slippageBps, 1 hours);
            _touch(assets[i].pool);
        }
    }

    function _wireAll() internal {
        for (uint256 i; i < assets.length; ++i) {
            router.setSecondary(
                assets[i].token,
                IAggregatorV3(assets[i].usdFeed),
                IAggregatorV3(USDT_USD_FEED),
                assets[i].feedMaxAge,
                USDT_USD_MAX_AGE,
                200
            );
        }
    }

    function test_fork_liveFeedsAgreeWithThePools_andNeverLoosenTheFloor() public {
        uint256[] memory poolSellMin = new uint256[](assets.length);
        uint256[] memory poolBuyMin = new uint256[](assets.length);
        for (uint256 i; i < assets.length; ++i) {
            (, poolSellMin[i]) = router.previewSwap(assets[i].token, USDT, assets[i].sellAmount);
            (, poolBuyMin[i]) = router.previewSwap(USDT, assets[i].token, 100e18);
        }

        _wireAll();
        for (uint256 i; i < assets.length; ++i) {
            (uint256 sellQuote, uint256 sellMin) =
                router.previewSwap(assets[i].token, USDT, assets[i].sellAmount);
            (uint256 buyQuote, uint256 buyMin) = router.previewSwap(USDT, assets[i].token, 100e18);
            assertGe(sellMin, poolSellMin[i], string.concat(assets[i].symbol, ": sale floor never looser"));
            assertGe(buyMin, poolBuyMin[i], string.concat(assets[i].symbol, ": buy floor never looser"));

            (IPriceSource source,) = router.secondaryOf(assets[i].token);
            uint256 feedSell = assets[i].sellAmount * source.price() / 1e18;
            console.log(assets[i].symbol);
            console.log("  sale: pool quote / feed quote (USDT wei):", sellQuote, feedSell);
            console.log("  sale floor: pool-only / with feed:", poolSellMin[i], sellMin);
            console.log("  buy 100 USDT: pool quote / floor with feed:", buyQuote, buyMin);
        }
    }

    function test_fork_staleFeed_failsTheQuoteClosed() public {
        _wireAll();
        // Push feeds do not update on a fork: 46 minutes later every feed is older than its max age (asset feeds
        // 81-180 s, USDT/USD 2,700 s), while the pools, traded again, are well inside `maxOracleAge`.
        vm.warp(vm.getBlockTimestamp() + 46 minutes);
        for (uint256 i; i < assets.length; ++i) {
            _touch(assets[i].pool);
        }
        for (uint256 i; i < assets.length; ++i) {
            vm.expectPartialRevert(PushFeedPriceSource.StaleFeed.selector);
            router.previewSwap(assets[i].token, USDT, assets[i].sellAmount);
        }
    }

    function test_fork_clearingTheSecondary_restoresPoolOnlyQuotes() public {
        _wireAll();
        vm.warp(vm.getBlockTimestamp() + 46 minutes);
        _touch(assets[0].pool);
        router.clearSecondary(assets[0].token);
        (uint256 quoted, uint256 minimum) = router.previewSwap(assets[0].token, USDT, assets[0].sellAmount);
        assertGt(quoted, 0);
        assertGt(minimum, 0);
    }
}
