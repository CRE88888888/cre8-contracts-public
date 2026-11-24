// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { AtpRegistry } from "../../../../src/atp/AtpRegistry.sol";
import { AtpExecutor } from "../../../../src/atp/AtpExecutor.sol";
import { MoolahParams } from "../../../../src/atp/yield/YieldInterfaces.sol";
import { AtpBorrowExecutorV2 } from "../../../../src/atp/borrow/v2/AtpBorrowExecutorV2.sol";
import { AtpBorrowExecutorV2Extension } from "../../../../src/atp/borrow/v2/AtpBorrowExecutorV2Extension.sol";
import { AtpBorrowRegistryV2 } from "../../../../src/atp/borrow/v2/AtpBorrowRegistryV2.sol";
import { AtpBorrowLensV2 } from "../../../../src/atp/borrow/v2/AtpBorrowLensV2.sol";
import { IAtpBorrowExecutorV2 } from "../../../../src/atp/borrow/v2/IAtpBorrowExecutorV2.sol";
import { IAtpBorrowRegistryV2 } from "../../../../src/atp/borrow/v2/IAtpBorrowRegistryV2.sol";
import { StrategyBox } from "../../../../src/atp/borrow/v2/StrategyBox.sol";
import {
    Erc4626VaultAdapter,
    VenusVaultAdapter,
    AaveVaultAdapter
} from "../../../../src/atp/borrow/v2/VaultAdapters.sol";
import { RoutingTypes as R } from "../../../../src/atp/borrow/v2/RoutingTypes.sol";
import { TestnetToken } from "../../../../src/testnet/TestnetToken.sol";
import { MockEarnVault } from "../../../../src/testnet/lending/MockEarnVault.sol";
import { MockLendingOracle } from "../../../../src/testnet/lending/MockLendingOracle.sol";
import { MockVenusComptroller } from "../../../../src/testnet/lending/MockVenusComptroller.sol";
import { MockVToken } from "../../../../src/testnet/lending/MockVToken.sol";
import { MockMoolah } from "../../../../src/testnet/lending/MockMoolah.sol";
import { MockAavePool } from "../../../../src/testnet/yield/MockAavePool.sol";
import { PricedOracle, PricedRouter } from "../../AtpExecutorBuyLimit.t.sol";
import { MockPermit2 } from "../../AtpExecutor.t.sol";

/// @dev The test contract is the portfolio account (it has code, enrolls itself, calls the executor and answers
/// ERC-1271 for hashes it approved). Collateral: NVDA and TSLA (single stocks), QQQ (index); all 100 USD.
/// Venus: NVDA and TSLA at a 60% factor (target 30%, deleverage 40%) with USDT and USDC loans.
/// Lista: TSLA/USDT 70% (target 30% by tier), TSLA/USDC 50% (target 25%), QQQ/USDC 75% (target 35%).
/// Vaults: ERC4626 USDT and USDC (rate reported 4.5%), Venus vUSDC supply, Aave USDT (3.5%). Borrow APR 2.5%.
abstract contract RoutingBase is Test {
    uint256 internal constant MAX = type(uint256).max;
    uint256 internal constant PRICE_E8 = 100e8;
    uint16 internal constant BORROW_APR = 250;
    uint16 internal constant VAULT_APR = 450;
    address internal constant LENDER = address(0x1E2D);
    address internal constant LIQUIDATOR = address(0x11D);
    address internal constant KEEPER = address(0x6EE);
    address internal constant REPORTER = address(0x4E9);
    address internal constant WALLET = address(0xA11E7);

    AtpRegistry internal registry;
    AtpExecutor internal atp;
    /// @dev The executor through its one interface (half of it runs in the extension by delegatecall).
    IAtpBorrowExecutorV2 internal lend;
    AtpBorrowExecutorV2Extension internal extension;
    AtpBorrowRegistryV2 internal credit;
    AtpBorrowLensV2 internal lens;
    Erc4626VaultAdapter internal erc4626Adapter;
    VenusVaultAdapter internal venusAdapter;
    AaveVaultAdapter internal aaveAdapter;

    TestnetToken internal usdt;
    TestnetToken internal usdc;
    TestnetToken internal nvda;
    TestnetToken internal tsla;
    TestnetToken internal qqq;
    TestnetToken internal lista;
    MockLendingOracle internal oracle;
    MockVenusComptroller internal comptroller;
    MockVToken internal vUsdt;
    MockVToken internal vUsdc;
    MockVToken internal vNvda;
    MockVToken internal vTsla;
    MockMoolah internal moolah;
    MockEarnVault internal vaultT;
    MockEarnVault internal vaultC;
    MockAavePool internal aaveT;

    // Routes
    bytes32 internal V_NVDA_T;
    bytes32 internal V_NVDA_C;
    bytes32 internal V_TSLA_T;
    bytes32 internal V_TSLA_C;
    bytes32 internal L_TSLA_T;
    bytes32 internal L_TSLA_C;
    bytes32 internal L_QQQ_C;
    // Vaults
    bytes32 internal K_T; // ERC4626 USDT
    bytes32 internal K_C; // ERC4626 USDC
    bytes32 internal K_VC; // Venus vUSDC
    bytes32 internal K_AT; // Aave USDT

    uint256 internal strategy;
    mapping(bytes32 => bool) internal signed;

    function setUp() public virtual {
        vm.chainId(97);
        vm.warp(1_000_000);
        usdt = new TestnetToken("Test USDT", "USDT", 18, address(this));
        usdc = new TestnetToken("Test USDC", "USDC", 18, address(this));
        nvda = new TestnetToken("NVIDIA", "NVDAB", 18, address(this));
        tsla = new TestnetToken("Tesla", "TSLAB", 18, address(this));
        qqq = new TestnetToken("QQQ", "QQQB", 18, address(this));
        lista = new TestnetToken("Lista", "LISTA", 18, address(this));
        address permit = 0x31c2F6fcFf4F8759b3Bd5Bf0e1084A055615c768;
        vm.etch(permit, address(new MockPermit2()).code);
        registry = new AtpRegistry();
        atp = new AtpExecutor(
            registry,
            new PricedRouter(),
            new PricedOracle(address(usdt)),
            permit,
            address(0xFEE),
            address(usdt),
            10_000,
            0.3e18
        );
        registry.setNumeraire(address(usdt));
        strategy = _newStrategy();
        registry.enroll(address(this), strategy, 1);

        // Venues.
        oracle = new MockLendingOracle(address(this));
        oracle.setPrice(address(usdt), 1e8);
        oracle.setPrice(address(usdc), 1e8);
        oracle.setPrice(address(nvda), PRICE_E8);
        oracle.setPrice(address(tsla), PRICE_E8);
        oracle.setPrice(address(qqq), PRICE_E8);
        comptroller = new MockVenusComptroller(address(this), address(oracle));
        vUsdt = new MockVToken(address(usdt), address(comptroller), address(this), BORROW_APR, "USDT");
        vUsdc = new MockVToken(address(usdc), address(comptroller), address(this), BORROW_APR, "USDC");
        vNvda = new MockVToken(address(nvda), address(comptroller), address(this), 0, "NVDAB");
        vTsla = new MockVToken(address(tsla), address(comptroller), address(this), 0, "TSLAB");
        comptroller.supportMarket(address(vUsdt));
        comptroller.supportMarket(address(vUsdc));
        comptroller.supportMarket(address(vNvda));
        comptroller.supportMarket(address(vTsla));
        comptroller.setCollateralFactor(address(vNvda), 0.6e18);
        comptroller.setCollateralFactor(address(vTsla), 0.6e18);
        moolah = new MockMoolah(address(this));
        moolah.createMarket(_params(usdt, tsla, 0.7e18), BORROW_APR);
        moolah.createMarket(_params(usdc, tsla, 0.5e18), BORROW_APR);
        moolah.createMarket(_params(usdc, qqq, 0.75e18), BORROW_APR);

        // Vaults.
        vaultT = new MockEarnVault(usdt, address(this), VAULT_APR);
        vaultC = new MockEarnVault(usdc, address(this), VAULT_APR);
        aaveT = new MockAavePool(usdt, address(this), 350);
        usdt.setMinter(address(vaultT), true);
        usdc.setMinter(address(vaultC), true);
        usdt.setMinter(aaveT.receipt(), true);

        // Background lenders.
        usdt.mint(LENDER, 10_000_000e18);
        usdc.mint(LENDER, 10_000_000e18);
        vm.startPrank(LENDER);
        usdt.approve(address(vUsdt), MAX);
        usdc.approve(address(vUsdc), MAX);
        usdt.approve(address(moolah), MAX);
        usdc.approve(address(moolah), MAX);
        usdt.approve(address(vaultT), MAX);
        usdc.approve(address(vaultC), MAX);
        usdt.approve(address(aaveT), MAX);
        vUsdt.mint(1_000_000e18);
        vUsdc.mint(1_000_000e18);
        moolah.supply(_params(usdt, tsla, 0.7e18), 1_000_000e18, 0, LENDER, "");
        moolah.supply(_params(usdc, tsla, 0.5e18), 1_000_000e18, 0, LENDER, "");
        moolah.supply(_params(usdc, qqq, 0.75e18), 1_000_000e18, 0, LENDER, "");
        vaultT.deposit(1_000_000e18, LENDER);
        vaultC.deposit(1_000_000e18, LENDER);
        aaveT.supply(address(usdt), 1_000_000e18, LENDER, 0);
        vm.stopPrank();

        // Routing v2: registry (bound to the executor's future address), lens, executor, adapters.
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 3);
        credit =
            new AtpBorrowRegistryV2(registry, address(atp), predicted, address(comptroller), address(moolah));
        lens = new AtpBorrowLensV2(credit);
        extension = new AtpBorrowExecutorV2Extension();
        lend = IAtpBorrowExecutorV2(address(new AtpBorrowExecutorV2(credit, lens, address(extension))));
        assertEq(address(lend), predicted, "executor address");
        erc4626Adapter = new Erc4626VaultAdapter(address(lend));
        venusAdapter = new VenusVaultAdapter(address(lend));
        aaveAdapter = new AaveVaultAdapter(address(lend));
        credit.setAdapter(R.VaultKind.ERC4626, address(erc4626Adapter));
        credit.setAdapter(R.VaultKind.VENUS, address(venusAdapter));
        credit.setAdapter(R.VaultKind.AAVE, address(aaveAdapter));
        credit.setLoanToken(address(usdt), true);
        credit.setLoanToken(address(usdc), true);
        credit.setAssetTier(address(nvda), R.Tier.STOCK);
        credit.setAssetTier(address(tsla), R.Tier.STOCK);
        credit.setAssetTier(address(qqq), R.Tier.INDEX_LARGE_CAP);
        credit.setVenusMarket(address(usdt), address(vUsdt));
        credit.setVenusMarket(address(usdc), address(vUsdc));
        credit.setVenusMarket(address(nvda), address(vNvda));
        credit.setVenusMarket(address(tsla), address(vTsla));
        credit.setRateReporter(REPORTER);
        credit.setRewardToken(address(lista), true);
        credit.setRewardProofSuffix(bytes("\nThank you for your support of listaDAO."));

        uint256 cap = 1_000_000e18;
        V_NVDA_T = credit.registerRoute(R.Venue.VENUS, address(nvda), address(usdt), bytes32(0), cap);
        V_NVDA_C = credit.registerRoute(R.Venue.VENUS, address(nvda), address(usdc), bytes32(0), cap);
        V_TSLA_T = credit.registerRoute(R.Venue.VENUS, address(tsla), address(usdt), bytes32(0), cap);
        V_TSLA_C = credit.registerRoute(R.Venue.VENUS, address(tsla), address(usdc), bytes32(0), cap);
        L_TSLA_T =
            credit.registerRoute(R.Venue.LISTA, address(tsla), address(usdt), _id(usdt, tsla, 0.7e18), cap);
        L_TSLA_C =
            credit.registerRoute(R.Venue.LISTA, address(tsla), address(usdc), _id(usdc, tsla, 0.5e18), cap);
        L_QQQ_C =
            credit.registerRoute(R.Venue.LISTA, address(qqq), address(usdc), _id(usdc, qqq, 0.75e18), cap);
        K_T = credit.registerVault(R.VaultKind.ERC4626, address(usdt), address(vaultT));
        K_C = credit.registerVault(R.VaultKind.ERC4626, address(usdc), address(vaultC));
        K_VC = credit.registerVault(R.VaultKind.VENUS, address(usdc), address(vUsdc));
        K_AT = credit.registerVault(R.VaultKind.AAVE, address(usdt), address(aaveT));
        _report(uint256(VAULT_APR) * 1e14, 0, 0);

        // Account-owner grants, once.
        comptroller.updateDelegate(address(lend), true);
        moolah.setAuthorization(address(lend), true);
        credit.setStrategyPolicy(10_000_000e18, WALLET, true);
        nvda.approve(address(lend), MAX);
        tsla.approve(address(lend), MAX);
        qqq.approve(address(lend), MAX);
        nvda.mint(address(this), 1_000e18);
        tsla.mint(address(this), 1_000e18);
        qqq.mint(address(this), 1_000e18);

        usdt.mint(LIQUIDATOR, 1_000_000e18);
        usdc.mint(LIQUIDATOR, 1_000_000e18);
        vm.startPrank(LIQUIDATOR);
        usdt.approve(address(vUsdt), MAX);
        usdc.approve(address(vUsdc), MAX);
        usdt.approve(address(moolah), MAX);
        usdc.approve(address(moolah), MAX);
        vm.stopPrank();
    }

    // ---- ERC-1271 of the account ----

    function isValidSignature(bytes32 hash, bytes calldata) external view returns (bytes4) {
        return signed[hash] ? bytes4(0x1626ba7e) : bytes4(0xffffffff);
    }

    // ---- helpers ----

    function _newStrategy() internal returns (uint256 id) {
        address[] memory assets = new address[](4);
        assets[0] = address(usdt);
        assets[1] = address(nvda);
        assets[2] = address(tsla);
        assets[3] = address(qqq);
        uint16[] memory weights = new uint16[](4);
        weights[1] = 4_000;
        weights[2] = 3_000;
        weights[3] = 3_000;
        id = registry.registerStrategy("routing", "test", true);
        registry.publishVersion(id, assets, weights, keccak256("hold"), 0);
    }

    function _params(TestnetToken loan, TestnetToken collateral, uint256 lltv)
        internal
        view
        returns (MoolahParams memory)
    {
        return MoolahParams(address(loan), address(collateral), address(oracle), address(moolah), lltv);
    }

    function _id(TestnetToken loan, TestnetToken collateral, uint256 lltv) internal view returns (bytes32) {
        return moolah.marketId(_params(loan, collateral, lltv));
    }

    /// @dev Report the ERC4626 vaults' base rate and incentive, and a borrow incentive on every route.
    function _report(uint256 vaultRate, uint256 vaultIncentive, uint256 borrowIncentive) internal {
        IAtpBorrowRegistryV2.RouteReport[] memory routes =
            new IAtpBorrowRegistryV2.RouteReport[](credit.routeCount());
        for (uint256 i; i < routes.length; ++i) {
            routes[i] = IAtpBorrowRegistryV2.RouteReport(credit.routeIds(i), borrowIncentive, 0);
        }
        IAtpBorrowRegistryV2.VaultReport[] memory vaults = new IAtpBorrowRegistryV2.VaultReport[](2);
        vaults[0] = IAtpBorrowRegistryV2.VaultReport(K_T, vaultRate, vaultIncentive);
        vaults[1] = IAtpBorrowRegistryV2.VaultReport(K_C, vaultRate, vaultIncentive);
        vm.prank(REPORTER);
        credit.reportRates(routes, vaults);
    }

    function _open(bytes32 route, bytes32 vault, uint256 collateral, uint256 borrow) internal {
        lend.executeOpen(address(this), route, vault, collateral, borrow, block.timestamp);
    }

    function _reduce(bytes32 route, bytes32 vault, uint256 repay, uint256 withdraw, uint256 cash) internal {
        lend.executeReduce(address(this), route, vault, repay, withdraw, cash, block.timestamp);
    }

    function _migrate(
        bytes32 from,
        bytes32 fromVault,
        bytes32 to,
        bytes32 toVault,
        uint256 borrow,
        uint256 cash
    ) internal {
        lend.executeMigrate(address(this), from, fromVault, to, toVault, borrow, cash, block.timestamp);
    }

    function _box() internal view returns (address) {
        return lend.boxOf(address(this));
    }

    function _held(bytes32 vault) internal returns (uint256) {
        return lens.vaultStatus(vault, address(this)).assets;
    }

    function _health(bytes32 route) internal view returns (R.Health memory) {
        return lens.health(route, address(this));
    }

    /// @dev Nothing may rest in the executor or the adapters, and neither may keep an allowance.
    function _noResidue() internal view {
        address[4] memory holders =
            [address(lend), address(erc4626Adapter), address(venusAdapter), address(aaveAdapter)];
        address[10] memory tokens = [
            address(usdt),
            address(usdc),
            address(nvda),
            address(tsla),
            address(qqq),
            address(vaultT),
            address(vaultC),
            address(vUsdc),
            aaveT.receipt(),
            address(vUsdt)
        ];
        address[9] memory spenders = [
            address(vUsdt),
            address(vUsdc),
            address(vNvda),
            address(vTsla),
            address(moolah),
            address(vaultT),
            address(vaultC),
            address(aaveT),
            address(lend)
        ];
        for (uint256 h; h < holders.length; ++h) {
            for (uint256 t; t < tokens.length; ++t) {
                assertEq(IERC20(tokens[t]).balanceOf(holders[h]), 0, "residue");
                for (uint256 s; s < spenders.length; ++s) {
                    assertEq(IERC20(tokens[t]).allowance(holders[h], spenders[s]), 0, "allowance left");
                }
            }
        }
    }

    /// @dev The account itself never holds a vault receipt or a loan token it did not bring.
    function _accountHoldsNoStrategyMoney() internal view {
        assertEq(vaultT.balanceOf(address(this)), 0, "account holds vault shares");
        assertEq(vaultC.balanceOf(address(this)), 0, "account holds vault shares");
        assertEq(vUsdc.balanceOf(address(this)), 0, "account holds vUSDC");
        assertEq(IERC20(aaveT.receipt()).balanceOf(address(this)), 0, "account holds aToken");
    }
}
