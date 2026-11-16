// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "./AtpYieldSafety.t.sol";

contract ReconcileDuringRedeem is MockVenus {
    AtpYieldRegistry immutable ledger;
    address public account;
    bytes32 public id;

    constructor(TestnetToken token, AtpYieldRegistry yields_) MockVenus(token, msg.sender, 0) {
        ledger = yields_;
    }

    function arm(address a, bytes32 i) external {
        account = a;
        id = i;
    }

    function redeem(uint256 shares) public override returns (uint256) {
        if (msg.sender == ledger.executor()) ledger.reconcile(account, id);
        return super.redeem(shares);
    }
}

/// @notice Regression assertions invert the review PoCs. New APIs use low-level calls so these tests
/// compile against the reviewed implementation and demonstrate the failure before the fix exists.
contract AtpYieldReviewTest is AtpYieldSafetyTest {
    function _call(bytes memory data) private {
        (bool ok, bytes memory reason) = address(yields).call(data);
        if (!ok) {
            assembly { revert(add(reason, 32), mload(reason)) }
        }
    }

    function test_review01_freeReservationRejected_withoutBlockingFundedSupply() public {
        address attacker = address(0xA77);
        vm.etch(attacker, hex"00");
        vm.startPrank(attacker);
        registry.enroll(attacker, strategy);
        yields.setYieldPolicy(ids[0], type(uint256).max, true);
        (bool ok,) = address(yields)
            .call(
                abi.encodeWithSignature("reserveSupply(address,bytes32,uint256)", attacker, ids[0], 10_000e18)
            );
        vm.stopPrank();
        assertFalse(ok, "unfunded account must not reserve shared capacity");

        _supply(0, 100e18);
        assertEq(yields.totalUnits(ids[0]), 100e8);
    }

    function test_review02_permissionlessReconcile_externalRedeemRecoversCapacity() public {
        _supply(0, 10_000e18 - 1);
        venus.transfer(address(0xE0A), venus.balanceOf(address(this)));
        uint256 held = venus.balanceOf(address(0xE0A));
        vm.prank(address(0xE0A));
        assertEq(venus.redeem(held), 0);
        vm.prank(OTHER);
        _call(abi.encodeWithSignature("reconcile(address,bytes32)", address(this), ids[0]));
        assertEq(yields.totalUnits(ids[0]), 0);
        vm.warp(block.timestamp + 1 days);
        _supply(0, 100e18);
    }

    function test_review02_recordWithdraw_convergesPreviouslyTransferredUnits() public {
        _supply(0, 100e18);
        venus.transfer(OTHER, venus.balanceOf(address(this)) / 2);
        _withdraw(0, venus.balanceOf(address(this)));
        assertEq(yields.accountUnits(address(this), ids[0]), 0);
        assertEq(yields.totalUnits(ids[0]), 0);
    }

    function test_review03_donationJump_doesNotLockExitOrValuation() public {
        _supply(1, 100e18);
        yields.quoteWithdraw(ids[1], 1e18);
        uint256 conservative = yields.receiptAssets(ids[1], address(this));
        asset.transfer(address(lista), 1e18);
        assertLe(yields.receiptAssets(ids[1], address(this)), conservative);
        assertGt(executor.previewAccountValue(address(this)), 0);
        _withdraw(1, lista.balanceOf(address(this)));
        assertEq(yields.totalUnits(ids[1]), 0);
    }

    function test_review04_rateOutsideBounds_stillRedeems() public {
        _supply(0, 100e18);
        venus.setAprBps(10_000);
        vm.warp(block.timestamp + 200 * 365 days);
        _withdraw(0, venus.balanceOf(address(this)));
        assertEq(yields.totalUnits(ids[0]), 0);
    }

    function test_review04_ownerCanOnlyWidenUpperBound() public {
        uint256 old = markets[0].maxRate;
        _call(abi.encodeWithSignature("widenMaxRate(bytes32,uint256)", ids[0], old + 1));
        assertEq(yields.market(ids[0]).maxRate, old + 1);
        (bool ok,) =
            address(yields).call(abi.encodeWithSignature("widenMaxRate(bytes32,uint256)", ids[0], old));
        assertFalse(ok);
        vm.prank(OTHER);
        (ok,) =
            address(yields).call(abi.encodeWithSignature("widenMaxRate(bytes32,uint256)", ids[0], old + 2));
        assertFalse(ok);
    }

    function test_review05_identityRequiresExactOwnerAcknowledgement() public {
        _supply(0, 100e18);
        vm.mockCall(
            address(venus), abi.encodeWithSignature("interestRateModel()"), abi.encode(address(lista))
        );
        vm.expectRevert(AtpYieldRegistry.AdmissionClosed.selector);
        executor.previewAccountValue(address(this));
        bytes32 expected = _identity(markets[0]);
        vm.prank(OTHER);
        (bool ok,) = address(yields)
            .call(abi.encodeWithSignature("acknowledgeIdentity(bytes32,bytes32)", ids[0], expected));
        assertFalse(ok);
        (ok,) = address(yields)
            .call(
                abi.encodeWithSignature("acknowledgeIdentity(bytes32,bytes32)", ids[0], bytes32(uint256(1)))
            );
        assertFalse(ok);
        _call(abi.encodeWithSignature("acknowledgeIdentity(bytes32,bytes32)", ids[0], expected));
        assertEq(yields.marketIdentity(ids[0]), expected);
        assertGt(executor.previewAccountValue(address(this)), 0);
    }

    function _identity(Y.Market memory m) private view returns (bytes32) {
        address model = address(lista);
        return keccak256(
            abi.encode(
                m.asset.codehash,
                m.target.codehash,
                m.receipt.codehash,
                m.riskSource.codehash,
                m.target,
                m.target.codehash,
                m.receipt,
                m.receipt.codehash,
                m.riskSource,
                m.riskSource.codehash,
                model,
                model.codehash
            )
        );
    }

    function test_review06_configurationChange_above80_allowsNAVAndAck_onlyStopsSupply() public {
        _freezeApr();
        _supply(0, 100e18);
        venus.setSupplyCap(2_000_000e18);
        venus.setLiquidity(100_010e18);
        bytes32 config = new YieldReaderHarness().health(markets[0]).configuration;
        assertGt(executor.previewAccountValue(address(this)), 0);
        yields.acknowledgeConfiguration(ids[0], config);
        assertEq(yields.market(ids[0]).configuration, config);
    }

    function test_review07_dustReceipt_doesNotBlockSupplyOrIncreaseTrackedExposure() public {
        vm.prank(address(0xB0));
        venus.transfer(address(this), 1);
        _supply(0, 100e18);
        assertEq(yields.accountUnits(address(this), ids[0]), 100e8);
        assertEq(yields.totalUnits(ids[0]), 100e8);
        assertEq(venus.balanceOf(address(this)), 100e8 + 1);
    }

    function test_review08_simulatedBorrow_neverPaysOwner_allProtocols() public {
        _freezeApr();
        for (uint256 i; i < 3; ++i) {
            uint256 before = asset.balanceOf(address(this));
            _liquidity(i, 0);
            assertEq(asset.balanceOf(address(this)), before, "simulation must retain cash inside mock");
            _liquidity(i, 1_000_000e18);
            assertEq(asset.balanceOf(address(this)), before, "restore must not debit owner");
        }
    }

    function test_review09_rateDrop_usesActualConservativeValue_andStillExits() public {
        _supply(0, 100e18);
        venus.setReserves(1e18);
        assertLt(yields.receiptAssets(ids[0], address(this)), 100e18);
        assertGt(executor.previewAccountValue(address(this)), 0);
        _withdraw(0, venus.balanceOf(address(this)));
        assertEq(yields.totalUnits(ids[0]), 0);
    }

    function test_review10_ordinaryPartialWithdraw_canResupplyAfterCooldown() public {
        _supply(0, 100e18);
        _withdraw(0, venus.balanceOf(address(this)) / 2);
        assertFalse(yields.exiting(address(this), ids[0]));
        vm.warp(block.timestamp + 1 days);
        _supply(0, 100e18);
    }

    function test_review14_listaRealLastAccrual_exact60ThenStale() public {
        vm.warp(block.timestamp + 60);
        assertEq(lista.market(lista.MARKET()).lastUpdate, lista.lastAccrual());
        yields.health(ids[1]);
        vm.warp(block.timestamp + 1);
        vm.expectRevert(YieldReader.UnsafeMarket.selector);
        yields.health(ids[1]);
        yields.refreshHealth(ids[1]);
        yields.health(ids[1]);
    }

    function test_review16_constructorUsesDedicatedError() public {
        vm.expectRevert(bytes4(keccak256("InvalidConstructor()")));
        new AtpYieldRegistry(AtpRegistry(address(0)), address(0));
    }

    function test_review07_withdrawTrackedPosition_donationRemainderCannotBlockNAV() public {
        _supply(0, 100e18);
        vm.prank(address(0xB0));
        venus.transfer(address(this), 1);
        _withdraw(0, 100e8);
        assertEq(yields.totalUnits(ids[0]), 0);
        assertEq(executor.previewAccountValue(address(this)), asset.balanceOf(address(this)));
    }

    function test_review02_syncAccount_reclaimsExternalTransfers_allProtocols() public {
        _freezeApr();
        for (uint256 i; i < 3; ++i) {
            if (i != 0) vm.warp(block.timestamp + 1 days);
            _supply(i, 100e18);
            IERC20 receipt = IERC20(markets[i].receipt);
            receipt.transfer(OTHER, receipt.balanceOf(address(this)));
            executor.previewAccountValue(address(this));
            assertEq(yields.accountUnits(address(this), ids[i]), 0);
            assertEq(yields.totalUnits(ids[i]), 0);
        }
    }

    function test_review08_productionMocksExposeNoArbitraryRateFeePauseOrCapSetters() public {
        MockVenus v = new MockVenus(asset, address(this), 0);
        MockLista l = new MockLista(asset, address(this), 0);
        MockAavePool a = new MockAavePool(asset, address(this), 0);
        _absent(address(v), abi.encodeWithSignature("setExchangeRate(uint256)", 1));
        _absent(address(v), abi.encodeWithSignature("setReserves(uint256)", 1));
        _absent(address(v), abi.encodeWithSignature("setErrorCodes(uint256,uint256)", 1, 1));
        _absent(address(v), abi.encodeWithSignature("setSupplyCap(uint256)", 1));
        _absent(address(v), abi.encodeWithSignature("setPaused(bool,bool)", true, true));
        _absent(address(l), abi.encodeWithSignature("setRiskCore(address)", address(v)));
        _absent(address(l), abi.encodeWithSignature("setFee(uint96)", uint96(1)));
        _absent(address(l), abi.encodeWithSignature("setFeeRecipient(address)", OTHER));
        _absent(address(l), abi.encodeWithSignature("setExitFeeBps(uint16)", uint16(1)));
        _absent(address(l), abi.encodeWithSignature("setSupplyCap(uint256)", 1));
        _absent(address(l), abi.encodeWithSignature("setPaused(bool,bool)", true, true));
        _absent(address(a), abi.encodeWithSignature("setSupplyCap(uint256)", 1));
        _absent(address(a), abi.encodeWithSignature("setPaused(bool,bool)", true, true));
        assertEq(l.fee(), 0);
        assertEq(l.exitFeeBps(), 0);
        assertEq(l.feeRecipient(), address(this));
    }

    function _absent(address target, bytes memory data) private {
        (bool ok,) = target.call(data);
        assertFalse(ok, "removed privileged selector must be unavailable");
    }

    function test_review07_untrackedDonation_cannotCreateStickyRiskExit() public {
        _freezeApr();
        vm.prank(address(0xB0));
        lista.transfer(address(this), 1);
        lista.setLiquidity(0);
        vm.expectRevert(AtpYieldRegistry.AdmissionClosed.selector);
        yields.markRiskExit(address(this), ids[1]);
        yields.requestExit(ids[1]);
        yields.setYieldPolicy(ids[1], 100e18, true);
        assertFalse(yields.exiting(address(this), ids[1]));
        lista.setLiquidity(1_000_000e18);
        _supply(1, 100e18);
    }

    function test_review04_registrationStillEnforcesInitialRateBounds() public {
        MockVenus v = new MockVenus(asset, address(this), 0);
        Y.Market memory m = markets[0];
        m.target = address(v);
        m.receipt = address(v);
        m.riskSource = address(v);
        m.minRate = v.exchangeRateStored() + 1;
        vm.expectRevert(YieldReader.BadRate.selector);
        yields.registerMarket(bytes32(uint256(101)), m);
    }

    function test_review02_reconcileDuringWithdraw_doesNotDoubleReleaseExposure() public {
        ReconcileDuringRedeem v = new ReconcileDuringRedeem(asset, yields);
        asset.setMinter(address(v), true);
        asset.approve(address(v), 1_000_000e18);
        assertEq(v.mint(1_000_000e18), 0);
        v.transfer(address(0xB0), v.balanceOf(address(this)));
        Y.Market memory m = markets[0];
        m.target = address(v);
        m.receipt = address(v);
        m.riskSource = address(v);
        m.configuration = new YieldReaderHarness().health(m).configuration;
        bytes32 id = bytes32(uint256(102));
        yields.registerMarket(id, m);
        yields.setYieldPolicy(id, 100e18, true);
        v.approve(address(executor), type(uint256).max);
        executor.executeSupply(
            address(this), id, 100e18, yields.quoteSupply(id, address(this), 100e18), block.timestamp
        );
        v.arm(address(this), id);
        uint256 quote = yields.quoteWithdraw(id, 50e8);
        executor.executeWithdraw(address(this), id, 50e8, quote, block.timestamp);
        assertEq(v.balanceOf(address(this)), 50e8);
        assertEq(yields.accountUnits(address(this), id), 50e8);
        assertEq(yields.totalUnits(id), 50e8);
    }
}
