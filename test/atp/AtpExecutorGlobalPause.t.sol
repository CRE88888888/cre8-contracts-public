// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";
import { AtpExecutor } from "../../src/atp/AtpExecutor.sol";
import { AtpRegistry } from "../../src/atp/AtpRegistry.sol";
import { MockUniversalRouter, MockOracleFloor, MockPermit2, MockERC20 } from "./AtpExecutor.t.sol";

/// @notice Pins the A10-3 kill switch: only the registry owner (the Safe) flips `globalPaused`, and while it is
/// set every `executeRebalance` fails closed before any other check; resuming restores execution.
/// @dev This test contract is both the registry owner (it deployed the registry) and the enrolled account (it
/// has code and enrolls itself), so `executeRebalance(address(this), [], deadline)` is the minimal call that
/// passes every per-account check: it isolates the switch from the swap path.
contract AtpExecutorGlobalPauseTest is Test {
    address internal constant SAFE = address(0x5AFE);
    address internal constant OPERATOR = address(0x0FE7);
    address internal constant OUTSIDER = address(0xCAFE);
    address internal constant FEE_RECIPIENT = address(0xFEE);

    AtpRegistry internal registry;
    AtpExecutor internal executor;
    AtpExecutor.SwapStep[] internal noSteps;

    function setUp() public {
        registry = new AtpRegistry();
        executor = new AtpExecutor(
            registry,
            new MockUniversalRouter(),
            new MockOracleFloor(),
            address(new MockPermit2()),
            FEE_RECIPIENT,
            address(new MockERC20()),
            10_000,
            0
        );
        registry.setOperator(OPERATOR);

        address[] memory assets = new address[](1);
        assets[0] = address(0xAAA1);
        uint16[] memory weights = new uint16[](1);
        weights[0] = 10_000;
        uint256 id = registry.registerStrategy("index", "global pause", true);
        registry.publishVersion(id, assets, weights, keccak256("schedule"), 0);
        registry.enroll(address(this), id);
    }

    function _rebalance() internal {
        executor.executeRebalance(address(this), noSteps, block.timestamp + 300);
    }

    function test_globalPaused_defaultsToFalse() public {
        assertFalse(executor.globalPaused(), "a fresh executor runs");
        _rebalance();
    }

    function test_setGlobalPaused_onlyRegistryOwner() public {
        vm.prank(OUTSIDER);
        vm.expectRevert(AtpExecutor.NotOwner.selector);
        executor.setGlobalPaused(true);

        // The operator can enroll and pause single accounts, but never touch the global switch.
        vm.prank(OPERATOR);
        vm.expectRevert(AtpExecutor.NotOwner.selector);
        executor.setGlobalPaused(true);

        vm.expectEmit(false, false, false, true, address(executor));
        emit AtpExecutor.GlobalPausedSet(true);
        executor.setGlobalPaused(true);
        assertTrue(executor.globalPaused(), "owner paused");

        vm.prank(OPERATOR);
        vm.expectRevert(AtpExecutor.NotOwner.selector);
        executor.setGlobalPaused(false);
        assertTrue(executor.globalPaused(), "operator cannot resume");
    }

    function test_globalPaused_blocksEveryRebalance() public {
        executor.setGlobalPaused(true);

        vm.expectRevert(AtpExecutor.ExecutorPaused.selector);
        _rebalance();

        // Checked first: even a call that would fail `NotAccount` reports the switch, so the cause is never
        // masked by a per-account error.
        vm.prank(OUTSIDER);
        vm.expectRevert(AtpExecutor.ExecutorPaused.selector);
        executor.executeRebalance(address(this), noSteps, block.timestamp + 300);
    }

    function test_globalPaused_isIndependentOfAccountPause() public {
        executor.setGlobalPaused(true);
        executor.setGlobalPaused(false);
        _rebalance();

        // The per-account pause keeps its own error, so backend and app can tell the two apart.
        registry.setPaused(address(this), true);
        vm.expectRevert(AtpExecutor.Paused.selector);
        _rebalance();
    }

    function test_resume_restoresExecution() public {
        executor.setGlobalPaused(true);
        vm.expectRevert(AtpExecutor.ExecutorPaused.selector);
        _rebalance();

        vm.expectEmit(false, false, false, true, address(executor));
        emit AtpExecutor.GlobalPausedSet(false);
        executor.setGlobalPaused(false);
        assertFalse(executor.globalPaused(), "resumed");
        _rebalance();
    }

    function test_switch_followsRegistryOwnershipHandover() public {
        registry.transferOwnership(SAFE);
        // Not yet accepted: the switch stays with the current owner.
        vm.prank(SAFE);
        vm.expectRevert(AtpExecutor.NotOwner.selector);
        executor.setGlobalPaused(true);

        vm.prank(SAFE);
        registry.acceptOwnership();

        vm.expectRevert(AtpExecutor.NotOwner.selector);
        executor.setGlobalPaused(true);
        vm.prank(SAFE);
        executor.setGlobalPaused(true);
        assertTrue(executor.globalPaused(), "new owner holds the switch");
    }
}
