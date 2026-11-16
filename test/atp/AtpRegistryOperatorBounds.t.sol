// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";
import { AtpRegistry } from "../../src/atp/AtpRegistry.sol";

/// @notice Pins A10-2 (cre8-contracts#11): the operator only makes an account's first enrollment and only
/// lifts the pause it set itself; the owner (Safe) outranks the operator but never lifts the account's own
/// pause; the account itself may re-enroll and lift every pause. `enrollments().paused` mirrors the flags.
contract AtpRegistryOperatorBoundsTest is Test {
    address internal constant SAFE = address(0x5AFE);
    address internal constant OPERATOR = address(0x0FE7);
    address internal constant PROVIDER = address(0xBEEF);
    address internal constant ACCOUNT = address(0xACC7);
    address internal constant OTHER_ACCOUNT = address(0xACC8);
    address internal constant OUTSIDER = address(0xCAFE);

    uint8 internal constant BY_OWNER = 1;
    uint8 internal constant BY_OPERATOR = 2;
    uint8 internal constant BY_ACCOUNT = 4;

    AtpRegistry internal registry;
    uint256 internal strategyA;
    uint256 internal strategyB;

    function setUp() public {
        registry = new AtpRegistry();
        registry.transferOwnership(SAFE);
        vm.prank(SAFE);
        registry.acceptOwnership();
        vm.prank(SAFE);
        registry.setOperator(OPERATOR);

        vm.startPrank(PROVIDER);
        strategyA = registry.registerStrategy("a", "strategy a", true);
        _publish(strategyA, address(0xAAA1));
        strategyB = registry.registerStrategy("b", "strategy b", true);
        _publish(strategyB, address(0xBBB1));
        vm.stopPrank();

        vm.prank(ACCOUNT);
        registry.approveEnrollment(strategyA, 1);
        vm.prank(OPERATOR);
        registry.enroll(ACCOUNT, strategyA, 1);
    }

    function _publish(uint256 id, address asset) internal {
        // Assets must be contracts since cre8-contracts#47; any code will do here.
        vm.etch(asset, hex"00");
        address[] memory assets = new address[](1);
        assets[0] = asset;
        uint16[] memory weights = new uint16[](1);
        weights[0] = 10_000;
        vm.warp(block.timestamp + 7 days);
        registry.publishVersion(id, assets, weights, keccak256("schedule"), 0);
        vm.warp(block.timestamp + 1 days);
    }

    function _pause(address by, bool paused) internal {
        vm.prank(by);
        registry.setPaused(ACCOUNT, paused);
    }

    function _assertPause(uint8 flags, string memory label) internal view {
        assertEq(registry.pauseFlags(ACCOUNT), flags, label);
        assertEq(
            registry.enrollments(ACCOUNT).paused, flags != 0, string.concat(label, " (paused mirrors flags)")
        );
    }

    // ---- enroll: operator only for the first enrollment ----

    function test_operator_firstEnrollment() public view {
        AtpRegistry.Enrollment memory e = registry.enrollments(ACCOUNT);
        assertEq(e.strategyId, strategyA);
        assertEq(e.version, 1);
        assertTrue(registry.isEnrolled(ACCOUNT));
    }

    function test_operator_cannotMoveAnEnrolledAccountToAnotherStrategy() public {
        vm.prank(OPERATOR);
        vm.expectRevert(abi.encodeWithSelector(AtpRegistry.AlreadyEnrolled.selector, ACCOUNT));
        registry.enroll(ACCOUNT, strategyB, 1);
        assertEq(registry.enrollments(ACCOUNT).strategyId, strategyA, "strategy unchanged");
    }

    function test_operator_cannotMoveAnEnrolledAccountToANewVersion() public {
        vm.prank(PROVIDER);
        _publish(strategyA, address(0xAAA2));

        vm.prank(OPERATOR);
        vm.expectRevert(abi.encodeWithSelector(AtpRegistry.AlreadyEnrolled.selector, ACCOUNT));
        registry.enroll(ACCOUNT, strategyA, 1);
        assertEq(registry.enrollments(ACCOUNT).version, 1, "version unchanged");
    }

    function test_operator_reEnrollCannotClearAPause() public {
        _pause(SAFE, true);
        vm.prank(OPERATOR);
        vm.expectRevert(abi.encodeWithSelector(AtpRegistry.AlreadyEnrolled.selector, ACCOUNT));
        registry.enroll(ACCOUNT, strategyA, 1);
        _assertPause(BY_OWNER, "still paused by the Safe");
    }

    function test_account_canMoveItselfToAnotherStrategyAndVersion() public {
        vm.prank(ACCOUNT);
        registry.enroll(ACCOUNT, strategyB, 1);
        assertEq(registry.enrollments(ACCOUNT).strategyId, strategyB, "moved strategy");

        vm.prank(PROVIDER);
        _publish(strategyB, address(0xBBB2));
        vm.prank(ACCOUNT);
        registry.enroll(ACCOUNT, strategyB, 2);
        assertEq(registry.enrollments(ACCOUNT).version, 2, "moved version");
    }

    function test_account_reEnrollClearsEveryPause() public {
        _pause(SAFE, true);
        _pause(OPERATOR, true);
        _pause(ACCOUNT, true);
        _assertPause(BY_OWNER | BY_OPERATOR | BY_ACCOUNT, "three sources");

        vm.expectEmit(true, false, false, true, address(registry));
        emit AtpRegistry.PauseFlagsSet(ACCOUNT, 0);
        vm.prank(ACCOUNT);
        registry.enroll(ACCOUNT, strategyA, 1);
        _assertPause(0, "cleared by the account's own enrollment");
    }

    function test_owner_andOutsider_stillCannotEnroll() public {
        vm.prank(SAFE);
        vm.expectRevert(AtpRegistry.Unauthorized.selector);
        registry.enroll(OTHER_ACCOUNT, strategyA, 1);

        vm.prank(OUTSIDER);
        vm.expectRevert(AtpRegistry.Unauthorized.selector);
        registry.enroll(OTHER_ACCOUNT, strategyA, 1);
    }

    // ---- pause sources ----

    function test_operator_liftsOnlyItsOwnPause() public {
        _pause(OPERATOR, true);
        _assertPause(BY_OPERATOR, "operator paused");
        _pause(OPERATOR, false);
        _assertPause(0, "operator lifted its own pause");
    }

    function test_operator_cannotLiftTheSafesPause() public {
        _pause(SAFE, true);
        _pause(OPERATOR, false);
        _assertPause(BY_OWNER, "Safe's pause survives the operator");
    }

    function test_operator_cannotLiftTheAccountsPause() public {
        _pause(ACCOUNT, true);
        _pause(OPERATOR, false);
        _assertPause(BY_ACCOUNT, "account's pause survives the operator");
    }

    function test_operator_liftingItsOwnBitLeavesTheSafesInPlace() public {
        _pause(SAFE, true);
        _pause(OPERATOR, true);
        _pause(OPERATOR, false);
        _assertPause(BY_OWNER, "only the operator bit cleared");
    }

    function test_safe_liftsItsOwnAndTheOperatorsPause() public {
        _pause(SAFE, true);
        _pause(OPERATOR, true);
        _pause(SAFE, false);
        _assertPause(0, "Safe outranks the operator");
    }

    function test_safe_cannotLiftTheAccountsPause() public {
        _pause(ACCOUNT, true);
        _pause(SAFE, true);
        _pause(SAFE, false);
        _assertPause(BY_ACCOUNT, "account's own pause survives the Safe");
    }

    function test_account_canPauseAndLiftEverything() public {
        _pause(ACCOUNT, true);
        _assertPause(BY_ACCOUNT, "self pause");
        _pause(SAFE, true);
        _pause(OPERATOR, true);

        vm.expectEmit(true, false, false, true, address(registry));
        emit AtpRegistry.EnrollmentPausedSet(ACCOUNT, false);
        _pause(ACCOUNT, false);
        _assertPause(0, "account lifted every source");
    }

    function test_revokedOperator_cannotTouchItsOldPause_safeCan() public {
        _pause(OPERATOR, true);
        vm.prank(SAFE);
        registry.setOperator(address(0));

        vm.prank(OPERATOR);
        vm.expectRevert(AtpRegistry.Unauthorized.selector);
        registry.setPaused(ACCOUNT, false);
        _assertPause(BY_OPERATOR, "revoked operator lost access");

        _pause(SAFE, false);
        _assertPause(0, "Safe cleared the old operator's pause");
    }

    function test_setPaused_rejectsOutsidersAndUnenrolledAccounts() public {
        vm.prank(OUTSIDER);
        vm.expectRevert(AtpRegistry.Unauthorized.selector);
        registry.setPaused(ACCOUNT, true);

        vm.prank(SAFE);
        vm.expectRevert(AtpRegistry.Unauthorized.selector);
        registry.setPaused(OTHER_ACCOUNT, true);

        vm.prank(OTHER_ACCOUNT);
        vm.expectRevert(AtpRegistry.Unauthorized.selector);
        registry.setPaused(OTHER_ACCOUNT, true);
    }

    /// @dev Whatever order the three sources act in, the mirrored `paused` field never disagrees with the
    /// flags, and the operator alone can never turn a paused account into a running one unless it was the
    /// only source.
    function testFuzz_pausedAlwaysMirrorsFlags(uint8[12] calldata actions) public {
        address[3] memory callers = [SAFE, OPERATOR, ACCOUNT];
        for (uint256 i; i < actions.length; ++i) {
            address by = callers[actions[i] % 3];
            bool paused = (actions[i] / 3) % 2 == 0;
            uint8 before = registry.pauseFlags(ACCOUNT);
            _pause(by, paused);
            uint8 afterFlags = registry.pauseFlags(ACCOUNT);
            assertEq(registry.enrollments(ACCOUNT).paused, afterFlags != 0, "mirror");
            if (by == OPERATOR) {
                assertEq(
                    afterFlags & ~BY_OPERATOR, before & ~BY_OPERATOR, "operator touches only its own bit"
                );
            }
            if (by == SAFE) {
                assertEq(afterFlags & BY_ACCOUNT, before & BY_ACCOUNT, "Safe never touches the account bit");
            }
        }
    }
}
