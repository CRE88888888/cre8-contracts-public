// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Script, console } from "forge-std/Script.sol";
import { AtpRegistry } from "../src/atp/AtpRegistry.sol";
import { AtpExecutor } from "../src/atp/AtpExecutor.sol";
import { AtpMultiPoolOracle } from "../src/atp/AtpMultiPoolOracle.sol";
import { PancakeV3TwapOracle } from "../src/atp/PancakeV3TwapOracle.sol";
import { IUniversalRouter } from "../src/atp/interfaces/IUniversalRouter.sol";
import { IOracleFloor } from "../src/atp/interfaces/IOracleFloor.sol";

/// @dev Minimal PancakeSwap V3 factory: `getPool` is the only call this script makes to it.
interface IV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool);
}

/// @title DeployAtp
/// @notice LOCAL FORK ONLY. Deploys the ATP stack on an Anvil fork of BSC mainnet (chain 56). Pools are
/// resolved at runtime through the PancakeSwap V3 factory, so a fork of any block height deploys identically.
///
/// @dev Never mainnet. A fork also reports chain id 56, so the guard is the broadcaster instead: the script
/// only broadcasts from Anvil's well-known account #0, which can never hold real funds on mainnet. The real
/// deployment is `DeployAtpMainnet.s.sol`, which never reuses anything and cannot run twice.
///
/// @dev Idempotency. `forge script` cannot read or write files here: `foundry.toml` grants no
/// `fs_permissions` (the default is read-only on `out/`), so the address book lives in this file as
/// constants instead of being read back from `deployments/fork.json`. Rerunning is therefore the same single
/// command with no arguments to remember and no environment to get wrong - the two ways a "reuse the existing
/// deployment" flag usually leaks a duplicate registry. Every entry is reused when its address still has
/// code, and redeployed only when it does not (a fork that lost its state), so a stale book heals instead of
/// producing a second registry that silently strands every enrollment.
///
/// @dev A reused contract is never trusted blindly: the pin that makes reuse safe (its pool, its numeraire,
/// its registry and oracle pointers) is re-read from chain, and a mismatch reverts here rather than yielding
/// a deployment that looks fine and quotes the wrong pool. `deployments/fork.json` is the human-readable
/// record of what this script produced, not its input.
///
/// @dev Deployment order is fixed and must stay so: the addresses below are the ones a run over an empty
/// address book prints, and reordering `new` calls reassigns the nonces.
contract DeployAtp is Script {
    // ---- address book for this fork (chain 56) ----
    // An entry is reused when it still has code; otherwise it is deployed again and printed for the record.
    //
    // v2 (router deploys its own oracles): registry nonce N, router N+1, executor N+4 (N+2, N+3 = setOracle).
    // Account #0's key is public, so it has real mainnet history: N is its mainnet nonce at the fork block
    // (25543 at block 133175282, 2026-11-12), not 0. A fork at a later block may see a higher N, in which
    // case these entries have no code and the script deploys fresh and prints the new addresses.
    address internal constant REGISTRY = 0xBe02b3db88ff0090eF3e56ac79fD4f4003ae72a7;
    address internal constant MULTI_POOL_ORACLE = 0x4989B5A9ec17ce669663a599FBefA0e414ed0b5E;
    address internal constant EXECUTOR_MULTI_POOL = 0xa1b9DA215e1eFab5a3935BF147009ce0687dd310;

    /// @dev Anvil's default account #0. The only broadcaster this script accepts on chain 56.
    address internal constant ANVIL_DEPLOYER = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;

    // ---- BSC mainnet (chain 56) pins ----
    address internal constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address internal constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address internal constant NVDAB = 0x02Fca66C1D1aFB4E2A7884261eB00F63598a7436;
    address internal constant V3_FACTORY = 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865;
    address internal constant V3_UNIVERSAL_ROUTER = 0x1A0A18AC4BECDDbd6389559687d1A73d8927E416;
    address internal constant PERMIT2 = 0x31c2F6fcFf4F8759b3Bd5Bf0e1084A055615c768;

    uint24 internal constant WBNB_USDT_FEE = 500;
    uint24 internal constant WBNB_USDT_FEE_FALLBACK = 2500;
    uint24 internal constant NVDAB_USDT_FEE = 2500;

    // ---- oracle config (matches the fork suite) ----
    uint32 internal constant TWAP_WINDOW = 30 minutes;
    uint16 internal constant MAX_SLIPPAGE_BPS = 100;
    uint32 internal constant MAX_ORACLE_AGE = 3600;

    struct Deployment {
        AtpRegistry registry;
        AtpMultiPoolOracle multiPoolOracle;
        AtpExecutor executorMultiPool;
        address wbnbUsdtPool;
        uint24 wbnbUsdtFee;
        address nvdabUsdtPool;
    }

    function run() external {
        Deployment memory d;

        // Pools are resolved through the factory rather than hardcoded, and the 0.05% / 0.25% fallback on
        // WBNB/USDT is kept: an oracle pins one pool forever, so a wrong one is a redeploy.
        d.wbnbUsdtFee = WBNB_USDT_FEE;
        d.wbnbUsdtPool = IV3Factory(V3_FACTORY).getPool(WBNB, USDT, WBNB_USDT_FEE);
        if (d.wbnbUsdtPool == address(0)) {
            d.wbnbUsdtFee = WBNB_USDT_FEE_FALLBACK;
            d.wbnbUsdtPool = IV3Factory(V3_FACTORY).getPool(WBNB, USDT, WBNB_USDT_FEE_FALLBACK);
        }
        require(d.wbnbUsdtPool != address(0), "no WBNB/USDT pool at 500 or 2500");
        d.nvdabUsdtPool = IV3Factory(V3_FACTORY).getPool(NVDAB, USDT, NVDAB_USDT_FEE);
        require(d.nvdabUsdtPool != address(0), "no NVDAB/USDT pool at 2500");

        vm.startBroadcast();
        if (block.chainid == 56) {
            require(msg.sender == ANVIL_DEPLOYER, "DeployAtp is fork-only; use DeployAtpMainnet on mainnet");
        }

        bool created;

        // 1. Registry (owner = deployer). Reused whenever it survives: it holds the enrollment state.
        (d.registry, created) = _reuseRegistry(REGISTRY);
        _row("registry", created, address(d.registry));

        // 2. The router: asset -> per-pair oracle, numeraire = USDT.
        (d.multiPoolOracle, created) = _reuseMultiPool(MULTI_POOL_ORACLE);
        _row("multiPoolOracle", created, address(d.multiPoolOracle));

        // 3. Register both pairs; the router deploys each TWAP oracle itself.
        _register(d.multiPoolOracle, WBNB, d.wbnbUsdtPool);
        _register(d.multiPoolOracle, NVDAB, d.nvdabUsdtPool);

        // 4. Executor pinned to the router. Reused only while it still points at the router and at the same
        //    registry; the v1 executor (oracle = the WBNB/USDT pair oracle) can never satisfy that.
        (d.executorMultiPool, created) = _reuseExecutor(EXECUTOR_MULTI_POOL, d.registry, d.multiPoolOracle);
        _row("executorMultiPool", created, address(d.executorMultiPool));

        vm.stopBroadcast();

        _report(d);
    }

    // ---------------------------------------------------------------- idempotent deployment

    /// @dev A recorded address is reusable only if it still has code: after a fork reset the book keeps its
    /// entries while the chain behind them is empty, and reusing a dead address would hand out a deployment
    /// that reverts on first use.
    function _live(address recorded) internal view returns (bool) {
        return recorded != address(0) && recorded.code.length != 0;
    }

    function _reuseRegistry(address recorded) internal returns (AtpRegistry registry, bool created) {
        if (!_live(recorded)) return (new AtpRegistry(), true);
        registry = AtpRegistry(recorded);
        // Pin: the book's address is only ours if we own it. Someone else may have spent this nonce of the
        // public anvil key on mainnet, leaving a foreign contract at the recorded address on a fresh fork.
        require(
            registry.owner() == msg.sender,
            "recorded registry is not owned by the deployer: clear its address first"
        );
        return (registry, false);
    }

    function _reuseMultiPool(address recorded) internal returns (AtpMultiPoolOracle multiPool, bool created) {
        if (!_live(recorded)) return (new AtpMultiPoolOracle(USDT), true);
        multiPool = AtpMultiPoolOracle(recorded);
        require(
            multiPool.numeraire() == USDT,
            "recorded router has a different numeraire: clear its address first"
        );
        return (multiPool, false);
    }

    /// @dev An executor deployed before A10-3 (still alive on a long-running fork) has no `globalPaused`.
    function _hasGlobalPause(address candidate) internal view returns (bool) {
        (bool ok, bytes memory ret) = candidate.staticcall(abi.encodeWithSignature("globalPaused()"));
        return ok && ret.length == 32;
    }

    function _reuseExecutor(address recorded, AtpRegistry registry, AtpMultiPoolOracle multiPool)
        internal
        returns (AtpExecutor executor, bool created)
    {
        if (_live(recorded)) {
            AtpExecutor candidate = AtpExecutor(recorded);
            // Fee recipient = deployer for the fork; point it at a treasury before mainnet.
            if (
                address(candidate.oracle()) == address(multiPool)
                    && address(candidate.registry()) == address(registry)
            ) {
                // Reusing it would silently drop the kill switch, and deploying a replacement would leave the
                // book pointing at the old one (a new executor on every run). Stop instead.
                require(
                    _hasGlobalPause(recorded),
                    "recorded executor predates the global pause (A10-3): restart the fork"
                );
                return (candidate, false);
            }
        }
        return (
            new AtpExecutor(
                registry,
                IUniversalRouter(V3_UNIVERSAL_ROUTER),
                IOracleFloor(address(multiPool)),
                PERMIT2,
                msg.sender
            ),
            true
        );
    }

    /// @dev Safe to repeat: an asset already registered on the same pool is skipped. One registered on a
    /// different pool is cleared first, so moving an asset takes two explicit statements and the gap fails
    /// closed with `OracleNotSet`.
    function _register(AtpMultiPoolOracle multiPool, address asset, address pool) internal {
        PancakeV3TwapOracle current = multiPool.oracleOf(asset);
        if (address(current) != address(0)) {
            if (address(current.pool()) == pool) {
                console.log(
                    string.concat("register            SKIP  ", vm.toString(asset), " already on this pool")
                );
                return;
            }
            multiPool.clearOracle(asset);
            console.log(
                string.concat(
                    "clearOracle         CLEAR ", vm.toString(asset), " was ", vm.toString(address(current))
                )
            );
        }
        PancakeV3TwapOracle oracle =
            multiPool.setOracle(asset, pool, TWAP_WINDOW, MAX_SLIPPAGE_BPS, MAX_ORACLE_AGE);
        console.log(
            string.concat(
                "setOracle           SET   ", vm.toString(asset), " -> ", vm.toString(address(oracle))
            )
        );
    }

    // ---------------------------------------------------------------- reporting

    function _row(string memory label, bool created, address target) internal {
        console.log(
            string.concat(label, created ? string(": NEW   ") : string(": REUSE "), vm.toString(target))
        );
    }

    /// @dev Printed as `key = address` so the block can be pasted into `deployments/fork.json` and read by
    /// eye against the constants above.
    function _report(Deployment memory d) internal {
        console.log("");
        console.log("--- address book (deployments/fork.json) ---");
        console.log(string.concat("registry          = ", vm.toString(address(d.registry))));
        console.log(string.concat("multiPoolOracle   = ", vm.toString(address(d.multiPoolOracle))));
        console.log(string.concat("executorMultiPool = ", vm.toString(address(d.executorMultiPool))));
        console.log(string.concat("pool (WBNB/USDT)  = ", vm.toString(d.wbnbUsdtPool)));
        console.log(string.concat("pool (NVDAB/USDT) = ", vm.toString(d.nvdabUsdtPool)));
        console.log("--- router.oracleOf() readback ---");
        console.log(
            string.concat("oracleOf(WBNB)    = ", vm.toString(address(d.multiPoolOracle.oracleOf(WBNB))))
        );
        console.log(
            string.concat("oracleOf(NVDAB)   = ", vm.toString(address(d.multiPoolOracle.oracleOf(NVDAB))))
        );
    }
}
