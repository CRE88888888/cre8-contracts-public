// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";
import { AtpRegistry } from "../../src/atp/AtpRegistry.sol";

/// @notice Pins the v2 roles of `AtpRegistry`: ownership moves only in two steps, the owner sets and revokes
/// the operator, and the operator (the backend relayer) can enroll and pause accounts but nothing else.
contract AtpRegistryRolesTest is Test {
    address internal constant SAFE = address(0x5AFE);
    address internal constant OPERATOR = address(0x0FE7);
    address internal constant PROVIDER = address(0xBEEF);
    address internal constant ACCOUNT = address(0xACC7);
    address internal constant OUTSIDER = address(0xCAFE);

    AtpRegistry internal registry;
    uint256 internal strategyId;

    function setUp() public {
        registry = new AtpRegistry();
        vm.startPrank(PROVIDER);
        strategyId = registry.registerStrategy("bsc-index", "stock index v1", true);
        address[] memory assets = new address[](1);
        assets[0] = address(0xAAA1);
        uint16[] memory weights = new uint16[](1);
        weights[0] = 10_000;
        registry.publishVersion(strategyId, assets, weights, keccak256("schedule"), 0);
        vm.stopPrank();
    }

    // ---- two-step ownership ----

    function test_transferOwnership_onlyProposes() public {
        vm.expectEmit(true, true, false, false, address(registry));
        emit AtpRegistry.OwnershipTransferStarted(address(this), SAFE);
        registry.transferOwnership(SAFE);

        assertEq(registry.owner(), address(this), "owner unchanged until accepted");
        assertEq(registry.pendingOwner(), SAFE, "pending owner recorded");

        // The proposed owner has no power yet.
        vm.prank(SAFE);
        vm.expectRevert(AtpRegistry.NotOwner.selector);
        registry.setDefaultFeeBps(1);
    }

    function test_acceptOwnership_movesTheRole() public {
        registry.transferOwnership(SAFE);

        vm.expectEmit(true, true, false, false, address(registry));
        emit AtpRegistry.OwnershipTransferred(address(this), SAFE);
        vm.prank(SAFE);
        registry.acceptOwnership();

        assertEq(registry.owner(), SAFE, "new owner");
        assertEq(registry.pendingOwner(), address(0), "pending cleared");

        vm.expectRevert(AtpRegistry.NotOwner.selector);
        registry.setDefaultFeeBps(1);
        vm.prank(SAFE);
        registry.setDefaultFeeBps(1);
        assertEq(registry.defaultSwapFeeBps(), 1, "new owner administers");
    }

    function test_acceptOwnership_revertsForAnyoneButThePendingOwner() public {
        registry.transferOwnership(SAFE);

        vm.prank(OUTSIDER);
        vm.expectRevert(AtpRegistry.NotPendingOwner.selector);
        registry.acceptOwnership();

        // Not even the current owner can short-circuit the handover.
        vm.expectRevert(AtpRegistry.NotPendingOwner.selector);
        registry.acceptOwnership();
    }

    function test_transferOwnership_toZeroCancels() public {
        registry.transferOwnership(SAFE);
        registry.transferOwnership(address(0));

        vm.prank(SAFE);
        vm.expectRevert(AtpRegistry.NotPendingOwner.selector);
        registry.acceptOwnership();
        assertEq(registry.owner(), address(this), "owner unchanged");
    }

    function test_transferOwnership_revertsForNonOwner() public {
        vm.prank(OUTSIDER);
        vm.expectRevert(AtpRegistry.NotOwner.selector);
        registry.transferOwnership(OUTSIDER);
    }

    // ---- operator ----

    function test_setOperator_onlyOwner() public {
        vm.prank(OUTSIDER);
        vm.expectRevert(AtpRegistry.NotOwner.selector);
        registry.setOperator(OUTSIDER);

        vm.expectEmit(true, true, false, false, address(registry));
        emit AtpRegistry.OperatorUpdated(address(0), OPERATOR);
        registry.setOperator(OPERATOR);
        assertEq(registry.operator(), OPERATOR);
    }

    function test_operator_canEnrollAnAccount() public {
        registry.setOperator(OPERATOR);

        vm.prank(OPERATOR);
        registry.enroll(ACCOUNT, strategyId);

        assertTrue(registry.isEnrolled(ACCOUNT), "enrolled");
        AtpRegistry.Enrollment memory enrollment = registry.enrollments(ACCOUNT);
        assertEq(enrollment.strategyId, strategyId);
        assertEq(enrollment.version, 1);
        assertFalse(enrollment.paused);
    }

    function test_account_canEnrollItself() public {
        vm.prank(ACCOUNT);
        registry.enroll(ACCOUNT, strategyId);
        assertTrue(registry.isEnrolled(ACCOUNT));
    }

    /// @dev v1 let the owner enroll anyone; in v2 the owner is a Safe and that branch is gone.
    function test_owner_cannotEnroll() public {
        registry.setOperator(OPERATOR);
        vm.expectRevert(AtpRegistry.Unauthorized.selector);
        registry.enroll(ACCOUNT, strategyId);
    }

    function test_outsider_cannotEnroll() public {
        registry.setOperator(OPERATOR);
        vm.prank(OUTSIDER);
        vm.expectRevert(AtpRegistry.Unauthorized.selector);
        registry.enroll(ACCOUNT, strategyId);
    }

    /// @dev With no operator set, nobody but the account itself can enroll it.
    function test_enroll_withoutOperator_onlyTheAccount() public {
        vm.prank(OPERATOR);
        vm.expectRevert(AtpRegistry.Unauthorized.selector);
        registry.enroll(ACCOUNT, strategyId);
    }

    function test_revokedOperator_cannotEnroll() public {
        registry.setOperator(OPERATOR);
        registry.setOperator(address(0));

        vm.prank(OPERATOR);
        vm.expectRevert(AtpRegistry.Unauthorized.selector);
        registry.enroll(ACCOUNT, strategyId);
    }

    function test_setPaused_byOperatorOrOwner() public {
        registry.setOperator(OPERATOR);
        vm.prank(OPERATOR);
        registry.enroll(ACCOUNT, strategyId);

        vm.prank(OPERATOR);
        registry.setPaused(ACCOUNT, true);
        assertTrue(registry.enrollments(ACCOUNT).paused, "operator paused");

        registry.setPaused(ACCOUNT, false);
        assertFalse(registry.enrollments(ACCOUNT).paused, "owner resumed");

        vm.prank(OUTSIDER);
        vm.expectRevert(AtpRegistry.Unauthorized.selector);
        registry.setPaused(ACCOUNT, true);
    }

    /// @dev The relayer key must not reach any admin power beyond enroll / pause.
    function test_operator_hasNoAdminPowers() public {
        registry.setOperator(OPERATOR);
        vm.startPrank(OPERATOR);

        vm.expectRevert(AtpRegistry.NotOwner.selector);
        registry.setDefaultFeeBps(1);
        vm.expectRevert(AtpRegistry.NotOwner.selector);
        registry.setStrategyFeeBps(strategyId, 1);
        vm.expectRevert(AtpRegistry.NotOwner.selector);
        registry.setOperator(OUTSIDER);
        vm.expectRevert(AtpRegistry.NotOwner.selector);
        registry.transferOwnership(OUTSIDER);

        address[] memory assets = new address[](1);
        assets[0] = address(0xAAA2);
        uint16[] memory weights = new uint16[](1);
        weights[0] = 10_000;
        vm.expectRevert(abi.encodeWithSelector(AtpRegistry.NotStrategyProvider.selector, strategyId));
        registry.publishVersion(strategyId, assets, weights, keccak256("schedule"), 0);

        vm.stopPrank();
    }
}
