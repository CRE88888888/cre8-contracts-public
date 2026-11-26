// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";
import { AtpExecutor } from "../../src/atp/AtpExecutor.sol";
import { AtpRegistry } from "../../src/atp/AtpRegistry.sol";
import { MockPermit2 } from "./AtpExecutor.t.sol";
import { BurnableToken, PricedOracle, PricedRouter } from "./AtpExecutorBuyLimit.t.sol";

contract AtpExecutorVersionsTest is Test {
    AtpRegistry registry;
    AtpExecutor executor;
    PricedOracle oracle;
    BurnableToken usdt;
    BurnableToken a;
    BurnableToken b;
    BurnableToken c;
    uint256 id;

    function setUp() public {
        usdt = new BurnableToken();
        a = new BurnableToken();
        b = new BurnableToken();
        c = new BurnableToken();
        oracle = new PricedOracle(address(usdt));
        oracle.setPrice(address(a), 2e18);
        oracle.setPrice(address(b), 1e18);
        oracle.setPrice(address(c), 1e18);
        registry = new AtpRegistry();
        executor = new AtpExecutor(
            registry,
            new PricedRouter(),
            oracle,
            address(new MockPermit2()),
            address(0xFEE),
            address(usdt),
            10_000,
            0
        );
        usdt.approve(address(executor), type(uint256).max);
        a.approve(address(executor), type(uint256).max);
        b.approve(address(executor), type(uint256).max);
        c.approve(address(executor), type(uint256).max);
        id = registry.registerStrategy("versions", "historical exits", true);
        _publish(address(a));
        vm.warp(vm.getBlockTimestamp() + 1 days);
        registry.enroll(address(this), id, 1);
        usdt.mint(address(this), 1_000e18);
        a.mint(address(this), 100e18);
    }

    function _publish(address token) private {
        address[] memory assets = new address[](2);
        assets[0] = address(usdt);
        assets[1] = token;
        uint16[] memory weights = new uint16[](2);
        weights[0] = 5_000;
        weights[1] = 5_000;
        registry.publishVersion(id, assets, weights, bytes32(0), 0);
    }

    function _swap(address tokenIn, address tokenOut, uint256 amount) private {
        (uint256 quote,) = oracle.previewSwap(tokenIn, tokenOut, amount);
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(
            address(executor), amount, quote, abi.encodePacked(tokenIn, uint24(500), tokenOut), true
        );
        AtpExecutor.SwapStep[] memory steps = new AtpExecutor.SwapStep[](1);
        steps[0] = AtpExecutor.SwapStep(
            tokenIn, tokenOut, amount, quote, address(executor.universalRouter()), abi.encode(hex"00", inputs)
        );
        executor.executeRebalance(address(this), steps, vm.getBlockTimestamp());
    }

    function _assertRejected(address tokenIn, address tokenOut) private {
        // Quote before arming the revert expectation: the failing call must be the executor.
        (uint256 quote,) = oracle.previewSwap(tokenIn, tokenOut, 1e18);
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(
            address(executor), 1e18, quote, abi.encodePacked(tokenIn, uint24(500), tokenOut), true
        );
        AtpExecutor.SwapStep[] memory steps = new AtpExecutor.SwapStep[](1);
        steps[0] = AtpExecutor.SwapStep(
            tokenIn, tokenOut, 1e18, quote, address(executor.universalRouter()), abi.encode(hex"00", inputs)
        );
        vm.expectRevert(AtpExecutor.AssetNotAllowed.selector);
        executor.executeRebalance(address(this), steps, vm.getBlockTimestamp());
    }

    function test_automaticFollowAtBoundary_oldAssetSellOnly_andValued() public {
        vm.warp(vm.getBlockTimestamp() + 6 days);
        _publish(address(b));
        _assertRejected(address(usdt), address(b));
        uint256 at = registry.version(id, 2).activeAt;
        vm.warp(at - 1);
        _swap(address(usdt), address(a), 10e18);
        vm.warp(at);
        assertEq(registry.enrollments(address(this)).version, 1, "consent record is retained");
        _assertRejected(address(usdt), address(a));
        assertEq(executor.previewAccountValue(address(this)), 1_200e18);
        _swap(address(usdt), address(b), 10e18);
        executor.setMaxBuyBps(0);
        _swap(address(a), address(usdt), a.balanceOf(address(this)));
        assertEq(a.balanceOf(address(this)), 0, "old holdings can always sell, even in sales-only mode");
    }

    function test_assetsTwoVersionsAgoRemainSellable_andNoDoubleCounting() public {
        vm.warp(vm.getBlockTimestamp() + 6 days);
        _publish(address(b));
        vm.warp(vm.getBlockTimestamp() + 7 days);
        _publish(address(c));
        vm.warp(vm.getBlockTimestamp() + 1 days);
        assertEq(executor.previewAccountValue(address(this)), 1_200e18);
        _swap(address(a), address(usdt), 100e18);
        assertEq(a.balanceOf(address(this)), 0);
        vm.warp(vm.getBlockTimestamp() + 6 days);
        _publish(address(a));
        vm.warp(vm.getBlockTimestamp() + 1 days);
        a.mint(address(this), 100e18);
        assertEq(registry.historicalAssets(id).length, 4, "USDT,A,B,C each once");
        assertEq(executor.previewAccountValue(address(this)), 1_400e18);
    }

    function test_cancelledAndNeverEffectiveAssetsCannotBeSoldOrValued() public {
        vm.warp(vm.getBlockTimestamp() + 6 days);
        _publish(address(b));
        b.mint(address(this), 100e18);
        _assertRejected(address(b), address(usdt));
        registry.cancelVersion(id);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        assertFalse(registry.wasAssetAllowed(id, address(b)));
        _assertRejected(address(b), address(usdt));
        assertEq(executor.previewAccountValue(address(this)), 1_200e18);
    }

    function test_unpricedHistoricalHoldingLowersCap_andSaleStillRequiresFloor() public {
        vm.warp(vm.getBlockTimestamp() + 6 days);
        _publish(address(b));
        vm.warp(vm.getBlockTimestamp() + 1 days);
        oracle.setPrice(address(a), 0);
        assertEq(executor.previewAccountValue(address(this)), 1_000e18);
        // A sale retains the production oracle check, even for a historically admitted token.
        AtpExecutor.SwapStep[] memory steps = new AtpExecutor.SwapStep[](1);
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(
            address(executor), 1e18, 1, abi.encodePacked(address(a), uint24(500), address(usdt)), true
        );
        steps[0] = AtpExecutor.SwapStep(
            address(a),
            address(usdt),
            1e18,
            1,
            address(executor.universalRouter()),
            abi.encode(hex"00", inputs)
        );
        vm.expectRevert(bytes("stale"));
        executor.executeRebalance(address(this), steps, vm.getBlockTimestamp());
        assertEq(a.balanceOf(address(this)), 100e18);
    }
}
