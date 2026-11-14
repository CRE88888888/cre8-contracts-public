// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";
import { DeployAtpMainnet } from "../../script/DeployAtpMainnet.s.sol";
import { AtpMainnetSpecs } from "../../script/AtpMainnetSpecs.sol";
import { AtpMultiPoolOracle } from "../../src/atp/AtpMultiPoolOracle.sol";
import { PancakeV3TwapOracle } from "../../src/atp/PancakeV3TwapOracle.sol";
import { MockToken, MockPancakeV3Pool } from "../atp/PancakeV3TwapOracle.t.sol";

/// @dev Exposes the internals of the mainnet deploy script that do not need chain 56.
contract DeployAtpMainnetHarness is DeployAtpMainnet {
    function verifyQuotes(AtpMultiPoolOracle router, PancakeV3TwapOracle oracle, OracleSpec memory spec)
        external
        view
        returns (bool)
    {
        return _verifyQuotes(router, oracle, spec);
    }

    function specs() external pure returns (OracleSpec[] memory) {
        return _oracleSpecs();
    }

    function constants() external pure returns (address usdt, uint16 minCardinality, uint32 usdtUsdMaxAge) {
        return (USDT, MIN_OBSERVATION_CARDINALITY, USDT_USD_MAX_AGE);
    }
}

/// @notice cre8-contracts#25: the deploy-time pool checks (M-2 cardinality, M-1 fail-closed classification) and
/// the oracle book the script deploys (L-5 feed ages, L-6 slippage tiers).
contract DeployAtpMainnetChecksTest is Test {
    DeployAtpMainnetHarness internal harness;
    AtpMultiPoolOracle internal router;
    MockPancakeV3Pool internal pool;
    PancakeV3TwapOracle internal oracle;
    MockToken internal asset;
    AtpMainnetSpecs.OracleSpec internal spec;
    address internal usdt;

    function setUp() public {
        vm.warp(100 days);
        harness = new DeployAtpMainnetHarness();
        (usdt,,) = harness.constants();
        vm.etch(usdt, address(new MockToken(18)).code); // the script prices against the real USDT address
        asset = new MockToken(18);
        router = new AtpMultiPoolOracle(usdt);
        (address token0, address token1) =
            usdt < address(asset) ? (usdt, address(asset)) : (address(asset), usdt);
        pool = new MockPancakeV3Pool(token0, token1);
        pool.setMeanTick(0, 30 minutes);
        oracle = router.setOracle(address(asset), address(pool), 30 minutes, 300, 1 hours);
        spec = AtpMainnetSpecs.OracleSpec("TEST", address(asset), address(pool), 300, address(0), 0);
    }

    // ---- M-2: observationCardinalityNext ----

    function test_livePoolWithEnoughCardinality_quotes() public view {
        assertTrue(harness.verifyQuotes(router, oracle, spec));
    }

    function test_cardinalityNextAtTheMinimum_passes_oneBelow_stopsTheDeployment() public {
        pool.setObservationCardinalityNext(2_400);
        assertTrue(harness.verifyQuotes(router, oracle, spec));

        pool.setObservationCardinalityNext(2_399);
        vm.expectRevert(
            bytes("observationCardinalityNext < 2400, run IncreaseObservationCardinality first: TEST")
        );
        harness.verifyQuotes(router, oracle, spec);
    }

    /// @dev The review's TRX / LTC case: a ring of 10 slots stops the deployment even if it quotes right now.
    function test_lowCardinalityPool_stopsTheDeploymentEvenWhenItQuotes() public {
        pool.setObservationCardinality(10);
        pool.setObservationCardinalityNext(10);
        oracle.previewSwap(address(asset), usdt, 1e18);
        vm.expectRevert(
            bytes("observationCardinalityNext < 2400, run IncreaseObservationCardinality first: TEST")
        );
        harness.verifyQuotes(router, oracle, spec);
    }

    // ---- M-1: market-state fail-closed is reported, not fatal ----

    function test_idlePool_isReportedFailClosed() public {
        pool.setObservationAge(1 hours + 1);
        assertFalse(harness.verifyQuotes(router, oracle, spec));

        pool.setObservationAge(1 hours); // exactly maxOracleAge still quotes
        assertTrue(harness.verifyQuotes(router, oracle, spec));
    }

    function test_poolWithShortHistory_isReportedFailClosed() public {
        pool.setObserveReverts(true); // cardinality just raised: not 30 minutes of history yet
        assertFalse(harness.verifyQuotes(router, oracle, spec));

        pool.setObserveReverts(false);
        pool.setRecentObserveReverts(true);
        assertFalse(harness.verifyQuotes(router, oracle, spec));
    }

    /// @dev A pool that looks servable but still cannot be quoted (here: locked) is not market state; the
    /// deployment stops instead of filing it under fail-closed.
    function test_servablePoolThatDoesNotQuote_stopsTheDeployment() public {
        pool.setUnlocked(false);
        vm.expectRevert(PancakeV3TwapOracle.TwapUnavailable.selector);
        harness.verifyQuotes(router, oracle, spec);
    }

    // ---- L-5 / L-6: the oracle book ----

    function test_book_hasThe38AdmittedAssets_eachOnItsOwnPool() public view {
        AtpMainnetSpecs.OracleSpec[] memory s = harness.specs();
        assertEq(s.length, 38);
        for (uint256 i; i < s.length; ++i) {
            for (uint256 j = i + 1; j < s.length; ++j) {
                assertTrue(s[i].asset != s[j].asset && s[i].pool != s[j].pool, "duplicate asset or pool");
            }
        }
    }

    /// @dev L-6 tiers: stablecoins 50 bps (inside the 20-50 band), deep low-fee pools 100, everything else 300.
    function test_book_slippageTiers() public view {
        AtpMainnetSpecs.OracleSpec[] memory s = harness.specs();
        uint256 tierS;
        uint256 tierA;
        for (uint256 i; i < s.length; ++i) {
            bytes32 sym = keccak256(bytes(s[i].symbol));
            if (sym == keccak256("USDC") || sym == keccak256("DAI")) {
                assertEq(s[i].maxSlippageBps, 50, s[i].symbol);
                assertGe(s[i].maxSlippageBps, 20);
                assertLe(s[i].maxSlippageBps, 50);
                ++tierS;
            } else if (
                sym == keccak256("WBNB") || sym == keccak256("BTCB") || sym == keccak256("ETH")
                    || sym == keccak256("QQQB") || sym == keccak256("XAUt") || sym == keccak256("NVDAB")
            ) {
                assertEq(s[i].maxSlippageBps, 100, s[i].symbol);
                ++tierA;
            } else {
                assertEq(s[i].maxSlippageBps, 300, s[i].symbol);
            }
        }
        assertEq(tierS, 2);
        assertEq(tierA, 6);
    }

    /// @dev L-5: about three heartbeats per feed, inside the adapter's bounds; USDT/USD has its own.
    function test_book_feedMaxAges() public view {
        AtpMainnetSpecs.OracleSpec[] memory s = harness.specs();
        uint256 withFeed;
        for (uint256 i; i < s.length; ++i) {
            if (s[i].usdFeed == address(0)) {
                assertEq(s[i].maxFeedAge, 0, s[i].symbol);
                continue;
            }
            ++withFeed;
            assertEq(s[i].maxFeedAge, _expectedFeedAge(s[i].symbol), s[i].symbol);
            assertGe(s[i].maxFeedAge, 1 minutes, "adapter floor");
            assertLe(s[i].maxFeedAge, 1 days, "adapter ceiling");
        }
        assertEq(withFeed, 11);
        (,, uint32 usdtUsdMaxAge) = harness.constants();
        assertEq(usdtUsdMaxAge, 2_700, "USDT/USD: 3 x 900 s heartbeat");
    }

    /// @dev 3 x the Chainlink heartbeat from docs#28; AVAX (24 h heartbeat) is capped at the 1 day ceiling.
    function _expectedFeedAge(string memory symbol) internal pure returns (uint32) {
        bytes32 sym = keccak256(bytes(symbol));
        if (sym == keccak256("WBNB")) return 3 * 27;
        if (sym == keccak256("DOGE")) return 3 * 47;
        if (sym == keccak256("BTCB") || sym == keccak256("ETH")) return 3 * 60;
        if (sym == keccak256("SOL") || sym == keccak256("TRX") || sym == keccak256("XRP")) return 3 * 600;
        if (sym == keccak256("USDC") || sym == keccak256("DAI") || sym == keccak256("LTC")) return 3 * 900;
        if (sym == keccak256("AVAX")) return 1 days;
        revert(string.concat("unexpected feed on ", symbol));
    }
}
