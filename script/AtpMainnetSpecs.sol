// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title AtpMainnetSpecs
/// @notice The BSC mainnet (chain 56) oracle book shared by `DeployAtpMainnet` and
/// `IncreaseObservationCardinality`: USDT, the window / age / cardinality constants, and the 38 admitted assets
/// with their pool, `maxSlippageBps` and secondary feed.
///
/// @dev `maxSlippageBps` tiers (cre8-contracts#25, review L-6). The floor discount is also the most one step can
/// lose when a session key leaks, so it is set per asset from pool fee, pool depth and volatility instead of a
/// flat 300 bps:
///
///   tier S  50 bps   USD stablecoins vs USDT (USDC, DAI): peg moves < 0.1%, pool fee 0.01%. The issue's
///                    20-50 bps band; 50 rather than 20 leaves room for a 0.1-0.2% peg wobble between the
///                    30 minute mean and the fill.
///   tier A 100 bps   pool fee <= 0.05% and >= ~300k USDT in the pool (WBNB, BTCB, ETH, QQQB, XAUt), plus NVDAB,
///                    whose v1 oracle already used 100 on a 345k USDT pool. Fee + impact at a useful step size is
///                    well under 1%.
///   tier B 300 bps   everything else: pool fee 0.25-1% and/or < 300k USDT in the pool, or a volatile asset.
///                    Fee + impact at the admitted step size already uses about 200 bps of the budget
///                    (docs#32 data), so a tighter floor would leave no tradable step. Their manipulation risk
///                    is review H-1, which a tighter discount does not fix.
///
/// Tightening a floor shrinks the largest step that still clears it: the per-asset step caps
/// (`max_leg_usdt` in the db) for the tier S / A assets have to be re-measured at the new floors before
/// launch (see the PR of #25 for the estimates).
///
/// Feed max ages (L-5): about three heartbeats of each feed (docs#28: BNB 27 s, DOGE 47 s, BTC / ETH 60 s,
/// SOL / TRX / XRP 600 s, USDC / DAI / LTC / USDT 900 s), capped at the adapter's 1 day ceiling for AVAX
/// (24 h heartbeat). USDT/USD has its own max age instead of borrowing each asset's.
abstract contract AtpMainnetSpecs {
    address internal constant USDT = 0x55d398326f99059fF775485246999027B3197955;

    uint32 internal constant TWAP_WINDOW = 30 minutes;
    /// @dev Longest a pool may go without a new observation before its oracle stops quoting (M-1).
    uint32 internal constant MAX_ORACLE_AGE = 1 hours;
    /// @dev Observation slots every pool must have committed to (`observationCardinalityNext`, review M-2).
    /// A pool writes at most one observation per block and BSC makes a block about every 0.75 s, so
    /// 30 minutes is up to 2,400 observations: with 2,400 slots no burst of tick-moving swaps can push the
    /// 30 minute lookback out of the ring buffer.
    uint16 internal constant MIN_OBSERVATION_CARDINALITY = 2_400;

    /// @dev Secondary source (#15): Chainlink standard (non-SVR) push feeds on BSC, picked from docs#28
    /// (`research/2026-11-13-price-feeds/`). USDT/USD converts the USD feeds so USDT is never assumed to be $1.
    address internal constant USDT_USD_FEED = 0xB97Ad0E74fa7d920791E90258A6E2085088b4320;
    /// @dev USDT/USD heartbeat is 900 s: three heartbeats.
    uint32 internal constant USDT_USD_MAX_AGE = 2_700;
    uint16 internal constant SECONDARY_MAX_DEVIATION_BPS = 200;

    struct OracleSpec {
        string symbol;
        address asset;
        address pool;
        uint16 maxSlippageBps;
        /// @dev asset/USD push feed for the secondary source, or zero for pool TWAP only (bStocks: no feed
        /// prices the token itself, docs#28).
        address usdFeed;
        /// @dev `PushFeedPriceSource.maxAge` for that feed (about 3 heartbeats, L-5); 0 when there is none.
        uint32 maxFeedAge;
    }

    /// @dev Every admitted non-numeraire asset of docs#32 (`research/2026-11-13-launch-admission/資料/admission.json`
    /// at docs `cd8a659`): its Pancake V3 USDT pool, `maxSlippageBps`, and - for an asset that is not a bStock and
    /// has a fresh Chainlink standard (8 decimal, non-SVR) feed - that feed as the secondary source. Generated
    /// from the JSON, addresses checksummed; TWAP 30 min / recent 5 min / max age 1 h for all. `maxSlippageBps` and `maxFeedAge` follow cre8-contracts#25
    /// (tiers and 3 x heartbeat, see the contract header), not the 300 bps / 1 h of the list.
    function _oracleSpecs() internal pure returns (OracleSpec[] memory specs) {
        specs = new OracleSpec[](38);
        specs[0] = OracleSpec(
            "AAPLB",
            0x431a3BEE82E2ca41e49895CbECE5bB0F76A89b7A,
            0xe9b9998B2EC5430D2246c7f1F8D9f298c97D7365,
            300,
            address(0),
            0
        ); // tier B; fee 2500; bStock: no feed prices the token
        specs[1] = OracleSpec(
            "AMZNB",
            0x1a4b499833A79A09ad7Cf1D42D7DacF71e92eb00,
            0x7530beb7Bde5843f668cf31b996fa1F748C9b6B1,
            300,
            address(0),
            0
        ); // tier B; fee 2500; bStock: no feed prices the token
        specs[2] = OracleSpec(
            "AVAX",
            0x1CE0c2827e2eF14D5C4f29a091d735A204794041,
            0x9f11264d6d0d9671dAb2CC485eb6Ec1B502C4025,
            300,
            0x5974855ce31EE8E1fff2e76591CbF83D7110F151,
            1 days
        ); // tier B; fee 2500; Chainlink, heartbeat 86400s
        specs[3] = OracleSpec(
            "BABAB",
            0x4eF9d3062c7F6ebA4AAE4990c5036598C6eff4ec,
            0xfD95CB1391999006Eb91797a7c62acFe88b20292,
            300,
            address(0),
            0
        ); // tier B; fee 2500; bStock: no feed prices the token
        specs[4] = OracleSpec(
            "BTCB",
            0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c,
            0x46Cf1cF8c69595804ba91dFdd8d6b960c9B0a7C4,
            100,
            0x264990fbd0A4796A3E3d8E37C4d5F87a3aCa5Ebf,
            180
        ); // tier A; fee 500; Chainlink, heartbeat 60s
        specs[5] = OracleSpec(
            "CRCLB",
            0x80f3D493EBCe97e343c53D29a137942416B4ffC0,
            0x29967c54c5Bf12E8158c8894376064b30ebaB297,
            300,
            address(0),
            0
        ); // tier B; fee 2500; bStock: no feed prices the token
        specs[6] = OracleSpec(
            "DJTB",
            0xF2ec508422174Ee564de98187db9359D318AFB6b,
            0x9aaDBd51515432DBB77c0A7F69C2B2c211f0C837,
            300,
            address(0),
            0
        ); // tier B; fee 2500; bStock: no feed prices the token
        specs[7] = OracleSpec(
            "DOGE",
            0xbA2aE424d960c26247Dd6c32edC70B295c744C43,
            0x89da4102853C6cf3F4e9979CBb1dC4a166F38E84,
            300,
            0x3AB0A0d137D4F946fBB19eecc6e92E64660231C8,
            141
        ); // tier B; fee 10000; Chainlink, heartbeat 47s
        specs[8] = OracleSpec(
            "ETH",
            0x2170Ed0880ac9A755fd29B2688956BD959F933F8,
            0xBe141893E4c6AD9272e8C04BAB7E6a10604501a5,
            100,
            0x9ef1B8c0E4F7dc8bF5719Ea496883DC6401d5b2e,
            180
        ); // tier A; fee 500; Chainlink, heartbeat 60s
        specs[9] = OracleSpec(
            "EWYB",
            0xBE82F76637DBA2C114C41Df856c2C51e522E2Cb8,
            0xc60ED5b770e8a3AbD60eE9Ed10Faa0aee577a66b,
            300,
            address(0),
            0
        ); // tier B; fee 2500; bStock: no feed prices the token
        specs[10] = OracleSpec(
            "GOOGLB",
            0x3F53De71c126BdaBAe20f9cD64848d317f6C3238,
            0x89001D846f7CA36EE089F73eEFC25657E1798144,
            300,
            address(0),
            0
        ); // tier B; fee 2500; bStock: no feed prices the token
        specs[11] = OracleSpec(
            "HOODB",
            0xA394dCEa3fd3847fD793afBFd163E2e3858B7c65,
            0xFEeF70FF6F58f0A900e28A77e5A8945aFB343923,
            300,
            address(0),
            0
        ); // tier B; fee 2500; bStock: no feed prices the token
        specs[12] = OracleSpec(
            "INTCB",
            0xe614E2fc6C787035FF51f452e8E826Bfd32D5283,
            0x4dD8e7C67033Ef4A745bB9f82a7C57c676eB2481,
            300,
            address(0),
            0
        ); // tier B; fee 2500; bStock: no feed prices the token
        specs[13] = OracleSpec(
            "METAB",
            0x7425889FE94F9d693E8daefE88BCCed6AcFEf4c0,
            0xC2151a561E928D16576d75Ea88544543ac63D80B,
            300,
            address(0),
            0
        ); // tier B; fee 2500; bStock: no feed prices the token
        specs[14] = OracleSpec(
            "MRNAB",
            0x5fd86da9B05abE396fe9d02a4A213A7c00556503,
            0xcC992887e9cee37a698541e2F6D1675453fbcfCC,
            300,
            address(0),
            0
        ); // tier B; fee 2500; bStock: no feed prices the token
        specs[15] = OracleSpec(
            "MSFTB",
            0x80106cb3EAD06659A5ad19DF39D9b4733863B9b0,
            0x5018b018cEB7645c927c5Cf246786F89ebCbe7Ea,
            300,
            address(0),
            0
        ); // tier B; fee 2500; bStock: no feed prices the token
        specs[16] = OracleSpec(
            "MSTRB",
            0xE87afb3076AeB0f9B14E368DE8145ae6a2826A14,
            0x692081209619735f25700557078aB084d3E5D007,
            300,
            address(0),
            0
        ); // tier B; fee 2500; bStock: no feed prices the token
        specs[17] = OracleSpec(
            "MUB",
            0xcdf2f3e0fa43C47A6662a91C9E4a7C5f69762699,
            0x9E75Ced0a01590890917C5180c3e3ed6a86A071e,
            300,
            address(0),
            0
        ); // tier B; fee 2500; bStock: no feed prices the token
        specs[18] = OracleSpec(
            "NFLXB",
            0xD6829Ea836b6FA224d099D40E54B31262f874631,
            0xAFab4441D8B354bBa790229c0E235E7e6187B3D0,
            300,
            address(0),
            0
        ); // tier B; fee 2500; bStock: no feed prices the token
        specs[19] = OracleSpec(
            "NOKB",
            0x7c4d7a180D737Dd5A70d8065a90E6746a69C37EA,
            0xD76cB6E9F642CDC7C33C9D4Fc6bDd858116DcC84,
            300,
            address(0),
            0
        ); // tier B; fee 2500; bStock: no feed prices the token
        specs[20] = OracleSpec(
            "NVDAB",
            0x02Fca66C1D1aFB4E2A7884261eB00F63598a7436,
            0x8FB4243b553aC29BA088aCf00B9B7dA24bD6690C,
            100,
            address(0),
            0
        ); // tier A (kept from the v1 oracle, 345k USDT pool); fee 2500; bStock: no feed prices the token
        specs[21] = OracleSpec(
            "QQQB",
            0x205812CdBed920aFf76C6580abD681a46D11efc7,
            0x7C84F9943Ec82cf2233c97A7Ee417f18bD2eC295,
            100,
            address(0),
            0
        ); // tier A; fee 500; bStock: no feed prices the token
        specs[22] = OracleSpec(
            "SGOVon",
            0xc008c5F579ec1450F20099c39F587547e27c7523,
            0xE0F4C53D777383cc77aDFa89087A9c877586F0dF,
            300,
            address(0),
            0
        ); // tier B; fee 2500; no fresh Chainlink feed
        specs[23] = OracleSpec(
            "SKHYB",
            0xCA750eF65f295BBECd685Abf54e82CAf297BDB61,
            0xD7d30F434b12F7Ed9b0Ae11fF1C754745a10aD52,
            300,
            address(0),
            0
        ); // tier B; fee 2500; bStock: no feed prices the token
        specs[24] = OracleSpec(
            "SNDKB",
            0x3eE4dF61bd4F867E349BEaE8bFE07bc31b4850fb,
            0xE4B5403f5103b02d1E8193B0D7D76D49F3F8ad77,
            300,
            address(0),
            0
        ); // tier B; fee 2500; bStock: no feed prices the token
        specs[25] = OracleSpec(
            "SOL",
            0x570A5D26f7765Ecb712C0924E4De545B89fD43dF,
            0x9F5a0AD81Fe7fD5dFb84EE7A0CFb83967359BD90,
            300,
            0x0E8a53DD9c13589df6382F13dA6B3Ec8F919B323,
            1_800
        ); // tier B; fee 2500; Chainlink, heartbeat 600s
        specs[26] = OracleSpec(
            "SPCXB",
            0xbe9D156892E55e7154BcD3cB0FEA677F9D3103E1,
            0x977DaFFC095b33872E2741c19568925015C35b4d,
            300,
            address(0),
            0
        ); // tier B; fee 2500; bStock: no feed prices the token
        specs[27] = OracleSpec(
            "SPYB",
            0x7138b48df7D98D7e3cc221BfE7192D0a178182D8,
            0x7aA6d92Fc369A8C1EDc631A3aAc44eFB0808ddbF,
            300,
            address(0),
            0
        ); // tier B; fee 100; bStock: no feed prices the token
        specs[28] = OracleSpec(
            "TLTon",
            0xf69e40069aC227C11459E3f4e8a446b3401616b6,
            0x77e6b624d664150d96e13d99c68144b2a047e554,
            300,
            address(0),
            0
        ); // tier B; fee 2500; no fresh Chainlink feed
        specs[29] = OracleSpec(
            "TRX",
            0xCE7de646e7208a4Ef112cb6ed5038FA6cC6b12e3,
            0xa98D8a5867D664B7A758652146fd93a7dE40eE82,
            300,
            0xF4C5e535756D11994fCBB12Ba8adD0192D9b88be,
            1_800
        ); // tier B; fee 2500; Chainlink, heartbeat 600s
        specs[30] = OracleSpec(
            "TSLAB",
            0x5b1910eAaD6450E50f816082Aa078C41F10C292f,
            0xB0f5E5400E8F0F7C242F2b7740C004f020579c41,
            300,
            address(0),
            0
        ); // tier B; fee 2500; bStock: no feed prices the token
        specs[31] = OracleSpec(
            "TSMB",
            0xAB78b89B5bb00236Be0B4B20704cBfa04EfC711c,
            0x03f59988F5c366046321cCcD2BF0E3878e2ed69C,
            300,
            address(0),
            0
        ); // tier B; fee 2500; bStock: no feed prices the token
        specs[32] = OracleSpec(
            "WBNB",
            0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c,
            0x36696169C63e42cd08ce11f5deeBbCeBae652050,
            100,
            0x0567F2323251f0Aab15c8dFb1967E4e8A7D42aeE,
            81
        ); // tier A; fee 500; Chainlink, heartbeat 27s
        specs[33] = OracleSpec(
            "XAUt",
            0x21cAef8A43163Eea865baeE23b9C2E327696A3bf,
            0x83A0A8A723262651Ae9C54BBbA929F167443bC59,
            100,
            address(0),
            0
        ); // tier A; fee 500; no fresh Chainlink feed
        specs[34] = OracleSpec(
            "XRP",
            0x1D2F0da169ceB9fC7B3144628dB156f3F6c60dBE,
            0x71f5a8F7d448E59B1ede00A19fE59e05d125E742,
            300,
            0x93A67D414896A280bF8FFB3b389fE3686E014fda,
            1_800
        ); // tier B; fee 2500; Chainlink, heartbeat 600s
        specs[35] = OracleSpec(
            "USDC",
            0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d,
            0x92b7807bF19b7DDdf89b706143896d05228f3121,
            50,
            0x51597f405303C4377E36123cBc172b13269EA163,
            2_700
        ); // tier S; fee 100; Chainlink, heartbeat 900s
        specs[36] = OracleSpec(
            "DAI",
            0x1AF3F329e8BE154074D8769D1FFa4eE058B1DBc3,
            0xe043558b77E2B4c262D7D6E579B005ceb7F4591C,
            50,
            0x132d3C0B1D2cEa0BC552588063bdBb210FDeecfA,
            2_700
        ); // tier S; fee 100; Chainlink, heartbeat 900s
        specs[37] = OracleSpec(
            "LTC",
            0x4338665CBB7B2485A8855A139b75D5e34AB0DB94,
            0x6B9E3825E39203277F8FD33371e36b5188B26410,
            300,
            0x74E72F37A8c415c8f1a98Ed42E78Ff997435791D,
            2_700
        ); // tier B; fee 2500; Chainlink, heartbeat 900s
    }
}
