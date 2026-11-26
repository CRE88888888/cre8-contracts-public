// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { PancakeV3TwapOracle } from "../../../src/atp/PancakeV3TwapOracle.sol";
import { IPancakeV3Pool } from "../../../src/atp/interfaces/IPancakeV3Pool.sol";
import { ForkPoolHelpers } from "./ForkPoolHelpers.sol";

interface IPoolCardinality {
    function increaseObservationCardinalityNext(uint16 observationCardinalityNext) external;
}

/// @notice Regression tests for the 2026-11-14 review's oracle PoCs (cre8-contracts#25) on a BSC mainnet fork.
/// The review's PoCs "passed" while the problem existed; here the same scenarios must be blocked:
/// - M-1: a pool idle for 30 days no longer quotes (the PoC got a normal floor from a 30-day-old price);
/// - M-2: after `increaseObservationCardinalityNext(2400)` and 30 minutes of trading, the PoC's ten dust swaps
///   no longer take the TRX oracle offline (without the step they still do, kept as the control case).
/// Pools and parameters are the ones `DeployAtpMainnet` uses. Skipped (never passed) without `BSC_RPC_URL`.
contract OracleHardeningForkTest is ForkPoolHelpers {
    address internal constant TRX = 0xCE7de646e7208a4Ef112cb6ed5038FA6cC6b12e3;
    address internal constant TRX_POOL = 0xa98D8a5867D664B7A758652146fd93a7dE40eE82;
    address internal constant SGOV = 0xc008c5F579ec1450F20099c39F587547e27c7523;
    address internal constant SGOV_POOL = 0xE0F4C53D777383cc77aDFa89087A9c877586F0dF;
    uint16 internal constant MIN_CARDINALITY = 2_400;

    function setUp() public {
        string memory rpc = vm.envOr("BSC_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);
    }

    function _oracle(address pool, address asset) internal returns (PancakeV3TwapOracle) {
        return new PancakeV3TwapOracle(pool, asset, FORK_USDT, 30 minutes, 300, 1 hours);
    }

    // ---- M-1 ----

    /// @dev Review PoC `test_poc_M1_maxOracleAgeIsNotEnforced`, now blocked: 30 days without a trade and the
    /// oracle refuses both directions. One real trade afterwards (a fresh observation) brings it back.
    function test_fork_M1_idlePoolFailsClosed_andRecoversOnTheNextTrade() public {
        PancakeV3TwapOracle oracle = _oracle(SGOV_POOL, SGOV);
        vm.warp(vm.getBlockTimestamp() + 30 days);
        vm.roll(vm.getBlockNumber() + 1);
        assertGt(_observationAge(SGOV_POOL), oracle.maxOracleAge(), "pool idle past maxOracleAge");

        vm.expectRevert(PancakeV3TwapOracle.TwapUnavailable.selector);
        oracle.previewSwap(FORK_USDT, SGOV, 100e18);
        vm.expectRevert(PancakeV3TwapOracle.TwapUnavailable.selector);
        oracle.previewSwap(SGOV, FORK_USDT, 1e18);

        _touch(SGOV_POOL);
        assertEq(_observationAge(SGOV_POOL), 0, "fresh observation");
        (uint256 quoted, uint256 minimum) = oracle.previewSwap(FORK_USDT, SGOV, 100e18);
        assertGt(quoted, 0);
        assertGt(minimum, 0);
    }

    /// @dev Boundary on live data: exactly `maxOracleAge` after the newest observation still quotes, one second
    /// later it does not.
    function test_fork_M1_boundaryOnALivePool() public {
        PancakeV3TwapOracle oracle = _oracle(SGOV_POOL, SGOV);
        _touch(SGOV_POOL);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        oracle.previewSwap(FORK_USDT, SGOV, 100e18);
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.expectRevert(PancakeV3TwapOracle.TwapUnavailable.selector);
        oracle.previewSwap(FORK_USDT, SGOV, 100e18);
    }

    // ---- M-2 ----

    /// @dev Control: the review PoC as is. With the pool's 10 slots, ten dust swaps one second apart push the
    /// 30 minute lookback out of the ring and the oracle goes offline.
    function test_fork_M2_withoutTheCardinalityStep_tenDustSwapsStillTakeTheOracleOffline() public {
        (,,, uint16 cardinality, uint16 next,,) = IPancakeV3Pool(TRX_POOL).slot0();
        // If this fails, the step has been run on mainnet and the control case no longer exists on a fresh fork.
        assertLt(next, MIN_CARDINALITY, "TRX pool already prepared on mainnet: drop this control test");
        PancakeV3TwapOracle oracle = _oracle(TRX_POOL, TRX);
        _ageHistory(oracle);
        _dustSwaps(cardinality);
        vm.expectRevert(PancakeV3TwapOracle.TwapUnavailable.selector);
        oracle.previewSwap(FORK_USDT, TRX, 100e18);
    }

    /// @dev The fix: `increaseObservationCardinalityNext(2400)` (what `IncreaseObservationCardinality` sends),
    /// then normal trading grows the ring and builds 30 minutes of history. The same ten dust swaps (and ten
    /// times as many) now leave the oracle quoting; pushing the lookback out takes 2,400 tick-moving swaps in 30
    /// minutes, i.e. one in every BSC block.
    function test_fork_M2_afterTheCardinalityStep_dustSwapsNoLongerTakeTheOracleOffline() public {
        (,,, uint16 cardinality,,,) = IPancakeV3Pool(TRX_POOL).slot0();
        IPoolCardinality(TRX_POOL).increaseObservationCardinalityNext(MIN_CARDINALITY);
        (,,,, uint16 next,,) = IPancakeV3Pool(TRX_POOL).slot0();
        assertGe(next, MIN_CARDINALITY, "next raised");

        // Trading wraps the old ring once; the pool then switches to the larger one.
        _dustSwaps(cardinality + 1);
        (,,, uint16 grown,,,) = IPancakeV3Pool(TRX_POOL).slot0();
        assertGe(grown, MIN_CARDINALITY, "ring grew on the next wrap");

        PancakeV3TwapOracle oracle = _oracle(TRX_POOL, TRX);
        _ageHistory(oracle);

        _dustSwaps(100);
        (uint256 quoted, uint256 minimum) = oracle.previewSwap(FORK_USDT, TRX, 100e18);
        assertGt(quoted, 0, "still quoting after 100 dust swaps");
        assertGt(minimum, 0);
        oracle.previewSwap(TRX, FORK_USDT, 100e6);
    }

    /// @dev A quiet market for 31 minutes, then one trade: the newest observation is fresh and the one before it
    /// is older than the 30 minute lookback, so the TWAP is servable even from the 10-slot ring.
    function _ageHistory(PancakeV3TwapOracle oracle) internal {
        vm.warp(vm.getBlockTimestamp() + 31 minutes);
        vm.roll(vm.getBlockNumber() + 2_480);
        _touch(TRX_POOL);
        oracle.previewSwap(FORK_USDT, TRX, 100e18); // quoting before the attack
    }

    /// @dev The review's griefing pattern: alternate a 20 USDT buy and its unwind, one per second, each moving
    /// the tick (so each writes an observation).
    function _dustSwaps(uint256 count) internal {
        IPancakeV3Pool pool = IPancakeV3Pool(TRX_POOL);
        bool usdtIsToken0 = pool.token0() == FORK_USDT;
        if (address(swapper) == address(0)) _touch(TRX_POOL);
        for (uint256 i; i < count; ++i) {
            vm.warp(vm.getBlockTimestamp() + 1);
            vm.roll(vm.getBlockNumber() + 2);
            (, int24 tickBefore,,,,,) = pool.slot0();
            if (i % 2 == 0) {
                deal(FORK_USDT, address(swapper), 20e18);
                swapper.swap(pool, usdtIsToken0, 20e18);
            } else {
                swapper.swap(pool, !usdtIsToken0, int256(IERC20(TRX).balanceOf(address(swapper))));
            }
            (, int24 tickAfter,,,,,) = pool.slot0();
            assertTrue(tickAfter != tickBefore, "each dust swap moves the tick");
        }
    }
}
