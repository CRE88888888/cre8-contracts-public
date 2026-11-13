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
import { PushFeedPriceSource } from "../src/atp/PushFeedPriceSource.sol";

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

    /// @dev Secondary source (#15): Chainlink standard (non-SVR) push feeds on BSC, picked from docs#28
    /// (`research/2026-11-13-price-feeds/`). USDT/USD converts the USD feeds so USDT is never assumed to be $1.
    /// Max feed age is per asset: 1 hour (the pool oracle's `MAX_ORACLE_AGE`) for feeds with a heartbeat of an
    /// hour or less, 1 day (the adapter's ceiling) for a 24 hour heartbeat (AVAX). Within it the 200 bps
    /// agreement check already catches a feed that stopped while the market moved.
    address internal constant USDT_USD_FEED = 0xB97Ad0E74fa7d920791E90258A6E2085088b4320;
    /// @dev The USDT/USD feed's heartbeat is 900 s, so 1 hour; the adapter applies one max age to both feeds,
    /// so an asset with a longer max age (AVAX) also tolerates an older USDT/USD answer.
    uint16 internal constant SECONDARY_MAX_DEVIATION_BPS = 200;

    struct OracleSpec {
        string symbol;
        address asset;
        address pool;
        uint16 maxSlippageBps;
        /// @dev asset/USD push feed for the secondary source, or zero for pool TWAP only (bStocks: no feed
        /// prices the token itself, docs#28).
        address usdFeed;
        /// @dev `PushFeedPriceSource.maxAge` for that feed; 0 when there is none.
        uint32 maxFeedAge;
    }

    /// @dev Every admitted non-numeraire asset of docs#32 (`research/2026-11-13-launch-admission/資料/admission.json`
    /// at docs `cd8a659`): its Pancake V3 USDT pool, `maxSlippageBps`, and - for an asset that is not a bStock and
    /// has a fresh Chainlink standard (8 decimal, non-SVR) feed - that feed as the secondary source. Generated
    /// from the JSON, addresses checksummed; TWAP 30 min / recent 5 min / max age 1 h for all, as the list says.
    function _oracleSpecs() internal pure returns (OracleSpec[] memory specs) {
        specs = new OracleSpec[](38);
        specs[0] = OracleSpec(
            "AAPLB",
            0x431a3BEE82E2ca41e49895CbECE5bB0F76A89b7A,
            0xe9b9998B2EC5430D2246c7f1F8D9f298c97D7365,
            300,
            address(0),
            0
        ); // fee 2500; bStock: no feed prices the token
        specs[1] = OracleSpec(
            "AMZNB",
            0x1a4b499833A79A09ad7Cf1D42D7DacF71e92eb00,
            0x7530beb7Bde5843f668cf31b996fa1F748C9b6B1,
            300,
            address(0),
            0
        ); // fee 2500; bStock: no feed prices the token
        specs[2] = OracleSpec(
            "AVAX",
            0x1CE0c2827e2eF14D5C4f29a091d735A204794041,
            0x9f11264d6d0d9671dAb2CC485eb6Ec1B502C4025,
            300,
            0x5974855ce31EE8E1fff2e76591CbF83D7110F151,
            1 days
        ); // fee 2500; Chainlink, heartbeat 86400s
        specs[3] = OracleSpec(
            "BABAB",
            0x4eF9d3062c7F6ebA4AAE4990c5036598C6eff4ec,
            0xfD95CB1391999006Eb91797a7c62acFe88b20292,
            300,
            address(0),
            0
        ); // fee 2500; bStock: no feed prices the token
        specs[4] = OracleSpec(
            "BTCB",
            0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c,
            0x46Cf1cF8c69595804ba91dFdd8d6b960c9B0a7C4,
            300,
            0x264990fbd0A4796A3E3d8E37C4d5F87a3aCa5Ebf,
            1 hours
        ); // fee 500; Chainlink, heartbeat 60s
        specs[5] = OracleSpec(
            "CRCLB",
            0x80f3D493EBCe97e343c53D29a137942416B4ffC0,
            0x29967c54c5Bf12E8158c8894376064b30ebaB297,
            300,
            address(0),
            0
        ); // fee 2500; bStock: no feed prices the token
        specs[6] = OracleSpec(
            "DJTB",
            0xF2ec508422174Ee564de98187db9359D318AFB6b,
            0x9aaDBd51515432DBB77c0A7F69C2B2c211f0C837,
            300,
            address(0),
            0
        ); // fee 2500; bStock: no feed prices the token
        specs[7] = OracleSpec(
            "DOGE",
            0xbA2aE424d960c26247Dd6c32edC70B295c744C43,
            0x89da4102853C6cf3F4e9979CBb1dC4a166F38E84,
            300,
            0x3AB0A0d137D4F946fBB19eecc6e92E64660231C8,
            1 hours
        ); // fee 10000; Chainlink, heartbeat 47s
        specs[8] = OracleSpec(
            "ETH",
            0x2170Ed0880ac9A755fd29B2688956BD959F933F8,
            0xBe141893E4c6AD9272e8C04BAB7E6a10604501a5,
            300,
            0x9ef1B8c0E4F7dc8bF5719Ea496883DC6401d5b2e,
            1 hours
        ); // fee 500; Chainlink, heartbeat 60s
        specs[9] = OracleSpec(
            "EWYB",
            0xBE82F76637DBA2C114C41Df856c2C51e522E2Cb8,
            0xc60ED5b770e8a3AbD60eE9Ed10Faa0aee577a66b,
            300,
            address(0),
            0
        ); // fee 2500; bStock: no feed prices the token
        specs[10] = OracleSpec(
            "GOOGLB",
            0x3F53De71c126BdaBAe20f9cD64848d317f6C3238,
            0x89001D846f7CA36EE089F73eEFC25657E1798144,
            300,
            address(0),
            0
        ); // fee 2500; bStock: no feed prices the token
        specs[11] = OracleSpec(
            "HOODB",
            0xA394dCEa3fd3847fD793afBFd163E2e3858B7c65,
            0xFEeF70FF6F58f0A900e28A77e5A8945aFB343923,
            300,
            address(0),
            0
        ); // fee 2500; bStock: no feed prices the token
        specs[12] = OracleSpec(
            "INTCB",
            0xe614E2fc6C787035FF51f452e8E826Bfd32D5283,
            0x4dD8e7C67033Ef4A745bB9f82a7C57c676eB2481,
            300,
            address(0),
            0
        ); // fee 2500; bStock: no feed prices the token
        specs[13] = OracleSpec(
            "METAB",
            0x7425889FE94F9d693E8daefE88BCCed6AcFEf4c0,
            0xC2151a561E928D16576d75Ea88544543ac63D80B,
            300,
            address(0),
            0
        ); // fee 2500; bStock: no feed prices the token
        specs[14] = OracleSpec(
            "MRNAB",
            0x5fd86da9B05abE396fe9d02a4A213A7c00556503,
            0xcC992887e9cee37a698541e2F6D1675453fbcfCC,
            300,
            address(0),
            0
        ); // fee 2500; bStock: no feed prices the token
        specs[15] = OracleSpec(
            "MSFTB",
            0x80106cb3EAD06659A5ad19DF39D9b4733863B9b0,
            0x5018b018cEB7645c927c5Cf246786F89ebCbe7Ea,
            300,
            address(0),
            0
        ); // fee 2500; bStock: no feed prices the token
        specs[16] = OracleSpec(
            "MSTRB",
            0xE87afb3076AeB0f9B14E368DE8145ae6a2826A14,
            0x692081209619735f25700557078aB084d3E5D007,
            300,
            address(0),
            0
        ); // fee 2500; bStock: no feed prices the token
        specs[17] = OracleSpec(
            "MUB",
            0xcdf2f3e0fa43C47A6662a91C9E4a7C5f69762699,
            0x9E75Ced0a01590890917C5180c3e3ed6a86A071e,
            300,
            address(0),
            0
        ); // fee 2500; bStock: no feed prices the token
        specs[18] = OracleSpec(
            "NFLXB",
            0xD6829Ea836b6FA224d099D40E54B31262f874631,
            0xAFab4441D8B354bBa790229c0E235E7e6187B3D0,
            300,
            address(0),
            0
        ); // fee 2500; bStock: no feed prices the token
        specs[19] = OracleSpec(
            "NOKB",
            0x7c4d7a180D737Dd5A70d8065a90E6746a69C37EA,
            0xD76cB6E9F642CDC7C33C9D4Fc6bDd858116DcC84,
            300,
            address(0),
            0
        ); // fee 2500; bStock: no feed prices the token
        specs[20] = OracleSpec(
            "NVDAB",
            0x02Fca66C1D1aFB4E2A7884261eB00F63598a7436,
            0x8FB4243b553aC29BA088aCf00B9B7dA24bD6690C,
            100,
            address(0),
            0
        ); // fee 2500; bStock: no feed prices the token
        specs[21] = OracleSpec(
            "QQQB",
            0x205812CdBed920aFf76C6580abD681a46D11efc7,
            0x7C84F9943Ec82cf2233c97A7Ee417f18bD2eC295,
            300,
            address(0),
            0
        ); // fee 500; bStock: no feed prices the token
        specs[22] = OracleSpec(
            "SGOVon",
            0xc008c5F579ec1450F20099c39F587547e27c7523,
            0xE0F4C53D777383cc77aDFa89087A9c877586F0dF,
            300,
            address(0),
            0
        ); // fee 2500; no fresh Chainlink feed
        specs[23] = OracleSpec(
            "SKHYB",
            0xCA750eF65f295BBECd685Abf54e82CAf297BDB61,
            0xD7d30F434b12F7Ed9b0Ae11fF1C754745a10aD52,
            300,
            address(0),
            0
        ); // fee 2500; bStock: no feed prices the token
        specs[24] = OracleSpec(
            "SNDKB",
            0x3eE4dF61bd4F867E349BEaE8bFE07bc31b4850fb,
            0xE4B5403f5103b02d1E8193B0D7D76D49F3F8ad77,
            300,
            address(0),
            0
        ); // fee 2500; bStock: no feed prices the token
        specs[25] = OracleSpec(
            "SOL",
            0x570A5D26f7765Ecb712C0924E4De545B89fD43dF,
            0x9F5a0AD81Fe7fD5dFb84EE7A0CFb83967359BD90,
            300,
            0x0E8a53DD9c13589df6382F13dA6B3Ec8F919B323,
            1 hours
        ); // fee 2500; Chainlink, heartbeat 600s
        specs[26] = OracleSpec(
            "SPCXB",
            0xbe9D156892E55e7154BcD3cB0FEA677F9D3103E1,
            0x977DaFFC095b33872E2741c19568925015C35b4d,
            300,
            address(0),
            0
        ); // fee 2500; bStock: no feed prices the token
        specs[27] = OracleSpec(
            "SPYB",
            0x7138b48df7D98D7e3cc221BfE7192D0a178182D8,
            0x7aA6d92Fc369A8C1EDc631A3aAc44eFB0808ddbF,
            300,
            address(0),
            0
        ); // fee 100; bStock: no feed prices the token
        specs[28] = OracleSpec(
            "TLTon",
            0xf69e40069aC227C11459E3f4e8a446b3401616b6,
            0x77e6b624d664150d96e13d99c68144b2a047e554,
            300,
            address(0),
            0
        ); // fee 2500; no fresh Chainlink feed
        specs[29] = OracleSpec(
            "TRX",
            0xCE7de646e7208a4Ef112cb6ed5038FA6cC6b12e3,
            0xa98D8a5867D664B7A758652146fd93a7dE40eE82,
            300,
            0xF4C5e535756D11994fCBB12Ba8adD0192D9b88be,
            1 hours
        ); // fee 2500; Chainlink, heartbeat 600s
        specs[30] = OracleSpec(
            "TSLAB",
            0x5b1910eAaD6450E50f816082Aa078C41F10C292f,
            0xB0f5E5400E8F0F7C242F2b7740C004f020579c41,
            300,
            address(0),
            0
        ); // fee 2500; bStock: no feed prices the token
        specs[31] = OracleSpec(
            "TSMB",
            0xAB78b89B5bb00236Be0B4B20704cBfa04EfC711c,
            0x03f59988F5c366046321cCcD2BF0E3878e2ed69C,
            300,
            address(0),
            0
        ); // fee 2500; bStock: no feed prices the token
        specs[32] = OracleSpec(
            "WBNB",
            0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c,
            0x36696169C63e42cd08ce11f5deeBbCeBae652050,
            100,
            0x0567F2323251f0Aab15c8dFb1967E4e8A7D42aeE,
            1 hours
        ); // fee 500; Chainlink, heartbeat 27s
        specs[33] = OracleSpec(
            "XAUt",
            0x21cAef8A43163Eea865baeE23b9C2E327696A3bf,
            0x83A0A8A723262651Ae9C54BBbA929F167443bC59,
            300,
            address(0),
            0
        ); // fee 500; no fresh Chainlink feed
        specs[34] = OracleSpec(
            "XRP",
            0x1D2F0da169ceB9fC7B3144628dB156f3F6c60dBE,
            0x71f5a8F7d448E59B1ede00A19fE59e05d125E742,
            300,
            0x93A67D414896A280bF8FFB3b389fE3686E014fda,
            1 hours
        ); // fee 2500; Chainlink, heartbeat 600s
        specs[35] = OracleSpec(
            "USDC",
            0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d,
            0x92b7807bF19b7DDdf89b706143896d05228f3121,
            300,
            0x51597f405303C4377E36123cBc172b13269EA163,
            1 hours
        ); // fee 100; Chainlink, heartbeat 900s
        specs[36] = OracleSpec(
            "DAI",
            0x1AF3F329e8BE154074D8769D1FFa4eE058B1DBc3,
            0xe043558b77E2B4c262D7D6E579B005ceb7F4591C,
            300,
            0x132d3C0B1D2cEa0BC552588063bdBb210FDeecfA,
            1 hours
        ); // fee 100; Chainlink, heartbeat 900s
        specs[37] = OracleSpec(
            "LTC",
            0x4338665CBB7B2485A8855A139b75D5e34AB0DB94,
            0x6B9E3825E39203277F8FD33371e36b5188B26410,
            300,
            0x74E72F37A8c415c8f1a98Ed42E78Ff997435791D,
            1 hours
        ); // fee 2500; Chainlink, heartbeat 900s
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
            if (specs[i].usdFeed != address(0)) {
                router.setSecondary(
                    specs[i].asset,
                    IAggregatorV3(specs[i].usdFeed),
                    IAggregatorV3(USDT_USD_FEED),
                    specs[i].maxFeedAge,
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
        // The only venue at deployment is the Universal Router, registered by the constructor. Aggregators
        // (KyberSwap, OpenOcean) are added by the Safe with `setVenue` after it has taken ownership.
        (AtpExecutor.VenueKind urKind, address urSpender) = executor.venues(V3_UNIVERSAL_ROUTER);
        require(
            urKind == AtpExecutor.VenueKind.PANCAKE_UR && urSpender == V3_UNIVERSAL_ROUTER,
            "executor UR venue"
        );

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
                        && deviation == SECONDARY_MAX_DEVIATION_BPS,
                    string.concat("secondary: ", specs[i].symbol)
                );
            }
            // Both directions, 100 USDT: a pool that cannot serve the 30 / 5 minute windows (cardinality, stale
            // history) or a secondary that is stale or disagrees fails the deployment here.
            (uint256 quoted, uint256 minimum) = router.previewSwap(USDT, specs[i].asset, 100e18);
            require(quoted != 0 && minimum != 0, string.concat("oracle cannot quote buy: ", specs[i].symbol));
            (uint256 back, uint256 backMin) = router.previewSwap(specs[i].asset, USDT, quoted);
            require(back != 0 && backMin != 0, string.concat("oracle cannot quote sale: ", specs[i].symbol));
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
