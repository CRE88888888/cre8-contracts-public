// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test, console2 } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { AtpRegistry } from "../../../src/atp/AtpRegistry.sol";
import { AtpBorrowExecutorV2 } from "../../../src/atp/borrow/v2/AtpBorrowExecutorV2.sol";
import { AtpBorrowExecutorV2Extension } from "../../../src/atp/borrow/v2/AtpBorrowExecutorV2Extension.sol";
import { AtpBorrowRegistryV2 } from "../../../src/atp/borrow/v2/AtpBorrowRegistryV2.sol";
import { AtpBorrowLensV2 } from "../../../src/atp/borrow/v2/AtpBorrowLensV2.sol";
import { IAtpBorrowExecutorV2 as IExec } from "../../../src/atp/borrow/v2/IAtpBorrowExecutorV2.sol";
import { IAtpBorrowRegistryV2 as IReg } from "../../../src/atp/borrow/v2/IAtpBorrowRegistryV2.sol";
import {
    Erc4626VaultAdapter,
    VenusVaultAdapter,
    AaveVaultAdapter
} from "../../../src/atp/borrow/v2/VaultAdapters.sol";
import { RoutingTypes as R } from "../../../src/atp/borrow/v2/RoutingTypes.sol";

contract GlobalPauseStub {
    bool public globalPaused;

    function set(bool paused) external {
        globalPaused = paused;
    }
}

interface IVenusAdmin {
    function updateDelegate(address delegate, bool allowBorrows) external;
    function oracle() external view returns (address);
}

interface IListaQueue {
    function supplyQueueLength() external view returns (uint256);
    function supplyQueue(uint256 index) external view returns (bytes32);
}

interface IMoolahAdmin {
    function setAuthorization(address authorized, bool newIsAuthorized) external;
    function market(bytes32 id) external view returns (uint128, uint128, uint128, uint128, uint128, uint128);
    function idToMarketParams(bytes32 id) external view returns (address, address, address, address, uint256);
}

/// @notice Routing v2 against the live BSC mainnet venues: Lista Moolah bStock markets and vaults, Venus core
/// pool (bStock collateral, vUSDT / vUSDC / vUSD1 / vU) and Aave v3. Balances come from `deal`; rates that
/// are not on chain are reported the way the backend would. Needs `BSC_RPC_URL` (a public endpoint is enough);
/// without it every test is reported as skipped.
contract BorrowRoutingV2ForkTest is Test {
    uint256 internal constant MAX = type(uint256).max;
    address internal constant MOOLAH = 0x8F73b65B4caAf64FBA2aF91cC5D4a2A1318E5D8C;
    address internal constant COMPTROLLER = 0xfD36E2c2a6789Db23113685031d7F16329158384;
    address internal constant AAVE_POOL = 0x6807dc923806fE8Fd134338EABCA509979a7e0cB;
    address internal constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address internal constant USDC = 0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d;
    address internal constant USD1 = 0x8d0D000Ee44948FC98c9B98A4FA4921476f08B0d;
    address internal constant U = 0xcE24439F2D9C6a2289F741120FE202248B666666;
    address internal constant NVDAB = 0x02Fca66C1D1aFB4E2A7884261eB00F63598a7436;
    address internal constant TSLAB = 0x5b1910eAaD6450E50f816082Aa078C41F10C292f;
    address internal constant V_USDT = 0xfD5840Cd36d94D7229439859C0112a4185BC0255;
    address internal constant V_USDC = 0xecA88125a5ADbe82614ffC12D0DB554E2e2867C8;
    address internal constant V_USD1 = 0x0C1DA220D301155b87318B90692Da8dc43B67340;
    address internal constant V_U = 0x3d5E269787d562b74aCC55F18Bd26C5D09Fa245E;
    address internal constant V_NVDAB = 0xEb8Ca841cBe1BC4832A10b15c7dAB1081eDaD371;
    address internal constant V_TSLAB = 0x97421799419Eb782628e73e7220d8E0A207469a3;
    address internal constant SPCXB = 0xbe9D156892E55e7154BcD3cB0FEA677F9D3103E1;
    address internal constant V_SPCXB = 0xC36dFaCc7a125859C106F29b9F2d874CCF29A55A;
    address internal constant LISTA_VAULT_USD1 = 0xfa27f172e0b6ebcEF9c51ABf817E2cb142FbE627;
    address internal constant LISTA_VAULT_U = 0x9A17Fd5Cb8EFc25d11567e713aE795A89775a759;
    address internal constant LISTA_VAULT_USDC = 0x8a06Ac91265dBEBE6D4606f45b10993E9a571869;
    address internal constant LISTA_VAULT_USDT = 0x6d6783C146F2B0B2774C1725297f1845dc502525;
    // Lista Moolah markets (api.lista.org zone 5, 2026-11-24).
    bytes32 internal constant M_NVDAB_USD1 =
        0xaa1b8576712e33031668c93baa6ca53818a687d43e216d91ca09eeaff674d8b1;
    bytes32 internal constant M_QQQB_USDC =
        0x3af25f66f76bd1024a1d5165bef8a49c30d7c6ef1a2292821551a3adf998e387;
    bytes32 internal constant M_QQQB_USD1 =
        0x78f0f036e0549defcb4c6b9039a72ce14f952326ce4bba229d761c00a2749dc4;
    bytes32 internal constant M_TSLAB_USDC =
        0x2c5ae93255b92d59b25cafc9d735eb4c7f45bf5701b4eb71513aa6f1bb4d1a45;
    address internal constant REPORTER = address(0x4E9);
    address internal constant KEEPER = address(0x6EE);

    AtpRegistry internal registry;
    GlobalPauseStub internal pins;
    IExec internal lend;
    AtpBorrowRegistryV2 internal credit;
    AtpBorrowLensV2 internal lens;
    address internal qqqb;

    bytes32 internal L_NVDAB_USD1;
    bytes32 internal L_QQQB_USDC;
    bytes32 internal L_QQQB_USD1;
    bytes32 internal L_TSLAB_USDC;
    bytes32 internal V_TSLAB_USDT;
    bytes32 internal V_TSLAB_USDC;
    bytes32 internal V_TSLAB_USD1;
    bytes32 internal V_TSLAB_U;
    bytes32 internal V_SPCXB_USDT;
    bytes32 internal K_LISTA_USD1;
    bytes32 internal K_LISTA_U;
    bytes32 internal K_LISTA_USDC;
    bytes32 internal K_LISTA_USDT;
    bytes32 internal K_VENUS_USDT;
    bytes32 internal K_VENUS_USDC;
    bytes32 internal K_VENUS_USD1;
    bytes32 internal K_VENUS_U;
    bytes32 internal K_AAVE_USDT;
    bytes32 internal K_AAVE_USDC;

    function setUp() public {
        string memory rpc = vm.envOr("BSC_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        // Latest block by default (public nodes only keep recent state). Set BSC_FORK_BLOCK with an archive
        // endpoint to pin the run and make it reproducible. In CI the pin is required: a run there must give
        // the same result every time.
        uint256 pinned = vm.envOr("BSC_FORK_BLOCK", uint256(0));
        require(pinned != 0 || !vm.envOr("CI", false), "CI fork tests need BSC_FORK_BLOCK (archive RPC)");
        if (pinned == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, pinned);
        (, qqqb,,,) = IMoolahAdmin(MOOLAH).idToMarketParams(M_QQQB_USDC);

        registry = new AtpRegistry();
        registry.setNumeraire(USDT);
        address[] memory assets = new address[](4);
        (assets[0], assets[1], assets[2], assets[3]) = (USDT, NVDAB, TSLAB, qqqb);
        uint16[] memory weights = new uint16[](4);
        (weights[1], weights[2], weights[3]) = (4_000, 3_000, 3_000);
        uint256 strategy = registry.registerStrategy("fork", "routing v2", true);
        registry.publishVersion(strategy, assets, weights, keccak256("hold"), 0);
        registry.enroll(address(this), strategy, 1);
        pins = new GlobalPauseStub();

        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 3);
        credit = new AtpBorrowRegistryV2(registry, address(pins), predicted, COMPTROLLER, MOOLAH);
        lens = new AtpBorrowLensV2(credit);
        address extension = address(new AtpBorrowExecutorV2Extension());
        lend = IExec(address(new AtpBorrowExecutorV2(credit, lens, extension)));
        credit.setAdapter(R.VaultKind.ERC4626, address(new Erc4626VaultAdapter(address(lend))));
        credit.setAdapter(R.VaultKind.VENUS, address(new VenusVaultAdapter(address(lend))));
        credit.setAdapter(R.VaultKind.AAVE, address(new AaveVaultAdapter(address(lend))));
        address[4] memory loans = [USDT, USDC, USD1, U];
        address[4] memory loanVTokens = [V_USDT, V_USDC, V_USD1, V_U];
        for (uint256 i; i < 4; ++i) {
            credit.setLoanToken(loans[i], true);
            credit.setVenusMarket(loans[i], loanVTokens[i]);
        }
        credit.setVenusMarket(NVDAB, V_NVDAB);
        credit.setVenusMarket(TSLAB, V_TSLAB);
        credit.setVenusMarket(SPCXB, V_SPCXB);
        credit.setAssetTier(SPCXB, R.Tier.STOCK);
        credit.setAssetTier(NVDAB, R.Tier.STOCK);
        credit.setAssetTier(TSLAB, R.Tier.STOCK);
        credit.setAssetTier(qqqb, R.Tier.INDEX_LARGE_CAP);
        credit.setRateReporter(REPORTER);

        uint256 cap = 10_000_000e18;
        L_NVDAB_USD1 = credit.registerRoute(R.Venue.LISTA, NVDAB, USD1, M_NVDAB_USD1, cap);
        L_QQQB_USDC = credit.registerRoute(R.Venue.LISTA, qqqb, USDC, M_QQQB_USDC, cap);
        L_QQQB_USD1 = credit.registerRoute(R.Venue.LISTA, qqqb, USD1, M_QQQB_USD1, cap);
        L_TSLAB_USDC = credit.registerRoute(R.Venue.LISTA, TSLAB, USDC, M_TSLAB_USDC, cap);
        // Venus: TSLAB and SPCXB have room under their supply caps; vNVDAB's 1,500 NVDAB cap is full on
        // mainnet today (2026-11-24), so NVDAB is exercised on Lista only.
        V_TSLAB_USDT = credit.registerRoute(R.Venue.VENUS, TSLAB, USDT, bytes32(0), cap);
        V_TSLAB_USDC = credit.registerRoute(R.Venue.VENUS, TSLAB, USDC, bytes32(0), cap);
        V_TSLAB_USD1 = credit.registerRoute(R.Venue.VENUS, TSLAB, USD1, bytes32(0), cap);
        V_TSLAB_U = credit.registerRoute(R.Venue.VENUS, TSLAB, U, bytes32(0), cap);
        V_SPCXB_USDT = credit.registerRoute(R.Venue.VENUS, SPCXB, USDT, bytes32(0), cap);
        K_LISTA_USD1 = credit.registerVault(R.VaultKind.ERC4626, USD1, LISTA_VAULT_USD1);
        K_LISTA_U = credit.registerVault(R.VaultKind.ERC4626, U, LISTA_VAULT_U);
        K_LISTA_USDC = credit.registerVault(R.VaultKind.ERC4626, USDC, LISTA_VAULT_USDC);
        K_LISTA_USDT = credit.registerVault(R.VaultKind.ERC4626, USDT, LISTA_VAULT_USDT);
        K_VENUS_USDT = credit.registerVault(R.VaultKind.VENUS, USDT, V_USDT);
        K_VENUS_USDC = credit.registerVault(R.VaultKind.VENUS, USDC, V_USDC);
        K_VENUS_USD1 = credit.registerVault(R.VaultKind.VENUS, USD1, V_USD1);
        K_VENUS_U = credit.registerVault(R.VaultKind.VENUS, U, V_U);
        K_AAVE_USDT = credit.registerVault(R.VaultKind.AAVE, USDT, AAVE_POOL);
        K_AAVE_USDC = credit.registerVault(R.VaultKind.AAVE, USDC, AAVE_POOL);
        _report();

        // Account-owner grants, once.
        IVenusAdmin(COMPTROLLER).updateDelegate(address(lend), true);
        IMoolahAdmin(MOOLAH).setAuthorization(address(lend), true);
        credit.setStrategyPolicy(10_000_000e18, address(0xA11E7), true);
        address[4] memory collaterals = [NVDAB, TSLAB, qqqb, SPCXB];
        for (uint256 i; i < 4; ++i) {
            deal(collaterals[i], address(this), 100e18);
            IERC20(collaterals[i]).approve(address(lend), MAX);
        }
    }

    /// @dev What the backend reports: Lista vault rates (not readable on chain) and reward programs. The
    /// numbers only need to make the carry positive here; the on-chain borrow rates are the live ones.
    function _report() internal {
        uint256 n = credit.routeCount();
        IReg.RouteReport[] memory routes = new IReg.RouteReport[](n);
        for (uint256 i; i < n; ++i) {
            routes[i] = IReg.RouteReport(credit.routeIds(i), 0.1e18, 0);
        }
        uint256 m = credit.vaultCount();
        IReg.VaultReport[] memory vaults = new IReg.VaultReport[](m);
        for (uint256 i; i < m; ++i) {
            vaults[i] = IReg.VaultReport(credit.vaultIds(i), 0.03e18, 0.02e18);
        }
        vm.prank(REPORTER);
        credit.reportRates(routes, vaults);
    }

    function _target(bytes32 route) internal view returns (uint256 amount) {
        R.Health memory h = lens.health(route, address(this));
        amount = (h.budgetValue - h.debtValue) * 99 / 100;
    }

    /// @dev Every action must fit well inside BSC's per-transaction limit of 16,777,216 gas.
    uint256 internal constant GAS_CEILING = 12_000_000;
    /// @dev Raw units an action may cost the strategy in share rounding (a Venus vToken unit is ~3e8).
    int256 internal constant EQUITY_TOLERANCE = 1e13;
    uint256 private _gasAtStart;
    int256 private _equityAtStart;

    /// @dev The account's loan-side money over the four tokens, at 1 USD each: its own balances, what sits in
    /// its box (idle and in vaults), minus its debts. An action moves money between these and must not lose any.
    function _equity() internal returns (int256 e) {
        address[4] memory tokens = [USDT, USDC, USD1, U];
        for (uint256 i; i < 4; ++i) {
            lens.syncToken(address(this), tokens[i]);
            e += int256(IERC20(tokens[i]).balanceOf(address(this)))
            + int256(lens.idleOf(address(this), tokens[i])) - int256(lens.tokenDebt(address(this), tokens[i]));
        }
        bytes32[] memory held = credit.accountVaults(address(this));
        for (uint256 i; i < held.length; ++i) {
            e += int256(lens.vaultStatus(held[i], address(this)).assets);
        }
    }

    function _begin() internal {
        _equityAtStart = _equity();
        _gasAtStart = gasleft();
    }

    function _end(string memory label) internal {
        uint256 used = _gasAtStart - gasleft();
        console2.log(string.concat("  ", label, " gas"), used);
        assertLt(used, GAS_CEILING, string.concat(label, ": above the gas ceiling"));
        assertGe(
            _equity() + EQUITY_TOLERANCE, _equityAtStart, string.concat(label, ": strategy money was lost")
        );
    }

    function _open(bytes32 route, bytes32 vault, uint256 collateral, uint256 borrow) internal {
        _begin();
        lend.executeOpen(address(this), route, vault, collateral, borrow, block.timestamp);
        _end("open");
    }

    function _reduce(bytes32 route, bytes32 vault, uint256 repay, uint256 withdraw, uint256 cash) internal {
        _begin();
        lend.executeReduce(address(this), route, vault, repay, withdraw, cash, block.timestamp);
        _end("reduce");
    }

    function _migrate(
        string memory label,
        bytes32 from,
        bytes32 fromVault,
        bytes32 to,
        bytes32 toVault,
        uint256 borrow,
        uint256 cash
    ) internal {
        _begin();
        lend.executeMigrate(address(this), from, fromVault, to, toVault, borrow, cash, block.timestamp);
        _end(label);
    }

    /// @dev What the account itself must add to repay the whole route from `vault`: the box's money against
    /// the debt, measured and bounded (a shortfall beyond what the carry of the elapsed days explains fails
    /// the test) instead of hidden behind a generous balance. Funds exactly that, plus dust for the interest
    /// of the next block, and returns it as `maxCashIn`.
    function _topUp(bytes32 route, bytes32 vault, uint256 boundBps) internal returns (uint256 cash) {
        R.Route memory r = credit.route(route);
        lens.sync(route, address(this));
        uint256 owed = lens.routeDebt(route, address(this));
        uint256 have = lens.idleOf(address(this), r.loan)
            + (vault == bytes32(0) ? 0 : lens.vaultStatus(vault, address(this)).assets);
        if (have < owed) {
            cash = owed - have;
            console2.log("  box short of the route's debt by (raw units)", cash);
            assertLe(cash, owed * boundBps / 10_000 + 1e12, "shortfall beyond what the carry explains");
        }
        cash += 1e12;
        deal(r.loan, address(this), IERC20(r.loan).balanceOf(address(this)) + cash);
        IERC20(r.loan).approve(address(lend), MAX);
    }

    /// @dev Let interest run. The venues' oracles refuse prices that are too old, so the prices of the
    /// moment are pinned first (a warp is not a market move); rates are reported again like the backend does.
    function _accrue(uint256 time) internal {
        _pinPrices();
        skip(time);
        vm.roll(block.number + time * 20 / 9); // 0.45 s blocks
        _report();
    }

    function _pinPrices() internal {
        bytes32[4] memory markets = [M_NVDAB_USD1, M_QQQB_USDC, M_QQQB_USD1, M_TSLAB_USDC];
        for (uint256 i; i < 4; ++i) {
            (address loan, address collateral, address oracle,,) =
                IMoolahAdmin(MOOLAH).idToMarketParams(markets[i]);
            _pin(oracle, abi.encodeWithSignature("peek(address)", loan));
            _pin(oracle, abi.encodeWithSignature("peek(address)", collateral));
        }
        // A deposit into a Lista vault supplies its supply-queue markets, and Moolah prices a market on supply:
        // every market in the vaults' supply queues needs a live price too.
        address[3] memory listaVaults = [LISTA_VAULT_USD1, LISTA_VAULT_USDC, LISTA_VAULT_U];
        for (uint256 v; v < 3; ++v) {
            uint256 n = IListaQueue(listaVaults[v]).supplyQueueLength();
            for (uint256 i; i < n; ++i) {
                (address loan, address collateral, address oracle,,) =
                    IMoolahAdmin(MOOLAH).idToMarketParams(IListaQueue(listaVaults[v]).supplyQueue(i));
                _pin(oracle, abi.encodeWithSignature("peek(address)", loan));
                _pin(oracle, abi.encodeWithSignature("peek(address)", collateral));
            }
        }
        address venusOracle = IVenusAdmin(COMPTROLLER).oracle();
        address[6] memory vTokens = [V_USDT, V_USDC, V_USD1, V_U, V_TSLAB, V_SPCXB];
        address[6] memory underlyings = [USDT, USDC, USD1, U, TSLAB, SPCXB];
        for (uint256 i; i < 6; ++i) {
            _pin(venusOracle, abi.encodeWithSignature("getUnderlyingPrice(address)", vTokens[i]));
            // Venus' price-protection hook on redeem / borrow reads the asset price directly.
            _pin(venusOracle, abi.encodeWithSignature("getPrice(address)", underlyings[i]));
        }
        // The comptroller also asks the oracle to refresh its bounds on every action; that refresh rejects
        // an old price too.
        vm.mockCall(venusOracle, abi.encodeWithSignature("updatePrice(address)"), "");
        vm.mockCall(venusOracle, abi.encodeWithSignature("updateAssetPrice(address)"), "");
    }

    function _pin(address target, bytes memory data) internal {
        (bool ok, bytes memory ret) = target.staticcall(data);
        if (ok) vm.mockCall(target, data, ret); // a price that is already unreadable stays unreadable
    }

    function _assertClean(address token) internal view {
        assertEq(IERC20(token).balanceOf(address(lend)), 0, "executor holds tokens");
    }

    // ---- route 1: Lista TSLAB/USDC -> Lista USDC vault, migrate to Venus TSLAB/USDC -> Venus vUSDC ----

    function test_fork_route1_listaUsdc_toVenusUsdc() public {
        _open(L_TSLAB_USDC, bytes32(0), 5e18, 0);
        uint256 borrow = _target(L_TSLAB_USDC);
        console2.log("route1 borrow USDC", borrow / 1e18);
        uint256 cash = IERC20(USDC).balanceOf(address(this));
        _open(L_TSLAB_USDC, K_LISTA_USDC, 0, borrow);
        assertEq(IERC20(USDC).balanceOf(address(this)), cash, "borrowed token reached the account");
        assertGt(IERC20(LISTA_VAULT_USDC).balanceOf(lend.boxOf(address(this))), 0);
        assertEq(IERC20(LISTA_VAULT_USDC).balanceOf(address(this)), 0);
        _accrue(3 days);
        _reduce(L_TSLAB_USDC, K_LISTA_USDC, borrow / 4, 0, 0);
        assertApproxEqRel(lens.debt(L_TSLAB_USDC, address(this)), borrow * 3 / 4, 0.01e18);

        // Migrate to Venus (same collateral, same loan token), new debt into Venus vUSDC.
        uint256 left = borrow * 3 / 4;
        _migrate(
            "migrate (Lista -> Venus)",
            L_TSLAB_USDC,
            K_LISTA_USDC,
            V_TSLAB_USDC,
            K_VENUS_USDC,
            left,
            _topUp(L_TSLAB_USDC, K_LISTA_USDC, 10)
        );
        assertEq(lens.debt(L_TSLAB_USDC, address(this)), 0);
        assertEq(lens.collateral(L_TSLAB_USDC, address(this)), 0);
        assertApproxEqRel(lens.collateral(V_TSLAB_USDC, address(this)), 5e18, 1e12);
        assertApproxEqAbs(lens.debt(V_TSLAB_USDC, address(this)), left, 2);
        assertGt(IERC20(V_USDC).balanceOf(lend.boxOf(address(this))), 0);
        assertEq(IERC20(V_USDC).balanceOf(address(this)), 0);
        _accrue(3 days);

        // Close. vUSDC supply pays less than the Venus borrow costs: the measured gap comes from the account.
        _reduce(V_TSLAB_USDC, K_VENUS_USDC, MAX, MAX, _topUp(V_TSLAB_USDC, K_VENUS_USDC, 10));
        assertEq(lens.debt(V_TSLAB_USDC, address(this)), 0);
        assertApproxEqRel(IERC20(TSLAB).balanceOf(address(this)), 100e18, 1e12);
        assertEq(credit.accountRoutes(address(this)).length, 0);
        assertEq(credit.accountVaults(address(this)).length, 0);
        assertEq(credit.accountPrincipalUsd(address(this)), 0);
        _assertClean(USDC);
        _assertClean(TSLAB);
    }

    // ---- route 2: Lista QQQB/USDC -> Lista USDC vault, migrate across tokens to Lista QQQB/USD1 ----

    function test_fork_route2_listaUsdc_toListaUsd1_acrossTokens() public {
        _open(L_QQQB_USDC, bytes32(0), 2e18, 0);
        uint256 borrow = _target(L_QQQB_USDC);
        console2.log("route2 borrow USDC", borrow / 1e18);
        _open(L_QQQB_USDC, K_LISTA_USDC, 0, borrow);
        assertEq(lens.targetLtv(L_QQQB_USDC), 0.35e18, "index tier binds below LLTV/2");
        _accrue(2 days);
        _reduce(L_QQQB_USDC, K_LISTA_USDC, borrow / 5, 0, 0);

        _migrate(
            "migrate (USDC -> USD1, two Lista vaults)",
            L_QQQB_USDC,
            K_LISTA_USDC,
            L_QQQB_USD1,
            K_LISTA_USD1,
            borrow * 3 / 4,
            _topUp(L_QQQB_USDC, K_LISTA_USDC, 10)
        );
        assertEq(lens.debt(L_QQQB_USDC, address(this)), 0);
        assertEq(lens.collateral(L_QQQB_USD1, address(this)), 2e18);
        assertApproxEqAbs(lens.debt(L_QQQB_USD1, address(this)), borrow * 3 / 4, 2);
        _accrue(2 days);
        _reduce(L_QQQB_USD1, K_LISTA_USD1, MAX, MAX, _topUp(L_QQQB_USD1, K_LISTA_USD1, 10));
        assertEq(lens.debt(L_QQQB_USD1, address(this)), 0);
        assertEq(IERC20(qqqb).balanceOf(address(this)), 100e18);
        assertEq(credit.accountRoutes(address(this)).length, 0);
        _assertClean(USDC);
        _assertClean(USD1);
        _assertClean(qqqb);
    }

    // ---- route 3: Venus TSLAB/USDT -> Aave USDT, change loan token to U -> Venus vU, then to Lista ----

    function test_fork_route3_venusUsdt_aave_toVenusU_toLista() public {
        _open(V_TSLAB_USDT, bytes32(0), 5e18, 0);
        uint256 borrow = _target(V_TSLAB_USDT);
        console2.log("route3 borrow USDT", borrow / 1e18);
        uint256 cash = IERC20(USDT).balanceOf(address(this)); // the test address holds dust on mainnet
        _open(V_TSLAB_USDT, K_AAVE_USDT, 0, borrow);
        assertEq(IERC20(USDT).balanceOf(address(this)), cash, "borrowed token reached the account");
        _accrue(3 days);
        _reduce(V_TSLAB_USDT, K_AAVE_USDT, borrow / 4, 0, 0);

        _migrate(
            "migrate (Venus loan token USDT -> U)",
            V_TSLAB_USDT,
            K_AAVE_USDT,
            V_TSLAB_U,
            K_VENUS_U,
            borrow / 2,
            _topUp(V_TSLAB_USDT, K_AAVE_USDT, 10)
        );
        assertEq(lens.debt(V_TSLAB_USDT, address(this)), 0);
        assertEq(lens.debt(V_TSLAB_U, address(this)), borrow / 2);
        assertEq(credit.accountRoutes(address(this)).length, 1);
        _accrue(3 days);

        // Venus -> Lista, new debt in USDC into Aave USDC.
        _migrate(
            "migrate (Venus -> Lista)",
            V_TSLAB_U,
            K_VENUS_U,
            L_TSLAB_USDC,
            K_AAVE_USDC,
            borrow / 2,
            _topUp(V_TSLAB_U, K_VENUS_U, 10)
        );
        assertEq(IERC20(V_TSLAB).balanceOf(address(this)), 0);
        assertApproxEqRel(lens.collateral(L_TSLAB_USDC, address(this)), 5e18, 1e12);
        _accrue(1 days);
        _reduce(L_TSLAB_USDC, K_AAVE_USDC, MAX, MAX, _topUp(L_TSLAB_USDC, K_AAVE_USDC, 10));
        assertApproxEqRel(IERC20(TSLAB).balanceOf(address(this)), 100e18, 1e12);
        assertEq(credit.accountRoutes(address(this)).length, 0);
        _assertClean(USDT);
        _assertClean(USDC);
        _assertClean(U);
        _assertClean(TSLAB);
    }

    // ---- route 4: Lista NVDAB/USD1 -> Lista USD1 vault, switch vault to Venus vUSD1 ----

    function test_fork_route4_listaNvdabUsd1_switchVault() public {
        _open(L_NVDAB_USD1, bytes32(0), 10e18, 0);
        uint256 borrow = _target(L_NVDAB_USD1);
        console2.log("route4 borrow USD1", borrow / 1e18);
        (uint256 utilization,) = lens.borrowMarket(L_NVDAB_USD1);
        console2.log("  NVDAB/USD1 utilization bps", utilization);
        // Lista's rate model steers markets to about 90% (this one was at 92.7% on 2026-11-24): the default
        // 95% limit admits it. A route limit below the live utilization keeps it closed.
        assertEq(credit.route(L_NVDAB_USD1).maxUtilizationBps, 9_500);
        credit.setRouteMaxUtilization(L_NVDAB_USD1, uint16(utilization - 1));
        vm.expectRevert(abi.encodeWithSelector(IExec.GateClosed.selector, uint8(R.Gate.BORROW_UTILIZATION)));
        lend.executeOpen(address(this), L_NVDAB_USD1, K_LISTA_USD1, 0, borrow, block.timestamp);
        // Back to the default, raised only if the live market happens to sit above 95% today.
        credit.setRouteMaxUtilization(L_NVDAB_USD1, utilization >= 9_490 ? 9_900 : 9_500);
        _open(L_NVDAB_USD1, K_LISTA_USD1, 0, borrow);
        _accrue(3 days);
        _reduce(L_NVDAB_USD1, K_LISTA_USD1, borrow / 4, 0, 0);
        _begin();
        lend.executeSwitchVault(address(this), K_LISTA_USD1, K_VENUS_USD1, MAX, block.timestamp);
        _end("switch vault");
        assertEq(IERC20(LISTA_VAULT_USD1).balanceOf(lend.boxOf(address(this))), 0);
        assertGt(IERC20(V_USD1).balanceOf(lend.boxOf(address(this))), 0);
        _accrue(2 days);
        _reduce(L_NVDAB_USD1, K_VENUS_USD1, MAX, MAX, _topUp(L_NVDAB_USD1, K_VENUS_USD1, 10));
        assertEq(lens.debt(L_NVDAB_USD1, address(this)), 0);
        assertEq(IERC20(NVDAB).balanceOf(address(this)), 100e18);
        assertEq(credit.accountRoutes(address(this)).length, 0);
        assertEq(credit.accountVaults(address(this)).length, 0);
        _assertClean(USD1);
    }

    // ---- Venus: two positions, one shared debt ----

    function test_fork_venus_twoPositions_close() public {
        _open(V_TSLAB_USDT, bytes32(0), 5e18, 0);
        _open(V_SPCXB_USDT, bytes32(0), 5e18, 0);
        uint256 borrow = _target(V_TSLAB_USDT) / 2;
        console2.log("venus x2 borrow USDT each", borrow / 1e18);
        // The Lista (Gauntlet) USDT vault has an empty supply queue today and takes no deposit.
        vm.expectRevert();
        lend.executeOpen(address(this), V_TSLAB_USDT, K_LISTA_USDT, 0, borrow, block.timestamp);
        _open(V_TSLAB_USDT, K_AAVE_USDT, 0, borrow);
        _open(V_SPCXB_USDT, K_AAVE_USDT, 0, borrow);
        assertEq(lens.debt(V_TSLAB_USDT, address(this)), 2 * borrow);
        assertEq(lens.routeDebt(V_SPCXB_USDT, address(this)), borrow);
        _accrue(5 days);
        // The first close repays its half from the pooled vault, which still covers it: no cash needed.
        _reduce(V_SPCXB_USDT, K_AAVE_USDT, MAX, MAX, 0);
        assertApproxEqRel(IERC20(SPCXB).balanceOf(address(this)), 100e18, 1e12);
        assertGt(lens.debt(V_TSLAB_USDT, address(this)), 0);
        // The last close carries the whole negative carry of five days (Aave pays less than Venus charges).
        _reduce(V_TSLAB_USDT, K_AAVE_USDT, MAX, MAX, _topUp(V_TSLAB_USDT, K_AAVE_USDT, 20));
        assertApproxEqRel(IERC20(TSLAB).balanceOf(address(this)), 100e18, 1e12);
        assertEq(lens.tokenDebt(address(this), USDT), 0);
        assertEq(credit.accountRoutes(address(this)).length, 0);
        assertEq(credit.accountVaults(address(this)).length, 0);
        _assertClean(USDT);
    }

    // ---- failure cases ----

    function test_fork_fail_healthBreach_and_liquidityExhausted() public {
        credit.setRouteMaxUtilization(L_NVDAB_USD1, 10_000);
        _open(L_NVDAB_USD1, bytes32(0), 10e18, 0);
        R.Health memory h = lens.health(L_NVDAB_USD1, address(this));
        vm.expectRevert();
        lend.executeOpen(
            address(this), L_NVDAB_USD1, K_LISTA_USD1, 0, h.budgetValue * 102 / 100, block.timestamp
        );
        // More than the market has left to lend.
        (uint128 supplied,, uint128 borrowed,,,) = IMoolahAdmin(MOOLAH).market(M_NVDAB_USD1);
        uint256 liquidity = supplied - borrowed;
        deal(NVDAB, address(this), 1_000_000e18);
        lend.executeOpen(address(this), L_NVDAB_USD1, bytes32(0), 900_000e18, 0, block.timestamp);
        vm.expectRevert();
        lend.executeOpen(address(this), L_NVDAB_USD1, K_LISTA_USD1, 0, liquidity + 1e18, block.timestamp);
    }

    function test_fork_fail_negativeCarry_and_unreadableVault() public {
        _open(V_TSLAB_USDT, bytes32(0), 5e18, 0);
        uint256 borrow = _target(V_TSLAB_USDT);
        // No fresh reports: Venus supply on vUSDT pays less than Venus charges to borrow USDT.
        _pinPrices();
        skip(3 days);
        vm.roll(block.number + 1);
        R.Quote memory q = lens.quote(V_TSLAB_USDT, K_VENUS_USDT);
        console2.log("venus USDT borrow rate bps", q.borrowRate / 1e14);
        console2.log("venus USDT supply rate bps", q.vaultRate / 1e14);
        assertEq(uint8(q.gate), uint8(R.Gate.NEGATIVE_CARRY));
        vm.expectRevert(abi.encodeWithSelector(IExec.GateClosed.selector, uint8(R.Gate.NEGATIVE_CARRY)));
        lend.executeOpen(address(this), V_TSLAB_USDT, K_VENUS_USDT, 0, borrow, block.timestamp);
        // A Lista vault's rate is not on chain: without a fresh report the pair is closed.
        assertEq(uint8(lens.quote(V_TSLAB_USDT, K_LISTA_USDT).gate), uint8(R.Gate.VAULT_UNREADABLE));
        vm.expectRevert(abi.encodeWithSelector(IExec.GateClosed.selector, uint8(R.Gate.VAULT_UNREADABLE)));
        lend.executeOpen(address(this), V_TSLAB_USDT, K_LISTA_USDT, 0, borrow, block.timestamp);
        q = lens.quote(V_TSLAB_USDT, K_AAVE_USDT);
        console2.log("aave USDT supply rate bps", q.vaultRate / 1e14);
    }

    function test_fork_fail_paused() public {
        _open(L_QQQB_USD1, bytes32(0), 2e18, 0);
        uint256 borrow = _target(L_QQQB_USD1);
        _open(L_QQQB_USD1, K_LISTA_USD1, 0, borrow / 2);
        credit.setPaused(true);
        vm.expectRevert(IReg.AdmissionClosed.selector);
        lend.executeOpen(address(this), L_QQQB_USD1, K_LISTA_USD1, 0, borrow / 4, block.timestamp);
        credit.setPaused(false);
        pins.set(true);
        vm.expectRevert(IReg.AdmissionClosed.selector);
        lend.executeOpen(address(this), L_QQQB_USD1, K_LISTA_USD1, 0, borrow / 4, block.timestamp);
        credit.setRoute(L_QQQB_USD1, false, true);
        // Every exit stays open while everything is paused and the route retired. Closed in the block it was
        // opened: the vault is a few raw units short of the debt (share rounding), nothing more.
        _reduce(L_QQQB_USD1, K_LISTA_USD1, MAX, MAX, _topUp(L_QQQB_USD1, K_LISTA_USD1, 0));
        assertEq(IERC20(qqqb).balanceOf(address(this)), 100e18);
    }

    function test_fork_deleverage_afterPriceDrop() public {
        _open(L_QQQB_USD1, bytes32(0), 2e18, 0);
        uint256 borrow = _target(L_QQQB_USD1);
        _open(L_QQQB_USD1, K_LISTA_USD1, 0, borrow);
        vm.prank(KEEPER);
        vm.expectRevert(IExec.NothingToDo.selector);
        lend.executeDeleverage(address(this), L_QQQB_USD1, K_LISTA_USD1, MAX);
        // The market's oracle reports QQQB 35% lower: LTV crosses the deleverage line (2/3 of LLTV).
        _mockPrice(M_QQQB_USD1, qqqb, 65);
        R.Health memory h = lens.health(L_QQQB_USD1, address(this));
        assertGe(h.debtValue, h.deleverageValue);
        _begin();
        vm.prank(KEEPER);
        uint256 repaid = lend.executeDeleverage(address(this), L_QQQB_USD1, K_LISTA_USD1, MAX);
        _end("deleverage");
        console2.log("  deleverage repaid USD1", repaid / 1e18);
        h = lens.health(L_QQQB_USD1, address(this));
        assertLe(h.debtValue, h.budgetValue);
        assertEq(IERC20(USD1).balanceOf(KEEPER), 0);
    }

    /// @dev Review M2 / M3 (the reviewer's fork PoC): a fresh position whose Lista vault holds a few raw units
    /// less than the debt, and a price so low that the health line asks for the whole debt. It used to walk
    /// the vault twice (11.8M gas) and then revert on Moolah's minimum loan. Now: one vault call, the minimum
    /// (plus a 1% margin) stays as debt, and the rest of the vault's money waits in the box.
    function test_fork_M2_deleverageWholeDebt_vaultShortByDust() public {
        _open(L_QQQB_USD1, bytes32(0), 2e18, 0);
        uint256 borrow = _target(L_QQQB_USD1);
        _open(L_QQQB_USD1, K_LISTA_USD1, 0, borrow);
        _mockPrice(M_QQQB_USD1, qqqb, 3);
        uint256 owed = lens.debt(L_QQQB_USD1, address(this));
        uint256 floor = lens.minLoan(L_QQQB_USD1);
        assertGt(floor, 0, "Moolah publishes its minimum loan");
        assertEq(lens.deleverageAmount(L_QQQB_USD1, address(this)), owed, "the line asks for all of it");
        _begin();
        vm.prank(KEEPER);
        uint256 repaid = lend.executeDeleverage(address(this), L_QQQB_USD1, K_LISTA_USD1, MAX);
        _end("deleverage (whole debt, vault short by dust)");
        uint256 left = lens.debt(L_QQQB_USD1, address(this));
        console2.log("  owed / repaid / left", owed, repaid, left);
        if (left != 0) {
            assertGe(left, floor, "left below Moolah's minimum loan");
            assertLe(left, floor * 102 / 100 + 1e12);
            assertGt(lens.idleOf(address(this), USD1), 0, "the rest of the vault's money is in the box");
        }
        assertEq(IERC20(USD1).balanceOf(KEEPER), 0);
        assertEq(IERC20(USD1).balanceOf(address(lend)), 0);
    }

    /// @dev Make a Lista market's oracle report `percent`% of the collateral's current price.
    function _mockPrice(bytes32 market, address collateral, uint256 percent) internal {
        (,, address oracle,,) = IMoolahAdmin(MOOLAH).idToMarketParams(market);
        (, bytes memory ret) = oracle.staticcall(abi.encodeWithSignature("peek(address)", collateral));
        uint256 price = abi.decode(ret, (uint256));
        vm.mockCall(
            oracle, abi.encodeWithSignature("peek(address)", collateral), abi.encode(price * percent / 100)
        );
    }
}
