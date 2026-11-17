// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";
import { AtpRegistry } from "../../src/atp/AtpRegistry.sol";
import { AtpExecutor } from "../../src/atp/AtpExecutor.sol";
import { AtpMultiPoolOracle } from "../../src/atp/AtpMultiPoolOracle.sol";
import { IOracleFloor } from "../../src/atp/interfaces/IOracleFloor.sol";
import { MockPermit2 } from "./AtpExecutor.t.sol";
import { BurnableToken, PricedOracle, PricedRouter } from "./AtpExecutorBuyLimit.t.sol";
import { MockPancakeV3Pool } from "./PancakeV3TwapOracle.t.sol";

contract AtpHistoricalAssetLimitTest is Test {
    AtpRegistry registry;
    uint256 id;
    bytes4 constant LIMIT_ERROR = AtpRegistry.StrategyAssetLimitExceeded.selector;

    function setUp() public {
        registry = new AtpRegistry();
        id = registry.registerStrategy("bounded history", "P11 review regression", true);
    }

    function _assets(uint256 offset, uint256 count) private returns (address[] memory assets) {
        assets = new address[](count);
        for (uint256 i; i < count; ++i) {
            assets[i] = address(uint160(0x100000 + offset + i));
            vm.etch(assets[i], hex"00");
        }
    }

    function _publish(uint256 strategy, address[] memory assets, bool settings) private {
        uint16[] memory weights = new uint16[](assets.length);
        for (uint256 i; i < weights.length; ++i) {
            weights[i] = uint16(10_000 / weights.length);
        }
        weights[0] += uint16(10_000 % weights.length);
        if (settings) {
            registry.publishSettingsVersion(strategy, assets, weights, bytes32(0), bytes32(0), 1_000, 0);
        } else {
            registry.publishVersion(strategy, assets, weights, bytes32(0), 0);
        }
    }

    function test_firstVersion128Accepted_and129RejectedByBothEntrypoints() public {
        assertEq(registry.MAX_STRATEGY_ASSETS(), 128);
        address[] memory tooMany = _assets(0, 129);
        vm.expectRevert(abi.encodeWithSelector(LIMIT_ERROR, uint256(129)));
        _publish(id, tooMany, false);
        vm.expectRevert(abi.encodeWithSelector(LIMIT_ERROR, uint256(129)));
        _publish(id, tooMany, true);
        assertEq(registry.versionCount(id), 0);
        assertEq(registry.lastPublishedAt(id), 0);
        assertEq(registry.historicalAssets(id).length, 0);

        _publish(id, _assets(0, 128), false);
        assertEq(registry.historicalAssets(id).length, 128, "first version is effective at once (#58)");
    }

    function test_maturedUnmaterializedHistoryCountsAt128_and129RevertsAtomically() public {
        address[] memory first = _assets(0, 127);
        _publish(id, first, false);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        // The first version materializes at publication (#58); the second matures below without being
        // materialized by any enrollment or other state-changing activation.
        address[] memory next = _assets(126, 2);
        _publish(id, next, true);
        assertEq(registry.historicalAssets(id).length, 127);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        assertEq(registry.historicalAssets(id).length, 128);
        assertTrue(registry.wasAssetAllowed(id, first[0]), "removed holdings retain sale admission");

        vm.warp(vm.getBlockTimestamp() + 6 days);
        uint64 last = registry.lastPublishedAt(id);
        address[] memory extra = _assets(128, 1);
        vm.expectRevert(abi.encodeWithSelector(LIMIT_ERROR, uint256(129)));
        _publish(id, extra, false);
        vm.expectRevert(abi.encodeWithSelector(LIMIT_ERROR, uint256(129)));
        _publish(id, extra, true);
        assertEq(registry.versionCount(id), 2);
        assertEq(registry.lastPublishedAt(id), last);
        assertEq(registry.activeVersion(id), 2);
        assertEq(registry.pendingVersion(id), 0);
        assertEq(registry.historicalAssets(id).length, 128);
        assertFalse(registry.wasAssetAllowed(id, extra[0]));

        // Reusing assets is valid even at capacity, including an immediate fee-only decrease.
        _publish(id, next, false);
        assertEq(registry.activeVersion(id), 3);
        assertEq(registry.historicalAssets(id).length, 128);
    }

    function test_cancelledVersionConsumesNoHistoryCapacity() public {
        _publish(id, _assets(0, 127), false);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        address[] memory cancelled = _assets(127, 1);
        _publish(id, cancelled, false);
        registry.cancelVersion(id);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        address[] memory replacement = _assets(128, 1);
        _publish(id, replacement, false);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        assertEq(registry.historicalAssets(id).length, 128);
        assertFalse(registry.wasAssetAllowed(id, cancelled[0]));
        assertTrue(registry.wasAssetAllowed(id, replacement[0]));
    }

    function test_fullUnionCanReorderAndReweight_andOtherStrategiesHaveOwnCapacity() public {
        address[] memory assets = _assets(0, 128);
        _publish(id, assets, false);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        (assets[0], assets[127]) = (assets[127], assets[0]);
        _publish(id, assets, true);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        assertEq(registry.historicalAssets(id).length, 128, "cross-version duplicates consume no capacity");
        uint256 second = registry.registerStrategy("independent", "per-strategy limit", true);
        _publish(second, _assets(128, 128), true);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        assertEq(registry.historicalAssets(second).length, 128);
        assertEq(registry.historicalAssets(id).length, 128);
    }

    function test_ownerCannotBypassUnionLimit() public {
        _publish(id, _assets(0, 128), false);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        address[] memory extra = _assets(128, 1);
        registry.transferOwnership(address(0xA11CE));
        vm.prank(address(0xA11CE));
        registry.acceptOwnership();
        uint16[] memory weights = new uint16[](1);
        weights[0] = 10_000;
        vm.prank(address(0xA11CE));
        vm.expectRevert(abi.encodeWithSelector(LIMIT_ERROR, uint256(129)));
        registry.publishVersion(id, extra, weights, bytes32(0), 0);
    }
}

/// @dev The independent review's balanceOf gas burner, copied without relaxing its behavior.
contract ExhaustsHistoricalBalanceRead {
    fallback() external {
        assembly { for { } 1 { } { } }
    }
}

contract AtpHistoricalAssetGasTest is Test {
    AtpRegistry registry;
    AtpExecutor executor;
    BurnableToken cash;
    BurnableToken a;
    BurnableToken b;
    PricedOracle oracle;
    PricedRouter router;
    MockPermit2 permit;
    uint256 id;
    uint256 start;

    function setUp() public {
        vm.record();
        vm.warp(2 days);
        start = vm.getBlockTimestamp();
        registry = new AtpRegistry();
        cash = new BurnableToken();
        a = new BurnableToken();
        b = new BurnableToken();
        registry.setNumeraire(address(cash));
        oracle = new PricedOracle(address(cash));
        oracle.setPrice(address(a), 1e18);
        oracle.setPrice(address(b), 1e18);
        router = new PricedRouter();
        permit = new MockPermit2();
        executor = _executor(oracle);
        cash.mint(address(this), 1_000e18);
        a.mint(address(this), 100e18);
        id = registry.registerStrategy("review", "historical valuation gas", true);
    }

    function _executor(IOracleFloor priceOracle) private returns (AtpExecutor e) {
        e = new AtpExecutor(
            registry, router, priceOracle, address(permit), address(0xFEE), address(cash), 10_000, 0
        );
        cash.approve(address(e), type(uint256).max);
        a.approve(address(e), type(uint256).max);
    }

    function _publish(address[] memory assets) private {
        uint16[] memory weights = new uint16[](assets.length);
        for (uint256 i; i < assets.length; ++i) {
            weights[i] = 1;
        }
        weights[0] += uint16(10_000 - assets.length);
        registry.publishSettingsVersion(id, assets, weights, bytes32(0), bytes32(0), 1_000, 0);
    }

    function _base() private view returns (address[] memory assets) {
        assets = new address[](3);
        assets[0] = address(cash);
        assets[1] = address(a);
        assets[2] = address(b);
    }

    function _step(address input, address output, uint256 amount)
        private
        view
        returns (AtpExecutor.SwapStep[] memory steps)
    {
        (uint256 quote,) = executor.oracle().previewSwap(input, output, amount);
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encode(
            address(executor), amount, quote, abi.encodePacked(input, uint24(500), output), true
        );
        steps = new AtpExecutor.SwapStep[](1);
        steps[0] =
            AtpExecutor.SwapStep(input, output, amount, quote, address(router), abi.encode(hex"00", data));
    }

    function _cool(address target) private {
        (bytes32[] memory reads, bytes32[] memory writes) = vm.accesses(target);
        for (uint256 i; i < reads.length; ++i) {
            vm.coolSlot(target, reads[i]);
        }
        for (uint256 i; i < writes.length; ++i) {
            vm.coolSlot(target, writes[i]);
        }
        vm.cool(target);
    }

    function _coolCore() private {
        // Read immutable dependencies before cooling; a later getter would warm the executor again.
        address yields = address(executor.yieldRegistry());
        address priceOracle = address(executor.oracle());
        _cool(address(registry));
        _cool(yields);
        _cool(address(cash));
        _cool(address(a));
        _cool(address(b));
        _cool(address(router));
        _cool(address(permit));
        _cool(priceOracle);
        _cool(address(executor));
    }

    function test_zeroHistoricalBalanceReadsBalanceButNeverPrice() public {
        _publish(_base());
        vm.warp(start + 7 days);
        address[] memory clean = new address[](2);
        clean[0] = address(cash);
        clean[1] = address(a);
        _publish(clean);
        vm.warp(start + 8 days);
        registry.enroll(address(this), id, 2);
        vm.expectCall(address(b), abi.encodeCall(b.balanceOf, (address(this))), 1);
        // Count the selector, rather than one input tuple: any price call at all would fail this test.
        vm.expectCall(address(oracle), abi.encodePacked(IOracleFloor.previewSwap.selector), 1);
        vm.expectCall(
            address(oracle), abi.encodeCall(oracle.previewSwap, (address(a), address(cash), 100e18)), 1
        );
        assertEq(executor.previewAccountValue(address(this)), 1_100e18);
    }

    function test_128OrdinaryAssetsWithHeldHistory_singleBuyBelow12MillionGas() public {
        AtpMultiPoolOracle realOracle = new AtpMultiPoolOracle(address(cash));
        executor = _executor(realOracle);
        address[] memory assets = new address[](128);
        address[] memory pools = new address[](127);
        address[] memory pairOracles = new address[](127);
        assets[0] = address(cash);
        assets[1] = address(a);
        for (uint256 i = 1; i < assets.length; ++i) {
            if (i > 1) {
                BurnableToken token = new BurnableToken();
                assets[i] = address(token);
                token.mint(address(this), 1e18);
            }
            MockPancakeV3Pool pool = new MockPancakeV3Pool(assets[i], address(cash));
            pool.setMeanTick(0, 30 minutes);
            pools[i - 1] = address(pool);
            pairOracles[i - 1] =
                address(realOracle.setOracle(assets[i], address(pool), 30 minutes, 50, 1 hours));
        }
        _publish(assets);
        vm.warp(start + 7 days);
        address[] memory clean = new address[](2);
        clean[0] = address(cash);
        clean[1] = address(a);
        _publish(clean);
        vm.warp(start + 8 days);
        registry.enroll(address(this), id, 2);
        assertEq(registry.historicalAssets(id).length, 128);
        assertEq(
            executor.previewAccountValue(address(this)), 1_226e18, "every held historical asset is valued"
        );
        AtpExecutor.SwapStep[] memory buying = _step(address(cash), address(a), 1e18);
        for (uint256 i; i < assets.length; ++i) {
            _cool(assets[i]);
        }
        for (uint256 i; i < pools.length; ++i) {
            _cool(pools[i]);
            _cool(pairOracles[i]);
        }
        _coolCore();
        uint256 beforeGas = gasleft();
        executor.executeRebalance{ gas: 12_000_000 }(address(this), buying, vm.getBlockTimestamp());
        uint256 used = beforeGas - gasleft();
        emit log_named_uint("128_ASSET_SINGLE_BUY_GAS", used);
        assertLt(used, 12_000_000);
        assertEq(cash.balanceOf(address(this)), 999e18);
        assertEq(a.balanceOf(address(this)), 101e18);
    }

    /// @dev Adapted from Independent.t.sol:198: the second 90-token publication must now be blocked.
    function test_reviewHistoricalBalanceReadGasPoC_unionLimitBlocksAccumulation() public {
        _publish(_base());
        vm.warp(start + 1 days);
        registry.enroll(address(this), id, 1);
        ExhaustsHistoricalBalanceRead hostile = new ExhaustsHistoricalBalanceRead();
        for (uint256 round; round < 2; ++round) {
            vm.warp(start + (round + 1) * 7 days);
            address[] memory assets = new address[](92);
            assets[0] = address(cash);
            assets[1] = address(a);
            for (uint256 i = 2; i < 92; ++i) {
                address token = address(uint160(0x100000 + round * 1000 + i));
                vm.etch(token, address(hostile).code);
                assets[i] = token;
            }
            if (round == 1) {
                vm.expectRevert(
                    abi.encodeWithSelector(AtpRegistry.StrategyAssetLimitExceeded.selector, uint256(183))
                );
            }
            _publish(assets);
            vm.warp(vm.getBlockTimestamp() + 1 days);
        }
        assertEq(registry.versionCount(id), 2);
        assertEq(registry.historicalAssets(id).length, 93);
        vm.warp(start + 21 days);
        _publish(_base());
        vm.warp(start + 22 days);
        registry.enroll(address(this), id, 3);
        address[] memory history = registry.historicalAssets(id);
        AtpExecutor.SwapStep[] memory buying = _step(address(cash), address(a), 1e18);
        for (uint256 i; i < history.length; ++i) {
            _cool(history[i]);
        }
        _coolCore();
        uint256 beforeGas = gasleft();
        executor.executeRebalance{ gas: 16_777_216 }(address(this), buying, vm.getBlockTimestamp());
        emit log_named_uint("REVIEW_POC_SINGLE_BUY_GAS", beforeGas - gasleft());
        assertEq(executor.previewAccountValue{ gas: 16_777_216 }(address(this)), 1_100e18);
        assertEq(cash.balanceOf(address(this)), 999e18);
        assertEq(a.balanceOf(address(this)), 101e18);
        executor.executeRebalance(
            address(this), _step(address(a), address(cash), 1e18), vm.getBlockTimestamp()
        );
        assertEq(cash.balanceOf(address(this)), 1_000e18);
    }
}
