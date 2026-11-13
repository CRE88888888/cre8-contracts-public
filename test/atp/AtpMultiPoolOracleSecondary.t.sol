// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { AtpMultiPoolOracle } from "../../src/atp/AtpMultiPoolOracle.sol";
import { PancakeV3TwapOracle } from "../../src/atp/PancakeV3TwapOracle.sol";
import { PushFeedPriceSource } from "../../src/atp/PushFeedPriceSource.sol";
import { IAggregatorV3 } from "../../src/atp/interfaces/IAggregatorV3.sol";
import { IPriceSource } from "../../src/atp/interfaces/IPriceSource.sol";
import { MockToken, MockPool } from "./AtpMultiPoolOracle.t.sol";

/// @dev AggregatorV3 stand-in: settable answer and updatedAt.
contract MockAggregator is IAggregatorV3 {
    uint8 public immutable decimals;
    int256 public answer;
    uint256 public updatedAt;

    constructor(uint8 decimals_, int256 answer_) {
        decimals = decimals_;
        answer = answer_;
        updatedAt = block.timestamp;
    }

    function set(int256 answer_, uint256 updatedAt_) external {
        answer = answer_;
        updatedAt = updatedAt_;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, updatedAt, updatedAt, 1);
    }
}

/// @notice Pins the secondary source of `AtpMultiPoolOracle` (cre8-contracts#15 §2): without one, quotes are
/// exactly the pool TWAP's; with one, quotes must agree within `maxDeviationBps`, the floor is the stricter of
/// the two, and a stale or unusable feed - asset or numeraire - fails closed. Only the owner wires it.
/// @dev Fixture: both pools sit at a 1 numeraire per 1 asset TWAP (tick 0 for the 18-decimal asset, tick
/// -276324 for the 6-decimal one), feeds read $1 for the asset and $1 for the numeraire, slippage 50 bps.
contract AtpMultiPoolOracleSecondaryTest is Test {
    uint32 internal constant WINDOW = 30 minutes;
    uint16 internal constant SLIPPAGE_BPS = 50;
    uint32 internal constant MAX_AGE = 1 hours;
    uint16 internal constant DEVIATION_BPS = 200;
    address internal constant OUTSIDER = address(0xB0B);

    MockToken internal numeraire;
    MockToken internal asset18;
    MockToken internal asset6;
    AtpMultiPoolOracle internal router;
    PancakeV3TwapOracle internal oracle18;
    MockAggregator internal assetFeed; // asset/USD, 8 decimals (Chainlink-style)
    MockAggregator internal usdtFeed; // numeraire/USD, 8 decimals
    MockAggregator internal asset6Feed; // asset/USD, 18 decimals (SVR-style)

    function setUp() public {
        vm.warp(1_000_000);
        numeraire = new MockToken(18);
        asset18 = new MockToken(18);
        asset6 = new MockToken(6);
        router = new AtpMultiPoolOracle(address(numeraire));
        oracle18 =
            router.setOracle(address(asset18), address(_pool(asset18, 0)), WINDOW, SLIPPAGE_BPS, MAX_AGE);
        router.setOracle(address(asset6), address(_pool(asset6, -276_324)), WINDOW, SLIPPAGE_BPS, MAX_AGE);
        assetFeed = new MockAggregator(8, 1e8);
        usdtFeed = new MockAggregator(8, 1e8);
        asset6Feed = new MockAggregator(18, 1e18);
    }

    function _pool(MockToken asset, int24 tick) internal returns (MockPool pool) {
        pool = new MockPool(address(numeraire), address(asset));
        pool.setMeanTick(tick, WINDOW);
    }

    function _wire() internal returns (IPriceSource) {
        return router.setSecondary(address(asset18), assetFeed, usdtFeed, MAX_AGE, DEVIATION_BPS);
    }

    function _sell(uint256 amount) internal view returns (uint256 quoted, uint256 minimum) {
        return router.previewSwap(address(asset18), address(numeraire), amount);
    }

    function _buy(uint256 amount) internal view returns (uint256 quoted, uint256 minimum) {
        return router.previewSwap(address(numeraire), address(asset18), amount);
    }

    function _floor(uint256 quote) internal pure returns (uint256) {
        return Math.mulDiv(quote, 10_000 - SLIPPAGE_BPS, 10_000, Math.Rounding.Ceil);
    }

    // ---- without a secondary nothing changes ----

    function test_noSecondary_quoteIsThePoolOraclesBitForBit() public view {
        (uint256 q, uint256 m) = _sell(100e18);
        (uint256 oq, uint256 om) = oracle18.previewSwap(address(asset18), address(numeraire), 100e18);
        assertEq(q, oq);
        assertEq(m, om);
        (IPriceSource source, uint16 dev) = router.secondaryOf(address(asset18));
        assertEq(address(source), address(0));
        assertEq(dev, 0);
    }

    // ---- wiring ----

    function test_setSecondary_deploysTheAdapterItself() public {
        IPriceSource source = _wire();
        (IPriceSource stored, uint16 dev) = router.secondaryOf(address(asset18));
        assertEq(address(stored), address(source));
        assertEq(dev, DEVIATION_BPS);
        PushFeedPriceSource adapter = PushFeedPriceSource(address(source));
        assertEq(address(adapter.assetFeed()), address(assetFeed));
        assertEq(address(adapter.numeraireFeed()), address(usdtFeed));
        assertEq(adapter.maxAge(), MAX_AGE);
        assertEq(source.price(), 1e18, "$1 / $1 at equal decimals");
    }

    function test_setSecondary_onlyOwner() public {
        vm.prank(OUTSIDER);
        vm.expectRevert(AtpMultiPoolOracle.NotOwner.selector);
        router.setSecondary(address(asset18), assetFeed, usdtFeed, MAX_AGE, DEVIATION_BPS);

        _wire();
        vm.prank(OUTSIDER);
        vm.expectRevert(AtpMultiPoolOracle.NotOwner.selector);
        router.clearSecondary(address(asset18));
    }

    function test_setSecondary_rejectsBadConfig() public {
        MockToken unregistered = new MockToken(18);
        vm.expectRevert(
            abi.encodeWithSelector(AtpMultiPoolOracle.OracleNotSet.selector, address(unregistered))
        );
        router.setSecondary(address(unregistered), assetFeed, usdtFeed, MAX_AGE, DEVIATION_BPS);

        vm.expectRevert(abi.encodeWithSelector(AtpMultiPoolOracle.InvalidDeviation.selector, uint16(0)));
        router.setSecondary(address(asset18), assetFeed, usdtFeed, MAX_AGE, 0);
        vm.expectRevert(abi.encodeWithSelector(AtpMultiPoolOracle.InvalidDeviation.selector, uint16(1_001)));
        router.setSecondary(address(asset18), assetFeed, usdtFeed, MAX_AGE, 1_001);

        vm.expectRevert(PushFeedPriceSource.InvalidConfig.selector);
        router.setSecondary(
            address(asset18), IAggregatorV3(address(0xDEAD)), usdtFeed, MAX_AGE, DEVIATION_BPS
        );
        vm.expectRevert(PushFeedPriceSource.InvalidConfig.selector);
        router.setSecondary(address(asset18), assetFeed, assetFeed, MAX_AGE, DEVIATION_BPS); // same feed twice
        vm.expectRevert(PushFeedPriceSource.InvalidConfig.selector);
        router.setSecondary(address(asset18), assetFeed, usdtFeed, 59, DEVIATION_BPS); // below a minute
        vm.expectRevert(PushFeedPriceSource.InvalidConfig.selector);
        router.setSecondary(address(asset18), assetFeed, usdtFeed, 1 days + 1, DEVIATION_BPS); // above a day

        _wire();
        vm.expectRevert(
            abi.encodeWithSelector(AtpMultiPoolOracle.SecondaryAlreadySet.selector, address(asset18))
        );
        _wire();
    }

    function test_clearSecondary_restoresPoolOnlyPricing() public {
        _wire();
        assetFeed.set(1.015e8, block.timestamp); // 1.5% above the pool: still agrees, tightens sale floors
        (, uint256 tightened) = _sell(100e18);
        router.clearSecondary(address(asset18));
        (uint256 q, uint256 m) = _sell(100e18);
        assertEq(q, 100e18);
        assertEq(m, _floor(100e18), "pool floor again");
        assertGt(tightened, m);

        vm.expectRevert(abi.encodeWithSelector(AtpMultiPoolOracle.SecondaryNotSet.selector, address(asset18)));
        router.clearSecondary(address(asset18));
    }

    function test_clearOracle_alsoDropsTheSecondary() public {
        _wire();
        router.clearOracle(address(asset18));
        (IPriceSource source,) = router.secondaryOf(address(asset18));
        assertEq(address(source), address(0), "a new pool registration starts without a secondary");
    }

    function test_newOwner_controlsTheSecondary() public {
        router.transferOwnership(OUTSIDER);
        vm.prank(OUTSIDER);
        router.acceptOwnership();
        vm.expectRevert(AtpMultiPoolOracle.NotOwner.selector);
        _wire();
        vm.prank(OUTSIDER);
        router.setSecondary(address(asset18), assetFeed, usdtFeed, MAX_AGE, DEVIATION_BPS);
    }

    // ---- agreement and the stricter floor ----

    function test_agreeingSources_keepTheQuote_andTheFloor() public {
        _wire();
        (uint256 q, uint256 m) = _sell(100e18);
        assertEq(q, 100e18, "quote stays the pool TWAP's");
        assertEq(m, _floor(100e18));
        (q, m) = _buy(100e18);
        assertEq(q, 100e18);
        assertEq(m, _floor(100e18));
    }

    function test_secondaryAbovePool_tightensSaleFloor_notBuyFloor() public {
        _wire();
        assetFeed.set(1.015e8, block.timestamp); // the feed says the asset is worth 1.5% more

        (uint256 q, uint256 m) = _sell(100e18);
        assertEq(q, 100e18);
        assertEq(m, _floor(101.5e18), "a sale must fetch what the feed says");

        uint256 secondaryBuy = Math.mulDiv(100e18, 1e18, 1.015e18);
        (q, m) = _buy(100e18);
        assertEq(m, _floor(100e18), "a buy keeps the (stricter) pool floor");
        assertGt(m, _floor(secondaryBuy));
    }

    function test_secondaryBelowPool_tightensBuyFloor_notSaleFloor() public {
        _wire();
        assetFeed.set(0.985e8, block.timestamp); // the feed says the asset is worth 1.5% less

        (, uint256 m) = _buy(100e18);
        assertEq(m, _floor(Math.mulDiv(100e18, 1e18, 0.985e18)), "a buy must get the feed's amount");
        (, m) = _sell(100e18);
        assertEq(m, _floor(100e18), "a sale keeps the (stricter) pool floor");
    }

    function test_disagreement_failsClosed_bothDirections() public {
        _wire();
        assetFeed.set(1.0205e8, block.timestamp); // gap 2.05 on 102.05 = 201 bps of the secondary quote
        vm.expectRevert(
            abi.encodeWithSelector(
                AtpMultiPoolOracle.SourcesDisagree.selector, address(asset18), 100e18, 102.05e18
            )
        );
        _sell(100e18);
        vm.expectRevert();
        _buy(100e18);
    }

    function test_deviationBound_isMeasuredOnTheSecondaryQuote() public {
        _wire();
        // The gap is measured against the secondary quote. Pool 100 vs secondary 102: 2 / 102 = 196 bps, passes.
        assetFeed.set(1.02e8, block.timestamp);
        _sell(100e18);
        // Secondary 98: gap 2 = 204 bps of 98, fails.
        assetFeed.set(0.98e8, block.timestamp);
        vm.expectRevert();
        _sell(100e18);
    }

    function test_numeraireDepeg_isPricedIn() public {
        _wire();
        usdtFeed.set(0.99e8, block.timestamp); // USDT at $0.99: one asset ($1) is worth 1.0101 USDT
        (, uint256 m) = _sell(100e18);
        assertEq(m, _floor(Math.mulDiv(Math.mulDiv(1e18, 1e18, 0.99e18), 100e18, 1e18)));

        usdtFeed.set(0.97e8, block.timestamp); // a 3% depeg pulls the feed outside the pool by > 200 bps
        vm.expectRevert();
        _sell(100e18);
    }

    // ---- stale or unusable feeds fail closed ----

    function test_staleAssetFeed_failsClosed() public {
        _wire();
        assetFeed.set(1e8, block.timestamp - MAX_AGE - 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                PushFeedPriceSource.StaleFeed.selector, address(assetFeed), block.timestamp - MAX_AGE - 1
            )
        );
        _sell(100e18);

        assetFeed.set(1e8, block.timestamp - MAX_AGE); // exactly maxAge old is still fresh
        _sell(100e18);
    }

    function test_staleNumeraireFeed_failsClosed() public {
        _wire();
        usdtFeed.set(1e8, block.timestamp - MAX_AGE - 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                PushFeedPriceSource.StaleFeed.selector, address(usdtFeed), block.timestamp - MAX_AGE - 1
            )
        );
        _buy(100e18);
    }

    function test_futureOrZeroTimestamp_failsClosed() public {
        _wire();
        assetFeed.set(1e8, block.timestamp + 1);
        vm.expectRevert();
        _sell(100e18);
        assetFeed.set(1e8, 0);
        vm.expectRevert();
        _sell(100e18);
    }

    function test_nonPositiveAnswer_failsClosed() public {
        _wire();
        assetFeed.set(0, block.timestamp);
        vm.expectRevert(
            abi.encodeWithSelector(PushFeedPriceSource.InvalidAnswer.selector, address(assetFeed), int256(0))
        );
        _sell(100e18);
        assetFeed.set(-1, block.timestamp);
        vm.expectRevert(
            abi.encodeWithSelector(PushFeedPriceSource.InvalidAnswer.selector, address(assetFeed), int256(-1))
        );
        _sell(100e18);
    }

    function test_timePassing_makesTheFeedStale() public {
        _wire();
        _sell(100e18);
        vm.warp(block.timestamp + MAX_AGE + 1);
        vm.expectRevert();
        _sell(100e18);
    }

    // ---- decimals ----

    function test_decimalsAreFolded_6DecimalAsset_18DecimalFeed() public {
        IPriceSource source =
            router.setSecondary(address(asset6), asset6Feed, usdtFeed, MAX_AGE, DEVIATION_BPS);
        // 1e18 raw of a 6-decimal asset = 1e12 tokens = 1e12 USDT = 1e30 raw numeraire.
        assertEq(source.price(), 1e30);
        (uint256 q, uint256 m) = router.previewSwap(address(asset6), address(numeraire), 100e6);
        (uint256 oq, uint256 om) =
            router.oracleOf(address(asset6)).previewSwap(address(asset6), address(numeraire), 100e6);
        assertEq(q, oq);
        assertGe(m, om, "never looser than the pool floor");
    }
}
