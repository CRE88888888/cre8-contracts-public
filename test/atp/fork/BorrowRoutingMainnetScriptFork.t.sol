// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { AtpRegistry } from "../../../src/atp/AtpRegistry.sol";
import { IAtpBorrowExecutorV2 } from "../../../src/atp/borrow/v2/IAtpBorrowExecutorV2.sol";
import { AtpBorrowRegistryV2 } from "../../../src/atp/borrow/v2/AtpBorrowRegistryV2.sol";
import { AtpBorrowLensV2 } from "../../../src/atp/borrow/v2/AtpBorrowLensV2.sol";
import { IAtpBorrowRegistryV2 as IReg } from "../../../src/atp/borrow/v2/IAtpBorrowRegistryV2.sol";
import { RoutingTypes as R } from "../../../src/atp/borrow/v2/RoutingTypes.sol";
import { DeployBorrowRoutingMainnet } from "../../../script/DeployBorrowRoutingMainnet.s.sol";

/// @dev The part of the live `AtpExecutor` routing v2 pins: its registry and the global pause.
contract RoutingCoreStub {
    AtpRegistry public immutable registry;
    bool public globalPaused;

    constructor(AtpRegistry registry_) {
        registry = registry_;
    }
}

/// @dev The mainnet script without its chain-id gate and broadcast, so a fork test can drive each step.
contract DeployBorrowRoutingMainnetHarness is DeployBorrowRoutingMainnet {
    function deploy(address core) external returns (Deployed memory d) {
        _checkCore(core);
        d = _deploy(core, address(this));
        _verifyWiring(core, d.lend);
    }

    /// @dev `verify` with the core given explicitly: the fork's stand-in core is not the one in
    /// `deployments/mainnet.json`, which the real `verify` (ATP_EXECUTOR) insists on.
    function verifyWith(address executor, address core) external view {
        _verify(executor, core);
    }

    function requireManifestCore(address core) external view {
        _requireManifestCore(core);
    }

    function spec()
        external
        pure
        returns (uint256 venusCollaterals, uint256 listaMarkets, uint256 vaults, uint256 routeCap)
    {
        return (_venusCollaterals().length, _listaMarkets().length, _vaults().length, ROUTE_CAP);
    }

    function listaMarket(uint256 i) external pure returns (ListaMarket memory) {
        return _listaMarkets()[i];
    }

    function usd1Vault() external pure returns (address token, address vault) {
        return (USD1, LISTA_VAULT_USD1);
    }
}

interface IMoolahAuthorization {
    function setAuthorization(address authorized, bool newIsAuthorized) external;
    function idToMarketParams(bytes32 id) external view returns (address, address, address, address, uint256);
}

/// @notice `DeployBorrowRoutingMainnet` rehearsed on a BSC mainnet fork: deploy, the owner calls it prints,
/// the read-only verification (and that it fails on each kind of drift), then one position through an
/// allowlisted route. Nothing is broadcast. Needs `BSC_RPC_URL`; skipped without it.
contract BorrowRoutingMainnetScriptForkTest is Test {
    address internal constant MOOLAH = 0x8F73b65B4caAf64FBA2aF91cC5D4a2A1318E5D8C;
    address internal constant OPERATOR = address(0x09E7A702);
    address internal constant RATE_REPORTER = address(0x4A7E4E9);
    // A real Lista market that is not in the spec (SPCXB/USDC, api.lista.org zone 5).
    bytes32 internal constant EXTRA_MARKET =
        0xe52b068bb5b6225de1800b434bdd465246faea79352000acad88bdff312eab95;
    address internal constant SPCXB = 0xbe9D156892E55e7154BcD3cB0FEA677F9D3103E1;
    address internal constant USDC = 0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d;
    // `contracts.AtpExecutor` of deployments/mainnet.json.
    address internal constant MANIFEST_EXECUTOR = 0x547764c2A6f789986F0f3E532c115ffC7E3AC9e7;

    DeployBorrowRoutingMainnetHarness internal script;
    AtpRegistry internal registry;
    RoutingCoreStub internal core;
    IAtpBorrowExecutorV2 internal lend;
    AtpBorrowRegistryV2 internal credit;
    AtpBorrowLensV2 internal lens;
    address[3] internal adapters;

    function setUp() public {
        string memory rpc = vm.envOr("BSC_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        // Latest block by default; BSC_FORK_BLOCK (archive RPC) pins it, and CI must pin.
        uint256 pinned = vm.envOr("BSC_FORK_BLOCK", uint256(0));
        require(pinned != 0 || !vm.envOr("CI", false), "CI fork tests need BSC_FORK_BLOCK (archive RPC)");
        if (pinned == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, pinned);
        registry = new AtpRegistry(); // this test is the owner, as the Safe will be
        registry.setOperator(OPERATOR);
        vm.setEnv("ATP_SAFE", vm.toString(address(this)));
        vm.setEnv("ATP_RATE_REPORTER", vm.toString(RATE_REPORTER));
        core = new RoutingCoreStub(registry);
        script = new DeployBorrowRoutingMainnetHarness();
        DeployBorrowRoutingMainnet.Deployed memory d = script.deploy(address(core));
        lend = d.lend;
        credit = d.credit;
        lens = d.lens;
        adapters = d.adapters;
    }

    function _configure() internal returns (uint256 sent) {
        DeployBorrowRoutingMainnet.Call[] memory calls = script.configCalls(address(lend), adapters);
        for (uint256 i; i < calls.length; ++i) {
            assertEq(calls[i].target, address(credit), "every owner call goes to the routing registry");
            (bool ok,) = calls[i].target.call(calls[i].data);
            assertTrue(ok, calls[i].label);
        }
        return calls.length;
    }

    function test_script_deployConfigureVerify_andDriftIsCaught() public {
        // Deployed but not configured: verification fails, and a stranger cannot configure.
        vm.expectRevert();
        script.verifyWith(address(lend), address(core));
        DeployBorrowRoutingMainnet.Call[] memory calls = script.configCalls(address(lend), adapters);
        vm.prank(OPERATOR);
        (bool ok,) = calls[0].target.call(calls[0].data);
        assertFalse(ok, "only the registry owner configures");

        uint256 sent = _configure();
        emit log_named_uint("owner calls", sent);
        script.verifyWith(address(lend), address(core));
        assertEq(script.configCalls(address(lend), adapters).length, 0, "configuration is idempotent");
        (uint256 venus, uint256 lista, uint256 vaults, uint256 cap) = script.spec();
        assertEq(credit.routeCount(), venus * 4 + lista);
        assertEq(credit.vaultCount(), vaults);
        assertEq(credit.rateReporter(), RATE_REPORTER, "a key of its own, not the session-key operator");

        // Each kind of drift is caught, and passes again once undone.
        bytes32 route = credit.routeIds(0);
        address collateral = credit.route(route).collateral;
        R.Tier tier = credit.assetTier(collateral);
        credit.setAssetTier(collateral, R.Tier.NONE);
        vm.expectRevert();
        script.verifyWith(address(lend), address(core));
        credit.setAssetTier(collateral, tier);

        credit.setRouteCap(route, cap + 1);
        vm.expectRevert(bytes("route cap"));
        script.verifyWith(address(lend), address(core));
        credit.setRouteCap(route, cap);

        credit.setRouteMaxUtilization(route, 8_500);
        vm.expectRevert(bytes("route utilization limit"));
        script.verifyWith(address(lend), address(core));
        credit.setRouteMaxUtilization(route, 9_500);

        credit.setPaused(true);
        vm.expectRevert(bytes("registry is paused"));
        script.verifyWith(address(lend), address(core));
        credit.setPaused(false);

        credit.setVault(credit.vaultIds(0), false, false);
        vm.expectRevert(bytes("vault state"));
        script.verifyWith(address(lend), address(core));
        credit.setVault(credit.vaultIds(0), true, false);

        credit.setRateReporter(OPERATOR);
        vm.expectRevert(bytes("rate reporter"));
        script.verifyWith(address(lend), address(core));
        credit.setRateReporter(RATE_REPORTER);
        script.verifyWith(address(lend), address(core));
    }

    function test_script_verify_catchesExtrasForeignCodeAndOwnership() public {
        _configure();
        script.verifyWith(address(lend), address(core));

        // A route beyond the spec: the allowlist on chain must equal the spec exactly.
        uint256 snapshot = vm.snapshotState();
        credit.registerRoute(R.Venue.LISTA, SPCXB, USDC, EXTRA_MARKET, 1);
        vm.expectRevert(bytes("routes on chain differ from the spec"));
        script.verifyWith(address(lend), address(core));
        vm.revertToState(snapshot);

        // Code that is not this repository's build: another contract's code, or one flipped bit.
        snapshot = vm.snapshotState();
        vm.etch(address(lens), address(credit).code);
        vm.expectRevert();
        script.verifyWith(address(lend), address(core));
        vm.revertToState(snapshot);
        snapshot = vm.snapshotState();
        address extension = lend.extension();
        bytes memory code = extension.code;
        code[code.length / 2] = bytes1(uint8(code[code.length / 2]) ^ 0x01);
        vm.etch(extension, code);
        vm.expectRevert();
        script.verifyWith(address(lend), address(core));
        vm.revertToState(snapshot);

        // Ownership: ATP_SAFE is required, must be a contract that owns the registry, with nothing pending.
        vm.setEnv("ATP_SAFE", vm.toString(address(0xBEEF)));
        vm.expectRevert();
        script.verifyWith(address(lend), address(core));
        vm.setEnv("ATP_SAFE", vm.toString(address(this)));
        registry.transferOwnership(address(0xBEEF));
        vm.expectRevert(bytes("ownership handover pending"));
        script.verifyWith(address(lend), address(core));
        registry.transferOwnership(address(this));
        vm.expectRevert(bytes("ownership handover pending"));
        script.verifyWith(address(lend), address(core));

        // The rate reporter may not be the session-key operator: the script refuses to plan it.
        vm.setEnv("ATP_RATE_REPORTER", vm.toString(OPERATOR));
        vm.expectRevert(bytes("rate reporter must not be the operator key"));
        script.configCalls(address(lend), adapters);
        vm.setEnv("ATP_RATE_REPORTER", vm.toString(RATE_REPORTER));
    }

    /// Third review L-2: the real `verify` takes the core from ATP_EXECUTOR and holds it against
    /// `deployments/mainnet.json`; it never reads it back from the contracts it is verifying.
    function test_script_verify_coreIsAnchoredToTheManifest_notToTheContractsUnderVerification() public {
        _configure();
        script.verifyWith(address(lend), address(core));
        // The stand-in core this stack is bound to is not the recorded one.
        vm.expectRevert(bytes("ATP_EXECUTOR is not the AtpExecutor in deployments/mainnet.json"));
        script.requireManifestCore(address(core));
        // The recorded core is live on this fork and its registry is the recorded registry ...
        script.requireManifestCore(MANIFEST_EXECUTOR);
        // ... and a stack bound to another core does not verify against it, whatever its getters say.
        vm.expectRevert(bytes("registry.atpExecutor"));
        script.verifyWith(address(lend), MANIFEST_EXECUTOR);
    }

    /// R4: runtime code identical to the build except for what an immutable holds, or for bytes where the
    /// build has zeros, is not this repository's deployment.
    function test_script_verify_catchesSwappedVenuePins_andBytesAlteredWhereTheBuildHasZeros() public {
        _configure();
        script.verifyWith(address(lend), address(core));
        address venus = credit.venusComptroller();
        address[2] memory holders = [address(lend), address(lens)];
        for (uint256 i; i < 2; ++i) {
            // The executor's / the lens's own copy of a venue address points somewhere else.
            uint256 snapshot = vm.snapshotState();
            (bytes memory code, uint256 replaced) = _replaceWord(holders[i].code, venus, address(0xBAD));
            assertGt(replaced, 0, "venue pin not found in the code");
            vm.etch(holders[i], code);
            vm.expectRevert(bytes(i == 0 ? "executor venue pins" : "lens venue pins"));
            script.verifyWith(address(lend), address(core));
            vm.revertToState(snapshot);
            // The two venues swapped.
            snapshot = vm.snapshotState();
            (code,) = _replaceWord(holders[i].code, venus, address(0xBAD));
            (code,) = _replaceWord(code, MOOLAH, venus);
            (code,) = _replaceWord(code, address(0xBAD), MOOLAH);
            vm.etch(holders[i], code);
            vm.expectRevert(bytes(i == 0 ? "executor venue pins" : "lens venue pins"));
            script.verifyWith(address(lend), address(core));
            vm.revertToState(snapshot);
        }
        // One byte changed where the build has a zero (and the deployment too): not an immutable's value.
        string[3] memory artifacts = [
            "AtpBorrowRegistryV2.sol:AtpBorrowRegistryV2",
            "AtpBorrowExecutorV2.sol:AtpBorrowExecutorV2",
            "StrategyBox.sol:StrategyBox"
        ];
        address[3] memory deployed = [address(credit), address(lend), lend.boxImplementation()];
        for (uint256 i; i < 3; ++i) {
            uint256 snapshot = vm.snapshotState();
            bytes memory built = vm.getDeployedCode(artifacts[i]);
            bytes memory code = deployed[i].code;
            uint256 at = code.length - 1;
            while (built[at] != 0 || code[at] != 0) --at;
            code[at] = 0x01;
            vm.etch(deployed[i], code);
            vm.expectRevert();
            script.verifyWith(address(lend), address(core));
            vm.revertToState(snapshot);
        }
        script.verifyWith(address(lend), address(core));
    }

    /// @dev `code` with every 32-byte word holding `from` (left-padded) rewritten to `to`.
    function _replaceWord(bytes memory code, address from, address to)
        internal
        pure
        returns (bytes memory, uint256 replaced)
    {
        bytes32 word = bytes32(uint256(uint160(from)));
        for (uint256 i; i + 32 <= code.length; ++i) {
            bytes32 found;
            assembly ("memory-safe") {
                found := mload(add(add(code, 0x20), i))
            }
            if (found != word) continue;
            assembly ("memory-safe") {
                mstore(add(add(code, 0x20), i), to)
            }
            ++replaced;
        }
        return (code, replaced);
    }

    function test_script_allowlistedRouteWorksEndToEnd() public {
        _configure();
        script.verifyWith(address(lend), address(core));
        // Lista QQQB/USD1 (spec row 3) into the Lista USD1 vault.
        DeployBorrowRoutingMainnet.ListaMarket memory m = script.listaMarket(3);
        (address usd1, address vault) = script.usd1Vault();
        assertEq(m.loan, usd1);
        address qqqb = m.collateral;
        bytes32 route = credit.routeIdOf(R.Venue.LISTA, qqqb, usd1, m.id);
        bytes32 vaultId = credit.vaultIdOf(R.VaultKind.ERC4626, usd1, vault);

        address[] memory assets = new address[](2);
        (assets[0], assets[1]) = (usd1, qqqb);
        uint16[] memory weights = new uint16[](2);
        weights[1] = 10_000;
        registry.setNumeraire(usd1);
        uint256 strategy = registry.registerStrategy("script fork", "routing v2", true);
        registry.publishVersion(strategy, assets, weights, keccak256("hold"), 0);
        registry.enroll(address(this), strategy, 1);
        IMoolahAuthorization(MOOLAH).setAuthorization(address(lend), true);
        credit.setStrategyPolicy(100_000e18, address(0), true);
        deal(qqqb, address(this), 2e18);
        IERC20(qqqb).approve(address(lend), type(uint256).max);

        // The Lista vault's rate is not on chain: the reporter key configured by the script reports it.
        IReg.RouteReport[] memory routes = new IReg.RouteReport[](0);
        IReg.VaultReport[] memory vaults = new IReg.VaultReport[](1);
        vaults[0] = IReg.VaultReport(vaultId, 0.05e18, 0);
        vm.prank(OPERATOR);
        vm.expectRevert(IReg.Unauthorized.selector);
        credit.reportRates(routes, vaults);
        vm.prank(RATE_REPORTER);
        credit.reportRates(routes, vaults);

        lend.executeOpen(address(this), route, bytes32(0), 2e18, 0, block.timestamp);
        R.Health memory h = lens.health(route, address(this));
        uint256 borrow = h.budgetValue * 9 / 10;
        lend.executeOpen(address(this), route, vaultId, 0, borrow, block.timestamp);
        assertGt(IERC20(vault).balanceOf(lend.boxOf(address(this))), 0);
        // Closed in the same block: the vault is a few raw units short of the debt (share rounding).
        deal(usd1, address(this), 1e12);
        IERC20(usd1).approve(address(lend), type(uint256).max);
        lend.executeReduce(
            address(this), route, vaultId, type(uint256).max, type(uint256).max, 1e12, block.timestamp
        );
        assertEq(IERC20(qqqb).balanceOf(address(this)), 2e18);
        assertEq(credit.accountRoutes(address(this)).length, 0);
    }
}
