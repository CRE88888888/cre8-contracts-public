// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "./AtpYieldSafety.t.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Second-review PoCs converted to assertions of the agreed behavior. The first-review
/// f1-f10 cases remain in AtpYieldReview.t.sol; accepted accounting limits are asserted here too.
contract AtpYieldReview2Test is AtpYieldSafetyTest {
    function _floor(uint256 quote) private pure returns (uint256) {
        return Math.mulDiv(quote, 9_990, 10_000);
    }

    function _nextBlock() private {
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.roll(vm.getBlockNumber() + 1);
    }

    function _gapSupply(uint256 i) private {
        uint256 minimum = Math.mulDiv(yields.quoteSupply(ids[i], OTHER, 100e18), 9_995, 10_000);
        _nextBlock();
        vm.prank(OTHER);
        executor.executeSupply(OTHER, ids[i], 100e18, minimum, block.timestamp);
        assertGe(IERC20(markets[i].receipt).balanceOf(OTHER), minimum);
        assertGt(yields.accountUnits(OTHER, ids[i]), 0);
    }

    function _gapWithdraw(uint256 i) private {
        _supply(i, 100e18);
        uint256 shares = IERC20(markets[i].receipt).balanceOf(address(this));
        uint256 minimum = Math.mulDiv(yields.quoteWithdraw(ids[i], shares), 9_995, 10_000);
        uint256 before = asset.balanceOf(address(this));
        _nextBlock();
        executor.executeWithdraw(address(this), ids[i], shares, minimum, block.timestamp);
        assertGe(asset.balanceOf(address(this)) - before, minimum);
        if (i == 2) {
            // Aave's signed shares are raw aTokens: interest accrued after the snapshot remains owned.
            assertGt(yields.accountUnits(address(this), ids[i]), 0);
            assertEq(yields.accountUnits(address(this), ids[i]), yields.units(ids[i], address(this)));
            _withdraw(i, IERC20(markets[i].receipt).balanceOf(address(this)));
        }
        assertEq(yields.accountUnits(address(this), ids[i]), 0);
    }

    function test_review2_gapSupplyVenus() public {
        _gapSupply(0);
    }

    function test_review2_gapSupplyLista() public {
        _gapSupply(1);
    }

    function test_review2_gapSupplyAave() public {
        _gapSupply(2);
    }

    function test_review2_gapWithdrawVenus() public {
        _gapWithdraw(0);
    }

    function test_review2_gapWithdrawLista() public {
        _gapWithdraw(1);
    }

    function test_review2_gapWithdrawAave() public {
        _gapWithdraw(2);
    }

    function test_review2_staleQuoteBeyondToleranceCannotWeakenActualMinimum() public {
        uint256 quoted = yields.quoteSupply(ids[0], OTHER, 100e18);
        uint256 minimum = quoted * 9_995 / 10_000;
        vm.warp(vm.getBlockTimestamp() + 14 days);
        uint256 actual = yields.quoteSupply(ids[0], OTHER, 100e18);
        vm.expectRevert(abi.encodeWithSelector(YieldActions.InsufficientOutput.selector, actual, minimum));
        vm.prank(OTHER);
        executor.executeSupply(OTHER, ids[0], 100e18, minimum, block.timestamp);
        assertEq(yields.accountUnits(OTHER, ids[0]), 0);
        assertEq(asset.balanceOf(OTHER), 100_000e18);
        _supply(0, 100e18);
        uint256 shares = venus.balanceOf(address(this));
        quoted = yields.quoteWithdraw(ids[0], shares);
        minimum = quoted * 9_995 / 10_000;
        vm.warp(vm.getBlockTimestamp() + 14 days);
        uint256 floor = _floor(yields.quoteWithdraw(ids[0], shares));
        vm.expectRevert(abi.encodeWithSelector(AtpExecutor.YieldMinimum.selector, minimum, floor));
        executor.executeWithdraw(address(this), ids[0], shares, minimum, block.timestamp);
        assertEq(venus.balanceOf(address(this)), shares);
    }

    function test_review2_zeroQuoteRejected_andPositiveMinBelowOneUnitFloor() public {
        _freezeApr();
        vm.mockCall(
            address(lista), abi.encodeWithSignature("previewDeposit(uint256)", 100e18), abi.encode(uint256(0))
        );
        vm.expectRevert(abi.encodeWithSelector(AtpExecutor.YieldMinimum.selector, 1, 0));
        executor.executeSupply(address(this), ids[1], 100e18, 1, block.timestamp);
        vm.clearMockedCalls();
        _supply(2, 100e18);
        executor.executeWithdraw(address(this), ids[2], 1, 1, block.timestamp);
        uint256 remaining = IERC20(markets[2].receipt).balanceOf(address(this));
        vm.mockCall(
            address(aave),
            abi.encodeWithSignature("getReserveNormalizedIncome(address)", address(asset)),
            abi.encode(uint256(0))
        );
        vm.expectRevert(YieldReader.BadRate.selector);
        executor.executeWithdraw(address(this), ids[2], remaining, 1, block.timestamp);
    }

    function test_review2_floorEquality_andActualMinimum_allProtocols() public {
        _freezeApr();
        for (uint256 i; i < 3; ++i) {
            if (i != 0) vm.warp(vm.getBlockTimestamp() + 1 days);
            uint256 quote = yields.quoteSupply(ids[i], address(this), 100e18);
            uint256 minimum = _floor(quote);
            vm.expectRevert(abi.encodeWithSelector(AtpExecutor.YieldMinimum.selector, minimum - 1, minimum));
            executor.executeSupply(address(this), ids[i], 100e18, minimum - 1, block.timestamp);
            vm.expectRevert(
                abi.encodeWithSelector(YieldActions.InsufficientOutput.selector, quote, quote + 1)
            );
            executor.executeSupply(address(this), ids[i], 100e18, quote + 1, block.timestamp);
            executor.executeSupply(address(this), ids[i], 100e18, minimum, block.timestamp);
            uint256 shares = IERC20(markets[i].receipt).balanceOf(address(this));
            quote = yields.quoteWithdraw(ids[i], shares);
            minimum = _floor(quote);
            vm.expectRevert(abi.encodeWithSelector(AtpExecutor.YieldMinimum.selector, minimum - 1, minimum));
            executor.executeWithdraw(address(this), ids[i], shares, minimum - 1, block.timestamp);
            vm.expectRevert(
                abi.encodeWithSelector(YieldActions.InsufficientOutput.selector, quote, quote + 1)
            );
            executor.executeWithdraw(address(this), ids[i], shares, quote + 1, block.timestamp);
            executor.executeWithdraw(address(this), ids[i], shares, minimum, block.timestamp);
            assertEq(yields.totalUnits(ids[i]), 0);
        }
    }

    function test_review2_donationCannotForceStickyRiskExit() public {
        _supply(1, 100e18);
        vm.warp(vm.getBlockTimestamp() + 3 days);
        vm.expectRevert(AtpYieldRegistry.AdmissionClosed.selector);
        yields.markRiskExit(address(this), ids[1]);
        yields.quoteWithdraw(ids[1], 1e18);
        asset.transfer(address(lista), 1e7);
        vm.prank(OTHER);
        vm.expectRevert(AtpYieldRegistry.AdmissionClosed.selector);
        yields.markRiskExit(address(this), ids[1]);
        assertFalse(yields.exiting(address(this), ids[1]));
        vm.warp(vm.getBlockTimestamp() + 1 days);
        _supply(1, 100e18);
    }

    function test_review2_riskRateEqualUpAndDown() public {
        _freezeApr();
        _supply(0, 100e18);
        uint256 rate = venus.exchangeRateStored();
        vm.expectRevert(AtpYieldRegistry.AdmissionClosed.selector);
        yields.markRiskExit(address(this), ids[0]);
        venus.setExchangeRate(markets[0].maxRate + 1);
        vm.expectRevert(AtpYieldRegistry.AdmissionClosed.selector);
        yields.markRiskExit(address(this), ids[0]);
        assertFalse(yields.exiting(address(this), ids[0]));
        venus.setExchangeRate(rate - 1);
        yields.markRiskExit(address(this), ids[0]);
        assertTrue(yields.exiting(address(this), ids[0]));
    }

    function test_review2_riskUtilizationBoundary_allProtocols() public {
        _freezeApr();
        for (uint256 i; i < 3; ++i) {
            if (i != 0) vm.warp(vm.getBlockTimestamp() + 1 days);
            _supply(i, 100e18);
            _liquidity(i, 1_000_100e18 * 1_001 / 10_000);
            vm.expectRevert(AtpYieldRegistry.AdmissionClosed.selector);
            yields.markRiskExit(address(this), ids[i]);
            _liquidity(i, 1_000_100e18 / 10);
            yields.markRiskExit(address(this), ids[i]);
            assertTrue(yields.exiting(address(this), ids[i]));
        }
    }

    function test_review2_riskConfigurationChangeAloneDoesNotForceExit() public {
        _supply(0, 100e18);
        venus.setSupplyCap(2_000_000e18);
        vm.expectRevert(AtpYieldRegistry.AdmissionClosed.selector);
        yields.markRiskExit(address(this), ids[0]);
        assertFalse(yields.exiting(address(this), ids[0]));
    }

    function test_review2_failedAndStaleReadsStillMarkRisk() public {
        _supply(1, 100e18);
        uint256 snapshot = vm.snapshotState();
        vm.mockCallRevert(
            address(lista), abi.encodeWithSignature("convertToAssets(uint256)", 1e18), hex"deadbeef"
        );
        yields.markRiskExit(address(this), ids[1]);
        assertTrue(yields.exiting(address(this), ids[1]));
        vm.clearMockedCalls();
        vm.revertToState(snapshot);
        MoolahMarket memory state = lista.market(lista.MARKET());
        state.lastUpdate = uint128(block.timestamp - 61);
        vm.mockCall(
            address(lista), abi.encodeWithSignature("market(bytes32)", lista.MARKET()), abi.encode(state)
        );
        yields.markRiskExit(address(this), ids[1]);
        assertTrue(yields.exiting(address(this), ids[1]));
    }

    function test_review2_donationSupplyPause23Then25Hours_exitStillWorks() public {
        lista.setAprBps(0);
        _supply(1, 100e18);
        uint256 t0 = vm.getBlockTimestamp();
        yields.quoteWithdraw(ids[1], 1e18);
        asset.transfer(address(lista), lista.totalAssets() / 365);
        vm.expectRevert(AtpYieldRegistry.UnacknowledgedRate.selector);
        yields.quoteSupply(ids[1], OTHER, 100e18);
        vm.warp(t0 + 23 hours);
        vm.expectRevert(AtpYieldRegistry.UnacknowledgedRate.selector);
        yields.quoteSupply(ids[1], OTHER, 100e18);
        _withdraw(1, lista.balanceOf(address(this)) / 2);
        vm.warp(t0 + 25 hours);
        assertGt(yields.quoteSupply(ids[1], OTHER, 100e18), 0);
    }

    function test_review2_capOnlyBoundsTrackedExecutorPositions() public {
        _freezeApr();
        _supply(0, 10_000e18);
        venus.transfer(address(0xE0A), venus.balanceOf(address(this)));
        yields.reconcile(address(this), ids[0]);
        uint256 q = yields.quoteSupply(ids[0], OTHER, 10_000e18);
        vm.prank(OTHER);
        executor.executeSupply(OTHER, ids[0], 10_000e18, q, block.timestamp);
        uint256 realExposure =
            (venus.balanceOf(address(0xE0A)) + venus.balanceOf(OTHER)) * venus.exchangeRateStored() / 1e18;
        assertEq(realExposure, 20_000e18);
        assertEq(yields.totalUnits(ids[0]), 10_000e8);
        uint256 tracked = yields.totalUnits(ids[0]);
        vm.prank(address(0xA77));
        yields.reconcile(OTHER, ids[0]);
        assertEq(yields.totalUnits(ids[0]), tracked);
    }

    function test_review2_withdrawDebitsTrackedBeforeDonatedReceipts() public {
        _supply(0, 100e18);
        uint256 own = venus.balanceOf(address(this));
        vm.prank(address(0xB0));
        venus.transfer(address(this), own / 2);
        _withdraw(0, own / 2);
        assertEq(venus.balanceOf(address(this)), own);
        assertEq(yields.accountUnits(address(this), ids[0]), own / 2);
    }

    function test_review2_reconcileClearsUnknownFlagWithoutReconsent() public {
        vm.mockCallRevert(
            address(venus), abi.encodeWithSelector(IERC20.balanceOf.selector, address(this)), hex"deadbeef"
        );
        yields.requestExit(ids[0]);
        assertTrue(yields.exiting(address(this), ids[0]));
        vm.clearMockedCalls();
        vm.prank(OTHER);
        yields.reconcile(address(this), ids[0]);
        assertFalse(yields.exiting(address(this), ids[0]));
        (,,, bool enabled) = yields.policies(address(this), ids[0]);
        assertFalse(enabled);
    }

    function test_review2_deploymentSizeHeadroom() public view {
        assertLe(address(yields).code.length, 24_576 - 1_000, "registry runtime headroom");
        assertLe(address(executor).code.length, 24_576 - 1_000, "executor runtime headroom");
        assertLe(
            vm.getCode("AtpYieldRegistry.sol:AtpYieldRegistry").length + 64,
            49_152 - 1_000,
            "registry initcode headroom"
        );
        assertLe(
            vm.getCode("AtpExecutor.sol:AtpExecutor").length + 256,
            49_152 - 1_000,
            "executor initcode headroom"
        );
        assertLe(yields.reader().code.length, 24_576 - 1_000, "view library runtime headroom");
        assertLe(
            vm.getCode("YieldView.sol:YieldView").length, 49_152 - 1_000, "view library initcode headroom"
        );
    }

    function test_review2_constructorRejectsMissingLinkedReader() public {
        vm.etch(yields.reader(), hex"");
        vm.expectRevert(AtpYieldRegistry.InvalidConstructor.selector);
        new AtpYieldRegistry(registry, address(executor));
    }

    function test_review2_linkedReaderCannotBeSwapVenue() public {
        address reader = yields.reader();
        assertTrue(yields.isYieldProtocol(reader));
        vm.expectRevert(abi.encodeWithSelector(AtpExecutor.BadVenue.selector, reader));
        executor.setVenue(reader, AtpExecutor.VenueKind.ERC20_APPROVE, reader);
    }
}
