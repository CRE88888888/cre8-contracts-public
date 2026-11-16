// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";
import { AtpRegistry } from "../../src/atp/AtpRegistry.sol";

/// @dev Seed only the history length to reach the uint16 boundary without 65,534 weekly publications.
contract RegistryVersionBoundaryHarness is AtpRegistry {
    function seedHistoryLength(uint256 strategy, uint256 length) external {
        Version[] storage history = _versions[strategy];
        assembly { sstore(history.slot, length) }
    }
}

contract AtpVersionLifecycleTest is Test {
    AtpRegistry internal registry;
    uint256 internal id;
    address internal constant ASSET = address(0xA11);

    function setUp() public {
        registry = new AtpRegistry();
        vm.etch(ASSET, hex"00");
        id = registry.registerStrategy("P11", "version lifecycle", true);
    }

    function test_firstPublicationCannotExecuteBefore24Hours() public {
        address[] memory assets = new address[](1);
        assets[0] = ASSET;
        uint16[] memory weights = new uint16[](1);
        weights[0] = 10_000;
        registry.publishVersion(id, assets, weights, bytes32(0), 0);
        assertEq(registry.activeVersion(id), 0, "a publication must wait 24 hours");
        assertFalse(registry.isAssetAllowed(id, 1, ASSET), "future version is not executable");
    }

    function _publish(uint16 fee, uint64 at) internal returns (uint16) {
        address[] memory assets = new address[](1);
        assets[0] = ASSET;
        uint16[] memory weights = new uint16[](1);
        weights[0] = 10_000;
        return registry.publishSettingsVersion(
            id, assets, weights, keccak256("schedule"), keccak256("rules"), fee, at
        );
    }

    function _first() internal {
        _publish(1_000, 0);
        vm.warp(vm.getBlockTimestamp() + 1 days);
    }

    function test_activationAtExactBoundary_andConfigHash() public {
        uint256 t = vm.getBlockTimestamp();
        _publish(1_000, uint64(t + 1 days));
        AtpRegistry.Version memory v = registry.version(id, 1);
        assertEq(
            v.configHash,
            keccak256(abi.encode(v.assets, v.weightsBps, v.scheduleHash, v.settingsHash, v.performanceFeeBps))
        );
        vm.warp(t + 1 days - 1);
        assertEq(registry.pendingVersion(id), 1);
        assertEq(registry.activeVersion(id), 0);
        vm.warp(t + 1 days);
        assertEq(registry.pendingVersion(id), 0);
        assertEq(registry.activeVersion(id), 1);
        assertTrue(registry.isAssetAllowed(id, 0, ASSET));
    }

    function test_ownerCannotShortenNotice_andZeroMeansEarliest() public {
        vm.expectRevert(
            abi.encodeWithSelector(AtpRegistry.ActivationTooSoon.selector, vm.getBlockTimestamp() + 1 days)
        );
        _publish(1_000, uint64(vm.getBlockTimestamp() + 1 days - 1));
        _publish(1_000, 0);
        assertEq(registry.version(id, 1).activeAt, vm.getBlockTimestamp() + 1 days);
    }

    function test_pendingCannotBeReplaced_evenAfter7Days() public {
        _publish(1_000, uint64(vm.getBlockTimestamp() + 30 days));
        vm.warp(vm.getBlockTimestamp() + 7 days);
        vm.expectRevert(abi.encodeWithSelector(AtpRegistry.PendingVersionExists.selector, id));
        _publish(900, 0);
    }

    function test_cancelPreservesHistoryAndPublicationClock() public {
        uint256 t = vm.getBlockTimestamp();
        _publish(1_000, 0);
        registry.cancelVersion(id);
        assertTrue(registry.cancelledVersion(id, 1));
        assertEq(registry.versionCount(id), 1);
        vm.warp(t + 7 days - 1);
        vm.expectRevert(abi.encodeWithSelector(AtpRegistry.PublicationTooSoon.selector, t + 7 days));
        _publish(900, 0);
        vm.warp(t + 7 days);
        assertEq(_publish(900, 0), 2);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        assertFalse(registry.isAssetAllowed(id, 1, ASSET));
        assertTrue(registry.isAssetAllowed(id, 2, ASSET));
        assertEq(registry.historicalAssets(id).length, 1);
    }

    function test_cancelOnlyBeforeBoundary_andAuthorized() public {
        _publish(1_000, 0);
        vm.prank(address(0xBAD));
        vm.expectRevert(abi.encodeWithSelector(AtpRegistry.NotStrategyProvider.selector, id));
        registry.cancelVersion(id);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.expectRevert(abi.encodeWithSelector(AtpRegistry.NoPendingVersion.selector, id));
        registry.cancelVersion(id);
    }

    function test_publicationIntervalExactBoundary_evenFeeDecrease() public {
        uint256 t = vm.getBlockTimestamp();
        _first();
        vm.warp(t + 7 days - 1);
        vm.expectRevert(abi.encodeWithSelector(AtpRegistry.PublicationTooSoon.selector, t + 7 days));
        _publish(900, 0);
        vm.warp(t + 7 days);
        _publish(900, 0);
        assertEq(registry.activeVersion(id), 2);
        assertEq(registry.version(id, 2).activeAt, vm.getBlockTimestamp());
    }

    function test_feeIncreaseAndUnchangedFeeWait24Hours() public {
        _first();
        vm.warp(vm.getBlockTimestamp() + 6 days);
        _publish(1_001, 0);
        assertEq(registry.activeVersion(id), 1);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        _publish(1_001, 0);
        assertEq(registry.activeVersion(id), 2);
        assertEq(registry.pendingVersion(id), 3);
    }

    function test_feeDecreaseWithChangedRulesIsDelayed() public {
        _first();
        vm.warp(vm.getBlockTimestamp() + 6 days);
        address[] memory assets = new address[](1);
        assets[0] = ASSET;
        uint16[] memory weights = new uint16[](1);
        weights[0] = 10_000;
        registry.publishSettingsVersion(
            id, assets, weights, keccak256("schedule"), keccak256("changed rules"), 900, 0
        );
        assertEq(registry.activeVersion(id), 1);
        assertEq(registry.pendingVersion(id), 2);
    }

    function test_feeBounds() public {
        vm.expectRevert(abi.encodeWithSelector(AtpRegistry.PerformanceFeeOutOfRange.selector, uint16(0)));
        _publish(0, 0);
        vm.expectRevert(abi.encodeWithSelector(AtpRegistry.PerformanceFeeOutOfRange.selector, uint16(499)));
        _publish(499, 0);
        vm.expectRevert(abi.encodeWithSelector(AtpRegistry.PerformanceFeeOutOfRange.selector, uint16(2_001)));
        _publish(2_001, 0);
        _publish(2_000, 0);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        _publish(500, 0);
        assertEq(registry.activeVersion(id), 2);
    }

    function test_L2_providerFrontRunsEnrollment_futureVersionCannotExecute() public {
        _first();
        vm.warp(vm.getBlockTimestamp() + 6 days);
        address replacement = address(0xB11);
        vm.etch(replacement, hex"00");
        address[] memory assets = new address[](1);
        assets[0] = replacement;
        uint16[] memory weights = new uint16[](1);
        weights[0] = 10_000;
        registry.publishSettingsVersion(
            id,
            assets,
            weights,
            keccak256("schedule"),
            keccak256("rules"),
            1_100,
            uint64(vm.getBlockTimestamp() + 365 days)
        );
        assertEq(registry.activeVersion(id), 1, "front-run publication cannot become effective early");
        registry.enroll(address(this), id, 1);
        assertEq(registry.enrollments(address(this)).version, 1);
        assertFalse(registry.isAssetAllowed(id, 2, replacement));
        assertFalse(registry.isAssetAllowed(id, 0, replacement));
        vm.warp(vm.getBlockTimestamp() + 365 days);
        vm.expectRevert(abi.encodeWithSelector(AtpRegistry.UnexpectedVersion.selector, uint16(1), uint16(2)));
        registry.enroll(address(this), id, 1);
        assertEq(registry.enrollments(address(this)).version, 1);
    }

    function test_zeroVersionAndEnrollmentBeforeActivationRejected() public {
        _publish(1_000, 0);
        vm.expectRevert(abi.encodeWithSelector(AtpRegistry.VersionNotPublished.selector, id));
        registry.enroll(address(this), id, 1);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.expectRevert(abi.encodeWithSelector(AtpRegistry.UnexpectedVersion.selector, uint16(0), uint16(1)));
        registry.enroll(address(this), id, 0);
    }

    function test_operatorNeedsExactOneUseAccountConsent_andCannotClearPause() public {
        _first();
        address operator = address(0x0FE7);
        address account = address(0xACC);
        registry.setOperator(operator);
        vm.prank(operator);
        vm.expectRevert(AtpRegistry.ConsentRequired.selector);
        registry.enroll(account, id, 1);
        vm.prank(account);
        registry.approveEnrollment(id, 1);
        vm.prank(operator);
        registry.enroll(account, id, 1);
        assertEq(registry.enrollmentApproval(account), bytes32(0));
        registry.setPaused(account, true);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(AtpRegistry.AlreadyEnrolled.selector, account));
        registry.enroll(account, id, 1);
        assertTrue(registry.enrollments(account).paused);
    }

    function test_accountCanRevokeConsent_andApprovalDoesNotSurviveVersionChange() public {
        _first();
        address operator = address(0x0FE7);
        address account = address(0xACC);
        registry.setOperator(operator);
        vm.startPrank(account);
        registry.approveEnrollment(id, 1);
        registry.revokeEnrollmentApproval();
        vm.stopPrank();
        vm.prank(operator);
        vm.expectRevert(AtpRegistry.ConsentRequired.selector);
        registry.enroll(account, id, 1);
        vm.prank(account);
        registry.approveEnrollment(id, 1);
        vm.warp(vm.getBlockTimestamp() + 6 days);
        _publish(900, 0);
        vm.prank(operator);
        vm.expectRevert(AtpRegistry.ConsentRequired.selector);
        registry.enroll(account, id, 2);
    }

    function testFuzz_nonFeeSettingsChangeCannotUseImmediateDecrease(bytes32 rules) public {
        vm.assume(rules != keccak256("rules"));
        _first();
        vm.warp(vm.getBlockTimestamp() + 6 days);
        address[] memory assets = new address[](1);
        assets[0] = ASSET;
        uint16[] memory weights = new uint16[](1);
        weights[0] = 10_000;
        vm.expectRevert(
            abi.encodeWithSelector(AtpRegistry.ActivationTooSoon.selector, vm.getBlockTimestamp() + 1 days)
        );
        registry.publishSettingsVersion(
            id, assets, weights, keccak256("schedule"), rules, 900, uint64(vm.getBlockTimestamp())
        );
    }

    function test_versionIndexUpperBoundCannotWrapToZero() public {
        RegistryVersionBoundaryHarness boundary = new RegistryVersionBoundaryHarness();
        uint256 strategy = boundary.registerStrategy("boundary", "uint16 version index", true);
        boundary.seedHistoryLength(strategy, type(uint16).max);
        vm.warp(10 days);
        address[] memory assets = new address[](1);
        assets[0] = ASSET;
        uint16[] memory weights = new uint16[](1);
        weights[0] = 10_000;
        assertEq(boundary.publishVersion(strategy, assets, weights, bytes32(0), 0), type(uint16).max);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        assertEq(boundary.activeVersion(strategy), type(uint16).max);
        vm.expectRevert(AtpRegistry.VersionLimit.selector);
        boundary.publishVersion(strategy, assets, weights, bytes32(0), 0);
        assertEq(boundary.versionCount(strategy), type(uint16).max);
        assertTrue(boundary.isAssetAllowed(strategy, 0, ASSET));
    }

    function test_activationTimestampUpperBoundCannotOverflow() public {
        uint256 maximum = type(uint64).max;
        _publish(1_000, uint64(maximum));
        vm.warp(maximum - 1);
        assertEq(registry.activeVersion(id), 0);
        vm.warp(maximum);
        assertEq(registry.activeVersion(id), 1);
        vm.expectRevert(abi.encodeWithSelector(AtpRegistry.ActivationTooSoon.selector, maximum + 1 days));
        _publish(1_001, 0);
        assertEq(registry.versionCount(id), 1);
    }
}
