// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Script, console } from "forge-std/Script.sol";
import { AtpRegistry } from "../src/atp/AtpRegistry.sol";
import { AtpExecutor } from "../src/atp/AtpExecutor.sol";
import { AtpMultiPoolOracle } from "../src/atp/AtpMultiPoolOracle.sol";
import { PancakeV3TwapOracle } from "../src/atp/PancakeV3TwapOracle.sol";
import { IUniversalRouter } from "../src/atp/interfaces/IUniversalRouter.sol";
import { IOracleFloor } from "../src/atp/interfaces/IOracleFloor.sol";

/// @dev The two Safe reads this script relies on to tell a real multisig from a mistyped address.
interface ISafe {
    function getThreshold() external view returns (uint256);
    function getOwners() external view returns (address[] memory);
}

/// @title DeployAtpMainnet
/// @notice One-shot deployment of the ATP v2 stack on BSC mainnet (chain 56): registry, oracle router with
/// all seven index oracles, executor, operator, and an ownership handover proposed to the Safe.
///
/// @dev Unlike `DeployAtp` (the local-fork tool) this script never reuses anything and never runs twice:
/// - `block.chainid` must be 56;
/// - `EXPECTED_DEPLOYER_NONCE` must equal the broadcaster's current nonce. After a successful broadcast the
///   nonce has moved on, so repeating the same command reverts instead of deploying a second stack.
///
/// Inputs (environment):
///   ATP_SAFE                 owner-to-be; must be a Safe with threshold >= 2. It must call
///                            `acceptOwnership()` on the registry and the router to take over.
///   ATP_TREASURY             executor `feeRecipient`.
///   ATP_OPERATOR             backend relayer key (`OPERATOR_PRIVATE_KEY`'s address): may enroll and pause.
///   EXPECTED_DEPLOYER_NONCE  the broadcaster's nonce right now (`cast nonce <deployer>`).
///
/// Oracle parameters are copied from the v1 oracles live on mainnet (read on 2026-11-12), so the floors the
/// executor enforces do not change with the redeploy.
contract DeployAtpMainnet is Script {
    // ---- BSC mainnet pins ----
    address internal constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address internal constant V3_UNIVERSAL_ROUTER = 0x1A0A18AC4BECDDbd6389559687d1A73d8927E416;
    address internal constant PERMIT2 = 0x31c2F6fcFf4F8759b3Bd5Bf0e1084A055615c768;

    uint32 internal constant TWAP_WINDOW = 30 minutes;
    uint32 internal constant MAX_ORACLE_AGE = 1 hours;
    /// @dev A10-1 buy limit: per account, buys within 24 hours may total at most 100% of its current value.
    uint16 internal constant MAX_BUY_BPS = 10_000;

    struct OracleSpec {
        string symbol;
        address asset;
        address pool;
        uint16 maxSlippageBps;
    }

    function _oracleSpecs() internal pure returns (OracleSpec[] memory specs) {
        specs = new OracleSpec[](7);
        specs[0] = OracleSpec(
            "WBNB",
            0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c,
            0x36696169C63e42cd08ce11f5deeBbCeBae652050,
            100
        );
        specs[1] = OracleSpec(
            "NVDAB",
            0x02Fca66C1D1aFB4E2A7884261eB00F63598a7436,
            0x8FB4243b553aC29BA088aCf00B9B7dA24bD6690C,
            100
        );
        specs[2] = OracleSpec(
            "DOGE",
            0xbA2aE424d960c26247Dd6c32edC70B295c744C43,
            0x89da4102853C6cf3F4e9979CBb1dC4a166F38E84,
            300
        );
        specs[3] = OracleSpec(
            "TSLAB",
            0x5b1910eAaD6450E50f816082Aa078C41F10C292f,
            0xB0f5E5400E8F0F7C242F2b7740C004f020579c41,
            300
        );
        specs[4] = OracleSpec(
            "SPCXB",
            0xbe9D156892E55e7154BcD3cB0FEA677F9D3103E1,
            0x977DaFFC095b33872E2741c19568925015C35b4d,
            300
        );
        specs[5] = OracleSpec(
            "BTCB",
            0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c,
            0x46Cf1cF8c69595804ba91dFdd8d6b960c9B0a7C4,
            300
        );
        specs[6] = OracleSpec(
            "ETH", 0x2170Ed0880ac9A755fd29B2688956BD959F933F8, 0xBe141893E4c6AD9272e8C04BAB7E6a10604501a5, 300
        );
    }

    function run() external {
        require(block.chainid == 56, "DeployAtpMainnet: BSC mainnet (56) only");

        address safe = vm.envAddress("ATP_SAFE");
        address treasury = vm.envAddress("ATP_TREASURY");
        address operator = vm.envAddress("ATP_OPERATOR");
        uint64 expectedNonce = uint64(vm.envUint("EXPECTED_DEPLOYER_NONCE"));

        require(treasury != address(0), "ATP_TREASURY is zero");
        require(operator != address(0), "ATP_OPERATOR is zero");
        require(operator != safe, "operator must not be the Safe");
        _requireSafe(safe);

        OracleSpec[] memory specs = _oracleSpecs();

        vm.startBroadcast();
        // Checked after startBroadcast so `msg.sender` is the broadcaster whose nonce actually moves.
        address deployer = msg.sender;
        require(
            vm.getNonce(deployer) == expectedNonce,
            "deployer nonce != EXPECTED_DEPLOYER_NONCE: already deployed, or a stale value"
        );
        require(deployer != safe, "deployer cannot be the Safe");
        // The deployer hands everything to the Safe and must keep no role afterwards (three separate keys).
        require(operator != deployer, "operator must not be the deployer");

        AtpRegistry registry = new AtpRegistry();
        AtpMultiPoolOracle router = new AtpMultiPoolOracle(USDT);
        for (uint256 i; i < specs.length; ++i) {
            router.setOracle(
                specs[i].asset, specs[i].pool, TWAP_WINDOW, specs[i].maxSlippageBps, MAX_ORACLE_AGE
            );
        }
        AtpExecutor executor = new AtpExecutor(
            registry,
            IUniversalRouter(V3_UNIVERSAL_ROUTER),
            IOracleFloor(address(router)),
            PERMIT2,
            treasury,
            USDT,
            MAX_BUY_BPS
        );
        registry.setOperator(operator);
        registry.transferOwnership(safe);
        router.transferOwnership(safe);
        vm.stopBroadcast();

        _verify(registry, router, executor, specs, safe, treasury, operator, deployer);
        _report(registry, router, executor, specs, safe, treasury, operator, deployer);
    }

    /// @dev A mistyped owner is the one mistake the two-step handover cannot undo cheaply, so the target is
    /// checked up front: it must be a contract that answers like a Safe with a real multisig threshold.
    function _requireSafe(address safe) internal view {
        require(safe != address(0) && safe.code.length != 0, "ATP_SAFE has no code: not a Safe");
        uint256 threshold = ISafe(safe).getThreshold();
        address[] memory owners = ISafe(safe).getOwners();
        require(threshold >= 2, "ATP_SAFE threshold must be >= 2");
        require(owners.length >= threshold, "ATP_SAFE owners < threshold");
        console.log(
            string.concat(
                "Safe ",
                vm.toString(safe),
                " threshold ",
                vm.toString(threshold),
                " of ",
                vm.toString(owners.length)
            )
        );
        for (uint256 i; i < owners.length; ++i) {
            console.log(string.concat("  signer ", vm.toString(owners[i])));
        }
    }

    /// @dev Reads every pin back from chain and quotes each asset once, so a pool whose TWAP cannot serve
    /// (cardinality, stale data) fails here instead of on the first user rebalance.
    function _verify(
        AtpRegistry registry,
        AtpMultiPoolOracle router,
        AtpExecutor executor,
        OracleSpec[] memory specs,
        address safe,
        address treasury,
        address operator,
        address deployer
    ) internal view {
        require(registry.owner() == deployer, "registry owner");
        require(registry.pendingOwner() == safe, "registry pendingOwner");
        require(registry.operator() == operator, "registry operator");
        require(router.owner() == deployer, "router owner");
        require(router.pendingOwner() == safe, "router pendingOwner");
        require(router.numeraire() == USDT, "router numeraire");
        require(address(executor.registry()) == address(registry), "executor registry");
        require(address(executor.oracle()) == address(router), "executor oracle");
        require(address(executor.permit2()) == PERMIT2, "executor permit2");
        require(address(executor.universalRouter()) == V3_UNIVERSAL_ROUTER, "executor router");
        require(executor.feeRecipient() == treasury, "executor feeRecipient");
        require(registry.defaultSwapFeeBps() == 0, "default fee");
        require(!executor.globalPaused(), "executor globalPaused");
        require(
            executor.numeraire() == USDT && executor.numeraire() == router.numeraire(), "executor numeraire"
        );
        require(executor.maxBuyBps() == MAX_BUY_BPS, "executor maxBuyBps");

        for (uint256 i; i < specs.length; ++i) {
            PancakeV3TwapOracle oracle = router.oracleOf(specs[i].asset);
            require(address(oracle) != address(0), string.concat("oracle missing: ", specs[i].symbol));
            require(address(oracle.pool()) == specs[i].pool, string.concat("oracle pool: ", specs[i].symbol));
            (uint256 quoted, uint256 minimum) = router.previewSwap(USDT, specs[i].asset, 100e18);
            require(quoted != 0 && minimum != 0, string.concat("oracle cannot quote: ", specs[i].symbol));
        }
    }

    function _report(
        AtpRegistry registry,
        AtpMultiPoolOracle router,
        AtpExecutor executor,
        OracleSpec[] memory specs,
        address safe,
        address treasury,
        address operator,
        address deployer
    ) internal view {
        console.log("");
        console.log("--- ATP v2 mainnet (paste into deployments/mainnet.json) ---");
        console.log(string.concat("deployer           ", vm.toString(deployer)));
        console.log(string.concat("AtpRegistry        ", vm.toString(address(registry))));
        console.log(string.concat("AtpMultiPoolOracle ", vm.toString(address(router))));
        console.log(string.concat("AtpExecutor        ", vm.toString(address(executor))));
        for (uint256 i; i < specs.length; ++i) {
            console.log(
                string.concat(
                    "oracle ",
                    specs[i].symbol,
                    "  ",
                    vm.toString(address(router.oracleOf(specs[i].asset))),
                    "  pool ",
                    vm.toString(specs[i].pool)
                )
            );
        }
        console.log(string.concat("operator           ", vm.toString(operator)));
        console.log(string.concat("feeRecipient       ", vm.toString(treasury)));
        console.log(string.concat("maxBuyBps          ", vm.toString(uint256(MAX_BUY_BPS))));
        console.log(
            string.concat("pendingOwner       ", vm.toString(safe), "  (Safe must acceptOwnership x2)")
        );
        console.log("");
        console.log("--- Safe transactions to finish the handover ---");
        console.log(
            string.concat("to ", vm.toString(address(registry)), "  data 0x79ba5097  (acceptOwnership)")
        );
        console.log(
            string.concat("to ", vm.toString(address(router)), "  data 0x79ba5097  (acceptOwnership)")
        );
    }
}
