// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { AtpPerfFeeLedger as Ledger } from "../../../src/atp/AtpPerfFeeLedger.sol";
import { AtpRegistry } from "../../../src/atp/AtpRegistry.sol";
import { AtpMultiPoolOracle } from "../../../src/atp/AtpMultiPoolOracle.sol";
import { AtpYieldRegistry } from "../../../src/atp/yield/AtpYieldRegistry.sol";
import { YieldReader } from "../../../src/atp/yield/YieldReader.sol";
import { YieldTypes as Y } from "../../../src/atp/yield/YieldTypes.sol";
import { TestnetToken } from "../../../src/testnet/TestnetToken.sol";
import { MockVenus } from "../../../src/testnet/yield/MockVenus.sol";
import { MockLista } from "../../../src/testnet/yield/MockLista.sol";
import { MockPancakeV3Pool } from "../PancakeV3TwapOracle.t.sol";
import { MockAavePool } from "../../../src/testnet/yield/MockAavePool.sol";

/// @notice Real yield registry and all three chain-97 protocol adapters; no mocked NAV return values.
contract AtpPerfFeeLedgerYieldTest is Test {
    Ledger internal ledger;
    AtpRegistry internal registry;
    AtpMultiPoolOracle internal oracle;
    AtpYieldRegistry internal yields;
    TestnetToken internal cash;
    MockVenus internal venus;
    MockLista internal lista;
    MockAavePool internal aave;
    address internal constant PAYER = address(0xCA5);
    address internal constant RECIPIENT = address(0xD8);
    Y.Market[3] internal markets;

    function setUp() public {
        vm.chainId(97);
        vm.warp(100 days);
        cash = new TestnetToken("Cash", "CASH", 18, address(this));
        registry = new AtpRegistry();
        registry.setNumeraire(address(cash));
        yields = new AtpYieldRegistry(registry, address(this));
        oracle = new AtpMultiPoolOracle(address(cash));
        ledger = new Ledger(registry, oracle, yields, address(0xFEE));
        address[] memory assets = new address[](1);
        assets[0] = address(cash);
        uint16[] memory weights = new uint16[](1);
        weights[0] = 10_000;
        uint256 strategy = registry.registerStrategy("yield", "yield", true);
        registry.publishSettingsVersion(strategy, assets, weights, bytes32(0), bytes32(0), 2_000, 0);
        vm.warp(registry.version(strategy, 1).activeAt);
        registry.enroll(address(this), strategy, 1);
        ledger.start();
        venus = new MockVenus(cash, address(this), 500);
        lista = new MockLista(cash, address(this), 500);
        aave = new MockAavePool(cash, address(this), 500);
        cash.setMinter(address(venus), true);
        cash.setMinter(address(lista), true);
        cash.setMinter(aave.receipt(), true);
        cash.mint(address(this), 3_000_000e18);
        cash.approve(address(venus), type(uint256).max);
        cash.approve(address(lista), type(uint256).max);
        cash.approve(address(aave), type(uint256).max);
        venus.mint(1_000_000e18);
        lista.deposit(1_000_000e18, address(this));
        aave.supply(address(cash), 1_000_000e18, address(this), 0);
        IERC20(address(venus)).transfer(PAYER, venus.balanceOf(address(this)));
        IERC20(address(lista)).transfer(PAYER, lista.balanceOf(address(this)));
        IERC20(aave.receipt()).transfer(PAYER, IERC20(aave.receipt()).balanceOf(address(this)));
        cash.mint(PAYER, 1_000e18);
        vm.startPrank(PAYER);
        cash.approve(address(ledger), 1_000e18);
        ledger.deposit(address(this), 1_000e18);
        vm.stopPrank();
        cash.approve(address(ledger), type(uint256).max);
        for (uint256 i; i < 3; ++i) {
            address target = i == 0 ? address(venus) : i == 1 ? address(lista) : address(aave);
            address receipt = i == 2 ? aave.receipt() : target;
            markets[i] = Y.Market(
                97,
                Y.Kind(i + 1),
                address(cash),
                receipt,
                target,
                target,
                bytes32(uint256(1)),
                i == 0 ? 1e27 : 1e17,
                i == 0 ? 1e30 : 1e20,
                true,
                false
            );
            markets[i].configuration = YieldReader.health(markets[i]).configuration;
            yields.registerMarket(bytes32(i + 1), markets[i]);
            yields.setYieldPolicy(bytes32(i + 1), 1_000e18, true);
        }
    }

    function _supply(uint256 i) internal {
        vm.warp(block.timestamp + 1 days);
        yields.beforeSupply(address(this), bytes32(i + 1), 100e18);
        uint256 beforeUnits = yields.units(bytes32(i + 1), address(this));
        if (i == 0) venus.mint(100e18);
        else if (i == 1) lista.deposit(100e18, address(this));
        else aave.supply(address(cash), 100e18, address(this), 0);
        // Called from this fixture as the registered executor, against real receipts.
        yields.recordSupply(address(this), bytes32(i + 1), beforeUnits);
    }

    function test_allThreeReceiptsCountOnce_evenWhenRetiredOrPaused() public {
        for (uint256 i; i < 3; ++i) {
            _supply(i);
        }
        uint256 nav = cash.balanceOf(address(this));
        for (uint256 i; i < 3; ++i) {
            nav += yields.receiptAssets(bytes32(i + 1), address(this));
            yields.setMarketSupply(bytes32(i + 1), false, true);
        }
        yields.setSupplyPaused(true);
        assertEq(ledger.accountValue(address(this)), nav);
        assertGe(nav, 1_000e18 - 3);
        assertLt(nav, 1_001e18);
    }

    function test_accruedYieldRaisesNavAndWithdrawalProfit() public {
        _supply(0);
        vm.warp(block.timestamp + 30 days);
        venus.accrueInterest();
        uint256 nav = ledger.accountValue(address(this));
        assertGt(nav, 1_000e18);
        Ledger.Withdrawal memory w = ledger.withdraw(100e18, RECIPIENT, 0, block.timestamp);
        assertGt(w.profit, 0);
        assertEq(w.value, nav);
        assertEq(w.fee, w.profit / 5);
    }

    function test_unacknowledgedDonationJumpCannotInflateYieldValue() public {
        _supply(1);
        uint256 beforeNav = ledger.accountValue(address(this));
        cash.mint(address(lista), 1_000_000e18);
        assertLe(ledger.accountValue(address(this)), beforeNav);
    }

    function test_brokenReceiptIdentityFailsClosed_andDirectCashExitStillWorks() public {
        _supply(0);
        vm.mockCall(address(venus), abi.encodeWithSignature("implementation()"), abi.encode(address(lista)));
        vm.expectRevert(AtpYieldRegistry.AdmissionClosed.selector);
        ledger.withdraw(100e18, RECIPIENT, 0, block.timestamp);
        cash.transfer(RECIPIENT, cash.balanceOf(address(this)));
        assertEq(cash.balanceOf(RECIPIENT), 900e18);
    }

    function test_nonNumeraireYieldUsesConservativeOracle() public {
        // Same receipts now have an underlying without an oracle in this test's router: no zero fallback.
        _supply(0);
        Y.Market memory m = markets[0];
        m.asset = address(lista);
        vm.mockCall(address(yields), abi.encodeCall(yields.market, (bytes32(uint256(1)))), abi.encode(m));
        vm.expectRevert(abi.encodeWithSelector(AtpMultiPoolOracle.OracleNotSet.selector, address(lista)));
        ledger.accountValue(address(this));
    }

    function test_nonNumeraireReceiptCountsUnderlyingAtLowerMean() public {
        TestnetToken stock = new TestnetToken("Stock", "STOCK", 18, address(this));
        MockVenus v = new MockVenus(stock, address(this), 0);
        stock.setMinter(address(v), true);
        stock.mint(address(this), 1_000_100e18);
        stock.approve(address(v), type(uint256).max);
        v.mint(1_000_000e18);
        v.transfer(PAYER, v.balanceOf(address(this)));
        MockPancakeV3Pool pair = new MockPancakeV3Pool(address(stock), address(cash));
        pair.setMeanTick(1_000, 30 minutes);
        pair.setRecentMeanTick(0);
        oracle.setOracle(address(stock), address(pair), 30 minutes, 50, 1 hours);
        AtpRegistry.Enrollment memory e = registry.enrollments(address(this));
        address[] memory assets = new address[](2);
        assets[0] = address(cash);
        assets[1] = address(stock);
        uint16[] memory weights = new uint16[](2);
        weights[0] = 5_000;
        weights[1] = 5_000;
        vm.warp(uint256(registry.lastPublishedAt(e.strategyId)) + registry.PUBLICATION_INTERVAL());
        registry.publishSettingsVersion(e.strategyId, assets, weights, bytes32(0), bytes32(0), 2_000, 0);
        vm.warp(registry.version(e.strategyId, 2).activeAt);
        registry.enroll(address(this), e.strategyId, 2);
        Y.Market memory m = Y.Market(
            97,
            Y.Kind.VENUS,
            address(stock),
            address(v),
            address(v),
            address(v),
            bytes32(0),
            1e27,
            1e30,
            true,
            false
        );
        m.configuration = YieldReader.health(m).configuration;
        bytes32 id = keccak256("stock-yield");
        yields.registerMarket(id, m);
        yields.setYieldPolicy(id, 1_000e18, true);
        yields.beforeSupply(address(this), id, 100e18);
        uint256 beforeUnits = yields.units(id, address(this));
        v.mint(100e18);
        yields.recordSupply(address(this), id, beforeUnits);
        assertEq(stock.balanceOf(address(this)), 0);
        assertEq(ledger.accountValue(address(this)), 1_100e18);
        Ledger.Withdrawal memory w = ledger.withdraw(100e18, RECIPIENT, 0, block.timestamp);
        assertEq(w.profit, uint256(100e18) * 100e18 / 1_100e18);
    }

    function test_zeroReceiptClaimContributesZeroNav() public {
        _supply(0);
        vm.mockCall(
            address(yields),
            abi.encodeCall(yields.receiptAssets, (bytes32(uint256(1)), address(this))),
            abi.encode(uint256(0))
        );
        assertEq(ledger.accountValue(address(this)), cash.balanceOf(address(this)));
        Ledger.Withdrawal memory w = ledger.withdraw(100e18, RECIPIENT, 100e18, block.timestamp);
        assertEq(w.fee, 0);
        assertEq(w.remainingPrincipal, (uint256(1_000e18) * 8 + 8) / 9);
        assertEq(cash.balanceOf(RECIPIENT), 100e18);
    }
}

/// @notice ThirdRound.t.sol reviewer fixture: a real partial Lista redemption leaves tracked
/// receipt dust whose valid claim floors to zero in a six-decimal underlying.
contract AtpPerfFeeLedgerReceiptDustTest is Test {
    Ledger internal ledger;
    AtpYieldRegistry internal yields;
    TestnetToken internal cash;
    TestnetToken internal underlying;
    MockLista internal vault;
    bytes32 internal constant MARKET = keccak256("six-decimal underlying");
    address internal constant PAYER = address(0xCA5);
    address internal constant RECIPIENT = address(0xD8);

    function setUp() public {
        vm.chainId(97);
        vm.warp(100 days);
        cash = new TestnetToken("review cash", "USDT", 18, address(this));
        underlying = new TestnetToken("six-decimal asset", "USD6", 6, address(this));
        AtpRegistry registry = new AtpRegistry();
        registry.setNumeraire(address(cash));
        AtpMultiPoolOracle oracle = new AtpMultiPoolOracle(address(cash));
        yields = new AtpYieldRegistry(registry, address(this));
        ledger = new Ledger(registry, oracle, yields, address(0xFEE));
        uint256 strategy = registry.registerStrategy("receipt", "receipt", true);
        address[] memory assets = new address[](2);
        assets[0] = address(cash);
        assets[1] = address(underlying);
        uint16[] memory weights = new uint16[](2);
        weights[0] = 5_000;
        weights[1] = 5_000;
        registry.publishSettingsVersion(strategy, assets, weights, 0, 0, 2_000, 0);
        vm.warp(registry.version(strategy, 1).activeAt);
        registry.enroll(address(this), strategy, 1);
        ledger.start();
        cash.mint(PAYER, 100e18);
        vm.startPrank(PAYER);
        cash.approve(address(ledger), 100e18);
        ledger.deposit(address(this), 100e18);
        vm.stopPrank();
        cash.approve(address(ledger), type(uint256).max);
        vault = new MockLista(underlying, address(this), 0);
        underlying.mint(address(this), 1_000_000e6);
        underlying.approve(address(vault), type(uint256).max);
        vault.deposit(1_000_000e6, address(this));
        vault.transfer(PAYER, vault.balanceOf(address(this)));
        Y.Market memory m = Y.Market(
            97,
            Y.Kind.LISTA,
            address(underlying),
            address(vault),
            address(vault),
            address(vault),
            bytes32(0),
            1e5,
            1e7,
            true,
            false
        );
        m.configuration = YieldReader.health(m).configuration;
        yields.registerMarket(MARKET, m);
        yields.setYieldPolicy(MARKET, 100e6, true);
        underlying.mint(address(this), 100e6);
        yields.beforeSupply(address(this), MARKET, 100e6);
        uint256 beforeUnits = yields.units(MARKET, address(this));
        vault.deposit(100e6, address(this));
        yields.recordSupply(address(this), MARKET, beforeUnits);
        beforeUnits = yields.units(MARKET, address(this));
        uint256 trackedBefore = yields.accountUnits(address(this), MARKET);
        vault.redeem(beforeUnits - 1, address(this), address(this));
        yields.recordWithdraw(address(this), MARKET, beforeUnits, trackedBefore);
        underlying.transfer(PAYER, underlying.balanceOf(address(this)));
        assertEq(vault.balanceOf(address(this)), 1);
        assertEq(yields.accountUnits(address(this), MARKET), 1);
        assertEq(yields.accountMarkets(address(this)).length, 1);
        assertGt(YieldReader.rate(m), 0);
        assertEq(yields.receiptAssets(MARKET, address(this)), 0);
    }

    function test_spec_validReceiptClaimFloorZeroAllowsCashWithdrawal() public {
        assertEq(ledger.accountValue(address(this)), 100e18);
        Ledger.Withdrawal memory w = ledger.withdraw(50e18, RECIPIENT, 50e18, block.timestamp);
        assertEq(w.fee, 0);
        assertEq(w.remainingPrincipal, 50e18);
        assertEq(cash.balanceOf(RECIPIENT), 50e18);
        assertEq(vault.balanceOf(address(this)), 1);
        assertEq(yields.accountUnits(address(this), MARKET), 1);
    }

    function _assertUnchanged() internal view {
        (uint256 principal,,,) = ledger.accounts(address(this));
        assertEq(principal, 100e18);
        assertEq(cash.balanceOf(address(this)), 100e18);
        assertEq(cash.balanceOf(RECIPIENT), 0);
        assertEq(vault.balanceOf(address(this)), 1);
        assertEq(yields.accountUnits(address(this), MARKET), 1);
    }

    function test_zeroClaimStillChecksReceiptIdentity() public {
        vm.mockCall(address(vault), abi.encodeWithSignature("implementation()"), abi.encode(address(cash)));
        vm.expectRevert(AtpYieldRegistry.AdmissionClosed.selector);
        ledger.withdraw(50e18, RECIPIENT, 0, block.timestamp);
        _assertUnchanged();
    }

    function test_zeroClaimStillChecksRateAndBubblesSourceFailures() public {
        vm.mockCall(address(vault), abi.encodeCall(vault.convertToAssets, (1e18)), abi.encode(uint256(0)));
        vm.expectRevert(YieldReader.BadRate.selector);
        ledger.withdraw(50e18, RECIPIENT, 0, block.timestamp);
        _assertUnchanged();
        vm.clearMockedCalls();
        vm.mockCallRevert(address(vault), abi.encodeCall(vault.previewRedeem, (1)), "receipt unavailable");
        vm.expectRevert(bytes("receipt unavailable"));
        ledger.withdraw(50e18, RECIPIENT, 0, block.timestamp);
        _assertUnchanged();
        vm.clearMockedCalls();
        assertEq(ledger.withdraw(50e18, RECIPIENT, 50e18, block.timestamp).fee, 0);
    }

    function test_zeroReceiptBalanceAllowsFullCashExit() public {
        uint256 tracked = yields.accountUnits(address(this), MARKET);
        vault.redeem(1, address(this), address(this));
        yields.recordWithdraw(address(this), MARKET, 1, tracked);
        assertEq(yields.accountMarkets(address(this)).length, 0);
        assertEq(yields.accountUnits(address(this), MARKET), 0);
        assertEq(ledger.withdraw(100e18, RECIPIENT, 100e18, block.timestamp).fee, 0);
    }

    function test_oneUnderlyingUnitIsValuedAndStillRequiresOracle() public {
        // At the first raw underlying unit (1e12 receipt units), zero-claim handling must stop.
        assertEq(vault.convertToAssets(1e12 - 1), 0);
        assertEq(vault.convertToAssets(1e12), 1);
        vm.warp(block.timestamp + 1 days);
        underlying.mint(address(this), 1);
        yields.beforeSupply(address(this), MARKET, 1);
        uint256 beforeUnits = yields.units(MARKET, address(this));
        vault.deposit(1, address(this));
        yields.recordSupply(address(this), MARKET, beforeUnits);
        assertEq(vault.balanceOf(address(this)), 1e12);
        assertEq(yields.receiptAssets(MARKET, address(this)), 1);
        vm.expectRevert(abi.encodeWithSelector(AtpMultiPoolOracle.OracleNotSet.selector, address(underlying)));
        ledger.withdraw(50e18, RECIPIENT, 0, block.timestamp);
        (uint256 principal,,,) = ledger.accounts(address(this));
        assertEq(principal, 100e18);
        assertEq(cash.balanceOf(RECIPIENT), 0);
    }
}
