// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";
import { AtpRegistry } from "../../src/atp/AtpRegistry.sol";

/// @notice Pins `AtpRegistry.publishVersion` validation: the weight sum, duplicate assets and the array-length
/// match and the 128-asset historical union bound gate the asset allowlist the executor trusts.
contract AtpRegistryTest is Test {
    address internal constant PROVIDER = address(0xBEEF);
    address internal constant OUTSIDER = address(0xCAFE);
    address internal constant ASSET_A = address(0xAAA1);
    address internal constant ASSET_B = address(0xAAA2);
    address internal constant ASSET_C = address(0xAAA3);

    AtpRegistry internal registry;
    uint256 internal strategyId;

    function setUp() public {
        registry = new AtpRegistry();
        // Assets must be contracts since cre8-contracts#47; any code will do for these allowlist tests.
        vm.etch(ASSET_A, hex"00");
        vm.etch(ASSET_B, hex"00");
        vm.etch(ASSET_C, hex"00");
        vm.prank(PROVIDER);
        strategyId = registry.registerStrategy("bsc-index", "stock index v1", true);
    }

    // ---- fixtures ----

    function _assets(uint256 count) internal returns (address[] memory assets) {
        assets = new address[](count);
        for (uint256 i; i < count; ++i) {
            assets[i] = address(uint160(0x1000 + i));
            vm.etch(assets[i], hex"00");
        }
    }

    function _weights(uint256 count, uint16 weight) internal pure returns (uint16[] memory weights) {
        weights = new uint16[](count);
        for (uint256 i; i < count; ++i) {
            weights[i] = weight;
        }
    }

    function _publish(address[] memory assets, uint16[] memory weights) internal {
        vm.prank(PROVIDER);
        vm.warp(block.timestamp + 7 days);
        registry.publishVersion(strategyId, assets, weights, keccak256("schedule"), 0);
        vm.warp(block.timestamp + 1 days);
    }

    // ---- happy path ----

    function test_publishVersion_recordsVersionAndAllowlist() public {
        address[] memory assets = new address[](2);
        assets[0] = ASSET_A;
        assets[1] = ASSET_B;
        uint16[] memory weights = new uint16[](2);
        weights[0] = 6_000;
        weights[1] = 4_000;

        _publish(assets, weights);

        assertEq(registry.activeVersion(strategyId), 1);
        assertEq(registry.versionCount(strategyId), 1);
        assertTrue(registry.isAssetAllowed(strategyId, 0, ASSET_A));
        assertTrue(registry.isAssetAllowed(strategyId, 0, ASSET_B));
        assertFalse(registry.isAssetAllowed(strategyId, 0, ASSET_C));

        // Explicit pin behaves the same for the version it names.
        assertTrue(registry.isAssetAllowed(strategyId, 1, ASSET_A));
        assertFalse(registry.isAssetAllowed(strategyId, 1, ASSET_C));
    }

    function test_publishVersion_isAppendOnlyAndKeepsOldAllowlist() public {
        address[] memory first = new address[](1);
        first[0] = ASSET_A;
        _publish(first, _weights(1, 10_000));

        address[] memory second = new address[](1);
        second[0] = ASSET_B;
        _publish(second, _weights(1, 10_000));

        assertEq(registry.activeVersion(strategyId), 2);
        assertEq(registry.versionCount(strategyId), 2);
        // The old version still answers for its own assets; a stray asset is never allowed.
        assertTrue(registry.isAssetAllowed(strategyId, 1, ASSET_A));
        assertFalse(registry.isAssetAllowed(strategyId, 1, ASSET_B));
        assertFalse(registry.isAssetAllowed(strategyId, 2, ASSET_A));
        assertTrue(registry.isAssetAllowed(strategyId, 2, ASSET_B));
    }

    function test_publishVersion_acceptsSixteenAssets() public {
        address[] memory assets = _assets(16);
        _publish(assets, _weights(assets.length, 625));

        assertEq(registry.versionCount(strategyId), 1);
        assertTrue(registry.isAssetAllowed(strategyId, 0, assets[15]));
    }

    /// @dev 17 was the first count the former 16-asset ceiling rejected (cre8-contracts#45).
    function test_publishVersion_acceptsSeventeenAssets() public {
        address[] memory assets = _assets(17);
        uint16[] memory weights = _weights(17, 588);
        weights[0] = 10_000 - 588 * 16;
        _publish(assets, weights);

        assertEq(registry.version(strategyId, 0).assets.length, 17);
        assertTrue(registry.isAssetAllowed(strategyId, 0, assets[16]));
    }

    /// @dev USDT + all 92 testnet assets, the largest version the testnet can hold today.
    function test_publishVersion_acceptsNinetyThreeAssets() public {
        address[] memory assets = _assets(93);
        uint16[] memory weights = _weights(93, 107);
        weights[0] = 10_000 - 107 * 92;
        _publish(assets, weights);

        AtpRegistry.Version memory published = registry.version(strategyId, 0);
        assertEq(published.assets.length, 93);
        assertEq(published.weightsBps.length, 93);
        assertEq(published.weightsBps[0], 156);
        assertEq(published.assets[92], assets[92]);
        assertTrue(registry.isAssetAllowed(strategyId, 0, assets[0]));
        assertTrue(registry.isAssetAllowed(strategyId, 0, assets[92]));
        assertFalse(registry.isAssetAllowed(strategyId, 0, address(uint160(0x1000 + 93))));
    }

    /// @dev Preserve the former 500-asset fixture: P11 now rejects it to bound historical valuation gas.
    function test_publishVersion_rejectsFiveHundredAssets() public {
        address[] memory assets = _assets(500);
        vm.expectRevert(abi.encodeWithSelector(AtpRegistry.StrategyAssetLimitExceeded.selector, uint256(500)));
        _publish(assets, _weights(500, 20));

        assertEq(registry.versionCount(strategyId), 0);
        assertFalse(registry.isAssetAllowed(strategyId, 0, assets[499]));
    }

    function test_publishVersion_largeVersionStillRejectsWeightMiss() public {
        vm.expectRevert(abi.encodeWithSelector(AtpRegistry.WeightsMismatch.selector, uint256(9_951)));
        _publish(_assets(93), _weights(93, 107));
    }

    function test_publishVersion_largeVersionStillRejectsDuplicateAtTheEnd() public {
        address[] memory assets = _assets(93);
        assets[92] = assets[0];
        uint16[] memory weights = _weights(93, 107);
        weights[0] = 10_000 - 107 * 92;

        vm.expectRevert(abi.encodeWithSelector(AtpRegistry.DuplicateAsset.selector, assets[0]));
        _publish(assets, weights);
    }

    // ---- weight validation ----

    function test_publishVersion_revertsWhenWeightsMissTenThousand() public {
        uint16[] memory weights = new uint16[](2);
        weights[0] = 5_000;
        weights[1] = 4_999;

        vm.expectRevert(abi.encodeWithSelector(AtpRegistry.WeightsMismatch.selector, uint256(9_999)));
        _publish(_twoAssets(), weights);
    }

    function test_publishVersion_revertsWhenWeightsExceedTenThousand() public {
        uint16[] memory weights = new uint16[](2);
        weights[0] = 6_000;
        weights[1] = 4_001;

        vm.expectRevert(abi.encodeWithSelector(AtpRegistry.WeightsMismatch.selector, uint256(10_001)));
        _publish(_twoAssets(), weights);
    }

    function test_publishVersion_revertsWhenEqualWeightsMissTenThousand() public {
        vm.expectRevert(abi.encodeWithSelector(AtpRegistry.WeightsMismatch.selector, uint256(9_998)));
        _publish(_twoAssets(), _weights(2, 4_999));
    }

    // ---- duplicate / length ----

    function test_publishVersion_revertsOnDuplicateAsset() public {
        address[] memory assets = new address[](2);
        assets[0] = ASSET_A;
        assets[1] = ASSET_A;

        vm.expectRevert(abi.encodeWithSelector(AtpRegistry.DuplicateAsset.selector, ASSET_A));
        _publish(assets, _weights(2, 5_000));
    }

    function test_publishVersion_revertsOnDuplicateAssetBeyondFirstSlot() public {
        address[] memory assets = new address[](3);
        assets[0] = ASSET_A;
        assets[1] = ASSET_B;
        assets[2] = ASSET_B;
        uint16[] memory weights = new uint16[](3);
        weights[0] = 3_000;
        weights[1] = 3_000;
        weights[2] = 4_000;

        vm.expectRevert(abi.encodeWithSelector(AtpRegistry.DuplicateAsset.selector, ASSET_B));
        _publish(assets, weights);
    }

    function test_publishVersion_revertsOnLengthMismatch() public {
        vm.expectRevert(AtpRegistry.LengthMismatch.selector);
        _publish(_twoAssets(), _weights(3, 3_333));
    }

    function test_publishVersion_revertsOnEmptyAssets() public {
        vm.expectRevert(AtpRegistry.EmptyAssets.selector);
        _publish(new address[](0), new uint16[](0));
    }

    // ---- assets must be contracts, weight 0 only for the numeraire (cre8-contracts#47 #4) ----

    /// @dev Before #47 a version could name an EOA, and every buy of that version then reverted in the
    /// executor's valuation (`balanceOf` on an address without code).
    function test_publishVersion_revertsOnAssetWithoutCode() public {
        address eoa = address(0xE0A);
        address[] memory assets = _twoAssets();
        assets[1] = eoa;
        vm.expectRevert(abi.encodeWithSelector(AtpRegistry.NotContract.selector, eoa));
        _publish(assets, _weights(2, 5_000));
    }

    /// @dev Weight 0 is how the backend lists USDT (the numeraire) without a target share; any other asset at
    /// weight 0 is rejected, so a version cannot be padded with free entries that only cost valuation gas.
    function test_publishVersion_weightZero_onlyForTheNumeraire() public {
        registry.setNumeraire(ASSET_A);
        uint16[] memory weights = new uint16[](3);
        weights[0] = 0;
        weights[1] = 10_000;
        weights[2] = 0;
        address[] memory assets = new address[](3);
        assets[0] = ASSET_A;
        assets[1] = ASSET_B;
        assets[2] = ASSET_C;
        vm.expectRevert(abi.encodeWithSelector(AtpRegistry.ZeroWeight.selector, ASSET_C));
        _publish(assets, weights);

        weights[1] = 5_000;
        weights[2] = 5_000;
        _publish(assets, weights); // USDT at 0 is fine
        assertEq(registry.version(strategyId, 0).weightsBps[0], 0);
    }

    /// @dev Until the owner names the numeraire, weight 0 is rejected for every asset (fail closed).
    function test_publishVersion_weightZero_rejectedWhileNoNumeraire() public {
        assertEq(registry.numeraire(), address(0));
        uint16[] memory weights = new uint16[](2);
        weights[1] = 10_000;
        vm.expectRevert(abi.encodeWithSelector(AtpRegistry.ZeroWeight.selector, ASSET_A));
        _publish(_twoAssets(), weights);
    }

    function test_setNumeraire_ownerOnly_contractOnly_once() public {
        vm.prank(OUTSIDER);
        vm.expectRevert(AtpRegistry.NotOwner.selector);
        registry.setNumeraire(ASSET_A);

        vm.expectRevert(abi.encodeWithSelector(AtpRegistry.NotContract.selector, address(0xE0A)));
        registry.setNumeraire(address(0xE0A));

        vm.expectEmit(true, false, false, false, address(registry));
        emit AtpRegistry.NumeraireSet(ASSET_A);
        registry.setNumeraire(ASSET_A);
        assertEq(registry.numeraire(), ASSET_A);

        vm.expectRevert(AtpRegistry.NumeraireAlreadySet.selector);
        registry.setNumeraire(ASSET_B);
    }

    // ---- authorisation ----

    function test_publishVersion_revertsForNonProvider() public {
        vm.prank(OUTSIDER);
        vm.expectRevert(abi.encodeWithSelector(AtpRegistry.NotStrategyProvider.selector, strategyId));
        vm.warp(block.timestamp + 7 days);
        registry.publishVersion(strategyId, _twoAssets(), _weights(2, 5_000), bytes32(0), 0);
        vm.warp(block.timestamp + 1 days);
    }

    function test_publishVersion_ownerMayPublish() public {
        // setUp deploys the registry from this test contract, so `address(this)` is the owner.
        vm.warp(block.timestamp + 7 days);
        registry.publishVersion(strategyId, _twoAssets(), _weights(2, 5_000), bytes32(0), 0);
        vm.warp(block.timestamp + 1 days);
        assertEq(registry.versionCount(strategyId), 1);
    }

    function test_publishVersion_revertsForUnknownStrategy() public {
        vm.expectRevert(abi.encodeWithSelector(AtpRegistry.UnknownStrategy.selector, uint256(999)));
        vm.warp(block.timestamp + 7 days);
        registry.publishVersion(999, _twoAssets(), _weights(2, 5_000), bytes32(0), 0);
        vm.warp(block.timestamp + 1 days);
    }

    // ---- allowlist defaults ----

    function test_isAssetAllowed_isFalseBeforeAnyPublish() public view {
        assertFalse(registry.isAssetAllowed(strategyId, 0, ASSET_A));
        assertEq(registry.activeVersion(strategyId), 0);
        assertEq(registry.versionCount(strategyId), 0);
    }

    function test_isAssetAllowed_isFalseForUnknownStrategyOrVersion() public view {
        assertFalse(registry.isAssetAllowed(999, 0, ASSET_A));
        assertFalse(registry.isAssetAllowed(strategyId, 7, ASSET_A));
    }

    function _twoAssets() internal pure returns (address[] memory assets) {
        assets = new address[](2);
        assets[0] = ASSET_A;
        assets[1] = ASSET_B;
    }
}
