// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";
import { PancakeV3TwapOracle } from "../../src/atp/PancakeV3TwapOracle.sol";

/// @dev ERC-20 metadata stub: the oracle reads `decimals()` at construction only.
contract MockToken {
    uint8 public immutable decimals;

    constructor(uint8 decimals_) {
        decimals = decimals_;
    }
}

/// @dev PancakeSwap V3 pool stub. `observe` answers exactly two lookbacks: `window` and 0.
contract MockPancakeV3Pool {
    address public immutable token0;
    address public immutable token1;

    uint160 public sqrtPriceX96 = 79_228_162_514_264_337_593_543_950_336; // 2^96, tick 0
    uint24 public fee = 500;
    uint128 public liquidity = 1e18;
    uint16 public observationCardinality = 2;
    bool public unlocked = true;

    uint32 public window;
    int56 public cumulativeAtWindow;
    int56 public cumulativeNow;

    bool public observeReverts;
    uint256 public observeLengthOverride;

    constructor(address token0_, address token1_) {
        token0 = token0_;
        token1 = token1_;
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint32, bool) {
        return (sqrtPriceX96, 0, 0, observationCardinality, observationCardinality, 0, unlocked);
    }

    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory ticks, uint160[] memory secondsPerLiquidityCumulativeX128s)
    {
        if (observeReverts) revert("mock: no history");

        uint256 length = observeLengthOverride == 0 ? secondsAgos.length : observeLengthOverride;
        ticks = new int56[](length);
        secondsPerLiquidityCumulativeX128s = new uint160[](length);
        for (uint256 i; i < length && i < secondsAgos.length; ++i) {
            ticks[i] = secondsAgos[i] == 0 ? cumulativeNow : cumulativeAtWindow;
        }
    }

    // ---- test controls ----

    /// @dev Builds cumulatives whose exact mean tick is `meanTick` over `window_`.
    function setMeanTick(int24 meanTick, uint32 window_) external {
        window = window_;
        cumulativeAtWindow = 0;
        cumulativeNow = int56(meanTick) * int56(uint56(window_));
    }

    function setCumulatives(int56 atWindow, int56 now, uint32 window_) external {
        window = window_;
        cumulativeAtWindow = atWindow;
        cumulativeNow = now;
    }

    function setObservationCardinality(uint16 cardinality) external {
        observationCardinality = cardinality;
    }

    function setUnlocked(bool unlocked_) external {
        unlocked = unlocked_;
    }

    function setSqrtPrice(uint160 sqrtPriceX96_) external {
        sqrtPriceX96 = sqrtPriceX96_;
    }

    function setObserveReverts(bool reverts_) external {
        observeReverts = reverts_;
    }

    function setObserveLengthOverride(uint256 length) external {
        observeLengthOverride = length;
    }
}

/// @notice Pins `PancakeV3TwapOracle`: TWAP-only pricing, the decimals-neutral raw ratio, the rounding
/// direction, the slippage floor and the fail-closed paths.
contract PancakeV3TwapOracleTest is Test {
    uint32 internal constant WINDOW = 30 minutes;
    uint16 internal constant MAX_SLIPPAGE_BPS = 50;
    uint32 internal constant MAX_ORACLE_AGE = 1 hours;

    MockToken internal token0;
    MockToken internal token1;
    MockPancakeV3Pool internal pool;
    PancakeV3TwapOracle internal oracle;

    function setUp() public {
        token0 = new MockToken(18);
        token1 = new MockToken(6);
        pool = new MockPancakeV3Pool(address(token0), address(token1));
        oracle = new PancakeV3TwapOracle(
            address(pool), address(token0), address(token1), WINDOW, MAX_SLIPPAGE_BPS, MAX_ORACLE_AGE
        );
    }

    // ---- pricing ----

    /// @dev Tick -276324 is a raw ratio of about 1e-12, i.e. one 18-decimal unit of `token0` buys about
    /// one 6-decimal unit of `token1`. That is exactly the decimals trap: the raw ratio already carries
    /// 10^(decimalsOut - decimalsIn), so a second factor would be off by 1e12.
    function test_quotesAcrossDecimalsInTheRawRatio() public {
        pool.setMeanTick(-276_324, WINDOW);

        (uint256 quoted, uint256 minimum) = oracle.previewSwap(address(token0), address(token1), 1000e18);
        assertEq(quoted, 1_000_002_644, "18 -> 6 quote");
        assertEq(minimum, 995_002_631, "50 bps floor");

        (uint256 quotedBack, uint256 minimumBack) =
            oracle.previewSwap(address(token1), address(token0), 1000e6);
        assertEq(quotedBack, 999_997_356_176_039_153_114, "6 -> 18 quote");
        assertEq(minimumBack, 994_997_369_395_158_957_349, "50 bps floor");
    }

    function test_quotesParityAtTickZero() public {
        pool.setMeanTick(0, WINDOW);

        (uint256 quoted, uint256 minimum) = oracle.previewSwap(address(token0), address(token1), 1000e18);
        assertEq(quoted, 1000e18, "raw parity");
        assertEq(minimum, 995e18, "50 bps floor");
    }

    function test_minimumIsCeilOfQuotedAfterSlippage() public {
        pool.setMeanTick(-276_324, WINDOW);
        (uint256 quoted, uint256 minimum) =
            oracle.previewSwap(address(token0), address(token1), 123_456_789e18);

        assertEq(minimum, _ceilDiv(quoted * (10_000 - MAX_SLIPPAGE_BPS), 10_000), "ceil floor");
    }

    /// @dev Solidity division truncates toward zero, so the mean tick needs a nudge in the two cases where
    /// truncation would lower the sold token's price. Selling `token0` (price rises with the tick) rounds
    /// up; selling `token1` (price falls with the tick) leaves the truncated tick alone.
    function test_meanTickRoundsUpTheSoldTokenPrice() public {
        MockToken tokenA = new MockToken(18);
        MockToken tokenB = new MockToken(18);
        MockPancakeV3Pool pool18 = new MockPancakeV3Pool(address(tokenA), address(tokenB));
        PancakeV3TwapOracle oracle18 = new PancakeV3TwapOracle(
            address(pool18), address(tokenA), address(tokenB), WINDOW, MAX_SLIPPAGE_BPS, MAX_ORACLE_AGE
        );
        // True mean tick 100.5: delta = 1800 * 100 + 900.
        pool18.setCumulatives(0, 180_900, 1800);

        (uint256 quotedSellA,) = oracle18.previewSwap(address(tokenA), address(tokenB), 1e18);
        assertEq(quotedSellA, 1_010_150_667_059_085_857, "sell token0 rounds the tick up to 101");

        (uint256 quotedSellB,) = oracle18.previewSwap(address(tokenB), address(tokenA), 1e18);
        assertEq(quotedSellB, 990_050_328_741_209_482, "sell token1 keeps the truncated tick 100");
    }

    /// @dev Pins `TickMathLite` at the pool's tick bounds. Above tick 0 the sqrt price exceeds 2^128, so
    /// the quote takes the full-width path; an overflow there would panic instead of reverting cleanly.
    /// Expected values come from an independent TickMath reference implementation.
    function test_quotesAtTheTickBounds() public {
        MockToken tokenA = new MockToken(18);
        MockToken tokenB = new MockToken(18);
        MockPancakeV3Pool pool18 = new MockPancakeV3Pool(address(tokenA), address(tokenB));
        PancakeV3TwapOracle bounded = new PancakeV3TwapOracle(
            address(pool18), address(tokenA), address(tokenB), WINDOW, MAX_SLIPPAGE_BPS, MAX_ORACLE_AGE
        );

        pool18.setMeanTick(887_272, WINDOW);
        (uint256 atMaxTick, uint256 minAtMaxTick) =
            bounded.previewSwap(address(tokenA), address(tokenB), 1e18);
        assertEq(atMaxTick, 340_256_786_836_388_094_070_642_339_899_681_172_762_184_831_912_720_469_416);
        assertGt(minAtMaxTick, 0);

        pool18.setMeanTick(-887_272, WINDOW);
        (uint256 atMinTick, uint256 minAtMinTick) =
            bounded.previewSwap(address(tokenA), address(tokenB), 1e18);
        assertEq(atMinTick, 1);
        assertEq(minAtMinTick, 1);
    }

    // ---- fail closed ----

    function test_revertsOnZeroAmount() public {
        pool.setMeanTick(0, WINDOW);
        vm.expectRevert(PancakeV3TwapOracle.ZeroAmount.selector);
        oracle.previewSwap(address(token0), address(token1), 0);
    }

    function test_revertsOnSameToken() public {
        pool.setMeanTick(0, WINDOW);
        vm.expectRevert(PancakeV3TwapOracle.UnsupportedPair.selector);
        oracle.previewSwap(address(token0), address(token0), 1e18);
    }

    function test_revertsOnTokenOutsideThePinnedPair() public {
        pool.setMeanTick(0, WINDOW);
        MockToken stray = new MockToken(18);

        vm.expectRevert(PancakeV3TwapOracle.UnsupportedPair.selector);
        oracle.previewSwap(address(stray), address(token1), 1e18);

        vm.expectRevert(PancakeV3TwapOracle.UnsupportedPair.selector);
        oracle.previewSwap(address(token0), address(stray), 1e18);
    }

    function test_revertsWhenObserveReverts() public {
        pool.setMeanTick(0, WINDOW);
        pool.setObserveReverts(true);

        vm.expectRevert(PancakeV3TwapOracle.TwapUnavailable.selector);
        oracle.previewSwap(address(token0), address(token1), 1e18);
    }

    function test_revertsWhenObservationCardinalityIsTooSmall() public {
        pool.setMeanTick(0, WINDOW);
        pool.setObservationCardinality(1);

        vm.expectRevert(PancakeV3TwapOracle.TwapUnavailable.selector);
        oracle.previewSwap(address(token0), address(token1), 1e18);
    }

    function test_revertsWhenPoolIsLocked() public {
        pool.setMeanTick(0, WINDOW);
        pool.setUnlocked(false);

        vm.expectRevert(PancakeV3TwapOracle.TwapUnavailable.selector);
        oracle.previewSwap(address(token0), address(token1), 1e18);
    }

    function test_revertsWhenObserveReturnsTheWrongShape() public {
        pool.setMeanTick(0, WINDOW);
        pool.setObserveLengthOverride(1);

        vm.expectRevert(PancakeV3TwapOracle.TwapUnavailable.selector);
        oracle.previewSwap(address(token0), address(token1), 1e18);
    }

    function test_revertsWhenSpotPriceIsOutsideTheValidRange() public {
        pool.setMeanTick(0, WINDOW);
        pool.setSqrtPrice(1);

        vm.expectRevert(PancakeV3TwapOracle.InvalidPoolPrice.selector);
        oracle.previewSwap(address(token0), address(token1), 1e18);
    }

    function test_revertsWhenMeanTickIsOutsideTheTickRange() public {
        pool.setMeanTick(1_000_000, WINDOW);

        vm.expectRevert(PancakeV3TwapOracle.InvalidPoolPrice.selector);
        oracle.previewSwap(address(token0), address(token1), 1e18);
    }

    /// @dev The quote rounds up, so even one raw unit of the sold token keeps a non-zero floor; a swap
    /// can never slip through with `minimum == 0`.
    function test_dustAmountKeepsANonZeroFloor() public {
        pool.setMeanTick(-276_324, WINDOW);

        (uint256 quoted, uint256 minimum) = oracle.previewSwap(address(token0), address(token1), 1);
        assertEq(quoted, 1, "one raw unit in still quotes one raw unit out");
        assertEq(minimum, 1, "floor never rounds to zero");
    }

    // ---- constructor ----

    function test_constructorPinsConfiguration() public view {
        assertEq(address(oracle.pool()), address(pool));
        assertEq(oracle.token0(), address(token0));
        assertEq(oracle.token1(), address(token1));
        assertEq(oracle.decimals0(), 18);
        assertEq(oracle.decimals1(), 6);
        assertEq(oracle.twapWindow(), WINDOW);
        assertEq(oracle.maxSlippageBps(), MAX_SLIPPAGE_BPS);
        assertEq(oracle.maxOracleAge(), MAX_ORACLE_AGE);
    }

    function test_constructorAcceptsReversedPairOrder() public {
        PancakeV3TwapOracle reversed = new PancakeV3TwapOracle(
            address(pool), address(token1), address(token0), WINDOW, MAX_SLIPPAGE_BPS, MAX_ORACLE_AGE
        );
        assertEq(reversed.token0(), address(token0));
        assertEq(reversed.token1(), address(token1));
    }

    function test_constructorRejectsShortWindow() public {
        vm.expectRevert(PancakeV3TwapOracle.InvalidConfig.selector);
        new PancakeV3TwapOracle(
            address(pool), address(token0), address(token1), 29 minutes, MAX_SLIPPAGE_BPS, MAX_ORACLE_AGE
        );
    }

    function test_constructorRejectsLongWindow() public {
        vm.expectRevert(PancakeV3TwapOracle.InvalidConfig.selector);
        new PancakeV3TwapOracle(
            address(pool), address(token0), address(token1), 91 minutes, MAX_SLIPPAGE_BPS, MAX_ORACLE_AGE
        );
    }

    function test_constructorRejectsZeroSlippage() public {
        vm.expectRevert(PancakeV3TwapOracle.InvalidConfig.selector);
        new PancakeV3TwapOracle(address(pool), address(token0), address(token1), WINDOW, 0, MAX_ORACLE_AGE);
    }

    function test_constructorRejectsFullSlippage() public {
        vm.expectRevert(PancakeV3TwapOracle.InvalidConfig.selector);
        new PancakeV3TwapOracle(
            address(pool), address(token0), address(token1), WINDOW, 10_000, MAX_ORACLE_AGE
        );
    }

    function test_constructorRejectsOracleAgeBelowWindow() public {
        vm.expectRevert(PancakeV3TwapOracle.InvalidConfig.selector);
        new PancakeV3TwapOracle(
            address(pool), address(token0), address(token1), WINDOW, MAX_SLIPPAGE_BPS, WINDOW - 1
        );
    }

    function test_constructorRejectsTokensOutsideThePool() public {
        MockToken stray = new MockToken(18);

        vm.expectRevert(PancakeV3TwapOracle.InvalidConfig.selector);
        new PancakeV3TwapOracle(
            address(pool), address(token0), address(stray), WINDOW, MAX_SLIPPAGE_BPS, MAX_ORACLE_AGE
        );
    }

    function test_constructorRejectsIdenticalTokens() public {
        vm.expectRevert(PancakeV3TwapOracle.InvalidConfig.selector);
        new PancakeV3TwapOracle(
            address(pool), address(token0), address(token0), WINDOW, MAX_SLIPPAGE_BPS, MAX_ORACLE_AGE
        );
    }

    function test_constructorRejectsPoolWithoutCode() public {
        vm.expectRevert(PancakeV3TwapOracle.InvalidConfig.selector);
        new PancakeV3TwapOracle(
            address(0xBEEF), address(token0), address(token1), WINDOW, MAX_SLIPPAGE_BPS, MAX_ORACLE_AGE
        );
    }

    function _ceilDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        return a == 0 ? 0 : ((a - 1) / b) + 1;
    }
}
