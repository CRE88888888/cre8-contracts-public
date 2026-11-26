// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { AtpRegistry } from "../../../src/atp/AtpRegistry.sol";
import { AtpExecutor } from "../../../src/atp/AtpExecutor.sol";
import { AtpYieldRegistry } from "../../../src/atp/yield/AtpYieldRegistry.sol";
import { YieldTypes as Y } from "../../../src/atp/yield/YieldTypes.sol";
import { YieldReader } from "../../../src/atp/yield/YieldReader.sol";
import { MoolahParams } from "../../../src/atp/yield/YieldInterfaces.sol";
import { AtpBorrowExecutor } from "../../../src/atp/borrow/AtpBorrowExecutor.sol";
import { AtpBorrowRegistry } from "../../../src/atp/borrow/AtpBorrowRegistry.sol";
import { BorrowTypes as B } from "../../../src/atp/borrow/BorrowTypes.sol";
import { TestnetToken } from "../../../src/testnet/TestnetToken.sol";
import { MockEarnVault } from "../../../src/testnet/lending/MockEarnVault.sol";
import { MockLendingOracle } from "../../../src/testnet/lending/MockLendingOracle.sol";
import { MockVenusComptroller } from "../../../src/testnet/lending/MockVenusComptroller.sol";
import { MockVToken } from "../../../src/testnet/lending/MockVToken.sol";
import { MockMoolah } from "../../../src/testnet/lending/MockMoolah.sol";
import { PricedOracle, PricedRouter } from "../AtpExecutorBuyLimit.t.sol";
import { MockPermit2 } from "../AtpExecutor.t.sol";

contract YieldHealthHarness {
    function health(Y.Market memory m) external view returns (Y.Health memory) {
        return YieldReader.health(m);
    }
}

/// @dev The test contract is the CRE8 portfolio account: it has code, enrolls itself and calls the executors.
/// NVDA is designated to Venus, TSLA to Lista; both priced 162.413 USD with a 50% factor, so target LTV is 25%
/// and the deleverage line 33.33%. Borrow APR 2.5%, earn vault 4.5% (EARN_UX §C).
abstract contract AtpBorrowBase is Test {
    uint8 internal constant BORROW_ACTION = 2;
    uint256 internal constant PRICE_E8 = 162.413e8;
    uint16 internal constant BORROW_APR = 250;
    uint16 internal constant VAULT_APR = 450;
    address internal constant LENDER = address(0x1E2D);
    address internal constant LIQUIDATOR = address(0x11D);
    address internal constant KEEPER = address(0x6EE);
    address internal constant OPERATOR = address(0x00FE);

    AtpRegistry internal registry;
    AtpExecutor internal executor;
    AtpYieldRegistry internal yields;
    AtpBorrowExecutor internal lend;
    AtpBorrowRegistry internal credit;
    TestnetToken internal usdt;
    TestnetToken internal nvda;
    TestnetToken internal tsla;
    MockLendingOracle internal oracle;
    MockVenusComptroller internal comptroller;
    MockVToken internal vUsdt;
    MockVToken internal vNvda;
    MockMoolah internal moolah;
    MoolahParams internal listaParams;
    MockEarnVault internal vault;
    bytes32 internal constant VENUS_ID = bytes32(uint256(0xA1));
    bytes32 internal constant LISTA_ID = bytes32(uint256(0xB1));
    bytes32 internal constant VAULT_ID = bytes32(uint256(0xC1));
    uint256 internal strategy;

    function setUp() public virtual {
        vm.chainId(97);
        vm.warp(1_000_000);
        usdt = new TestnetToken("Test USDT", "USDT", 18, address(this));
        nvda = new TestnetToken("NVIDIA", "NVDAB", 18, address(this));
        tsla = new TestnetToken("Tesla", "TSLAB", 18, address(this));
        address permit = 0x31c2F6fcFf4F8759b3Bd5Bf0e1084A055615c768;
        vm.etch(permit, address(new MockPermit2()).code);
        registry = new AtpRegistry();
        registry.setOperator(OPERATOR);
        executor = new AtpExecutor(
            registry,
            new PricedRouter(),
            new PricedOracle(address(usdt)),
            permit,
            address(0xFEE),
            address(usdt),
            10_000,
            0.3e18
        );
        yields = executor.yieldRegistry();
        lend = new AtpBorrowExecutor(registry, address(executor));
        credit = lend.borrowRegistry();

        address[] memory assets = new address[](3);
        assets[0] = address(usdt);
        assets[1] = address(nvda);
        assets[2] = address(tsla);
        uint16[] memory weights = new uint16[](3);
        weights[1] = 5_000;
        weights[2] = 5_000;
        registry.setNumeraire(address(usdt));
        strategy = registry.registerStrategy("borrow", "test", true);
        registry.publishVersion(strategy, assets, weights, keccak256("hold"), 0);
        registry.enroll(address(this), strategy, 1);

        // Lending markets.
        oracle = new MockLendingOracle(address(this));
        oracle.setPrice(address(usdt), 1e8);
        oracle.setPrice(address(nvda), PRICE_E8);
        oracle.setPrice(address(tsla), PRICE_E8);
        comptroller = new MockVenusComptroller(address(this), address(oracle));
        vUsdt = new MockVToken(address(usdt), address(comptroller), address(this), BORROW_APR, "USDT");
        vNvda = new MockVToken(address(nvda), address(comptroller), address(this), 0, "NVDAB");
        comptroller.supportMarket(address(vUsdt));
        comptroller.supportMarket(address(vNvda));
        comptroller.setCollateralFactor(address(vNvda), 0.5e18);
        comptroller.setActionPaused(address(vNvda), BORROW_ACTION, true);
        moolah = new MockMoolah(address(this));
        listaParams = MoolahParams(address(usdt), address(tsla), address(oracle), address(moolah), 0.5e18);
        moolah.createMarket(listaParams, BORROW_APR);

        // Background lenders.
        usdt.mint(LENDER, 3_000_000e18);
        vm.startPrank(LENDER);
        usdt.approve(address(vUsdt), type(uint256).max);
        usdt.approve(address(moolah), type(uint256).max);
        vUsdt.mint(1_000_000e18);
        moolah.supply(listaParams, 1_000_000e18, 0, LENDER, "");
        vm.stopPrank();

        // Earn vault: a Lista USDT vault admitted in the yield registry.
        vault = new MockEarnVault(usdt, address(this), VAULT_APR);
        usdt.setMinter(address(vault), true);
        vm.startPrank(LENDER);
        usdt.approve(address(vault), type(uint256).max);
        vault.deposit(1_000_000e18, LENDER);
        vm.stopPrank();
        Y.Market memory ym = Y.Market(
            97,
            Y.Kind.LISTA,
            address(usdt),
            address(vault),
            address(vault),
            address(vault),
            bytes32(0),
            1e17,
            1e20,
            true,
            false
        );
        ym.configuration = new YieldHealthHarness().health(ym).configuration;
        yields.registerMarket(VAULT_ID, ym);

        credit.registerMarket(VENUS_ID, _venusMarket());
        credit.registerMarket(LISTA_ID, _listaMarket());

        // Account-owner grants for the route.
        comptroller.updateDelegate(address(lend), true);
        moolah.setAuthorization(address(lend), true);
        credit.setBorrowPolicy(VENUS_ID, 10_000_000e18, true);
        credit.setBorrowPolicy(LISTA_ID, 10_000_000e18, true);
        nvda.approve(address(lend), type(uint256).max);
        tsla.approve(address(lend), type(uint256).max);
        usdt.approve(address(lend), type(uint256).max);
        vault.approve(address(lend), type(uint256).max);
        nvda.mint(address(this), 100e18);
        tsla.mint(address(this), 100e18);
        usdt.mint(address(this), 1_000e18);

        usdt.mint(LIQUIDATOR, 1_000_000e18);
        vm.startPrank(LIQUIDATOR);
        usdt.approve(address(vUsdt), type(uint256).max);
        usdt.approve(address(moolah), type(uint256).max);
        vm.stopPrank();
    }

    function _venusMarket() internal view returns (B.Market memory) {
        return B.Market(
            B.Kind.VENUS,
            B.Tier.STOCK,
            address(nvda),
            address(usdt),
            address(comptroller),
            address(vNvda),
            address(vUsdt),
            bytes32(0),
            VAULT_ID,
            address(0),
            1_000_000e18,
            true,
            false
        );
    }

    function _listaMarket() internal view returns (B.Market memory) {
        return B.Market(
            B.Kind.LISTA,
            B.Tier.STOCK,
            address(tsla),
            address(usdt),
            address(moolah),
            address(0),
            address(0),
            moolah.marketId(listaParams),
            VAULT_ID,
            address(0),
            1_000_000e18,
            true,
            false
        );
    }

    function _token(bytes32 id) internal view returns (TestnetToken) {
        return id == VENUS_ID ? nvda : tsla;
    }

    function _post(bytes32 id, uint256 amount) internal {
        lend.executeSupplyCollateral(address(this), id, amount, block.timestamp);
    }

    function _borrow(bytes32 id, uint256 amount) internal {
        lend.executeBorrow(address(this), id, amount, block.timestamp);
    }

    function _repay(bytes32 id, uint256 amount, bool fromVault) internal {
        lend.executeRepay(address(this), id, amount, fromVault, block.timestamp);
    }

    function _withdraw(bytes32 id, uint256 amount) internal {
        lend.executeWithdrawCollateral(address(this), id, amount, block.timestamp);
    }

    function _ltv(bytes32 id) internal view returns (uint256) {
        B.Health memory h = credit.health(id, address(this));
        return h.debtValue == 0 ? 0 : (h.debtValue * 1e18 + h.collateralValue - 1) / h.collateralValue;
    }

    /// @dev Largest debt (USDT raw at $1) keeping LTV exactly at the target.
    function _maxDebtAtTarget(bytes32 id) internal view returns (uint256) {
        return credit.health(id, address(this)).collateralValue * credit.targetLtv(id) / 1e18;
    }

    function _noResidue() internal view {
        assertEq(usdt.balanceOf(address(lend)), 0, "executor holds USDT");
        assertEq(nvda.balanceOf(address(lend)), 0, "executor holds NVDA");
        assertEq(tsla.balanceOf(address(lend)), 0, "executor holds TSLA");
        assertEq(vault.balanceOf(address(lend)), 0, "executor holds vault shares");
        assertEq(usdt.allowance(address(lend), address(vUsdt)), 0, "vUSDT allowance left");
        assertEq(usdt.allowance(address(lend), address(moolah)), 0, "Moolah USDT allowance left");
        assertEq(usdt.allowance(address(lend), address(vault)), 0, "vault allowance left");
        assertEq(nvda.allowance(address(lend), address(vNvda)), 0, "vNVDA allowance left");
        assertEq(tsla.allowance(address(lend), address(moolah)), 0, "Moolah collateral allowance left");
    }

    function _usdtOf(address who) internal view returns (uint256) {
        return IERC20(address(usdt)).balanceOf(who);
    }

    /// @dev Make the earn vault's utilization exactly `bps` (rounded up) by parking cash as simulated borrows.
    function _vaultUtilization(uint256 bps) internal {
        vault.accrue();
        uint256 cash = usdt.balanceOf(address(vault));
        uint256 borrowed = cash * bps / 10_000;
        vault.setLiquidity(cash - borrowed);
    }
}
