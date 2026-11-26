// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Script, console } from "forge-std/Script.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { AtpRegistry } from "../src/atp/AtpRegistry.sol";
import { MoolahParams } from "../src/atp/yield/YieldInterfaces.sol";
import { IVenusComptroller, IMoolahCore } from "../src/atp/borrow/BorrowInterfaces.sol";
import { AtpBorrowExecutorV2 } from "../src/atp/borrow/v2/AtpBorrowExecutorV2.sol";
import { AtpBorrowExecutorV2Extension } from "../src/atp/borrow/v2/AtpBorrowExecutorV2Extension.sol";
import { IAtpBorrowExecutorV2 } from "../src/atp/borrow/v2/IAtpBorrowExecutorV2.sol";
import { AtpBorrowRegistryV2 } from "../src/atp/borrow/v2/AtpBorrowRegistryV2.sol";
import { AtpBorrowLensV2 } from "../src/atp/borrow/v2/AtpBorrowLensV2.sol";
import { RoutingV2Deployer } from "../src/atp/borrow/v2/RoutingV2Deployer.sol";
import { StrategyBox } from "../src/atp/borrow/v2/StrategyBox.sol";
import { IStrategyVaultAdapter } from "../src/atp/borrow/v2/IStrategyVaultAdapter.sol";
import {
    VaultAdapterBase,
    Erc4626VaultAdapter,
    VenusVaultAdapter,
    AaveVaultAdapter
} from "../src/atp/borrow/v2/VaultAdapters.sol";
import { RoutingTypes as R } from "../src/atp/borrow/v2/RoutingTypes.sol";
import { BorrowRoutingMainnetSpecs } from "./BorrowRoutingMainnetSpecs.sol";

interface IRoutingCore {
    function registry() external view returns (AtpRegistry);
    function globalPaused() external view returns (bool);
}

interface IOwned2Step {
    function owner() external view returns (address);
    function pendingOwner() external view returns (address);
}

/// @title DeployBorrowRoutingMainnet
/// @notice Strategy Earn routing v2 on BSC mainnet (chain 56), in three separate steps so that the deployer
/// key never needs an owner role and the owner (a Safe) never needs to deploy:
///
/// 1. `run()` (any funded deployer key, 8 transactions): the single-use `RoutingV2Deployer`, through it the
///    registry / lens / executor trio, the executor's extension, and the three vault adapters. No configuration, no ownership: the
///    registry's owner is `AtpRegistry.owner()` from the first block.
///    Env: ATP_EXECUTOR (the live `AtpExecutor` whose registry and global pause v2 shares),
///    EXPECTED_DEPLOYER_NONCE (the broadcaster's nonce now; a second run reverts instead of deploying twice).
///    Eight transactions with the extension.
/// 2. `printConfig(executor, erc4626Adapter, venusAdapter, aaveAdapter)` (read-only): every owner call still
///    missing for the allowlist in `BorrowRoutingMainnetSpecs`, as (target, calldata) for the Safe.
///    `configure(...)` sends the same calls when the owner is a key (fork rehearsals).
/// 3. `verify(executor)` (read-only; the final check once the Safe has sent the calls): the code of all eight
///    contracts against this repository's build, their wiring, the allowlists equal to the spec exactly (no
///    route or vault more or less), the safety lines of every route, the rate reporter (ATP_RATE_REPORTER,
///    never the operator key), and that ATP_SAFE owns the registry with no pending handover. Reverts on the
///    first mismatch. Env: ATP_EXECUTOR is required and must be the core recorded in
///    `deployments/mainnet.json` (it is never read from the contracts being verified).
///
/// Nothing in this script moves funds, and nothing here was broadcast.
contract DeployBorrowRoutingMainnet is Script, BorrowRoutingMainnetSpecs {
    struct Deployed {
        RoutingV2Deployer deployer;
        AtpBorrowRegistryV2 credit;
        AtpBorrowLensV2 lens;
        IAtpBorrowExecutorV2 lend;
        address extension;
        address[3] adapters; // ERC4626, VENUS, AAVE
    }

    struct Call {
        address target;
        bytes data;
        string label;
    }

    // ---- 1. deploy ----

    function run() external returns (Deployed memory d) {
        require(block.chainid == 56, "DeployBorrowRoutingMainnet: BSC mainnet (56) only");
        address core = vm.envAddress("ATP_EXECUTOR");
        uint64 expectedNonce = uint64(vm.envUint("EXPECTED_DEPLOYER_NONCE"));
        _checkCore(core);

        vm.startBroadcast();
        // Checked after startBroadcast so `msg.sender` is the broadcaster whose nonce actually moves.
        require(
            vm.getNonce(msg.sender) == expectedNonce,
            "deployer nonce != EXPECTED_DEPLOYER_NONCE: already deployed, or a stale value"
        );
        d = _deploy(core, msg.sender);
        vm.stopBroadcast();

        _verifyWiring(core, d.lend);
        console.log("routingDeployer   ", address(d.deployer));
        console.log("routingRegistry   ", address(d.credit));
        console.log("routingLens       ", address(d.lens));
        console.log("routingExecutor   ", address(d.lend));
        console.log("executorExtension ", d.extension);
        console.log("boxImplementation ", d.lend.boxImplementation());
        console.log("erc4626Adapter    ", d.adapters[0]);
        console.log("venusAdapter      ", d.adapters[1]);
        console.log("aaveAdapter       ", d.adapters[2]);
        console.log("registry owner    ", d.credit.registry().owner());
        console.log(
            "Next: printConfig(executor, erc4626Adapter, venusAdapter, aaveAdapter), then verify(executor)."
        );
    }

    /// @dev The live core must be the stack that has the global pause and a registry v2 can share.
    function _checkCore(address core) internal view {
        require(core.code.length != 0, "ATP_EXECUTOR has no code");
        AtpRegistry registry = IRoutingCore(core).registry();
        require(address(registry).code.length != 0, "ATP_EXECUTOR.registry() has no code");
        IRoutingCore(core).globalPaused(); // reverts on an executor without the global pause
        require(registry.owner() != address(0), "registry without owner");
        require(
            VENUS_COMPTROLLER.code.length != 0 && LISTA_MOOLAH.code.length != 0
                && AAVE_V3_POOL.code.length != 0,
            "venue without code"
        );
    }

    /// @dev `sender` is the account these creations and calls come from: the broadcaster in `run()`.
    function _deploy(address core, address sender) internal returns (Deployed memory d) {
        AtpRegistry registry = IRoutingCore(core).registry();
        d.deployer = new RoutingV2Deployer(sender);
        d.credit = AtpBorrowRegistryV2(
            d.deployer
                .deployRegistry(
                    abi.encodePacked(
                        type(AtpBorrowRegistryV2).creationCode,
                        abi.encode(
                            registry, core, d.deployer.predictedExecutor(), VENUS_COMPTROLLER, LISTA_MOOLAH
                        )
                    )
                )
        );
        d.lens = AtpBorrowLensV2(
            d.deployer.deployLens(abi.encodePacked(type(AtpBorrowLensV2).creationCode, abi.encode(d.credit)))
        );
        d.extension = address(new AtpBorrowExecutorV2Extension());
        d.lend = IAtpBorrowExecutorV2(
            d.deployer
                .deployExecutor(
                    abi.encodePacked(
                        type(AtpBorrowExecutorV2).creationCode, abi.encode(d.credit, d.lens, d.extension)
                    )
                )
        );
        d.adapters[0] = address(new Erc4626VaultAdapter(address(d.lend)));
        d.adapters[1] = address(new VenusVaultAdapter(address(d.lend)));
        d.adapters[2] = address(new AaveVaultAdapter(address(d.lend)));
    }

    // ---- 2. owner configuration ----

    /// @notice Every owner call the spec still needs, in the order they must be sent. Empty when done.
    function configCalls(address executor, address[3] memory adapters)
        public
        view
        returns (Call[] memory calls)
    {
        IAtpBorrowExecutorV2 lend = IAtpBorrowExecutorV2(executor);
        AtpBorrowRegistryV2 credit = AtpBorrowRegistryV2(lend.borrowRegistry());
        address target = address(credit);
        Call[] memory buffer = new Call[](128);
        uint256 n;

        R.VaultKind[3] memory kinds = [R.VaultKind.ERC4626, R.VaultKind.VENUS, R.VaultKind.AAVE];
        for (uint256 i; i < 3; ++i) {
            require(
                IStrategyVaultAdapter(adapters[i]).kind() == uint8(kinds[i])
                    && VaultAdapterBase(adapters[i]).executor() == executor,
                "adapter does not belong to this executor"
            );
            address set = credit.adapterOf(kinds[i]);
            require(set == address(0) || set == adapters[i], "another adapter is already set");
            if (set == address(0)) {
                buffer[n++] =
                    Call(target, abi.encodeCall(credit.setAdapter, (kinds[i], adapters[i])), "setAdapter");
            }
        }
        address[4] memory loans = _loans();
        address[4] memory loanVTokens = _loanVTokens();
        for (uint256 i; i < 4; ++i) {
            require(IERC20Metadata(loans[i]).decimals() == 18, "loan token decimals");
            if (!credit.loanTokenAllowed(loans[i])) {
                buffer[n++] =
                    Call(target, abi.encodeCall(credit.setLoanToken, (loans[i], true)), "setLoanToken");
            }
            if (credit.venusMarket(loans[i]) != loanVTokens[i]) {
                buffer[n++] = Call(
                    target,
                    abi.encodeCall(credit.setVenusMarket, (loans[i], loanVTokens[i])),
                    "setVenusMarket"
                );
            }
        }
        VenusCollateral[] memory venus = _venusCollaterals();
        for (uint256 i; i < venus.length; ++i) {
            _requireSymbol(venus[i].asset, venus[i].symbol);
            if (credit.venusMarket(venus[i].asset) != venus[i].vToken) {
                buffer[n++] = Call(
                    target,
                    abi.encodeCall(credit.setVenusMarket, (venus[i].asset, venus[i].vToken)),
                    string.concat("setVenusMarket ", venus[i].symbol)
                );
            }
            if (credit.assetTier(venus[i].asset) != venus[i].tier) {
                buffer[n++] = Call(
                    target,
                    abi.encodeCall(credit.setAssetTier, (venus[i].asset, venus[i].tier)),
                    string.concat("setAssetTier ", venus[i].symbol)
                );
            }
            for (uint256 t; t < 4; ++t) {
                if (!_routeExists(
                        credit, credit.routeIdOf(R.Venue.VENUS, venus[i].asset, loans[t], bytes32(0))
                    )) {
                    buffer[n++] = Call(
                        target,
                        abi.encodeCall(
                            credit.registerRoute,
                            (R.Venue.VENUS, venus[i].asset, loans[t], bytes32(0), ROUTE_CAP)
                        ),
                        string.concat("registerRoute Venus ", venus[i].symbol)
                    );
                }
            }
        }
        ListaMarket[] memory lista = _listaMarkets();
        for (uint256 i; i < lista.length; ++i) {
            (address collateral, address loan) = _listaTokens(lista[i]);
            // The same collateral appears in several markets: queue its tier once.
            bool queued;
            for (uint256 j; j < i && !queued; ++j) {
                (address earlier,) = _listaTokens(lista[j]);
                queued = earlier == collateral;
            }
            if (!queued && credit.assetTier(collateral) != lista[i].tier) {
                buffer[n++] = Call(
                    target,
                    abi.encodeCall(credit.setAssetTier, (collateral, lista[i].tier)),
                    string.concat("setAssetTier ", lista[i].label)
                );
            }
            if (!_routeExists(credit, credit.routeIdOf(R.Venue.LISTA, collateral, loan, lista[i].id))) {
                buffer[n++] = Call(
                    target,
                    abi.encodeCall(
                        credit.registerRoute, (R.Venue.LISTA, collateral, loan, lista[i].id, ROUTE_CAP)
                    ),
                    string.concat("registerRoute Lista ", lista[i].label)
                );
            }
        }
        VaultSpec[] memory vaults = _vaults();
        for (uint256 i; i < vaults.length; ++i) {
            if (!_vaultExists(credit, credit.vaultIdOf(vaults[i].kind, vaults[i].token, vaults[i].target))) {
                buffer[n++] = Call(
                    target,
                    abi.encodeCall(credit.registerVault, (vaults[i].kind, vaults[i].token, vaults[i].target)),
                    "registerVault"
                );
            }
        }
        address[2] memory rewards = _rewardTokens();
        for (uint256 i; i < 2; ++i) {
            if (!credit.rewardTokenAllowed(rewards[i])) {
                buffer[n++] =
                    Call(target, abi.encodeCall(credit.setRewardToken, (rewards[i], true)), "setRewardToken");
            }
        }
        if (keccak256(credit.rewardProofSuffix()) != keccak256(REWARD_PROOF_SUFFIX)) {
            buffer[n++] = Call(
                target,
                abi.encodeCall(credit.setRewardProofSuffix, (REWARD_PROOF_SUFFIX)),
                "setRewardProofSuffix"
            );
        }
        if (credit.rateReporter() != _rateReporter(credit)) {
            buffer[n++] = Call(
                target, abi.encodeCall(credit.setRateReporter, (_rateReporter(credit))), "setRateReporter"
            );
        }
        calls = new Call[](n);
        for (uint256 i; i < n; ++i) {
            calls[i] = buffer[i];
        }
    }

    /// @notice Print the missing owner calls for the Safe (to = registry, value = 0).
    function printConfig(address executor, address erc4626Adapter, address venusAdapter, address aaveAdapter)
        external
        view
    {
        Call[] memory calls = configCalls(executor, [erc4626Adapter, venusAdapter, aaveAdapter]);
        console.log("owner calls missing:", calls.length);
        for (uint256 i; i < calls.length; ++i) {
            console.log(string.concat("CALL ", vm.toString(i), " ", calls[i].label));
            console.log("  to  ", calls[i].target);
            console.log(string.concat("  data ", vm.toString(calls[i].data)));
        }
    }

    /// @notice Send the missing owner calls from the broadcaster, which must be the registry owner. For fork
    /// rehearsals and for an owner that is a key; a Safe uses `printConfig`.
    function configure(address executor, address erc4626Adapter, address venusAdapter, address aaveAdapter)
        external
    {
        Call[] memory calls = configCalls(executor, [erc4626Adapter, venusAdapter, aaveAdapter]);
        vm.startBroadcast();
        for (uint256 i; i < calls.length; ++i) {
            (bool ok, bytes memory ret) = calls[i].target.call(calls[i].data);
            if (!ok) {
                assembly {
                    revert(add(ret, 0x20), mload(ret))
                }
            }
        }
        vm.stopBroadcast();
        verify(executor);
    }

    // ---- 3. read-only verification ----

    /// @notice Read everything back from chain. Reverts on the first mismatch with what `run()` deploys and
    /// what the spec lists. With ATP_SAFE set, also requires the Safe to own the registry with no pending
    /// handover (the routing registry has no owner of its own: it follows `AtpRegistry.owner()`).
    /// ATP_EXECUTOR is required: the core is never taken from the contracts being verified, and it must be
    /// the `AtpExecutor` (with its `AtpRegistry`) this repository records in `deployments/mainnet.json`.
    function verify(address executor) public view {
        address core = vm.envAddress("ATP_EXECUTOR");
        _requireManifestCore(core);
        _verify(executor, core);
    }

    /// @dev The anchor of `verify`: `core` is the live core recorded in `deployments/mainnet.json` for this
    /// chain, and its registry is the recorded one. A routing stack bound to any other core fails here or in
    /// `_verifyWiring`, whatever its own getters say.
    function _requireManifestCore(address core) internal view {
        string memory json = vm.readFile(string.concat(vm.projectRoot(), "/deployments/mainnet.json"));
        require(vm.parseJsonUint(json, ".chainId") == block.chainid, "deployments/mainnet.json: other chain");
        require(
            core == vm.parseJsonAddress(json, ".contracts.AtpExecutor"),
            "ATP_EXECUTOR is not the AtpExecutor in deployments/mainnet.json"
        );
        require(
            address(IRoutingCore(core).registry()) == vm.parseJsonAddress(json, ".contracts.AtpRegistry"),
            "ATP_EXECUTOR.registry() is not the AtpRegistry in deployments/mainnet.json"
        );
    }

    /// @dev `verify` against a given core. Only `verify` (core from ATP_EXECUTOR, anchored to the manifest)
    /// and fork tests (a stand-in core passed explicitly) reach this.
    function _verify(address executor, address core) internal view {
        IAtpBorrowExecutorV2 lend = IAtpBorrowExecutorV2(executor);
        AtpBorrowRegistryV2 credit = AtpBorrowRegistryV2(lend.borrowRegistry());
        AtpBorrowLensV2 lens = AtpBorrowLensV2(lend.lens());
        _verifyWiring(core, lend);

        require(!credit.paused(), "registry is paused");
        R.VaultKind[3] memory kinds = [R.VaultKind.ERC4626, R.VaultKind.VENUS, R.VaultKind.AAVE];
        for (uint256 i; i < 3; ++i) {
            address adapter = credit.adapterOf(kinds[i]);
            require(adapter != address(0), "adapter not set");
            require(
                IStrategyVaultAdapter(adapter).kind() == uint8(kinds[i])
                    && VaultAdapterBase(adapter).executor() == executor,
                "adapter wiring"
            );
        }
        address[4] memory loans = _loans();
        address[4] memory loanVTokens = _loanVTokens();
        for (uint256 i; i < 4; ++i) {
            require(credit.loanTokenAllowed(loans[i]), "loan token not allowed");
            require(credit.venusMarket(loans[i]) == loanVTokens[i], "loan vToken");
        }
        uint256 routes;
        VenusCollateral[] memory venus = _venusCollaterals();
        for (uint256 i; i < venus.length; ++i) {
            _requireSymbol(venus[i].asset, venus[i].symbol);
            require(credit.venusMarket(venus[i].asset) == venus[i].vToken, "collateral vToken");
            for (uint256 t; t < 4; ++t) {
                _verifyRoute(
                    credit,
                    lens,
                    credit.routeIdOf(R.Venue.VENUS, venus[i].asset, loans[t], bytes32(0)),
                    venus[i].asset,
                    venus[i].tier
                );
                ++routes;
            }
        }
        ListaMarket[] memory lista = _listaMarkets();
        for (uint256 i; i < lista.length; ++i) {
            (address collateral, address loan) = _listaTokens(lista[i]);
            _verifyRoute(
                credit,
                lens,
                credit.routeIdOf(R.Venue.LISTA, collateral, loan, lista[i].id),
                collateral,
                lista[i].tier
            );
            ++routes;
        }
        VaultSpec[] memory vaults = _vaults();
        for (uint256 i; i < vaults.length; ++i) {
            bytes32 id = credit.vaultIdOf(vaults[i].kind, vaults[i].token, vaults[i].target);
            require(_vaultExists(credit, id), "vault missing");
            R.Vault memory v = credit.vault(id);
            require(v.enabled && !v.retired && v.receipt.code.length != 0, "vault state");
            require(credit.vaultOpen(id), "vault closed");
        }
        address[2] memory rewards = _rewardTokens();
        for (uint256 i; i < 2; ++i) {
            require(credit.rewardTokenAllowed(rewards[i]), "reward token not allowed");
        }
        require(
            keccak256(credit.rewardProofSuffix()) == keccak256(REWARD_PROOF_SUFFIX), "reward proof suffix"
        );
        require(credit.rateReporter() == _rateReporter(credit), "rate reporter");
        require(credit.MAX_BORROW_UTILIZATION_BPS() == 9_500, "default utilization limit");

        // Nothing beyond the spec: the allowlists on chain are exactly these routes and vaults.
        require(credit.routeCount() == routes, "routes on chain differ from the spec");
        require(credit.vaultCount() == vaults.length, "vaults on chain differ from the spec");

        // The code on chain is this repository's build, byte for byte, and every immutable in it holds one
        // of the addresses listed here (each of which a getter checked above or in `_verifyWiring` returns).
        address venusAdapter = credit.adapterOf(R.VaultKind.VENUS);
        _requireCode(
            address(credit),
            "AtpBorrowRegistryV2.sol:AtpBorrowRegistryV2",
            _pins(address(credit.registry()), core, executor, VENUS_COMPTROLLER, LISTA_MOOLAH)
        );
        _requireCode(
            address(lens),
            "AtpBorrowLensV2.sol:AtpBorrowLensV2",
            _pins(address(credit), executor, VENUS_COMPTROLLER, LISTA_MOOLAH, address(0))
        );
        _requireCode(executor, "AtpBorrowExecutorV2.sol:AtpBorrowExecutorV2", _executorPins(lend));
        _requireCode(
            lend.extension(),
            "AtpBorrowExecutorV2Extension.sol:AtpBorrowExecutorV2Extension",
            _pins(lend.extension(), address(0), address(0), address(0), address(0))
        );
        address[] memory one = _pins(executor, address(0), address(0), address(0), address(0));
        _requireCode(lend.boxImplementation(), "StrategyBox.sol:StrategyBox", one);
        _requireCode(credit.adapterOf(R.VaultKind.ERC4626), "VaultAdapters.sol:Erc4626VaultAdapter", one);
        _requireCode(
            venusAdapter,
            "VaultAdapters.sol:VenusVaultAdapter",
            _pins(executor, address(credit), address(0), address(0), address(0))
        );
        require(address(VenusVaultAdapter(venusAdapter).registry()) == address(credit), "adapter registry");
        _requireCode(credit.adapterOf(R.VaultKind.AAVE), "VaultAdapters.sol:AaveVaultAdapter", one);

        // Ownership: the Safe owns the registry (and with it this routing registry), nothing pending.
        address safe = vm.envAddress("ATP_SAFE");
        IOwned2Step owned = IOwned2Step(address(credit.registry()));
        require(safe.code.length != 0, "ATP_SAFE has no code");
        require(owned.owner() == safe, "registry owner is not the Safe");
        require(owned.pendingOwner() == address(0), "ownership handover pending");
        console.log("verified: routes in spec", routes);
        console.log("verified: vaults in spec", vaults.length);
        console.log("on chain: routes", credit.routeCount());
        console.log("on chain: vaults", credit.vaultCount());
    }

    /// @dev The five contracts point at each other and at the venues, and nothing else.
    function _verifyWiring(address core, IAtpBorrowExecutorV2 lend) internal view {
        AtpBorrowRegistryV2 credit = AtpBorrowRegistryV2(lend.borrowRegistry());
        AtpBorrowLensV2 lens = AtpBorrowLensV2(lend.lens());
        require(address(lend).code.length != 0 && address(credit).code.length != 0, "missing code");
        require(credit.executor() == address(lend), "registry.executor");
        require(address(lens.borrowRegistry()) == address(credit) && lens.executor() == address(lend), "lens");
        require(address(credit.atpExecutor()) == core, "registry.atpExecutor");
        require(address(credit.registry()) == address(IRoutingCore(core).registry()), "registry.registry");
        require(
            credit.venusComptroller() == VENUS_COMPTROLLER && credit.moolah() == LISTA_MOOLAH, "venue pins"
        );
        // The executor and the lens carry their own copies of the venue addresses.
        require(
            lend.venusComptroller() == VENUS_COMPTROLLER && lend.moolah() == LISTA_MOOLAH,
            "executor venue pins"
        );
        require(
            lens.venusComptroller() == VENUS_COMPTROLLER && lens.moolah() == LISTA_MOOLAH, "lens venue pins"
        );
        require(lend.extension().code.length != 0, "extension");
        address box = lend.boxImplementation();
        require(box.code.length != 0 && StrategyBox(box).executor() == address(lend), "box implementation");
        require(StrategyBox(box).account() == address(0), "box implementation initialized");
    }

    /// @dev The route exists, is open for new risk with the launch cap and the default utilization limit,
    /// and its lines are exactly min(tier ceiling, F / 2) and F x 2/3.
    function _verifyRoute(
        AtpBorrowRegistryV2 credit,
        AtpBorrowLensV2 lens,
        bytes32 id,
        address collateral,
        R.Tier tier
    ) internal view {
        require(_routeExists(credit, id), "route missing");
        R.Route memory r = credit.route(id);
        require(r.enabled && !r.retired && credit.routeOpen(id), "route closed");
        require(r.collateral == collateral && credit.assetTier(collateral) == tier, "route collateral / tier");
        require(r.borrowCap == ROUTE_CAP, "route cap");
        require(r.maxUtilizationBps == 9_500, "route utilization limit");
        uint256 f = lens.liquidationLtv(id);
        uint256 ceiling = tier == R.Tier.INDEX_LARGE_CAP ? 0.35e18 : tier == R.Tier.STOCK ? 0.3e18 : 0.2e18;
        require(f != 0 && f < 1e18, "venue factor");
        require(lens.targetLtv(id) == (ceiling < f / 2 ? ceiling : f / 2), "target LTV");
        require(lens.deleverageLtv(id) == f * 2 / 3, "deleverage LTV");
    }

    // ---- helpers ----

    /// @dev The key that posts rate reports: ATP_RATE_REPORTER, which must not be the registry's operator (the
    /// session-key relayer): a leaked relayer key must not also be able to misreport rates.
    function _rateReporter(AtpBorrowRegistryV2 credit) internal view returns (address reporter) {
        reporter = vm.envAddress("ATP_RATE_REPORTER");
        require(reporter != address(0), "ATP_RATE_REPORTER is zero");
        require(reporter != credit.registry().operator(), "rate reporter must not be the operator key");
        require(reporter != credit.registry().owner(), "rate reporter must not be the owner");
    }

    /// @dev Moolah must return exactly the pinned collateral, loan token and oracle for the market id.
    function _listaTokens(ListaMarket memory m) internal view returns (address collateral, address loan) {
        MoolahParams memory p = IMoolahCore(LISTA_MOOLAH).idToMarketParams(m.id);
        require(
            p.collateralToken == m.collateral && p.loanToken == m.loan && p.oracle == m.oracle,
            string.concat("Lista market does not match its pins: ", m.label)
        );
        address[4] memory loans = _loans();
        require(
            p.loanToken == loans[0] || p.loanToken == loans[1] || p.loanToken == loans[2]
                || p.loanToken == loans[3],
            "Lista market loan token is not one of the four"
        );
        return (p.collateralToken, p.loanToken);
    }

    /// @dev One place an immutable sits in a contract's runtime code (the build artifact's
    /// `deployedBytecode.immutableReferences`; fields in the order the JSON parser returns them).
    struct ImmutableRef {
        uint256 length;
        uint256 start;
    }

    /// @dev The code at `deployed` is this repository's build of `artifact`, exactly: outside the places the
    /// build artifact lists for immutables every byte is the build's, and each immutable holds one of `pins`
    /// (one immutable per pin, in any order: which one holds which is what the getters prove, and the getters
    /// are this build's code). Reads `out/`, so the build must be the one being verified.
    function _requireCode(address deployed, string memory artifact, address[] memory pins) internal view {
        bytes memory built = vm.getDeployedCode(artifact);
        bytes memory code = deployed.code;
        require(code.length != 0 && code.length == built.length, string.concat("code length: ", artifact));
        string memory json =
            vm.readFile(string.concat(vm.projectRoot(), "/out/", vm.replace(artifact, ":", "/"), ".json"));
        string memory key = ".deployedBytecode.immutableReferences";
        string[] memory ids = vm.parseJsonKeys(json, key);
        require(ids.length == pins.length, string.concat("immutable count: ", artifact));
        bool[] memory used = new bool[](pins.length);
        for (uint256 i; i < ids.length; ++i) {
            ImmutableRef[] memory refs =
                abi.decode(vm.parseJson(json, string.concat(key, "['", ids[i], "']")), (ImmutableRef[]));
            bytes32 value;
            for (uint256 k; k < refs.length; ++k) {
                uint256 start = refs[k].start;
                require(refs[k].length == 32 && start + 32 <= code.length, "immutable reference");
                bytes32 word;
                assembly ("memory-safe") {
                    let at := add(add(code, 0x20), start)
                    word := mload(at)
                    mstore(at, 0)
                }
                require(k == 0 || word == value, string.concat("immutable differs within: ", artifact));
                value = word;
            }
            bool found;
            for (uint256 j; j < pins.length && !found; ++j) {
                if (used[j] || bytes32(uint256(uint160(pins[j]))) != value) continue;
                (used[j], found) = (true, true);
            }
            require(found, string.concat("immutable is not a pinned address: ", artifact));
        }
        require(keccak256(code) == keccak256(built), string.concat("code differs from the build: ", artifact));
    }

    /// @dev Up to five pinned addresses (zero = unused slot).
    function _pins(address a, address b, address c, address d, address e)
        internal
        pure
        returns (address[] memory pins)
    {
        address[5] memory all = [a, b, c, d, e];
        uint256 n;
        while (n < 5 && all[n] != address(0)) ++n;
        pins = new address[](n);
        for (uint256 i; i < n; ++i) {
            pins[i] = all[i];
        }
    }

    function _executorPins(IAtpBorrowExecutorV2 lend) internal view returns (address[] memory pins) {
        pins = new address[](6);
        pins[0] = lend.borrowRegistry();
        pins[1] = lend.lens();
        pins[2] = lend.boxImplementation();
        pins[3] = lend.extension();
        pins[4] = VENUS_COMPTROLLER;
        pins[5] = LISTA_MOOLAH;
    }

    function _requireSymbol(address token, string memory symbol) internal view {
        require(token.code.length != 0, string.concat("no code: ", symbol));
        require(
            keccak256(bytes(IERC20Metadata(token).symbol())) == keccak256(bytes(symbol)),
            string.concat("symbol mismatch: ", symbol)
        );
    }

    function _routeExists(AtpBorrowRegistryV2 credit, bytes32 id) internal view returns (bool) {
        try credit.route(id) returns (R.Route memory) {
            return true;
        } catch {
            return false;
        }
    }

    function _vaultExists(AtpBorrowRegistryV2 credit, bytes32 id) internal view returns (bool) {
        try credit.vault(id) returns (R.Vault memory) {
            return true;
        } catch {
            return false;
        }
    }
}
