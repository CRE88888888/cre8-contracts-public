// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Script, console } from "forge-std/Script.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { AtpRegistry } from "../src/atp/AtpRegistry.sol";
import { IAtpBorrowExecutorV2 } from "../src/atp/borrow/v2/IAtpBorrowExecutorV2.sol";
import { AtpBorrowRegistryV2 } from "../src/atp/borrow/v2/AtpBorrowRegistryV2.sol";
import { AtpBorrowCashSwapper } from "../src/atp/borrow/v2/AtpBorrowCashSwapper.sol";

interface ICashPoolFactory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address);
}

interface ICashPool {
    function factory() external view returns (address);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function fee() external view returns (uint24);
    function liquidity() external view returns (uint128);
}

interface ICashOwned {
    function owner() external view returns (address);
    function pendingOwner() external view returns (address);
}

/// @notice BSC mainnet (chain 56): `AtpBorrowCashSwapper` for a deployed routing v2 stack
/// (docs/borrow-routing-v2.zh-TW.md §17). Three steps, like `DeployBorrowRoutingMainnet`; nothing here needs an
/// owner key to deploy, and the owner (the Safe behind `AtpRegistry.owner()`) deploys nothing.
///   1. `run()`           ROUTING_EXECUTOR=<routing v2 executor>: one creation, by any funded key.
///   2. `printConfig(s)`  read-only: the `setPool` calls the owner still has to send (to = the swapper).
///                        `configure(s)` sends them from the broadcaster (fork rehearsal, or an owner key).
///   3. `verify(s)`       read-only: code equals this build, bound to the routing executor recorded in
///                        `deployments/mainnet.json` (`borrowV2.executor`) and through it to the core
///                        recorded there, the three pools are PancakeSwap V3's own 0.01% USDT pools,
///                        limits at their defaults, ATP_SAFE owns it.
/// The routing stack itself is verified by `DeployBorrowRoutingMainnet.verify(executor)`; its executor is
/// written into `deployments/mainnet.json` after that, and `verify` here takes it from nowhere else (fourth
/// review L-A: an executor from the environment could be a stand-in that only points at the real core).
contract DeployBorrowCashSwapperMainnet is Script {
    address internal constant PANCAKE_V3_FACTORY = 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865;
    uint24 internal constant POOL_FEE = 100; // 0.01%
    address internal constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address internal constant USDC = 0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d;
    address internal constant USD1 = 0x8d0D000Ee44948FC98c9B98A4FA4921476f08B0d;
    address internal constant U = 0xcE24439F2D9C6a2289F741120FE202248B666666;
    // PancakeSwap V3 0.01% pools against USDT, read from the factory on 2026-11-25 and re-read on every run.
    address internal constant POOL_USDC = 0x92b7807bF19b7DDdf89b706143896d05228f3121;
    address internal constant POOL_USD1 = 0x9c4Ee895e4f6Ce07Ada631C508D1306Db7502cCE;
    address internal constant POOL_U = 0xA0909f81785f87f3e79309F0E73A7d82208094E4;
    uint16 internal constant MAX_PEG_BPS = 25;
    uint16 internal constant BUFFER_BPS = 100;

    struct Call {
        address target;
        bytes data;
        string label;
    }

    struct ImmutableRef {
        uint256 length;
        uint256 start;
    }

    function tokens() public pure returns (address[3] memory) {
        return [USDC, USD1, U];
    }

    function pools() public pure returns (address[3] memory) {
        return [POOL_USDC, POOL_USD1, POOL_U];
    }

    // ---- 1. deploy ----

    function run() external returns (AtpBorrowCashSwapper swapper) {
        require(block.chainid == 56, "DeployBorrowCashSwapperMainnet: BSC mainnet (56) only");
        address executor = vm.envAddress("ROUTING_EXECUTOR");
        _checkBook();
        vm.startBroadcast();
        swapper = _deploy(executor);
        vm.stopBroadcast();
        console.log("cashSwapper      ", address(swapper));
        console.log("routingExecutor  ", swapper.executor());
        console.log("owner (registry) ", AtpRegistry(swapper.registry()).owner());
        console.log("Next: printConfig(swapper), then verify(swapper).");
    }

    function _deploy(address executor) internal returns (AtpBorrowCashSwapper swapper) {
        require(executor.code.length != 0, "ROUTING_EXECUTOR has no code");
        swapper = new AtpBorrowCashSwapper(executor);
        require(swapper.usdt() == USDT, "the core's numeraire is not USDT");
    }

    /// @dev Each pool is the factory's own 0.01% pool of USDT and the token, with liquidity in range.
    function _checkBook() internal view {
        address[3] memory t = tokens();
        address[3] memory p = pools();
        for (uint256 i; i < 3; ++i) {
            require(IERC20Metadata(t[i]).decimals() == 18, "loan token decimals");
            require(
                ICashPoolFactory(PANCAKE_V3_FACTORY).getPool(USDT, t[i], POOL_FEE) == p[i],
                "pool is not the factory's 0.01% pool"
            );
            ICashPool pool = ICashPool(p[i]);
            (address a, address b) = (pool.token0(), pool.token1());
            require(
                pool.factory() == PANCAKE_V3_FACTORY && pool.fee() == POOL_FEE
                    && ((a == USDT && b == t[i]) || (a == t[i] && b == USDT)),
                "pool parameters"
            );
            require(pool.liquidity() != 0, "pool without liquidity in range");
        }
        require(IERC20Metadata(USDT).decimals() == 18, "USDT decimals");
    }

    // ---- 2. owner configuration ----

    /// @notice The `setPool` calls still missing. A token that is not yet a loan token of the routing
    /// registry cannot be listed: configure the routing stack first.
    function configCalls(address swapper) public view returns (Call[] memory calls) {
        _checkBook();
        AtpBorrowCashSwapper s = AtpBorrowCashSwapper(swapper);
        address[3] memory t = tokens();
        address[3] memory p = pools();
        Call[] memory buffer = new Call[](3);
        uint256 n;
        for (uint256 i; i < 3; ++i) {
            if (s.poolOf(t[i]) == p[i]) continue;
            require(
                AtpBorrowRegistryV2(s.borrowRegistry()).loanTokenAllowed(t[i]),
                "token is not a routing loan token yet: configure the routing registry first"
            );
            buffer[n++] = Call(
                swapper,
                abi.encodeCall(s.setPool, (t[i], p[i])),
                string.concat("setPool ", IERC20Metadata(t[i]).symbol())
            );
        }
        calls = new Call[](n);
        for (uint256 i; i < n; ++i) {
            calls[i] = buffer[i];
        }
    }

    function printConfig(address swapper) external view {
        Call[] memory calls = configCalls(swapper);
        console.log("owner calls missing:", calls.length);
        for (uint256 i; i < calls.length; ++i) {
            console.log(string.concat("CALL ", vm.toString(i), " ", calls[i].label));
            console.log("  to  ", calls[i].target);
            console.log(string.concat("  data ", vm.toString(calls[i].data)));
        }
    }

    function configure(address swapper) external {
        Call[] memory calls = configCalls(swapper);
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
    }

    // ---- 3. read-only verification ----

    /// @notice ATP_SAFE is required. Both anchors come from `deployments/mainnet.json` and from nowhere
    /// else: the routing executor the swapper must be bound to (`borrowV2.executor`, recorded once routing
    /// v2 is on mainnet and verified; until then this fails) and the core `AtpRegistry` behind it.
    function verify(address swapper) external view {
        string memory json = vm.readFile(string.concat(vm.projectRoot(), "/deployments/mainnet.json"));
        require(vm.parseJsonUint(json, ".chainId") == block.chainid, "deployments/mainnet.json: other chain");
        require(
            vm.keyExistsJson(json, ".borrowV2.executor"),
            "deployments/mainnet.json has no borrowV2.executor: record the verified routing v2 executor first"
        );
        _verify(
            swapper,
            vm.parseJsonAddress(json, ".borrowV2.executor"),
            vm.parseJsonAddress(json, ".contracts.AtpRegistry")
        );
    }

    function _verify(address swapper, address executor, address coreRegistry) internal view {
        AtpBorrowCashSwapper s = AtpBorrowCashSwapper(swapper);
        address credit = IAtpBorrowExecutorV2(executor).borrowRegistry();
        require(s.executor() == executor, "swapper is bound to another executor");
        require(s.borrowRegistry() == credit, "swapper registry");
        require(s.lens() == IAtpBorrowExecutorV2(executor).lens(), "swapper lens");
        require(AtpBorrowRegistryV2(credit).executor() == executor, "routing registry / executor");
        require(s.registry() == address(AtpBorrowRegistryV2(credit).registry()), "swapper core registry");
        require(
            s.registry() == coreRegistry, "core registry is not the AtpRegistry in deployments/mainnet.json"
        );
        require(s.usdt() == USDT && AtpRegistry(coreRegistry).numeraire() == USDT, "USDT");
        // Six immutables: the five addresses below (the getters, this build's code, prove which is which)
        // and USDT's scale to 18 decimals, which is 1.
        bytes32[] memory pins = new bytes32[](6);
        pins[0] = _word(executor);
        pins[1] = _word(credit);
        pins[2] = _word(IAtpBorrowExecutorV2(executor).lens());
        pins[3] = _word(coreRegistry);
        pins[4] = _word(USDT);
        pins[5] = bytes32(uint256(1));
        _requireCode(swapper, "AtpBorrowCashSwapper.sol:AtpBorrowCashSwapper", pins);

        _checkBook();
        address[3] memory t = tokens();
        address[3] memory p = pools();
        for (uint256 i; i < 3; ++i) {
            require(s.poolOf(t[i]) == p[i], string.concat("pool not set: ", IERC20Metadata(t[i]).symbol()));
        }
        require(s.poolOf(USDT) == address(0), "a pool is set for USDT");
        require(s.maxPegBps() == MAX_PEG_BPS && s.bufferBps() == BUFFER_BPS, "limits are not the defaults");

        address safe = vm.envAddress("ATP_SAFE");
        require(safe.code.length != 0, "ATP_SAFE has no code");
        require(ICashOwned(coreRegistry).owner() == safe, "registry owner is not the Safe");
        require(ICashOwned(coreRegistry).pendingOwner() == address(0), "ownership handover pending");
        console.log("verified: cash swapper", swapper);
    }

    function _word(address a) private pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }

    /// @dev The code at `deployed` is this repository's build of `artifact`: every byte outside the places
    /// the build artifact lists for immutables is the build's, and each immutable holds one of `pins` (one
    /// immutable per pin; which holds which is what the getters prove, and the getters are this build's
    /// code). Reads `out/`, so build first.
    function _requireCode(address deployed, string memory artifact, bytes32[] memory pins) internal view {
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
                if (used[j] || pins[j] != value) continue;
                (used[j], found) = (true, true);
            }
            require(found, string.concat("immutable is not a pinned value: ", artifact));
        }
        require(keccak256(code) == keccak256(built), string.concat("code differs from the build: ", artifact));
    }
}
