// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { AtpRegistry } from "../../src/atp/AtpRegistry.sol";
import { AtpExecutor } from "../../src/atp/AtpExecutor.sol";
import { AtpYieldRegistry } from "../../src/atp/yield/AtpYieldRegistry.sol";
import { YieldTypes as Y } from "../../src/atp/yield/YieldTypes.sol";
import { MoolahParams } from "../../src/atp/yield/YieldInterfaces.sol";
import { AtpBorrowExecutor } from "../../src/atp/borrow/AtpBorrowExecutor.sol";
import { AtpBorrowRegistry } from "../../src/atp/borrow/AtpBorrowRegistry.sol";
import { BorrowTypes as BT } from "../../src/atp/borrow/BorrowTypes.sol";
import { TestnetToken } from "../../src/testnet/TestnetToken.sol";
import { MockEarnVault } from "../../src/testnet/lending/MockEarnVault.sol";
import { MockLendingOracle } from "../../src/testnet/lending/MockLendingOracle.sol";
import { MockVenusComptroller } from "../../src/testnet/lending/MockVenusComptroller.sol";
import { MockVToken } from "../../src/testnet/lending/MockVToken.sol";
import { MockMoolah } from "../../src/testnet/lending/MockMoolah.sol";
import { TestnetAssets } from "../../script/testnet/TestnetAssets.sol";
import { TestnetBorrowBook as BB } from "../../script/testnet/TestnetBorrowBook.sol";
import { PricedOracle, PricedRouter } from "../atp/AtpExecutorBuyLimit.t.sol";
import { MockPermit2 } from "../atp/AtpExecutor.t.sol";
import { YieldHealthHarness } from "../atp/borrow/AtpBorrowBase.sol";

/// @notice #67: the chain 97 Strategy Earn market book. Static rules (EARN_UX §D, the 32-market registry cap,
/// rows 0-4 unchanged) and a local replay of what `DeployBorrowTestnet` configures for every row, with each
/// token's real testnet decimals: every row registers, gets min(class cap, F/2) / 2F/3, opens with a positive
/// carry, and borrows exactly up to its target LTV but not one raw unit more.
contract TestnetBorrowBookTest is Test {
    uint8 internal constant BORROW_ACTION = 2;
    address internal constant LENDER = address(0x1E2D);
    address internal constant OPERATOR = address(0x00FE);
    bytes32 internal constant VAULT_ID = bytes32(uint256(0xC1));
    uint256 internal constant REGISTRY_MAX_MARKETS = 32;

    AtpRegistry internal registry;
    AtpBorrowExecutor internal lend;
    AtpBorrowRegistry internal credit;
    TestnetToken internal usdt;
    MockLendingOracle internal oracle;
    MockVenusComptroller internal comptroller;
    MockVToken internal vUsdt;
    MockMoolah internal moolah;
    MockEarnVault internal vault;

    BB.Spec[] internal rows;
    TestnetToken[] internal tokens;
    bytes32[] internal ids;

    function setUp() public {
        vm.chainId(97);
        vm.warp(1_000_000);
        usdt = new TestnetToken("Test USDT", "USDT", 18, address(this));
        address permit = 0x31c2F6fcFf4F8759b3Bd5Bf0e1084A055615c768;
        vm.etch(permit, address(new MockPermit2()).code);
        registry = new AtpRegistry();
        registry.setOperator(OPERATOR);
        AtpExecutor core = new AtpExecutor(
            registry,
            new PricedRouter(),
            new PricedOracle(address(usdt)),
            permit,
            address(0xFEE),
            address(usdt),
            10_000,
            0.3e18
        );
        lend = new AtpBorrowExecutor(registry, address(core));
        credit = lend.borrowRegistry();
        registry.setNumeraire(address(usdt));

        oracle = new MockLendingOracle(address(this));
        oracle.setPrice(address(usdt), 1e8);
        comptroller = new MockVenusComptroller(address(this), address(oracle));
        vUsdt = new MockVToken(address(usdt), address(comptroller), address(this), BB.BORROW_APR_BPS, "USDT");
        comptroller.supportMarket(address(vUsdt));
        moolah = new MockMoolah(address(this));
        moolah.setRewardToken(address(usdt));
        usdt.setMinter(address(moolah), true);

        usdt.mint(LENDER, 100_000_000e18);
        vm.startPrank(LENDER);
        usdt.approve(address(vUsdt), type(uint256).max);
        usdt.approve(address(moolah), type(uint256).max);
        vUsdt.mint(BB.VENUS_SEED);
        vm.stopPrank();

        vault = new MockEarnVault(usdt, address(this), BB.VAULT_APR_BPS);
        vault.setIncentiveAprBps(BB.VAULT_INCENTIVE_BPS);
        usdt.setMinter(address(vault), true);
        vm.startPrank(LENDER);
        usdt.approve(address(vault), type(uint256).max);
        vault.deposit(BB.VAULT_SEED, LENDER);
        vm.stopPrank();
        Y.Market memory ym = Y.Market(
            97,
            Y.Kind.LISTA,
            address(usdt),
            address(vault),
            address(vault),
            address(vault),
            bytes32(0),
            0.5e18,
            2e18,
            false,
            false
        );
        ym.configuration = new YieldHealthHarness().health(ym).configuration;
        AtpYieldRegistry yields = core.yieldRegistry();
        yields.registerMarket(VAULT_ID, ym);

        BB.Spec[] memory specs = BB.specs();
        for (uint256 i; i < specs.length; ++i) {
            rows.push(specs[i]);
        }
    }

    // ---- static rules ----

    function test_book_fitsTheDeployedRegistry_withOneSlotFree() public view {
        assertEq(rows.length, BB.COUNT);
        assertEq(BB.COUNT, 31);
        assertLt(BB.COUNT, REGISTRY_MAX_MARKETS, "one registry slot stays free for replacing a market");
    }

    function test_book_firstFiveRowsAreTheDeployedMarkets() public view {
        // Market ids are derived from (kind, collateral): moving these rows would orphan the chain 97 markets.
        _row(0, "NVDAB", BT.Kind.VENUS, BT.Tier.STOCK, 0.6e18, 50);
        _row(1, "TSLAB", BT.Kind.VENUS, BT.Tier.STOCK, 0.6e18, 50);
        _row(2, "SPCXB", BT.Kind.VENUS, BT.Tier.STOCK, 0.5e18, 50);
        _row(3, "QQQB", BT.Kind.LISTA, BT.Tier.INDEX_LARGE_CAP, 0.7e18, 100);
        _row(4, "MSTRB", BT.Kind.LISTA, BT.Tier.CRYPTO_LINKED, 0.5e18, 100);
    }

    function test_book_symbolsAreUniqueTestnetAssets_andNewRowsAreLista() public view {
        for (uint256 i; i < rows.length; ++i) {
            assertGt(BB.priceE8(rows[i].symbol), 0, rows[i].symbol);
            for (uint256 j; j < i; ++j) {
                assertNotEq(
                    keccak256(bytes(rows[i].symbol)), keccak256(bytes(rows[j].symbol)), rows[i].symbol
                );
            }
            assertGt(rows[i].factor, 0, rows[i].symbol);
            assertLt(rows[i].factor, 1e18, rows[i].symbol);
            assertTrue(rows[i].tier != BT.Tier.NONE, rows[i].symbol);
            assertLe(rows[i].collateralIncentiveBps, 100, rows[i].symbol);
            if (i >= 5) assertTrue(rows[i].kind == BT.Kind.LISTA, rows[i].symbol);
        }
    }

    function test_book_leaveOutLeveragedVolatileAndSatellites() public view {
        string[9] memory absent =
            ["TQQQB", "SOXLB", "DOGE", "AMCB", "DJTB", "CYPHB", "PENGB", "MRVLB", "RDDTB"];
        for (uint256 a; a < absent.length; ++a) {
            for (uint256 i; i < rows.length; ++i) {
                assertNotEq(keccak256(bytes(rows[i].symbol)), keccak256(bytes(absent[a])), absent[a]);
            }
        }
    }

    function test_book_classes_followEarnUxD() public view {
        _tier("SPYB", BT.Tier.INDEX_LARGE_CAP, 0.7e18);
        _tier("EWYB", BT.Tier.INDEX_LARGE_CAP, 0.7e18);
        _tier("XAUt", BT.Tier.INDEX_LARGE_CAP, 0.7e18);
        _tier("AAPLB", BT.Tier.INDEX_LARGE_CAP, 0.6e18);
        _tier("GOOGLB", BT.Tier.INDEX_LARGE_CAP, 0.6e18);
        _tier("INTCB", BT.Tier.STOCK, 0.6e18);
        _tier("GMEB", BT.Tier.STOCK, 0.5e18);
        _tier("COINB", BT.Tier.CRYPTO_LINKED, 0.5e18);
        _tier("BMNRB", BT.Tier.CRYPTO_LINKED, 0.5e18);
        _tier("BNCB", BT.Tier.CRYPTO_LINKED, 0.5e18);
        _tier("BTCB", BT.Tier.CRYPTO_LINKED, 0.8e18);
        _tier("WBNB", BT.Tier.CRYPTO_LINKED, 0.8e18);
    }

    // ---- local replay of the deployment ----

    function test_everyRow_registers_withClassCapAndHalfFactor_andOpensWithPositiveCarry() public {
        _registerAll();
        assertEq(credit.marketCount(), BB.COUNT);
        for (uint256 i; i < rows.length; ++i) {
            bytes32 id = ids[i];
            uint256 cap = rows[i].tier == BT.Tier.INDEX_LARGE_CAP
                ? 0.35e18
                : rows[i].tier == BT.Tier.STOCK ? 0.3e18 : 0.2e18;
            uint256 target = Math.min(cap, rows[i].factor / 2);
            assertEq(credit.targetLtv(id), target, rows[i].symbol);
            assertLe(credit.targetLtv(id) * 2, rows[i].factor, rows[i].symbol);
            assertEq(credit.deleverageLtv(id), rows[i].factor * 2 / 3, rows[i].symbol);
            assertEq(credit.collateralMarket(address(tokens[i])), id, rows[i].symbol);
            BT.Status memory s = credit.status(id, address(0));
            assertEq(uint8(s.gate), uint8(BT.Gate.OPEN), rows[i].symbol);
            assertGt(s.vaultRate + s.vaultIncentiveRate + s.borrowIncentiveRate, s.borrowRate, rows[i].symbol);
        }
    }

    function test_registryCap_32ndMarketFits_33rdIsRefused() public {
        _registerAll();
        // The free slot.
        TestnetToken extra = new TestnetToken("ETH", "ETH", 18, address(this));
        oracle.setPrice(address(extra), 1_906e8);
        credit.registerMarket(keccak256("slot32"), _listaMarket(extra, 0.8e18, BT.Tier.CRYPTO_LINKED));
        assertEq(credit.marketCount(), REGISTRY_MAX_MARKETS);
        TestnetToken more = new TestnetToken("More", "MORE", 18, address(this));
        oracle.setPrice(address(more), 1e8);
        BT.Market memory m = _listaMarket(more, 0.6e18, BT.Tier.STOCK);
        vm.expectRevert(AtpBorrowRegistry.BadMarket.selector);
        credit.registerMarket(keccak256("slot33"), m);
    }

    function test_everyNewRow_borrowsExactlyToTarget_butNotOneRawMore() public {
        _registerAll();
        _enrollEverything();
        for (uint256 i = 5; i < rows.length; ++i) {
            bytes32 id = ids[i];
            TestnetToken token = tokens[i];
            // About 10,000 USD of the asset, in its own decimals.
            uint256 amount = 10_000e8 * 10 ** token.decimals() / BB.priceE8(rows[i].symbol);
            token.mint(address(this), amount);
            lend.executeSupplyCollateral(address(this), id, amount, block.timestamp);
            uint256 max = credit.health(id, address(this)).collateralValue * credit.targetLtv(id) / 1e18;
            assertGt(max, 1_000e18, rows[i].symbol);
            uint256 snap = vm.snapshotState();
            vm.expectPartialRevert(AtpBorrowExecutor.LtvTooHigh.selector);
            lend.executeBorrow(address(this), id, max + 1, block.timestamp);
            vm.revertToState(snap);
            lend.executeBorrow(address(this), id, max, block.timestamp);
            BT.Status memory s = credit.status(id, address(this));
            assertEq(s.ltv, credit.targetLtv(id), rows[i].symbol);
            assertEq(s.debt, max, rows[i].symbol);
            assertGe(s.vaultAssets + 1, max, rows[i].symbol);
            assertFalse(s.shouldDeleverage, rows[i].symbol);
        }
    }

    function test_newRow_deleveragesAtTwoThirdsOfLltv_notBefore() public {
        _registerAll();
        _enrollEverything();
        uint256 i = _index("XAUt"); // 6 decimals: value math must follow the token's decimals.
        bytes32 id = ids[i];
        TestnetToken token = tokens[i];
        uint256 amount = 10_000e8 * 10 ** token.decimals() / BB.priceE8("XAUt");
        token.mint(address(this), amount);
        lend.executeSupplyCollateral(address(this), id, amount, block.timestamp);
        uint256 max = credit.health(id, address(this)).collateralValue * credit.targetLtv(id) / 1e18;
        lend.executeBorrow(address(this), id, max, block.timestamp);
        // LTV 35% -> 46.67% line: the price has to fall 25%.
        uint256 price = BB.priceE8("XAUt");
        oracle.setPrice(address(token), price * 7_600 / 10_000);
        assertFalse(credit.status(id, address(this)).shouldDeleverage);
        vm.expectRevert(AtpBorrowExecutor.NothingToDo.selector);
        lend.executeDeleverage(address(this), id);
        oracle.setPrice(address(token), price * 7_400 / 10_000);
        assertTrue(credit.status(id, address(this)).shouldDeleverage);
        vm.prank(address(0xBEEF));
        lend.executeDeleverage(address(this), id);
        assertApproxEqAbs(credit.status(id, address(this)).ltv, credit.targetLtv(id), 1e12);
    }

    // ---- helpers ----

    function _registerAll() internal {
        TestnetAssets.AssetSpec[] memory assets = TestnetAssets.specs();
        for (uint256 i; i < rows.length; ++i) {
            uint8 decimals;
            for (uint256 j; j < assets.length; ++j) {
                if (keccak256(bytes(assets[j].symbol)) == keccak256(bytes(rows[i].symbol))) {
                    decimals = assets[j].decimals;
                    break;
                }
            }
            assertGt(decimals, 0, rows[i].symbol);
            TestnetToken token = new TestnetToken(rows[i].symbol, rows[i].symbol, decimals, address(this));
            tokens.push(token);
            oracle.setPrice(address(token), BB.priceE8(rows[i].symbol));
            BT.Market memory m;
            if (rows[i].kind == BT.Kind.VENUS) {
                MockVToken v =
                    new MockVToken(address(token), address(comptroller), address(this), 0, rows[i].symbol);
                comptroller.supportMarket(address(v));
                comptroller.setCollateralFactor(address(v), rows[i].factor);
                comptroller.setActionPaused(address(v), BORROW_ACTION, true);
                v.setIncentives(address(usdt), rows[i].collateralIncentiveBps, 0);
                usdt.setMinter(address(v), true);
                m = BT.Market(
                    BT.Kind.VENUS,
                    rows[i].tier,
                    address(token),
                    address(usdt),
                    address(comptroller),
                    address(v),
                    address(vUsdt),
                    bytes32(0),
                    VAULT_ID,
                    address(0),
                    BB.BORROW_CAP,
                    true,
                    false
                );
            } else {
                m = _listaMarket(token, rows[i].factor, rows[i].tier);
                moolah.setIncentives(m.listaId, rows[i].collateralIncentiveBps, BB.LISTA_BORROW_INCENTIVE_BPS);
            }
            bytes32 id = BB.id(rows[i], address(token));
            credit.registerMarket(id, m);
            ids.push(id);
        }
    }

    function _listaMarket(TestnetToken token, uint256 lltv, BT.Tier tier)
        internal
        returns (BT.Market memory m)
    {
        MoolahParams memory p =
            MoolahParams(address(usdt), address(token), address(oracle), address(moolah), lltv);
        bytes32 listaId = moolah.createMarket(p, BB.BORROW_APR_BPS);
        vm.prank(LENDER);
        moolah.supply(p, BB.LISTA_SEED, 0, LENDER, "");
        m = BT.Market(
            BT.Kind.LISTA,
            tier,
            address(token),
            address(usdt),
            address(moolah),
            address(0),
            address(0),
            listaId,
            VAULT_ID,
            address(0),
            BB.BORROW_CAP,
            true,
            false
        );
    }

    /// @dev The test contract is the portfolio account: enroll, consent to every market, grant and approve.
    function _enrollEverything() internal {
        address[] memory assets = new address[](1);
        assets[0] = address(usdt);
        uint16[] memory weights = new uint16[](1);
        weights[0] = 10_000;
        uint256 strategy = registry.registerStrategy("borrow book", "test", true);
        registry.publishVersion(strategy, assets, weights, keccak256("hold"), 0);
        registry.enroll(address(this), strategy, 1);
        comptroller.updateDelegate(address(lend), true);
        moolah.setAuthorization(address(lend), true);
        for (uint256 i; i < ids.length; ++i) {
            credit.setBorrowPolicy(ids[i], 1_000_000e18, true);
            tokens[i].approve(address(lend), type(uint256).max);
        }
        usdt.approve(address(lend), type(uint256).max);
        vault.approve(address(lend), type(uint256).max);
    }

    function _index(string memory symbol) internal view returns (uint256) {
        for (uint256 i; i < rows.length; ++i) {
            if (keccak256(bytes(rows[i].symbol)) == keccak256(bytes(symbol))) return i;
        }
        revert(string.concat("no row ", symbol));
    }

    function _row(
        uint256 i,
        string memory symbol,
        BT.Kind kind,
        BT.Tier tier,
        uint256 factor,
        uint16 incentive
    ) internal view {
        assertEq(rows[i].symbol, symbol);
        assertTrue(rows[i].kind == kind, symbol);
        assertTrue(rows[i].tier == tier, symbol);
        assertEq(rows[i].factor, factor, symbol);
        assertEq(rows[i].collateralIncentiveBps, incentive, symbol);
    }

    function _tier(string memory symbol, BT.Tier tier, uint256 factor) internal view {
        uint256 i = _index(symbol);
        assertTrue(rows[i].tier == tier, symbol);
        assertEq(rows[i].factor, factor, symbol);
    }
}
