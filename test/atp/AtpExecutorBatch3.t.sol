// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Vm } from "forge-std/Test.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { AtpExecutor } from "../../src/atp/AtpExecutor.sol";
import { AtpMultiPoolOracle } from "../../src/atp/AtpMultiPoolOracle.sol";
import { PancakeV3TwapOracle } from "../../src/atp/PancakeV3TwapOracle.sol";
import { PushFeedPriceSource } from "../../src/atp/PushFeedPriceSource.sol";
import { MockAggregator } from "./AtpMultiPoolOracleSecondary.t.sol";
import { TestnetToken } from "../../src/testnet/TestnetToken.sol";
import { Batch3Fixture, LocalV3Pool, LocalPoolVenue } from "./fixtures/batch3/Batch3Fixture.sol";

/// @notice CT-1 contract side of V2/V4/V8/V9. Signals, cost ledger, 16-step splitting and UserOp gas remain
/// backend responsibilities. No executor selector or production parameter is added for any strategy.
contract AtpExecutorBatch3Test is Batch3Fixture {
    function test_realObservations_quote18And6Decimals_bothDirections() public {
        TestnetToken six = new TestnetToken("Local six", "SIX", 6, address(this));
        int24 tick = address(asset) < address(six) ? int24(-276_324) : int24(276_324);
        LocalV3Pool mixed = _newPoolAtTick(asset, six, tick);
        LocalPoolVenue lp = new LocalPoolVenue(mixed);
        asset.mint(address(lp), 1e32);
        six.mint(address(lp), 1e32);
        lp.addLiquidity(1e18);
        PancakeV3TwapOracle adapter =
            new PancakeV3TwapOracle(address(mixed), address(asset), address(six), WINDOW, 50, 1 hours);
        _advance(WINDOW);
        lp.addLiquidity(1);
        (uint256 q, uint256 floor) = adapter.previewSwap(address(asset), address(six), 1_000e18);
        assertEq(q, 1_000_002_644, "tick -276324 already includes decimal scaling");
        assertEq(floor, 995_002_631);
        (q, floor) = adapter.previewSwap(address(six), address(asset), 1_000e6);
        assertEq(q, 999_997_356_176_039_153_114);
        assertEq(floor, 994_997_369_395_158_957_349);
    }

    function test_oracleWarmup_exact1800_andSpotCrashDoesNotBecomeSignalPrice() public {
        vm.expectRevert(PancakeV3TwapOracle.TwapUnavailable.selector);
        oracle.previewSwap(address(asset), address(usdt), 1e18);
        _advance(WINDOW - 1);
        venue.addLiquidity(1);
        vm.expectRevert(PancakeV3TwapOracle.TwapUnavailable.selector);
        oracle.previewSwap(address(asset), address(usdt), 1e18);
        _advance(1);
        venue.addLiquidity(1);
        (uint256 p,) = oracle.previewSwap(address(asset), address(usdt), 1e18);
        assertEq(p, 1e18, "full 1800 seconds of real observations");
        _movePrice(-2_000);
        (uint256 afterCrash,) = oracle.previewSwap(address(asset), address(usdt), 1e18);
        assertEq(afterCrash, p, "spot moved, no elapsed time in TWAP");
        assertLt(_realOutput(false, 1e18), 0.9e18, "executable spot already below SL");
        assertGt(afterCrash, 0.9e18, "TWAP has not crossed SL");
        _advance(WINDOW);
        venue.addLiquidity(1);
        (uint256 matured,) = oracle.previewSwap(address(asset), address(usdt), 1e18);
        assertLt(matured, 0.9e18, "only time at the new tick moves signal price");
    }

    function test_oracleWarmup_exact5400_andStaleRecovery() public {
        PancakeV3TwapOracle longOracle = new PancakeV3TwapOracle(
            address(pool), address(asset), address(usdt), 90 minutes, 50, 90 minutes
        );
        _advance(90 minutes - 1);
        venue.addLiquidity(1);
        vm.expectRevert(PancakeV3TwapOracle.TwapUnavailable.selector);
        longOracle.previewSwap(address(asset), address(usdt), 1e18);
        _advance(1);
        venue.addLiquidity(1);
        (uint256 quoted,) = longOracle.previewSwap(address(asset), address(usdt), 1e18);
        assertEq(quoted, 1e18);
        _advance(90 minutes);
        longOracle.previewSwap(address(asset), address(usdt), 1e18); // exact max age
        _advance(1);
        vm.expectRevert(PancakeV3TwapOracle.TwapUnavailable.selector);
        longOracle.previewSwap(address(asset), address(usdt), 1e18);
        venue.addLiquidity(1);
        (quoted,) = longOracle.previewSwap(address(asset), address(usdt), 1e18);
        assertEq(quoted, 1e18, "new real observation recovers the source");
    }

    function test_recentFloor_bindsSale_afterFiveMinuteRise() public {
        _warm();
        _movePrice(1_000);
        _advance(5 minutes);
        venue.addLiquidity(1);
        (uint256 twap, uint256 recent, uint256 minimum) =
            pairOracle.previewSwapWindows(address(asset), address(usdt), 10e18);
        assertGt(recent, twap);
        assertEq(minimum, Math.mulDiv(recent, 9_950, BPS, Math.Rounding.Ceil));
        AtpExecutor.SwapStep[] memory steps = _one(_step(false, 10e18));
        // The sale would clear the 30-minute floor; a spot retrace below the recent floor must still fail.
        _movePrice(300);
        uint256 actual = _realOutput(false, 10e18);
        assertGt(actual, Math.mulDiv(twap, 9_950, BPS - FEE_BPS, Math.Rounding.Ceil));
        assertLt(actual, steps[0].amountOutMin);
        _expectFloor(steps, actual, steps[0].amountOutMin);
        _assertUnspent();
    }

    function test_stopSignalDoesNotPermitSaleBelowTwapFloor() public {
        _warm();
        _movePrice(-2_000);
        _advance(WINDOW);
        venue.addLiquidity(1);
        (uint256 p,) = oracle.previewSwap(address(asset), address(usdt), 1e18);
        assertLt(p, 0.9e18, "SL signal has crossed");
        AtpExecutor.SwapStep[] memory steps = _one(_step(false, 10e18));
        _movePrice(-3_000);
        uint256 actual = _realOutput(false, 10e18);
        _expectFloor(steps, actual, steps[0].amountOutMin);
        _assertUnspent();
        _movePrice(-2_000);
        _run(address(this), steps);
        assertEq(asset.balanceOf(address(this)), 990e18, "exit only after real output clears floor");
        _assertClean();
    }

    function test_limitBuy_netPriceIncludesFeeTopUp_exactBoundAndOneRawShort() public {
        _warm();
        uint256 amount = 10e18;
        uint256 topUp = executor.minFeeDue(address(this), amount);
        assertEq(topUp, 0.09e18);
        uint256 actual = _realOutput(true, amount);
        uint256 net = actual - actual * FEE_BPS / BPS;
        // T is the conservative maximum effective price (USDT per raw-scaled asset) this fill can meet.
        uint256 limitPrice = Math.mulDiv(amount + topUp, 1e18, net, Math.Rounding.Ceil);
        uint256 requiredNet = Math.mulDiv(amount + topUp, 1e18, limitPrice, Math.Rounding.Ceil);
        uint256 grossBound = Math.mulDiv(requiredNet, BPS, BPS - FEE_BPS, Math.Rounding.Ceil);
        assertLe(grossBound, actual);
        AtpExecutor.SwapStep[] memory steps = _one(_step(true, amount));
        assertGt(grossBound, steps[0].amountOutMin, "limit is stricter than oracle floor");
        steps[0].amountOutMin = actual + 1;
        _expectFloor(steps, actual, actual + 1);
        _assertUnspent();
        steps[0].amountOutMin = actual; // equality binds even though venue has no minimum argument
        _run(address(this), steps);
        assertEq(asset.balanceOf(address(this)), 1_000e18 + net);
        assertEq(usdt.balanceOf(address(this)), 1_000e18 - amount - topUp);
        assertEq(usdt.balanceOf(FEE_RECIPIENT), topUp);
        assertLe(Math.mulDiv(amount + topUp, 1e18, net, Math.Rounding.Ceil), limitPrice);
        _assertClean();
    }

    function test_takeProfit_netProceedsIncludeTopUp_exactBoundAndOneRawShort() public {
        _warm();
        uint256 amount = 10e18;
        uint256 actual = _realOutput(false, amount);
        uint256 topUp = executor.minFeeDue(address(this), actual); // sale notional is gross USDT
        uint256 net = actual - actual * FEE_BPS / BPS - topUp;
        uint256 target = net * 1e18 / amount;
        uint256 requiredGross = Math.mulDiv(
            Math.mulDiv(target, amount, 1e18, Math.Rounding.Ceil) + topUp,
            BPS,
            BPS - FEE_BPS,
            Math.Rounding.Ceil
        );
        assertLe(requiredGross, actual);
        AtpExecutor.SwapStep[] memory steps = _one(_step(false, amount));
        assertGt(requiredGross, steps[0].amountOutMin);
        steps[0].amountOutMin = actual + 1;
        _expectFloor(steps, actual, actual + 1);
        _assertUnspent();
        steps[0].amountOutMin = actual;
        _run(address(this), steps);
        assertEq(usdt.balanceOf(address(this)), 1_000e18 + net);
        assertGe((usdt.balanceOf(address(this)) - 1_000e18) * 1e18 / amount, target);
        assertEq(usdt.balanceOf(FEE_RECIPIENT), actual * FEE_BPS / BPS + topUp);
        _assertClean();
    }

    function test_limitBuy_signalAndGrossPricePass_butFeeInclusiveLimitRejects() public {
        _warm();
        uint256 amount = 10e18;
        uint256 limitPrice = 1.01e18;
        (uint256 p,) = oracle.previewSwap(address(asset), address(usdt), 1e18);
        assertLe(p, limitPrice, "signal condition is satisfied");
        uint256 actual = _realOutput(true, amount);
        uint256 topUp = executor.minFeeDue(address(this), amount);
        uint256 ignoringTopUp = Math.mulDiv(
            Math.mulDiv(amount, 1e18, limitPrice, Math.Rounding.Ceil), BPS, BPS - FEE_BPS, Math.Rounding.Ceil
        );
        uint256 withTopUp = Math.mulDiv(
            Math.mulDiv(amount + topUp, 1e18, limitPrice, Math.Rounding.Ceil),
            BPS,
            BPS - FEE_BPS,
            Math.Rounding.Ceil
        );
        assertGe(actual, ignoringTopUp, "omitting fee top-up would wrongly accept this fill");
        assertLt(actual, withTopUp);
        AtpExecutor.SwapStep[] memory steps = _one(_step(true, amount));
        steps[0].amountOutMin = withTopUp;
        _expectFloor(steps, actual, withTopUp);
        _assertUnspent();
    }

    function test_takeProfit_grossPricePasses_butFeeInclusiveTargetRejects() public {
        _warm();
        uint256 amount = 10e18;
        uint256 requiredNet = 9.95e18;
        uint256 actual = _realOutput(false, amount);
        assertGt(actual, requiredNet, "gross price exceeds TP");
        uint256 topUp = executor.minFeeDue(address(this), actual);
        uint256 bound = Math.mulDiv(requiredNet + topUp, BPS, BPS - FEE_BPS, Math.Rounding.Ceil);
        assertLt(actual - actual / 1_000 - topUp, requiredNet, "net proceeds miss TP");
        AtpExecutor.SwapStep[] memory steps = _one(_step(false, amount));
        steps[0].amountOutMin = bound;
        _expectFloor(steps, actual, bound);
        _assertUnspent();
    }

    function test_buyCap_exactValue_plusOneRaw_andZeroCapStillAllowsSale() public {
        _warm();
        executor.setMaxBuyBps(5_000);
        (uint256 cap,,) = executor.buyAllowance(address(this));
        assertEq(cap, 1_000e18);
        AtpExecutor.SwapStep[] memory steps = _one(_step(true, cap + 1));
        vm.expectRevert(abi.encodeWithSelector(AtpExecutor.BuyLimitExceeded.selector, cap + 1, cap));
        executor.executeRebalance(address(this), steps, block.timestamp);
        _assertUnspent();
        _run(address(this), _one(_step(true, cap)));
        (, uint192 bought) = executor.buyWindowOf(address(this));
        assertEq(bought, cap, "exact cap accepted");
        executor.setMaxBuyBps(0);
        steps = _one(_step(true, 1));
        vm.expectRevert(abi.encodeWithSelector(AtpExecutor.BuyLimitExceeded.selector, cap + 1, 0));
        executor.executeRebalance(address(this), steps, block.timestamp);
        uint256 before = asset.balanceOf(address(this));
        _run(address(this), _one(_step(false, 10e18)));
        assertEq(asset.balanceOf(address(this)), before - 10e18);
        (, bought) = executor.buyWindowOf(address(this));
        assertLt(bought, cap, "the sale credited its output back (cre8-contracts#76)");
        (uint128 gross,) = executor.buyChurnOf(address(this));
        assertEq(gross, cap, "gross side never credited");
        _assertClean();
    }

    function test_mixedSixteenSteps_realTransfersEventsAndFeeAccounting() public {
        _warm();
        AtpExecutor.SwapStep[] memory steps = new AtpExecutor.SwapStep[](16);
        for (uint256 i; i < steps.length; ++i) {
            steps[i] = _step(i % 2 == 0, 1e18);
        }
        vm.recordLogs();
        _run(address(this), steps);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 swaps;
        uint256 notional;
        uint256 feeUsdt;
        uint256 feeAsset;
        uint256 cash = 1_000e18;
        uint256 units = 1_000e18;
        uint256 transfers;
        uint256 feeEvents;
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory entry = logs[i];
            if (entry.topics[0] == keccak256("Transfer(address,address,uint256)")) ++transfers;
            if (entry.emitter == address(executor) && entry.topics[0] == AtpExecutor.MinFeeCharged.selector) {
                assertEq(entry.topics[1], bytes32(uint256(uint160(address(this)))));
                uint256 emittedTopUp = notional / 100 - notional / 1_000;
                assertEq(entry.data, abi.encode(notional, emittedTopUp, emittedTopUp));
                ++feeEvents;
            }
            if (entry.emitter != address(executor) || entry.topics[0] != AtpExecutor.SwapExecuted.selector) {
                continue;
            }
            assertEq(entry.topics[1], bytes32(uint256(uint160(address(this)))));
            (
                address tokenIn,
                address tokenOut,
                uint256 amountIn,
                uint256 gross,
                uint256 fee,
                uint256 net,
                uint256 grossFloor
            ) = abi.decode(entry.data, (address, address, uint256, uint256, uint256, uint256, uint256));
            bool buy = swaps % 2 == 0;
            assertEq(tokenIn, buy ? address(usdt) : address(asset));
            assertEq(tokenOut, buy ? address(asset) : address(usdt));
            assertEq(amountIn, steps[swaps].amountIn);
            assertGe(gross, steps[swaps].amountOutMin);
            // Despite the ABI field name oracleFloor, the event exposes minGross, already grossed up.
            assertEq(grossFloor, _minGross(tokenIn, tokenOut, amountIn));
            (, uint256 netFloor) = oracle.previewSwap(tokenIn, tokenOut, amountIn);
            assertGe(net, netFloor);
            assertEq(fee, gross / 1_000);
            assertEq(net + fee, gross);
            _assertTransfer(logs, tokenIn, address(this), address(executor), amountIn);
            _assertTransfer(logs, tokenOut, address(pool), address(executor), gross);
            _assertTransfer(logs, tokenOut, address(executor), address(this), net);
            _assertTransfer(logs, tokenOut, address(executor), FEE_RECIPIENT, fee);
            notional += buy ? amountIn : gross;
            if (buy) {
                cash -= amountIn;
                units += net;
                feeAsset += fee;
            } else {
                units -= amountIn;
                cash += net;
                feeUsdt += fee;
            }
            ++swaps;
        }
        assertEq(swaps, 16);
        assertEq(feeEvents, 1);
        assertGe(transfers, swaps * 4, "input, pool output, proportional fee and account transfer");
        uint256 topUp = notional / 100 - notional / 1_000; // c < 30: capped at 1%
        assertEq(usdt.balanceOf(address(this)), cash - topUp);
        assertEq(asset.balanceOf(address(this)), units);
        assertEq(usdt.balanceOf(FEE_RECIPIENT), feeUsdt + topUp);
        assertEq(asset.balanceOf(FEE_RECIPIENT), feeAsset);
        (, uint192 bought) = executor.buyWindowOf(address(this));
        assertLt(bought, 8e18, "sales credit the window back (cre8-contracts#76)");
        (uint128 gross,) = executor.buyChurnOf(address(this));
        assertEq(gross, 8e18, "every buy counted gross, sales never consume quota");
        (, uint192 c, uint256 paid) = executor.minFeeWindowOf(address(this));
        assertEq(c, notional);
        assertEq(paid, topUp);
        _assertClean();
    }

    function test_finalSellFailure_rollsBackPriorBuyTransfersFeesWindowsAndPool() public {
        _warm();
        AtpExecutor.SwapStep[] memory steps = new AtpExecutor.SwapStep[](2);
        steps[0] = _step(true, 10e18);
        steps[1] = _step(false, 10e18);
        steps[1].amountOutMin = 20e18;
        uint256 snapshot = vm.snapshotState();
        _run(address(this), _one(steps[0])); // prove the first leg can really succeed
        uint256 sellOutput = _realOutput(false, 10e18);
        assertLt(sellOutput, steps[1].amountOutMin);
        assertTrue(vm.revertToState(snapshot));
        (uint160 beforePrice,,,,,,) = pool.slot0();
        vm.expectRevert(
            abi.encodeWithSelector(AtpExecutor.BelowFloor.selector, sellOutput, steps[1].amountOutMin)
        );
        executor.executeRebalance(address(this), steps, block.timestamp);
        (uint160 afterPrice,,,,,,) = pool.slot0();
        assertEq(afterPrice, beforePrice);
        _assertUnspent();
    }

    function _assertTransfer(Vm.Log[] memory logs, address token, address from, address to, uint256 amount)
        private
        pure
    {
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == token && logs[i].topics.length == 3
                    && logs[i].topics[0] == keccak256("Transfer(address,address,uint256)")
                    && logs[i].topics[1] == bytes32(uint256(uint160(from)))
                    && logs[i].topics[2] == bytes32(uint256(uint160(to)))
                    && abi.decode(logs[i].data, (uint256)) == amount
            ) return;
        }
        revert("matching ERC20 Transfer missing");
    }

    function test_localReplay_sameScenarioProducesSameTransfersFeesAndWindows() public {
        _warm();
        uint256 snapshot = vm.snapshotState();
        bytes32 first = _replay();
        assertTrue(vm.revertToState(snapshot));
        assertEq(_replay(), first, "same scenario and initial chain state reproduce the full result");
    }

    function _replay() private returns (bytes32) {
        AtpExecutor.SwapStep[] memory steps = new AtpExecutor.SwapStep[](2);
        steps[0] = _step(true, 10e18);
        steps[1] = _step(false, 5e18);
        vm.recordLogs();
        _run(address(this), steps);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        (uint64 buyStart, uint192 bought) = executor.buyWindowOf(address(this));
        (uint64 feeStart, uint192 notional, uint256 paid) = executor.minFeeWindowOf(address(this));
        return keccak256(
            abi.encode(
                keccak256("CT51-mixed-replay-v1"),
                logs,
                usdt.balanceOf(address(this)),
                asset.balanceOf(address(this)),
                usdt.balanceOf(FEE_RECIPIENT),
                asset.balanceOf(FEE_RECIPIENT),
                buyStart,
                bought,
                feeStart,
                notional,
                paid
            )
        );
    }

    function test_secondaryFailure_missingOrStaleSourceCannotBecomeZeroFloor() public {
        _warm();
        AtpExecutor.SwapStep[] memory steps = _one(_step(true, 10e18));
        MockAggregator assetFeed = new MockAggregator(8, 1e8);
        MockAggregator cashFeed = new MockAggregator(8, 1e8);
        oracle.setSecondary(address(asset), assetFeed, cashFeed, 1 hours, 1 hours, 200);
        assetFeed.set(1e8, block.timestamp - 1 hours - 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                PushFeedPriceSource.StaleFeed.selector, address(assetFeed), block.timestamp - 1 hours - 1
            )
        );
        executor.executeRebalance(address(this), steps, block.timestamp);
        _assertUnspent();
        oracle.clearSecondary(address(asset));
        oracle.clearOracle(address(asset));
        vm.expectRevert(abi.encodeWithSelector(AtpMultiPoolOracle.OracleNotSet.selector, address(asset)));
        executor.executeRebalance(address(this), steps, block.timestamp);
        _assertUnspent();
    }

    function test_globalPause_blocksBothDirections_andResumeRestoresRealSale() public {
        _warm();
        AtpExecutor.SwapStep[] memory buy = _one(_step(true, 1e18));
        AtpExecutor.SwapStep[] memory sell = _one(_step(false, 1e18));
        executor.setGlobalPaused(true);
        vm.expectRevert(AtpExecutor.ExecutorPaused.selector);
        executor.executeRebalance(address(this), buy, block.timestamp);
        vm.expectRevert(AtpExecutor.ExecutorPaused.selector);
        executor.executeRebalance(address(this), sell, block.timestamp);
        _assertUnspent();
        executor.setGlobalPaused(false);
        _run(address(this), sell);
        assertEq(asset.balanceOf(address(this)), 999e18);
        _assertClean();
    }

    function _expectFloor(AtpExecutor.SwapStep[] memory steps, uint256 actual, uint256 bound) private {
        vm.expectRevert(abi.encodeWithSelector(AtpExecutor.BelowFloor.selector, actual, bound));
        executor.executeRebalance(address(this), steps, block.timestamp);
    }

    function _assertUnspent() private view {
        assertEq(usdt.balanceOf(address(this)), 1_000e18);
        assertEq(asset.balanceOf(address(this)), 1_000e18);
        assertEq(usdt.balanceOf(FEE_RECIPIENT), 0);
        assertEq(asset.balanceOf(FEE_RECIPIENT), 0);
        (uint64 start, uint192 bought) = executor.buyWindowOf(address(this));
        assertEq(start, 0);
        assertEq(bought, 0);
        (uint64 feeStart, uint192 notional, uint256 paid) = executor.minFeeWindowOf(address(this));
        assertEq(feeStart, 0);
        assertEq(notional, 0);
        assertEq(paid, 0);
        _assertClean();
    }
}
