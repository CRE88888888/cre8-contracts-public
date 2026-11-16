// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { AtpRegistry } from "../../src/atp/AtpRegistry.sol";
import { AtpExecutor } from "../../src/atp/AtpExecutor.sol";
import { IUniversalRouter } from "../../src/atp/interfaces/IUniversalRouter.sol";
import { AtpYieldRegistry } from "../../src/atp/yield/AtpYieldRegistry.sol";
import { YieldTypes as Y } from "../../src/atp/yield/YieldTypes.sol";
import { MoolahMarket } from "../../src/atp/yield/YieldInterfaces.sol";
import { YieldReader } from "../../src/atp/yield/YieldReader.sol";
import { YieldActions } from "../../src/atp/yield/YieldActions.sol";
import { TestnetToken } from "../../src/testnet/TestnetToken.sol";
import { MockVenus } from "../../src/testnet/yield/MockVenus.sol";
import { MockLista } from "../../src/testnet/yield/MockLista.sol";
import { MockAavePool } from "../../src/testnet/yield/MockAavePool.sol";
import { PricedOracle, PricedRouter } from "./AtpExecutorBuyLimit.t.sol";
import { MockPermit2 } from "./AtpExecutor.t.sol";

import { AdversarialVenus, AdversarialLista, AdversarialAave } from "./YieldAdversarialMocks.sol";

contract YieldReaderHarness {
    function exposure(Y.Market memory m, uint256 shares) external view returns (uint256) {
        return YieldReader.assets(m, shares, true);
    }

    function health(Y.Market memory m) external view returns (Y.Health memory) {
        return YieldReader.health(m);
    }
}

contract SenderTaxAsset is TestnetToken {
    address public taxed;
    constructor() TestnetToken("Sender tax", "TAX", 18, msg.sender) { }

    function setTaxed(address account) external {
        taxed = account;
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (taxed != address(0) && from == taxed && to != address(0) && amount != 0) {
            super._update(from, address(0xFEE), 1);
        }
        super._update(from, to, amount);
    }
}

contract SenderTaxReceipt is MockVenus {
    constructor(TestnetToken asset) MockVenus(asset, msg.sender, 0) { }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        super.transferFrom(from, to, amount);
        _burn(from, 1);
        return true;
    }
}

contract ReentrantVenus is MockVenus {
    AtpExecutor immutable executor;
    bool public attempted;

    constructor(TestnetToken asset, AtpExecutor target) MockVenus(asset, msg.sender, 0) {
        executor = target;
    }

    function mint(uint256 amount) public override returns (uint256) {
        if (msg.sender == address(executor)) _reenter();
        return super.mint(amount);
    }

    function redeem(uint256 shares) public override returns (uint256) {
        if (msg.sender == address(executor)) _reenter();
        return super.redeem(shares);
    }

    function _reenter() private {
        attempted = true;
        (bool ok, bytes memory reason) = address(executor)
            .call(
                abi.encodeCall(
                    AtpExecutor.executeSupply, (address(this), bytes32(uint256(99)), 1, 1, block.timestamp)
                )
            );
        require(
            !ok && bytes4(reason) == bytes4(keccak256("ReentrancyGuardReentrantCall()")),
            "reentrancy guard absent"
        );
    }
}

contract AtpYieldSafetyTest is Test {
    AtpRegistry registry;
    AtpExecutor executor;
    AtpYieldRegistry yields;
    TestnetToken asset;
    AdversarialVenus venus;
    AdversarialLista lista;
    AdversarialAave aave;
    bytes32[3] ids;
    Y.Market[3] markets;
    address constant OTHER = address(0xBEEF);
    address constant OPERATOR = address(0x00FE);
    uint256 strategy;

    function setUp() public {
        vm.chainId(97);
        vm.warp(1_000_000);
        asset = new TestnetToken("Test USDT", "USDT", 18, address(this));
        address permit = 0x31c2F6fcFf4F8759b3Bd5Bf0e1084A055615c768;
        vm.etch(permit, address(new MockPermit2()).code);
        registry = new AtpRegistry();
        registry.setOperator(OPERATOR);
        executor = new AtpExecutor(
            registry,
            new PricedRouter(),
            new PricedOracle(address(asset)),
            permit,
            address(0xFEE),
            address(asset),
            10_000,
            0.3e18
        );
        yields = executor.yieldRegistry();
        venus = new AdversarialVenus(asset, address(this), 500);
        lista = new AdversarialLista(asset, address(this), 300);
        aave = new AdversarialAave(asset, address(this), 300);
        asset.setMinter(address(venus), true);
        asset.setMinter(address(lista), true);
        asset.setMinter(aave.receipt(), true);
        asset.mint(address(this), 10_000_000e18);
        asset.approve(address(venus), type(uint256).max);
        asset.approve(address(lista), type(uint256).max);
        asset.approve(address(aave), type(uint256).max);
        venus.mint(1_000_000e18);
        lista.deposit(1_000_000e18, address(this));
        aave.supply(address(asset), 1_000_000e18, address(this), 0);
        // Background receipt holders are not CRE8 accounts. Test funds belong to separate accounts.
        venus.transfer(address(0xB0), venus.balanceOf(address(this)));
        lista.transfer(address(0xB0), lista.balanceOf(address(this)));
        IERC20(aave.receipt()).transfer(address(0xB0), IERC20(aave.receipt()).balanceOf(address(this)));
        address[] memory assets = new address[](1);
        assets[0] = address(asset);
        uint16[] memory weights = new uint16[](1);
        weights[0] = 10_000;
        strategy = registry.registerStrategy("yield", "test", true);
        registry.publishVersion(strategy, assets, weights, keccak256("hold"), 0);
        registry.enroll(address(this), strategy);
        vm.etch(OTHER, hex"00");
        vm.prank(OPERATOR);
        registry.enroll(OTHER, strategy);
        asset.mint(OTHER, 100_000e18);
        asset.approve(address(executor), type(uint256).max);
        vm.prank(OTHER);
        asset.approve(address(executor), type(uint256).max);
        for (uint256 i; i < 3; ++i) {
            ids[i] = bytes32(i + 1);
            address target = i == 0 ? address(venus) : i == 1 ? address(lista) : address(aave);
            address receipt = i == 2 ? aave.receipt() : target;
            Y.Market memory m = Y.Market(
                97,
                Y.Kind(i + 1),
                address(asset),
                receipt,
                target,
                target,
                bytes32(0),
                i == 0 ? 1e27 : 1e17,
                i == 0 ? 1e30 : 1e20,
                true,
                false
            );
            m.configuration = new YieldReaderHarness().health(m).configuration;
            markets[i] = m;
            yields.registerMarket(ids[i], m);
            yields.setYieldPolicy(ids[i], 100_000e18, true);
            vm.prank(OTHER);
            yields.setYieldPolicy(ids[i], 100_000e18, true);
            IERC20(receipt).approve(address(executor), type(uint256).max);
            vm.prank(OTHER);
            IERC20(receipt).approve(address(executor), type(uint256).max);
        }
    }

    function _supply(uint256 i, uint256 amount) internal {
        executor.executeSupply(
            address(this), ids[i], amount, yields.quoteSupply(ids[i], address(this), amount), block.timestamp
        );
    }

    function _withdraw(uint256 i, uint256 shares) internal {
        executor.executeWithdraw(
            address(this), ids[i], shares, yields.quoteWithdraw(ids[i], shares), block.timestamp
        );
    }

    function test_allProtocols_roundTrip_minEquals_andAllowancesZero() public {
        uint256 expectedCash = asset.balanceOf(address(this));
        for (uint256 i; i < 3; ++i) {
            if (i != 0) vm.warp(block.timestamp + 1 days);
            _supply(i, 100e18);
            assertEq(asset.allowance(address(executor), markets[i].target), 0);
            uint256 shares = IERC20(markets[i].receipt).balanceOf(address(this));
            expectedCash = expectedCash - 100e18 + yields.quoteWithdraw(ids[i], shares);
            _withdraw(i, shares);
            assertEq(asset.balanceOf(address(this)), expectedCash);
            assertEq(asset.balanceOf(address(executor)), 0);
            assertEq(IERC20(markets[i].receipt).balanceOf(address(executor)), 0);
            assertEq(yields.totalUnits(ids[i]), 0);
        }
        assertEq(asset.balanceOf(address(this)), expectedCash);
    }

    function test_supplyZero_minZero_andBelowTrustedQuoteRejected() public {
        for (uint256 i; i < 3; ++i) {
            vm.expectRevert(AtpExecutor.ZeroAmount.selector);
            executor.executeSupply(address(this), ids[i], 0, 1, block.timestamp);
            vm.expectRevert(AtpExecutor.ZeroAmount.selector);
            executor.executeSupply(address(this), ids[i], 100e18, 0, block.timestamp);
            uint256 quote = yields.quoteSupply(ids[i], address(this), 100e18);
            uint256 floor = quote * 9_990 / 10_000;
            vm.expectRevert(abi.encodeWithSelector(AtpExecutor.YieldMinimum.selector, floor - 1, floor));
            executor.executeSupply(address(this), ids[i], 100e18, floor - 1, block.timestamp);
        }
    }

    function test_minimum50_andCooldownEqual() public {
        uint256 quote = yields.quoteSupply(ids[0], address(this), 50e18 - 1);
        vm.expectRevert(abi.encodeWithSelector(AtpExecutor.YieldMinimum.selector, 50e18 - 1, 50e18));
        executor.executeSupply(address(this), ids[0], 50e18 - 1, quote, block.timestamp);
        _supply(0, 50e18);
        vm.warp(block.timestamp + 1 days - 1);
        quote = yields.quoteSupply(ids[0], address(this), 50e18);
        vm.expectRevert(AtpYieldRegistry.SupplyCooldown.selector);
        executor.executeSupply(address(this), ids[0], 50e18, quote, block.timestamp);
        vm.warp(block.timestamp + 1);
        _supply(0, 50e18);
    }

    function test_sharedCapacity_twoAccounts_equalThenPlusOne() public {
        _freezeApr();
        _supply(0, 9_000e18);
        uint256 quote = yields.quoteSupply(ids[0], OTHER, 1_090e18);
        vm.prank(OTHER);
        executor.executeSupply(OTHER, ids[0], 1_090e18, quote, block.timestamp);
        assertEq(yields.totalUnits(ids[0]), 10_090e8);
        vm.warp(block.timestamp + 1 days);
        vm.expectRevert(
            abi.encodeWithSelector(AtpYieldRegistry.CapacityExceeded.selector, 10_100.9e18 + 1, 10_100.9e18)
        );
        vm.prank(address(executor));
        yields.beforeSupply(address(this), ids[0], 10.9e18 + 1);
    }

    function test_unknownReservationsDoNotExpire_orReleaseByOperator() public {
        for (uint256 i; i < 2; ++i) {
            vm.prank(i == 0 ? address(this) : OPERATOR);
            (bool ok,) = address(yields)
                .call(
                    abi.encodeWithSignature(
                        "reserveSupply(address,bytes32,uint256)", address(this), ids[0], 10_000e18
                    )
                );
            assertFalse(ok);
        }
        _supply(0, 100e18);
        assertEq(yields.totalUnits(ids[0]), 100e8);
    }

    function test_cashOnlyRequestExit_requiresFreshConsent_butCanSupplyAgain() public {
        for (uint256 i; i < 3; ++i) {
            yields.requestExit(ids[i]);
            assertFalse(yields.exiting(address(this), ids[i]));
            uint256 quote = yields.quoteSupply(ids[i], address(this), 100e18);
            vm.expectRevert(AtpYieldRegistry.ConsentRequired.selector);
            executor.executeSupply(address(this), ids[i], 100e18, quote, block.timestamp);
            yields.setYieldPolicy(ids[i], 100e18, true);
            if (i != 0) vm.warp(block.timestamp + 1 days);
            _supply(i, 100e18);
            assertGt(yields.totalUnits(ids[i]), 0);
            yields.requestExit(ids[i]);
            yields.setYieldPolicy(ids[i], 100e18, true);
            assertTrue(yields.exiting(address(this), ids[i]), "held receipts keep the exit sticky");
            _withdraw(i, IERC20(markets[i].receipt).balanceOf(address(this)));
            assertFalse(yields.exiting(address(this), ids[i]));
        }
    }

    function test_cashOnlyUnknownReceiptRead_stopsSupply_andCanReconsentAfterRecovery() public {
        vm.mockCallRevert(
            address(venus), abi.encodeWithSelector(IERC20.balanceOf.selector, address(this)), hex"deadbeef"
        );
        yields.requestExit(ids[0]);
        assertTrue(yields.exiting(address(this), ids[0]));
        vm.clearMockedCalls();
        uint256 quote = yields.quoteSupply(ids[0], address(this), 100e18);
        vm.expectRevert(AtpYieldRegistry.AdmissionClosed.selector);
        executor.executeSupply(address(this), ids[0], 100e18, quote, block.timestamp);
        yields.setYieldPolicy(ids[0], 100e18, true);
        assertFalse(yields.exiting(address(this), ids[0]));
        _supply(0, 100e18);
    }

    function test_cashOnlyRiskObservation_cannotPermanentlyLockFutureSupply() public {
        _freezeApr();
        for (uint256 i; i < 3; ++i) {
            _liquidity(i, 0);
            vm.expectRevert(AtpYieldRegistry.AdmissionClosed.selector);
            yields.markRiskExit(address(this), ids[i]);
            assertFalse(yields.exiting(address(this), ids[i]));
            _liquidity(i, 1_000_000e18);
            if (i != 0) vm.warp(block.timestamp + 1 days);
            _supply(i, 100e18);
            assertGt(yields.totalUnits(ids[i]), 0);
        }
    }

    function test_retirement_andPauses_neverLockPureWithdraw() public {
        _supply(0, 100e18);
        yields.setMarketSupply(ids[0], false, true);
        yields.setSupplyPaused(true);
        registry.setPaused(address(this), true);
        executor.setMaxBuyBps(0);
        _withdraw(0, venus.balanceOf(address(this)));
        assertEq(venus.balanceOf(address(this)), 0);
    }

    function test_emergencyPause_ownerDirectRedeemStillWorks() public {
        _supply(0, 100e18);
        executor.setGlobalPaused(true);
        vm.expectRevert(AtpExecutor.ExecutorPaused.selector);
        executor.executeWithdraw(address(this), ids[0], 1, 1, block.timestamp);
        assertEq(venus.redeem(venus.balanceOf(address(this))), 0);
        assertEq(venus.balanceOf(address(this)), 0);
    }

    function test_venusErrorCode_revertsAtomically_andDustIsUntouched() public {
        asset.mint(address(executor), 7);
        venus.setErrorCodes(5, 0);
        uint256 before = asset.balanceOf(address(this));
        vm.expectRevert(abi.encodeWithSignature("ProtocolError(uint256)", 5));
        executor.executeSupply(address(this), ids[0], 100e18, 1e10, block.timestamp);
        assertEq(asset.balanceOf(address(this)), before);
        assertEq(yields.totalUnits(ids[0]), 0);
        venus.setErrorCodes(0, 0);
        _supply(0, 100e18);
        assertEq(asset.balanceOf(address(executor)), 7);
        venus.setErrorCodes(0, 9);
        uint256 shares = venus.balanceOf(address(this));
        uint256 quote = yields.quoteWithdraw(ids[0], shares);
        vm.expectRevert(abi.encodeWithSignature("ProtocolError(uint256)", 9));
        executor.executeWithdraw(address(this), ids[0], shares, quote, block.timestamp);
        assertEq(venus.balanceOf(address(this)), shares);
    }

    function test_receiptValue_noDoubleCounting_interest_andRetiredPosition() public {
        (uint256 before,,) = executor.buyAllowance(address(this));
        _supply(0, 100e18);
        (uint256 afterSupply,,) = executor.buyAllowance(address(this));
        assertEq(afterSupply, before);
        vm.warp(block.timestamp + 365 days);
        venus.accrueInterest();
        (uint256 afterInterest,,) = executor.buyAllowance(address(this));
        assertGt(afterInterest, before);
        yields.setMarketSupply(ids[0], false, true);
        (uint256 retired,,) = executor.buyAllowance(address(this));
        assertEq(retired, afterInterest);
    }

    function test_unknownReceiptValue_failsClosed_buyAllowance() public {
        _supply(0, 100e18);
        venus.setExchangeRate(0);
        vm.expectRevert(YieldReader.BadRate.selector);
        executor.buyAllowance(address(this));
    }

    function test_wrongPair_chain_orOverwrite_rejected() public {
        Y.Market memory m = markets[0];
        vm.expectRevert(AtpYieldRegistry.BadMarket.selector);
        yields.registerMarket(ids[0], m);
        m.chainId = 56;
        m.receipt = address(0x1234);
        vm.expectRevert(YieldReader.InvalidMarket.selector);
        yields.registerMarket(bytes32(uint256(10)), m);
        vm.expectRevert(AtpYieldRegistry.Unauthorized.selector);
        vm.prank(OPERATOR);
        yields.setSupplyPaused(true);
    }

    function test_externalReceiptTransfer_keepsCapacity_andStopsNewSupply() public {
        _supply(0, 100e18);
        venus.transfer(OTHER, venus.balanceOf(address(this)));
        vm.prank(OTHER);
        yields.reconcile(address(this), ids[0]);
        assertEq(yields.totalUnits(ids[0]), 0);
        vm.warp(block.timestamp + 1 days);
        _supply(0, 100e18);
    }

    function _freezeApr() internal {
        venus.setAprBps(0);
        lista.setAprBps(0);
        aave.setAprBps(0);
    }

    function _liquidity(uint256 i, uint256 amount) internal {
        if (i == 0) venus.setLiquidity(amount);
        else if (i == 1) lista.setLiquidity(amount);
        else aave.setLiquidity(amount);
    }

    function test_allProtocols_utilizationBoundaries_failClosed() public {
        _freezeApr();
        uint256[7] memory utilization = [uint256(0), 7_999, 8_000, 8_001, 8_999, 9_000, 10_000];
        for (uint256 i; i < 3; ++i) {
            for (uint256 k; k < utilization.length; ++k) {
                _liquidity(i, 1_000_000e18 * (10_000 - utilization[k]) / 10_000);
                assertEq(yields.health(ids[i]).utilizationBps, utilization[k]);
                uint256 snapshot = vm.snapshotState();
                if (utilization[k] > 8_000) vm.expectRevert(AtpYieldRegistry.AdmissionClosed.selector);
                vm.prank(address(executor));
                yields.beforeSupply(address(this), ids[i], 50e18);
                vm.revertToState(snapshot);
            }
        }
    }

    function test_allProtocols_partialExit_retry_fullExit_bypassesOrdinaryLimits() public {
        _freezeApr();
        for (uint256 i; i < 3; ++i) {
            if (i != 0) vm.warp(block.timestamp + 1 days);
            _supply(i, 100e18);
            _liquidity(i, 40e18);
            yields.markRiskExit(address(this), ids[i]);
            uint256 shares = i == 0 ? 40e8 : 40e18;
            _withdraw(i, shares);
            assertTrue(yields.exiting(address(this), ids[i]));
            assertGt(IERC20(markets[i].receipt).balanceOf(address(this)), 0);
            _liquidity(i, 1_000_000e18);
            uint256 minShares = yields.quoteSupply(ids[i], address(this), 50e18);
            vm.expectRevert(AtpYieldRegistry.AdmissionClosed.selector);
            executor.executeSupply(address(this), ids[i], 50e18, minShares, block.timestamp);
            _withdraw(i, IERC20(markets[i].receipt).balanceOf(address(this)));
            assertFalse(yields.exiting(address(this), ids[i]));
            assertEq(yields.totalUnits(ids[i]), 0);
        }
    }

    function test_allProtocols_withdrawMinZeroOrBelowQuote_reverts_andMinimumEqualPasses() public {
        _freezeApr();
        for (uint256 i; i < 3; ++i) {
            if (i != 0) vm.warp(block.timestamp + 1 days);
            _supply(i, 50e18);
            uint256 shares = IERC20(markets[i].receipt).balanceOf(address(this));
            vm.expectRevert(AtpExecutor.ZeroAmount.selector);
            executor.executeWithdraw(address(this), ids[i], shares, 0, block.timestamp);
            uint256 quote = yields.quoteWithdraw(ids[i], shares);
            uint256 floor = quote * 9_990 / 10_000;
            vm.expectRevert(abi.encodeWithSelector(AtpExecutor.YieldMinimum.selector, floor - 1, floor));
            executor.executeWithdraw(address(this), ids[i], shares, floor - 1, block.timestamp);
            _withdraw(i, shares);
        }
    }

    function test_configurationChanged_failsClosed_butExitStillWorks() public {
        _freezeApr();
        _supply(1, 100e18);
        lista.setFee(1e16);
        uint256 minShares = yields.quoteSupply(ids[1], address(this), 50e18);
        vm.warp(block.timestamp + 1 days);
        vm.expectRevert(AtpYieldRegistry.AdmissionClosed.selector);
        executor.executeSupply(address(this), ids[1], 50e18, minShares, block.timestamp);
        lista.setExitFeeBps(100);
        // The net redeem preview, rather than the gross convertToAssets, is the owner's output bound.
        uint256 shares = lista.balanceOf(address(this));
        uint256 quote = yields.quoteWithdraw(ids[1], shares);
        assertLt(quote, lista.convertToAssets(shares));
        _withdraw(1, shares);
    }

    function test_reenrollment_requiresFreshConsent() public {
        address[] memory assets = new address[](1);
        assets[0] = address(asset);
        uint16[] memory weights = new uint16[](1);
        weights[0] = 10_000;
        registry.publishVersion(strategy, assets, weights, keccak256("new"), 0);
        registry.enroll(address(this), strategy);
        uint256 quote = yields.quoteSupply(ids[0], address(this), 100e18);
        vm.expectRevert(AtpYieldRegistry.ConsentRequired.selector);
        executor.executeSupply(address(this), ids[0], 100e18, quote, block.timestamp);
    }

    function test_deadlineEquality_andOneSecondExpired() public {
        uint256 quote = yields.quoteSupply(ids[0], address(this), 100e18);
        vm.expectRevert(AtpExecutor.DeadlineExpired.selector);
        executor.executeSupply(address(this), ids[0], 100e18, quote, block.timestamp - 1);
        executor.executeSupply(address(this), ids[0], 100e18, quote, block.timestamp);
    }

    function test_mockAddressesRejectedOnMainnetProfile() public {
        vm.chainId(56);
        AtpYieldRegistry mainnet = new AtpYieldRegistry(registry, address(executor));
        Y.Market memory m = markets[0];
        m.chainId = 56;
        vm.expectRevert(YieldReader.InvalidMarket.selector);
        mainnet.registerMarket(bytes32(uint256(10)), m);
    }

    function test_listaEightDecimalUnderlying_has18DecimalShares() public {
        TestnetToken doge = new TestnetToken("Dogecoin", "DOGE", 8, address(this));
        MockLista vault = new MockLista(doge, address(this), 1);
        assertEq(vault.decimals(), 18);
    }

    function test_venusSixDecimalUnderlying_mintsEightDecimalReceipts() public {
        TestnetToken six = new TestnetToken("Six decimals", "SIX", 6, address(this));
        MockVenus market = new MockVenus(six, address(this), 1);
        six.mint(address(this), 10e6);
        six.approve(address(market), 10e6);
        assertEq(market.mint(10e6), 0);
        assertEq(market.balanceOf(address(this)), 10e8);
        assertEq(market.redeem(10e8), 0);
        assertEq(six.balanceOf(address(this)), 10e6);
    }

    function test_venusExposesComptrollerSupplyCapGetter() public view {
        (bool ok, bytes memory data) =
            address(venus).staticcall(abi.encodeWithSignature("supplyCaps(address)", address(venus)));
        assertTrue(ok, "Compound v2 cap getter must exist");
        assertEq(abi.decode(data, (uint256)), 0, "zero means uncapped");
    }

    function test_protocolSupplyCaps_equalAccepted_thenExhausted_butExitUnaffected() public {
        _freezeApr();
        for (uint256 i; i < 3; ++i) {
            if (i != 0) vm.warp(block.timestamp + 1 days);
            if (i == 0) venus.setSupplyCap(1_000_050e18);
            else if (i == 1) lista.setSupplyCap(1_000_050e18);
            else aave.setSupplyCap(1_000_050);
            if (i == 1) lista.accrue();
            bytes32 config = new YieldReaderHarness().health(markets[i]).configuration;
            yields.acknowledgeConfiguration(ids[i], config);
            _supply(i, 50e18);
            uint256 minimum = yields.quoteSupply(ids[i], OTHER, 50e18);
            vm.expectRevert(abi.encodeWithSelector(AtpYieldRegistry.SupplyCapExceeded.selector, 50e18, 0));
            vm.prank(OTHER);
            executor.executeSupply(OTHER, ids[i], 50e18, minimum, block.timestamp);
            _withdraw(i, IERC20(markets[i].receipt).balanceOf(address(this)));
            assertEq(yields.totalUnits(ids[i]), 0);
        }
    }

    function test_protocolCapIncludesAllInFlightReservations_equalAndOneRawOver() public {
        _freezeApr();
        venus.setSupplyCap(1_000_100e18);
        bytes32 config = new YieldReaderHarness().health(markets[0]).configuration;
        yields.acknowledgeConfiguration(ids[0], config);
        _supply(0, 100e18);
        vm.expectRevert(abi.encodeWithSelector(AtpYieldRegistry.SupplyCapExceeded.selector, 1, 0));
        vm.prank(address(executor));
        yields.beforeSupply(OTHER, ids[0], 1);
    }

    function test_senderTaxCannotDebitMoreThanTheSupplyAmount() public {
        SenderTaxAsset taxed = new SenderTaxAsset();
        MockVenus v = new MockVenus(taxed, address(this), 0);
        taxed.setMinter(address(v), true);
        taxed.mint(address(this), 1_001_000e18);
        taxed.approve(address(v), 1_000_000e18);
        v.mint(1_000_000e18);
        v.transfer(address(0xB0), v.balanceOf(address(this)));
        AtpExecutor fresh = new AtpExecutor(
            registry,
            new PricedRouter(),
            new PricedOracle(address(taxed)),
            address(executor.permit2()),
            address(0xFEE),
            address(taxed),
            10_000,
            0
        );
        AtpYieldRegistry freshYields = fresh.yieldRegistry();
        Y.Market memory m = markets[0];
        m.asset = address(taxed);
        m.receipt = address(v);
        m.target = address(v);
        m.riskSource = address(v);
        m.configuration = new YieldReaderHarness().health(m).configuration;
        freshYields.registerMarket(ids[0], m);
        address[] memory assets = new address[](1);
        assets[0] = address(taxed);
        uint16[] memory weights = new uint16[](1);
        weights[0] = 10_000;
        registry.publishVersion(strategy, assets, weights, keccak256("tax test"), 0);
        registry.enroll(address(this), strategy);
        freshYields.setYieldPolicy(ids[0], 100e18, true);
        taxed.approve(address(fresh), 100e18);
        taxed.setTaxed(address(this));
        uint256 minimum = freshYields.quoteSupply(ids[0], address(this), 100e18);
        vm.expectRevert(YieldActions.InexactTransfer.selector);
        fresh.executeSupply(address(this), ids[0], 100e18, minimum, block.timestamp);
        assertEq(taxed.balanceOf(address(this)), 1_000e18);
    }

    function test_withdrawCannotDebitExtraReceiptShares() public {
        SenderTaxReceipt receipt = new SenderTaxReceipt(asset);
        asset.approve(address(receipt), 1_000_000e18);
        assertEq(receipt.mint(1_000_000e18), 0);
        receipt.transfer(address(0xB0), receipt.balanceOf(address(this)));
        Y.Market memory m = markets[0];
        m.target = address(receipt);
        m.receipt = address(receipt);
        m.riskSource = address(receipt);
        m.configuration = new YieldReaderHarness().health(m).configuration;
        bytes32 id = keccak256("sender-tax-receipt");
        yields.registerMarket(id, m);
        yields.setYieldPolicy(id, 100e18, true);
        receipt.approve(address(executor), type(uint256).max);
        executor.executeSupply(
            address(this), id, 100e18, yields.quoteSupply(id, address(this), 100e18), block.timestamp
        );
        uint256 shares = receipt.balanceOf(address(this));
        uint256 beforeAssets = asset.balanceOf(address(this));
        uint256 minimum = yields.quoteWithdraw(id, shares / 2);
        vm.expectRevert(YieldActions.InexactTransfer.selector);
        executor.executeWithdraw(address(this), id, shares / 2, minimum, block.timestamp);
        assertEq(receipt.balanceOf(address(this)), shares);
        assertEq(asset.balanceOf(address(this)), beforeAssets);
        assertEq(yields.totalUnits(id), shares);
    }

    function test_aaveReserveReportsAssetDecimalsAndSimulatedLiquidityRate() public view {
        MockAavePool.ReserveData memory reserve = aave.getReserveData(address(asset));
        assertEq((reserve.configuration >> 48) & 255, asset.decimals());
        assertEq(reserve.currentLiquidityRate, 300 * 1e27 / 10_000);
    }

    function test_listaPerformanceFeeMintsActualFeeShares() public {
        uint256 principal = lista.totalAssets();
        uint256 shares = lista.totalSupply();
        lista.setFee(1e17);
        vm.warp(block.timestamp + 365 days);
        uint256 gross = lista.totalAssets();
        uint256 feeAssets = (gross - principal) / 10;
        uint256 expected = feeAssets * (shares + 1) / (gross - feeAssets + 1);
        assertGt(expected, 0);
        lista.deposit(1e18, OTHER);
        assertEq(lista.balanceOf(address(this)), expected);
    }

    function test_highUtilization_stickyExitUntilFullRedemption() public {
        _freezeApr();
        _supply(0, 100e18);
        venus.setLiquidity(100_010e18); // exactly 90% utilized before any CRE8 redemption
        yields.markRiskExit(address(this), ids[0]);
        assertTrue(yields.exiting(address(this), ids[0]));
        venus.setLiquidity(1_000_100e18);
        vm.warp(block.timestamp + 1 days);
        uint256 quote = yields.quoteSupply(ids[0], address(this), 50e18);
        vm.expectRevert(AtpYieldRegistry.AdmissionClosed.selector);
        executor.executeSupply(address(this), ids[0], 50e18, quote, block.timestamp);
        _withdraw(0, venus.balanceOf(address(this)));
        assertFalse(yields.exiting(address(this), ids[0]));
    }

    function test_multiVault_sharedCoreCash_isNotCountedTwice() public {
        _freezeApr();
        AdversarialLista other = new AdversarialLista(asset, address(this), 0);
        asset.setMinter(address(other), true);
        asset.approve(address(other), type(uint256).max);
        other.deposit(1_000_000e18, address(0xB0));
        other.setRiskCore(address(lista));
        Y.Market memory m = markets[1];
        m.target = address(other);
        m.receipt = address(other);
        m.configuration = new YieldReaderHarness().health(m).configuration;
        bytes32 id = bytes32(uint256(10));
        yields.registerMarket(id, m);
        yields.setYieldPolicy(id, 20_000e18, true);
        _supply(1, 9_000e18);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        executor.executeSupply(
            address(this), id, 999e18, yields.quoteSupply(id, address(this), 999e18), block.timestamp
        );
        uint256 exposure = new YieldReaderHarness().exposure(markets[1], yields.totalUnits(ids[1]))
            + new YieldReaderHarness().exposure(m, yields.totalUnits(id));
        lista.accrue();
        uint256 limit = new YieldReaderHarness().health(m).supply / 100;
        assertLe(exposure, limit);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.expectRevert(abi.encodeWithSelector(AtpYieldRegistry.CapacityExceeded.selector, limit + 1, limit));
        vm.prank(address(executor));
        yields.beforeSupply(address(this), id, limit - exposure + 1);
    }

    function test_reentrantProtocol_supplyAndWithdraw_areRejected() public {
        ReentrantVenus v = new ReentrantVenus(asset, executor);
        asset.setMinter(address(v), true);
        asset.approve(address(v), type(uint256).max);
        v.mint(1_000_000e18);
        v.transfer(address(0xB0), v.balanceOf(address(this)));
        Y.Market memory m = markets[0];
        m.target = address(v);
        m.receipt = address(v);
        m.riskSource = address(v);
        m.configuration = new YieldReaderHarness().health(m).configuration;
        bytes32 id = bytes32(uint256(99));
        yields.registerMarket(id, m);
        yields.setYieldPolicy(id, 1_000e18, true);
        uint256 quote = yields.quoteSupply(id, address(this), 100e18);
        executor.executeSupply(address(this), id, 100e18, quote, block.timestamp);
        assertTrue(v.attempted());
        v.approve(address(executor), type(uint256).max);
        uint256 shares = v.balanceOf(address(this));
        uint256 assets = yields.quoteWithdraw(id, shares);
        executor.executeWithdraw(address(this), id, shares, assets, block.timestamp);
        assertEq(v.balanceOf(address(this)), 0);
    }

    function testFuzz_reservationCap(uint256 amount) public {
        amount = bound(amount, 1, 20_000e18);
        if (amount > 10_000e18) {
            vm.expectRevert(
                abi.encodeWithSelector(AtpYieldRegistry.CapacityExceeded.selector, amount, 10_000e18)
            );
        }
        vm.prank(address(executor));
        yields.beforeSupply(address(this), ids[0], amount);
        if (amount <= 10_000e18) {
            assertEq(yields.totalUnits(ids[0]), 0, "before hook does not invent receipts");
            assertEq(yields.lastSupply(address(this), address(asset)), block.timestamp);
        }
    }

    function test_rateLossAndJump_stopValuation_untilOwnerAcknowledges() public {
        _supply(0, 100e18);
        uint256 original = venus.exchangeRateStored();
        venus.setExchangeRate(original / 2);
        assertEq(yields.receiptAssets(ids[0], address(this)), 50e18);
        assertGt(executor.previewAccountValue(address(this)), 0);
        vm.expectRevert(AtpYieldRegistry.Unauthorized.selector);
        vm.prank(OPERATOR);
        yields.acknowledgeRate(ids[0]);
        yields.acknowledgeRate(ids[0]);
        venus.setExchangeRate(original * 2);
        assertEq(yields.receiptAssets(ids[0], address(this)), 50e18);
        assertGt(executor.previewAccountValue(address(this)), 0);
        vm.expectRevert(AtpYieldRegistry.UnacknowledgedRate.selector);
        yields.quoteSupply(ids[0], address(this), 50e18);
    }

    function test_listaMaxRedeemRounding_doesNotLockExactExit() public {
        vm.warp(block.timestamp + 1 days);
        _supply(1, 100e18);
        uint256 shares = lista.balanceOf(address(this));
        assertLt(lista.maxRedeem(address(this)), shares);
        _withdraw(1, shares);
        assertEq(lista.balanceOf(address(this)), 0);
    }

    function test_staleAndFutureMarketData_rejected_exact60SecondsAccepted() public {
        bytes memory selector = abi.encodeWithSignature("market(bytes32)", lista.MARKET());
        MoolahMarket memory state =
            MoolahMarket(1_000_000e18, 1_000_000e18, 0, 0, uint128(block.timestamp - 61), 0);
        uint256 quote = yields.quoteSupply(ids[1], address(this), 100e18);
        vm.mockCall(address(lista), selector, abi.encode(state));
        vm.expectRevert(YieldReader.UnsafeMarket.selector);
        executor.executeSupply(address(this), ids[1], 100e18, quote, block.timestamp);
        state.lastUpdate = uint128(block.timestamp + 1);
        vm.mockCall(address(lista), selector, abi.encode(state));
        vm.expectRevert(YieldReader.UnsafeMarket.selector);
        executor.executeSupply(address(this), ids[1], 100e18, quote, block.timestamp);
        state.lastUpdate = uint128(block.timestamp - 60);
        vm.mockCall(address(lista), selector, abi.encode(state));
        executor.executeSupply(address(this), ids[1], 100e18, quote, block.timestamp);
        assertGt(lista.balanceOf(address(this)), 0);
    }

    function test_missingRiskRead_stopsSupply_butDoesNotLockBackedExit() public {
        _supply(1, 100e18);
        vm.mockCallRevert(
            address(lista),
            abi.encodeWithSignature("paused()"),
            abi.encodeWithSignature("Error(string)", "risk read failed")
        );
        vm.warp(block.timestamp + 1 days);
        uint256 quote = yields.quoteSupply(ids[1], address(this), 50e18);
        vm.expectRevert(bytes("risk read failed"));
        executor.executeSupply(address(this), ids[1], 50e18, quote, block.timestamp);
        _withdraw(1, lista.balanceOf(address(this)));
        assertEq(lista.balanceOf(address(this)), 0);
    }

    function test_emptyMarket_hasNoBootstrapExemption() public {
        MockVenus empty = new MockVenus(asset, address(this), 500);
        Y.Market memory m = markets[0];
        m.target = address(empty);
        m.receipt = address(empty);
        m.riskSource = address(empty);
        YieldReaderHarness reader = new YieldReaderHarness();
        vm.expectRevert(YieldReader.UnsafeMarket.selector);
        reader.health(m);
    }

    function test_mockControls_ownerOnly_APRBounded_andWrongChainRejected() public {
        vm.expectRevert(bytes("yield mock: owner only"));
        vm.prank(OTHER);
        venus.setAprBps(100);
        vm.expectRevert(bytes("yield mock: owner only"));
        vm.prank(OTHER);
        lista.setLiquidity(0);
        vm.expectRevert(bytes("yield mock: owner only"));
        vm.prank(OTHER);
        aave.setAprBps(100);
        vm.expectRevert(bytes("APR cap"));
        venus.setAprBps(10_001);
        vm.expectRevert(bytes("APR cap"));
        lista.setAprBps(10_001);
        vm.expectRevert(bytes("APR cap"));
        aave.setAprBps(10_001);
        venus.setAprBps(10_000);
        lista.setAprBps(10_000);
        aave.setAprBps(10_000);
        vm.chainId(56);
        vm.expectRevert(bytes("yield mock: chain 97 only"));
        new MockVenus(asset, address(this), 500);
        vm.expectRevert(bytes("yield mock: chain 97 only"));
        new MockLista(asset, address(this), 300);
        vm.expectRevert(bytes("yield mock: chain 97 only"));
        new MockAavePool(asset, address(this), 300);
    }

    function test_configurationApproval_ownerOnly_preservesExposureAndReservations() public {
        _freezeApr();
        _supply(1, 100e18);
        uint256 tracked = yields.totalUnits(ids[1]);
        lista.setFee(1e16);
        bytes32 config = new YieldReaderHarness().health(markets[1]).configuration;
        assertGt(executor.previewAccountValue(address(this)), 0);
        vm.expectRevert(AtpYieldRegistry.Unauthorized.selector);
        vm.prank(OPERATOR);
        yields.acknowledgeConfiguration(ids[1], config);
        yields.acknowledgeConfiguration(ids[1], config);
        assertEq(yields.totalUnits(ids[1]), tracked);
        assertGt(executor.previewAccountValue(address(this)), 0);
    }

    function test_registeredYieldProtocolsCannotBecomeSwapVenues_orSpenders() public {
        for (uint256 i; i < 3; ++i) {
            vm.expectRevert(abi.encodeWithSelector(AtpExecutor.BadVenue.selector, markets[i].target));
            executor.setVenue(markets[i].target, AtpExecutor.VenueKind.ERC20_APPROVE, markets[i].target);
        }
        vm.expectRevert(abi.encodeWithSelector(AtpExecutor.BadVenue.selector, address(yields)));
        executor.setVenue(address(yields), AtpExecutor.VenueKind.ERC20_APPROVE, address(yields));
        address swapRouter = address(executor.universalRouter());
        vm.expectRevert(abi.encodeWithSelector(AtpExecutor.BadVenue.selector, address(aave)));
        executor.setVenue(swapRouter, AtpExecutor.VenueKind.ERC20_APPROVE, address(aave));
    }

    function test_venueConfiguredBeforeMarketRegistration_isRejectedAtExecution() public {
        AtpExecutor fresh = new AtpExecutor(
            registry,
            IUniversalRouter(address(aave)),
            executor.oracle(),
            address(executor.permit2()),
            address(0xFEE),
            address(asset),
            10_000,
            0
        );
        AtpYieldRegistry freshYields = fresh.yieldRegistry();
        freshYields.registerMarket(ids[2], markets[2]);
        TestnetToken otherAsset = new TestnetToken("Other", "OTHER", 18, address(this));
        address[] memory assets = new address[](2);
        assets[0] = address(asset);
        assets[1] = address(otherAsset);
        uint16[] memory weights = new uint16[](2);
        weights[0] = 5_000;
        weights[1] = 5_000;
        registry.publishVersion(strategy, assets, weights, keccak256("new"), 0);
        registry.enroll(address(this), strategy);
        AtpExecutor.SwapStep[] memory steps = new AtpExecutor.SwapStep[](1);
        steps[0] = AtpExecutor.SwapStep(address(asset), address(otherAsset), 1e18, 1, address(aave), hex"");
        vm.expectRevert(abi.encodeWithSelector(AtpExecutor.BadVenue.selector, address(aave)));
        fresh.executeRebalance(address(this), steps, block.timestamp);
    }
}
