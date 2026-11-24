// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Script, console } from "forge-std/Script.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { AtpExecutor } from "../../src/atp/AtpExecutor.sol";
import { AtpRegistry } from "../../src/atp/AtpRegistry.sol";
import { AtpBorrowExecutor } from "../../src/atp/borrow/AtpBorrowExecutor.sol";
import { AtpBorrowRegistry } from "../../src/atp/borrow/AtpBorrowRegistry.sol";
import { BorrowTypes as BT } from "../../src/atp/borrow/BorrowTypes.sol";
import { MoolahParams } from "../../src/atp/yield/YieldInterfaces.sol";
import { AtpBorrowExecutorV2 } from "../../src/atp/borrow/v2/AtpBorrowExecutorV2.sol";
import { AtpBorrowExecutorV2Extension } from "../../src/atp/borrow/v2/AtpBorrowExecutorV2Extension.sol";
import { IAtpBorrowExecutorV2 } from "../../src/atp/borrow/v2/IAtpBorrowExecutorV2.sol";
import { AtpBorrowRegistryV2 } from "../../src/atp/borrow/v2/AtpBorrowRegistryV2.sol";
import { AtpBorrowLensV2 } from "../../src/atp/borrow/v2/AtpBorrowLensV2.sol";
import { IAtpBorrowRegistryV2 } from "../../src/atp/borrow/v2/IAtpBorrowRegistryV2.sol";
import { RoutingV2Deployer } from "../../src/atp/borrow/v2/RoutingV2Deployer.sol";
import {
    Erc4626VaultAdapter,
    VenusVaultAdapter,
    AaveVaultAdapter
} from "../../src/atp/borrow/v2/VaultAdapters.sol";
import { RoutingTypes as R } from "../../src/atp/borrow/v2/RoutingTypes.sol";
import { TestnetToken } from "../../src/testnet/TestnetToken.sol";
import { MockLendingOracle } from "../../src/testnet/lending/MockLendingOracle.sol";
import { MockVenusComptroller } from "../../src/testnet/lending/MockVenusComptroller.sol";
import { MockVToken } from "../../src/testnet/lending/MockVToken.sol";
import { MockMoolah } from "../../src/testnet/lending/MockMoolah.sol";
import { MockRewardEarnVault } from "../../src/testnet/lending/MockRewardEarnVault.sol";
import { MockAavePool } from "../../src/testnet/yield/MockAavePool.sol";
import { TestnetBook as TB } from "./TestnetBook.sol";
import { TestnetRoutingBook as RB } from "./TestnetRoutingBook.sol";

/// @notice Chain 97 only: deploys Strategy Earn routing v2 next to the existing core and the #64 / #67 lending
/// mocks, which it reuses (lending oracle, Venus comptroller, vUSDT, Lista Moolah, every listed collateral).
/// Nothing already deployed is changed except that the existing mocks get new markets and new USDT minters.
/// New: mock USDC / USD1 / U and a mock reward token (LISTA); a Venus market per new loan token; Lista markets
/// in the new loan tokens for `TestnetRoutingBook.listaCollaterals()` (plus Lista USDT markets for NVDAB and
/// TSLAB); an ERC4626 earn vault per loan token and Aave pools for USDT and USDC; the v2 registry, lens and
/// executor (through the single-use `RoutingV2Deployer`) and the three vault adapters; then every route and
/// vault is registered and a first rate report is posted.
/// The sender (DEPLOYER, or OWNER with ROUTING_DEPLOY_SENDER) deploys; OWNER, which owns the registry and the
/// mocks, configures. Idempotent: a rerun broadcasts nothing. Keys: TESTNET_DEPLOYER_KEY / TESTNET_OWNER_KEY
/// (fork: --unlocked). Env: TESTNET_EXECUTOR (manifest contracts.executor), BORROW_EXECUTOR_V1 (manifest
/// borrow.executor): every collateral, tier, vToken and Lista market is read from the v1 registry on chain.
contract DeployBorrowRoutingTestnet is Script {
    struct Out {
        IAtpBorrowExecutorV2 lend;
        AtpBorrowRegistryV2 credit;
        AtpBorrowLensV2 lens;
        address[4] loans; // USDT, USDC, USD1, U
        address[4] loanVTokens;
        address[4] vaults; // ERC4626 earn vaults
        address[4] aave; // Aave pools per loan token (zero = none)
        address rewardToken;
    }

    struct Ctx {
        AtpExecutor core;
        AtpRegistry registry;
        AtpBorrowRegistry v1;
        MockLendingOracle oracle;
        MockVenusComptroller comptroller;
        MockMoolah moolah;
        address sender;
    }

    function run() external returns (Out memory o) {
        require(block.chainid == 97, "routing deploy: chain 97 only");
        _rememberKey("TESTNET_DEPLOYER_KEY", TB.DEPLOYER);
        _rememberKey("TESTNET_OWNER_KEY", TB.OWNER);
        Ctx memory c;
        c.core = AtpExecutor(vm.envAddress("TESTNET_EXECUTOR"));
        c.registry = c.core.registry();
        require(c.registry.owner() == TB.OWNER, "routing deploy: registry owner");
        c.v1 = AtpBorrowExecutor(vm.envAddress("BORROW_EXECUTOR_V1")).borrowRegistry();
        c.sender = vm.envOr("ROUTING_DEPLOY_SENDER", TB.DEPLOYER);
        require(c.sender == TB.DEPLOYER || c.sender == TB.OWNER, "routing deploy: sender");
        o.loans[0] = c.core.numeraire();
        _venues(c, o);

        // 1. Contracts (CREATE2 through the deterministic deployer; the trio through its single-use deployer).
        RB.Loan[] memory extra = RB.loans();
        RB.Loan memory usdt = RB.usdt();
        vm.startBroadcast(c.sender);
        o.rewardToken = _create2(
            "routing.token.LISTA",
            abi.encodePacked(
                type(TestnetToken).creationCode,
                abi.encode("Testnet Lista reward", "LISTA", uint8(18), TB.OWNER)
            )
        );
        for (uint256 i; i < 3; ++i) {
            o.loans[i + 1] = _create2(
                string.concat("routing.token.", extra[i].symbol),
                abi.encodePacked(
                    type(TestnetToken).creationCode,
                    abi.encode(extra[i].name, extra[i].symbol, uint8(18), TB.OWNER)
                )
            );
            o.loanVTokens[i + 1] = _create2(
                string.concat("routing.venus.v", extra[i].symbol),
                abi.encodePacked(
                    type(MockVToken).creationCode,
                    abi.encode(
                        o.loans[i + 1],
                        address(c.comptroller),
                        TB.OWNER,
                        extra[i].venusBorrowBps,
                        extra[i].symbol
                    )
                )
            );
        }
        for (uint256 i; i < 4; ++i) {
            RB.Loan memory l = i == 0 ? usdt : extra[i - 1];
            o.vaults[i] = _create2(
                string.concat("routing.earnVault.", l.symbol),
                abi.encodePacked(
                    type(MockRewardEarnVault).creationCode,
                    abi.encode(o.loans[i], TB.OWNER, l.vaultBps, o.rewardToken)
                )
            );
            if (l.aaveBps != 0) {
                o.aave[i] = _create2(
                    string.concat("routing.aave.", l.symbol),
                    abi.encodePacked(
                        type(MockAavePool).creationCode, abi.encode(o.loans[i], TB.OWNER, l.aaveBps)
                    )
                );
            }
        }
        (o.credit, o.lens, o.lend) = _trio(c);
        address[3] memory adapters = [
            _create2(
                "routing.adapter.erc4626",
                abi.encodePacked(type(Erc4626VaultAdapter).creationCode, abi.encode(address(o.lend)))
            ),
            _create2(
                "routing.adapter.venus",
                abi.encodePacked(type(VenusVaultAdapter).creationCode, abi.encode(address(o.lend)))
            ),
            _create2(
                "routing.adapter.aave",
                abi.encodePacked(type(AaveVaultAdapter).creationCode, abi.encode(address(o.lend)))
            )
        ];
        vm.stopBroadcast();

        // 2. OWNER: mocks (prices, markets, liquidity, simulated rates), then the v2 allowlists.
        vm.startBroadcast(TB.OWNER);
        _mocks(c, o, usdt, extra);
        _allowlists(c, o, adapters);
        _routesAndVaults(c, o);
        _firstReport(o, usdt, extra);
        _revokeOwnerMinter(o.loans[0]);
        vm.stopBroadcast();

        console.log("MANIFEST routingExecutor", address(o.lend));
        console.log("MANIFEST routingRegistry", address(o.credit));
        console.log("MANIFEST routingLens", address(o.lens));
        console.log("MANIFEST routingBoxImplementation", o.lend.boxImplementation());
        console.log("MANIFEST routingRewardToken", o.rewardToken);
        string[4] memory symbols = ["USDT", "USDC", "USD1", "U"];
        for (uint256 i; i < 4; ++i) {
            console.log(string.concat("MANIFEST routing.token.", symbols[i]), o.loans[i]);
            console.log(string.concat("MANIFEST routing.venus.v", symbols[i]), o.loanVTokens[i]);
            console.log(string.concat("MANIFEST routing.earnVault.", symbols[i]), o.vaults[i]);
            if (o.aave[i] != address(0)) {
                console.log(string.concat("MANIFEST routing.aave.", symbols[i]), o.aave[i]);
            }
        }
        console.log("MANIFEST routingRouteCount", o.credit.routeCount());
        console.log("MANIFEST routingVaultCount", o.credit.vaultCount());
    }

    // ---- existing venues, read from the v1 registry ----

    function _venues(Ctx memory c, Out memory o) private view {
        uint256 n = c.v1.marketCount();
        for (uint256 i; i < n; ++i) {
            BT.Market memory m = c.v1.market(c.v1.marketIds(i));
            if (m.kind == BT.Kind.VENUS) {
                c.comptroller = MockVenusComptroller(m.core);
                o.loanVTokens[0] = m.loanVToken;
            } else {
                c.moolah = MockMoolah(m.core);
            }
        }
        require(
            address(c.comptroller) != address(0) && address(c.moolah) != address(0), "routing deploy: venues"
        );
        c.oracle = MockLendingOracle(c.comptroller.oracle());
        require(c.oracle.owner() == TB.OWNER, "routing deploy: oracle owner");
    }

    // ---- the registry / lens / executor trio ----

    function _trio(Ctx memory c)
        private
        returns (AtpBorrowRegistryV2 credit, AtpBorrowLensV2 lens, IAtpBorrowExecutorV2 lend)
    {
        RoutingV2Deployer d = RoutingV2Deployer(
            _create2(
                "routing.deployer",
                abi.encodePacked(type(RoutingV2Deployer).creationCode, abi.encode(c.sender))
            )
        );
        if (d.registry() == address(0)) {
            d.deployRegistry(
                abi.encodePacked(
                    type(AtpBorrowRegistryV2).creationCode,
                    abi.encode(
                        c.registry,
                        address(c.core),
                        d.predictedExecutor(),
                        address(c.comptroller),
                        address(c.moolah)
                    )
                )
            );
        }
        if (d.lens() == address(0)) {
            d.deployLens(abi.encodePacked(type(AtpBorrowLensV2).creationCode, abi.encode(d.registry())));
        }
        address extension =
            _create2("routing.executorExtension", type(AtpBorrowExecutorV2Extension).creationCode);
        if (d.executor() == address(0)) {
            d.deployExecutor(
                abi.encodePacked(
                    type(AtpBorrowExecutorV2).creationCode, abi.encode(d.registry(), d.lens(), extension)
                )
            );
        }
        credit = AtpBorrowRegistryV2(d.registry());
        lens = AtpBorrowLensV2(d.lens());
        lend = IAtpBorrowExecutorV2(d.executor());
        require(
            credit.executor() == address(lend) && lend.borrowRegistry() == address(credit)
                && lend.lens() == address(lens) && lend.extension() == extension
                && address(lens.borrowRegistry()) == address(credit)
                && credit.venusComptroller() == address(c.comptroller)
                && credit.moolah() == address(c.moolah),
            "routing deploy: wiring"
        );
    }

    // ---- mocks ----

    function _mocks(Ctx memory c, Out memory o, RB.Loan memory usdt, RB.Loan[] memory extra) private {
        // Reward token: the vaults mint it.
        for (uint256 i; i < 4; ++i) {
            _minter(o.rewardToken, o.vaults[i]);
        }
        // New loan tokens: price, Venus market with liquidity, simulated-interest minters.
        for (uint256 i = 1; i < 4; ++i) {
            address token = o.loans[i];
            MockVToken v = MockVToken(o.loanVTokens[i]);
            if (c.oracle.prices(token) != 1e8) c.oracle.setPrice(token, 1e8);
            (bool listed,,) = c.comptroller.markets(address(v));
            if (!listed) c.comptroller.supportMarket(address(v));
            _minter(token, address(v));
            _minter(token, address(c.moolah));
            if (v.totalSupply() == 0) {
                _mint(token, RB.VENUS_SEED);
                TestnetToken(token).approve(address(v), RB.VENUS_SEED);
                require(v.mint(RB.VENUS_SEED) == 0, "seed vToken");
            }
        }
        // Earn vaults and Aave pools for all four tokens.
        for (uint256 i; i < 4; ++i) {
            RB.Loan memory l = i == 0 ? usdt : extra[i - 1];
            address token = o.loans[i];
            MockRewardEarnVault vault = MockRewardEarnVault(o.vaults[i]);
            _minter(token, address(vault));
            if (vault.incentiveAprBps() != l.vaultIncentiveBps) {
                vault.setIncentiveAprBps(l.vaultIncentiveBps);
            }
            if (vault.totalSupply() == 0) {
                _mint(token, RB.VAULT_SEED);
                TestnetToken(token).approve(address(vault), RB.VAULT_SEED);
                vault.deposit(RB.VAULT_SEED, TB.OWNER);
            }
            if (o.aave[i] != address(0)) {
                MockAavePool pool = MockAavePool(o.aave[i]);
                _minter(token, pool.receipt());
                if (IERC20Metadata(pool.receipt()).totalSupply() == 0) {
                    _mint(token, RB.VAULT_SEED);
                    TestnetToken(token).approve(address(pool), RB.VAULT_SEED);
                    pool.supply(token, RB.VAULT_SEED, TB.OWNER, 0);
                }
            }
        }
        // Lista markets: the listed collaterals in each new loan token, and USDT for the Venus-only ones.
        string[] memory symbols = RB.listaCollaterals();
        for (uint256 s; s < symbols.length; ++s) {
            (address collateral, uint256 factor, bool hasListaUsdt) = _collateral(c, symbols[s]);
            for (uint256 i; i < 4; ++i) {
                if (i == 0 && hasListaUsdt) continue;
                RB.Loan memory l = i == 0 ? usdt : extra[i - 1];
                MoolahParams memory p =
                    MoolahParams(o.loans[i], collateral, address(c.oracle), address(c.moolah), factor);
                bytes32 id = c.moolah.marketId(p);
                if (c.moolah.market(id).lastUpdate == 0) c.moolah.createMarket(p, l.listaBorrowBps);
                if (c.moolah.collateralIncentiveAprBps(id) != RB.LISTA_COLLATERAL_INCENTIVE_BPS) {
                    c.moolah
                        .setIncentives(id, RB.LISTA_COLLATERAL_INCENTIVE_BPS, RB.LISTA_BORROW_INCENTIVE_BPS);
                }
                if (c.moolah.market(id).totalSupplyAssets == 0) {
                    _mint(o.loans[i], RB.LISTA_SEED);
                    TestnetToken(o.loans[i]).approve(address(c.moolah), RB.LISTA_SEED);
                    c.moolah.supply(p, RB.LISTA_SEED, 0, TB.OWNER, "");
                }
            }
        }
    }

    // ---- v2 allowlists ----

    function _allowlists(Ctx memory c, Out memory o, address[3] memory adapters) private {
        AtpBorrowRegistryV2 credit = o.credit;
        R.VaultKind[3] memory kinds = [R.VaultKind.ERC4626, R.VaultKind.VENUS, R.VaultKind.AAVE];
        for (uint256 i; i < 3; ++i) {
            if (credit.adapterOf(kinds[i]) == address(0)) credit.setAdapter(kinds[i], adapters[i]);
            require(credit.adapterOf(kinds[i]) == adapters[i], "routing deploy: adapter");
        }
        for (uint256 i; i < 4; ++i) {
            if (!credit.loanTokenAllowed(o.loans[i])) credit.setLoanToken(o.loans[i], true);
            if (credit.venusMarket(o.loans[i]) == address(0)) {
                credit.setVenusMarket(o.loans[i], o.loanVTokens[i]);
            }
        }
        if (credit.rateReporter() != TB.OPERATOR && credit.rateReporter() != TB.OWNER) {
            credit.setRateReporter(TB.OWNER); // handed to OPERATOR after the first report
        }
        if (!credit.rewardTokenAllowed(o.rewardToken)) credit.setRewardToken(o.rewardToken, true);
        if (keccak256(credit.rewardProofSuffix()) != keccak256(RB.REWARD_PROOF_SUFFIX)) {
            credit.setRewardProofSuffix(RB.REWARD_PROOF_SUFFIX);
        }
        // Tiers and Venus collateral markets follow the v1 registry.
        uint256 n = c.v1.marketCount();
        for (uint256 i; i < n; ++i) {
            BT.Market memory m = c.v1.market(c.v1.marketIds(i));
            if (uint8(credit.assetTier(m.collateral)) != uint8(m.tier)) {
                credit.setAssetTier(m.collateral, R.Tier(uint8(m.tier)));
            }
            if (m.kind == BT.Kind.VENUS && credit.venusMarket(m.collateral) == address(0)) {
                credit.setVenusMarket(m.collateral, m.collateralVToken);
            }
        }
    }

    function _routesAndVaults(Ctx memory c, Out memory o) private {
        AtpBorrowRegistryV2 credit = o.credit;
        // Every v1 market as a USDT route; Venus collaterals also in the three new loan tokens.
        uint256 n = c.v1.marketCount();
        for (uint256 i; i < n; ++i) {
            BT.Market memory m = c.v1.market(c.v1.marketIds(i));
            if (m.kind == BT.Kind.VENUS) {
                for (uint256 t; t < 4; ++t) {
                    _route(credit, R.Venue.VENUS, m.collateral, o.loans[t], bytes32(0));
                }
            } else {
                _route(credit, R.Venue.LISTA, m.collateral, o.loans[0], m.listaId);
            }
        }
        // The extra Lista markets.
        string[] memory symbols = RB.listaCollaterals();
        for (uint256 s; s < symbols.length; ++s) {
            (address collateral, uint256 factor, bool hasListaUsdt) = _collateral(c, symbols[s]);
            for (uint256 t; t < 4; ++t) {
                if (t == 0 && hasListaUsdt) continue;
                bytes32 id = c.moolah
                    .marketId(
                        MoolahParams(o.loans[t], collateral, address(c.oracle), address(c.moolah), factor)
                    );
                _route(credit, R.Venue.LISTA, collateral, o.loans[t], id);
            }
        }
        for (uint256 t; t < 4; ++t) {
            _vault(credit, R.VaultKind.ERC4626, o.loans[t], o.vaults[t]);
            _vault(credit, R.VaultKind.VENUS, o.loans[t], o.loanVTokens[t]);
            if (o.aave[t] != address(0)) _vault(credit, R.VaultKind.AAVE, o.loans[t], o.aave[t]);
        }
    }

    /// @dev The mocks' simulated incentives and the ERC4626 vault rates, posted the way the backend will.
    function _firstReport(Out memory o, RB.Loan memory usdt, RB.Loan[] memory extra) private {
        AtpBorrowRegistryV2 credit = o.credit;
        if (credit.rateReporter() != TB.OWNER) return; // already handed over
        uint256 n = credit.routeCount();
        IAtpBorrowRegistryV2.RouteReport[] memory routes = new IAtpBorrowRegistryV2.RouteReport[](n);
        for (uint256 i; i < n; ++i) {
            bytes32 id = credit.routeIds(i);
            bool lista = credit.route(id).venue == R.Venue.LISTA;
            routes[i] = IAtpBorrowRegistryV2.RouteReport(
                id,
                lista ? uint256(RB.LISTA_BORROW_INCENTIVE_BPS) * 1e14 : 0,
                lista ? uint256(RB.LISTA_COLLATERAL_INCENTIVE_BPS) * 1e14 : 0
            );
        }
        IAtpBorrowRegistryV2.VaultReport[] memory vaults = new IAtpBorrowRegistryV2.VaultReport[](4);
        for (uint256 t; t < 4; ++t) {
            RB.Loan memory l = t == 0 ? usdt : extra[t - 1];
            vaults[t] = IAtpBorrowRegistryV2.VaultReport(
                credit.vaultIdOf(R.VaultKind.ERC4626, o.loans[t], o.vaults[t]),
                uint256(l.vaultBps) * 1e14,
                uint256(l.vaultIncentiveBps) * 1e14
            );
        }
        credit.reportRates(routes, vaults);
        credit.setRateReporter(TB.OPERATOR);
    }

    // ---- helpers ----

    /// @dev Collateral token, its venue factor in v1 and whether v1 already has a Lista USDT market for it.
    function _collateral(Ctx memory c, string memory symbol)
        private
        view
        returns (address token, uint256 factor, bool hasListaUsdt)
    {
        uint256 n = c.v1.marketCount();
        for (uint256 i; i < n; ++i) {
            bytes32 id = c.v1.marketIds(i);
            BT.Market memory m = c.v1.market(id);
            if (keccak256(bytes(IERC20Metadata(m.collateral).symbol())) != keccak256(bytes(symbol))) {
                continue;
            }
            return (m.collateral, c.v1.liquidationLtv(id), m.kind == BT.Kind.LISTA);
        }
        revert(string.concat("routing deploy: no collateral ", symbol));
    }

    function _route(
        AtpBorrowRegistryV2 credit,
        R.Venue venue,
        address collateral,
        address loan,
        bytes32 listaId
    ) private {
        bytes32 id = credit.routeIdOf(venue, collateral, loan, listaId);
        try credit.route(id) returns (R.Route memory) {
            return;
        } catch { }
        credit.registerRoute(venue, collateral, loan, listaId, RB.ROUTE_CAP);
    }

    function _vault(AtpBorrowRegistryV2 credit, R.VaultKind kind, address token, address target) private {
        bytes32 id = credit.vaultIdOf(kind, token, target);
        try credit.vault(id) returns (R.Vault memory) {
            return;
        } catch { }
        credit.registerVault(kind, token, target);
    }

    function _create2(string memory label, bytes memory initCode) private returns (address expected) {
        expected = TB.create2Address(label, initCode);
        if (expected.code.length != 0) return expected;
        (bool ok, bytes memory result) = TB.CREATE2_FACTORY.call(abi.encodePacked(TB.salt(label), initCode));
        require(
            ok && result.length == 20 && address(bytes20(result)) == expected,
            string.concat("CREATE2 failed: ", label)
        );
    }

    function _minter(address token, address minter) private {
        if (!TestnetToken(token).isMinter(minter)) TestnetToken(token).setMinter(minter, true);
    }

    /// @dev OWNER is a minter of the tokens it deployed here; for USDT it lends itself the role for the seeds
    /// and `_revokeOwnerMinter` takes it back in the same run.
    function _mint(address token, uint256 amount) private {
        _minter(token, TB.OWNER);
        TestnetToken(token).mint(TB.OWNER, amount);
    }

    function _revokeOwnerMinter(address usdt) private {
        if (TestnetToken(usdt).isMinter(TB.OWNER)) TestnetToken(usdt).setMinter(TB.OWNER, false);
    }

    function _rememberKey(string memory name, address expected) private {
        uint256 key = vm.envOr(name, uint256(0));
        if (key == 0) return;
        require(vm.addr(key) == expected, string.concat(name, " does not derive the expected address"));
        vm.rememberKey(key);
    }
}
