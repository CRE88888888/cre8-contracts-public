// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Script, console } from "forge-std/Script.sol";
import { AtpRegistry } from "../src/atp/AtpRegistry.sol";
import { AtpExecutor } from "../src/atp/AtpExecutor.sol";
import { AtpMultiPoolOracle } from "../src/atp/AtpMultiPoolOracle.sol";
import { PancakeV3TwapOracle } from "../src/atp/PancakeV3TwapOracle.sol";
import { IUniversalRouter } from "../src/atp/interfaces/IUniversalRouter.sol";
import { IOracleFloor } from "../src/atp/interfaces/IOracleFloor.sol";
import { IAggregatorV3 } from "../src/atp/interfaces/IAggregatorV3.sol";
import { IPriceSource } from "../src/atp/interfaces/IPriceSource.sol";
import { IPancakeV3Pool } from "../src/atp/interfaces/IPancakeV3Pool.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { PushFeedPriceSource } from "../src/atp/PushFeedPriceSource.sol";
import { AtpMainnetSpecs } from "./AtpMainnetSpecs.sol";

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
/// Oracle parameters (pools, slippage tiers, feed max ages) are in `AtpMainnetSpecs`. Before this script
/// can pass, every pool must have `observationCardinalityNext >= 2400`: run `IncreaseObservationCardinality`
/// first (permissionless, any funded wallet; cre8-contracts#25, review M-2).
contract DeployAtpMainnet is Script, AtpMainnetSpecs {
    // ---- BSC mainnet pins (the oracle book is in `AtpMainnetSpecs`) ----
    address internal constant V3_UNIVERSAL_ROUTER = 0x1A0A18AC4BECDDbd6389559687d1A73d8927E416;
    address internal constant PERMIT2 = 0x31c2F6fcFf4F8759b3Bd5Bf0e1084A055615c768;

    /// @dev A10-1 buy limit: per account, buys within 24 hours may total at most 100% of its current value.
    uint16 internal constant MAX_BUY_BPS = 10_000;
    /// @notice Minimum fee per swap batch (cre8-contracts#33): 0.30 USDT (18 decimals on BSC); settable by the Safe.
    uint256 internal constant MIN_BATCH_FEE = 0.3e18;

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
            if (specs[i].usdFeed != address(0)) {
                router.setSecondary(
                    specs[i].asset,
                    IAggregatorV3(specs[i].usdFeed),
                    IAggregatorV3(USDT_USD_FEED),
                    specs[i].maxFeedAge,
                    USDT_USD_MAX_AGE,
                    SECONDARY_MAX_DEVIATION_BPS
                );
            }
        }
        AtpExecutor executor = new AtpExecutor(
            registry,
            IUniversalRouter(V3_UNIVERSAL_ROUTER),
            IOracleFloor(address(router)),
            PERMIT2,
            treasury,
            USDT,
            MAX_BUY_BPS,
            MIN_BATCH_FEE
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

    /// @dev Reads every pin back from chain, requires every pool's `observationCardinalityNext` to be at least
    /// `MIN_OBSERVATION_CARDINALITY`, and quotes each asset both ways. A pool that cannot be quoted right now
    /// because of market state - idle past `maxOracleAge` (M-1, e.g. a bStock outside market hours) or with
    /// less history than a window (e.g. a pool whose cardinality was only just raised) - does not fail the
    /// deployment: the script reads that state from the pool itself, requires the router to refuse the asset
    /// with exactly `TwapUnavailable` in both directions, and logs it. Any other failure stops the deployment.
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
        require(executor.minBatchFee() == MIN_BATCH_FEE, "executor minBatchFee");
        // The only venue at deployment is the Universal Router, registered by the constructor. Aggregators
        // (KyberSwap, OpenOcean) are added by the Safe with `setVenue` after it has taken ownership.
        (AtpExecutor.VenueKind urKind, address urSpender) = executor.venues(V3_UNIVERSAL_ROUTER);
        require(
            urKind == AtpExecutor.VenueKind.PANCAKE_UR && urSpender == V3_UNIVERSAL_ROUTER,
            "executor UR venue"
        );

        uint256 closedNow;
        for (uint256 i; i < specs.length; ++i) {
            PancakeV3TwapOracle oracle = router.oracleOf(specs[i].asset);
            require(address(oracle) != address(0), string.concat("oracle missing: ", specs[i].symbol));
            require(address(oracle.pool()) == specs[i].pool, string.concat("oracle pool: ", specs[i].symbol));
            require(
                oracle.maxSlippageBps() == specs[i].maxSlippageBps && oracle.twapWindow() == TWAP_WINDOW
                    && oracle.maxOracleAge() == MAX_ORACLE_AGE,
                string.concat("oracle params: ", specs[i].symbol)
            );
            (IPriceSource source, uint16 deviation) = router.secondaryOf(specs[i].asset);
            if (specs[i].usdFeed == address(0)) {
                require(
                    address(source) == address(0), string.concat("unexpected secondary: ", specs[i].symbol)
                );
            } else {
                require(
                    address(PushFeedPriceSource(address(source)).assetFeed()) == specs[i].usdFeed
                        && address(PushFeedPriceSource(address(source)).numeraireFeed()) == USDT_USD_FEED
                        && PushFeedPriceSource(address(source)).maxAge() == specs[i].maxFeedAge
                        && PushFeedPriceSource(address(source)).numeraireMaxAge() == USDT_USD_MAX_AGE
                        && deviation == SECONDARY_MAX_DEVIATION_BPS,
                    string.concat("secondary: ", specs[i].symbol)
                );
            }
            if (!_verifyQuotes(router, oracle, specs[i])) ++closedNow;
        }
        console.log(
            string.concat(
                "oracles quoting now: ",
                vm.toString(specs.length - closedNow),
                " of ",
                vm.toString(specs.length),
                " (the rest fail closed with TwapUnavailable, see above)"
            )
        );
    }

    /// @dev Cardinality pin plus a two-way quote (or, when the pool's own state says it cannot be quoted now,
    /// a two-way `TwapUnavailable`). Returns whether the asset quotes right now.
    function _verifyQuotes(AtpMultiPoolOracle router, PancakeV3TwapOracle oracle, OracleSpec memory spec)
        internal
        view
        returns (bool live)
    {
        IPancakeV3Pool pool = oracle.pool();
        (,, uint16 index, uint16 cardinality, uint16 cardinalityNext,,) = pool.slot0();
        require(
            cardinalityNext >= MIN_OBSERVATION_CARDINALITY,
            string.concat(
                "observationCardinalityNext < 2400, run IncreaseObservationCardinality first: ", spec.symbol
            )
        );
        string memory closedReason = _closedReason(pool, index, cardinality, oracle.maxOracleAge());
        if (bytes(closedReason).length == 0) {
            // Both directions, 100 USDT: a secondary that is stale or disagrees fails the deployment here.
            (uint256 quoted, uint256 minimum) = router.previewSwap(USDT, spec.asset, 100e18);
            require(quoted != 0 && minimum != 0, string.concat("oracle cannot quote buy: ", spec.symbol));
            (uint256 back, uint256 backMin) = router.previewSwap(spec.asset, USDT, quoted);
            require(back != 0 && backMin != 0, string.concat("oracle cannot quote sale: ", spec.symbol));
            return true;
        }
        _requireTwapUnavailable(router, USDT, spec.asset, 100e18, spec.symbol);
        _requireTwapUnavailable(
            router, spec.asset, USDT, 10 ** IERC20Metadata(spec.asset).decimals(), spec.symbol
        );
        console.log(string.concat("fail-closed now: ", spec.symbol, " (", closedReason, ")"));
        return false;
    }

    /// @dev Why the pool cannot be quoted right now, read from the pool itself; empty when it can.
    function _closedReason(IPancakeV3Pool pool, uint16 index, uint16 cardinality, uint32 maxOracleAge)
        internal
        view
        returns (string memory)
    {
        (uint32 observedAt,,, bool initialized) = pool.observations(index);
        uint32 age;
        unchecked {
            age = uint32(block.timestamp) - observedAt;
        }
        if (!initialized || age > maxOracleAge) {
            return string.concat("pool idle ", vm.toString(uint256(age)), " s > maxOracleAge");
        }
        uint32[] memory ago = new uint32[](2);
        ago[0] = TWAP_WINDOW;
        try pool.observe(ago) { }
        catch {
            return string.concat("history < 30 min, cardinality ", vm.toString(uint256(cardinality)));
        }
        ago[0] = 5 minutes;
        try pool.observe(ago) { }
        catch {
            return string.concat("history < 5 min, cardinality ", vm.toString(uint256(cardinality)));
        }
        return "";
    }

    function _requireTwapUnavailable(
        AtpMultiPoolOracle router,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        string memory symbol
    ) internal view {
        try router.previewSwap(tokenIn, tokenOut, amountIn) {
            revert(string.concat("pool cannot serve but the oracle quoted: ", symbol));
        } catch (bytes memory err) {
            require(
                err.length >= 4 && bytes4(err) == PancakeV3TwapOracle.TwapUnavailable.selector,
                string.concat("oracle reverted with something other than TwapUnavailable: ", symbol)
            );
        }
    }

    function _secondary(AtpMultiPoolOracle router, address asset)
        internal
        view
        returns (IPriceSource source)
    {
        (source,) = router.secondaryOf(asset);
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
                    vm.toString(specs[i].pool),
                    specs[i].usdFeed == address(0)
                        ? ""
                        : string.concat(
                            "  secondary ", vm.toString(address(_secondary(router, specs[i].asset)))
                        )
                )
            );
        }
        console.log(string.concat("operator           ", vm.toString(operator)));
        console.log(string.concat("feeRecipient       ", vm.toString(treasury)));
        console.log(string.concat("maxBuyBps          ", vm.toString(uint256(MAX_BUY_BPS))));
        console.log(string.concat("minBatchFee        ", vm.toString(MIN_BATCH_FEE)));
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
