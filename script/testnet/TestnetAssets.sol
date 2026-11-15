// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title TestnetAssets
/// @notice The 38 launch assets as testnet mocks (cre8-contracts#30): the list, order, `maxSlippageBps` tier
/// (cre8-contracts#25: S 50 / A 100 / B 300) and secondary-feed choice of `AtpMainnetSpecs`; symbol, decimals,
/// Pancake V3 fee tier and bStock `uiMultiplier` of the mainnet token and pool; and a fixed starting price.
/// @dev `maxFeedAge` is NOT mainnet's 3 x Chainlink heartbeat (81-180 s for the fast feeds): the mock feeds are
/// pushed by the testnet price keeper (backend `src/keeper`, a push every 60-300 s step, and it checks each
/// source's `maxAge` against these values), so they keep 1 hour (AVAX 1 day). The secondary sources are
/// deployed by the router with CREATE, so these ages do not move any address.
/// @dev Generated from BSC mainnet, read-only, at block 133542361 (2026-11-14): `decimals()`, `name()`,
/// `uiMultiplier()` of each token and `fee()` / `slot0()` of each `DeployAtpMainnet` pool. Prices are the pool
/// spot rounded to 6 significant digits, in USDT (18 decimals) per whole token: a fixed baseline, not a live
/// market. `uiMultiplier` 0 = not a bStock (plain `TestnetToken`); 1e18 = 1x.
library TestnetAssets {
    struct AssetSpec {
        string symbol;
        string name;
        uint8 decimals;
        uint24 fee;
        uint256 priceE18;
        uint16 maxSlippageBps;
        bool hasFeed;
        uint32 maxFeedAge;
        uint256 uiMultiplier;
    }

    uint256 internal constant COUNT = 38;

    function specs() internal pure returns (AssetSpec[] memory s) {
        s = new AssetSpec[](COUNT);
        s[0] = AssetSpec(
            "AAPLB", "Apple (testnet)", 18, 2500, 356976000000000000000, 300, false, 0, 1001135424170860199
        ); // 356.976 USDT
        s[1] = AssetSpec(
            "AMZNB", "Amazon (testnet)", 18, 2500, 264729000000000000000, 300, false, 0, 1000000000000000000
        ); // 264.729 USDT
        s[2] = AssetSpec("AVAX", "Avalanche (testnet)", 18, 2500, 8019980000000000000, 300, true, 1 days, 0); // 8.01998 USDT
        s[3] = AssetSpec(
            "BABAB", "Alibaba (testnet)", 18, 2500, 93783500000000000000, 300, false, 0, 1000000000000000000
        ); // 93.7835 USDT
        s[4] = AssetSpec(
            "BTCB", "BTCB Token (testnet)", 18, 500, 67123700000000000000000, 100, true, 1 hours, 0
        ); // 67123.7 USDT
        s[5] = AssetSpec(
            "CRCLB",
            "Circle Internet Group Inc. (testnet)",
            18,
            2500,
            60586400000000000000,
            300,
            false,
            0,
            1000000000000000000
        ); // 60.5864 USDT
        s[6] = AssetSpec(
            "DJTB",
            "Trump Media & Technology Group Corp (testnet)",
            18,
            2500,
            4586300000000000000,
            300,
            false,
            0,
            1000000000000000000
        ); // 4.58630 USDT
        s[7] = AssetSpec("DOGE", "Dogecoin (testnet)", 8, 10000, 62730900000000000, 300, true, 1 hours, 0); // 0.0627309 USDT
        s[8] = AssetSpec(
            "ETH", "Ethereum Token (testnet)", 18, 500, 1906330000000000000000, 100, true, 1 hours, 0
        ); // 1906.33 USDT
        s[9] = AssetSpec(
            "EWYB",
            "iShares MSCI South Korea ETF (testnet)",
            18,
            2500,
            140701000000000000000,
            300,
            false,
            0,
            1000000000000000000
        ); // 140.701 USDT
        s[10] = AssetSpec(
            "GOOGLB",
            "Alphabet (testnet)",
            18,
            2500,
            293439000000000000000,
            300,
            false,
            0,
            1000478058978107511
        ); // 293.439 USDT
        s[11] = AssetSpec(
            "HOODB", "Robinhood (testnet)", 18, 2500, 76282500000000000000, 300, false, 0, 1000000000000000000
        ); // 76.2825 USDT
        s[12] = AssetSpec(
            "INTCB",
            "Intel Corporation (testnet)",
            18,
            2500,
            58566900000000000000,
            300,
            false,
            0,
            1000000000000000000
        ); // 58.5669 USDT
        s[13] = AssetSpec(
            "METAB",
            "Meta Platforms (testnet)",
            18,
            2500,
            639072000000000000000,
            300,
            false,
            0,
            1000548290410744950
        ); // 639.072 USDT
        s[14] = AssetSpec(
            "MRNAB", "Moderna (testnet)", 18, 2500, 221708000000000000000, 300, false, 0, 1000000000000000000
        ); // 221.708 USDT
        s[15] = AssetSpec(
            "MSFTB",
            "Microsoft (testnet)",
            18,
            2500,
            522467000000000000000,
            300,
            false,
            0,
            1001313964833366845
        ); // 522.467 USDT
        s[16] = AssetSpec(
            "MSTRB",
            "Strategy Inc. (testnet)",
            18,
            2500,
            107424000000000000000,
            300,
            false,
            0,
            1000000000000000000
        ); // 107.424 USDT
        s[17] = AssetSpec(
            "MUB",
            "Micron Technology Inc (testnet)",
            18,
            2500,
            766962000000000000000,
            300,
            false,
            0,
            1000217357013353696
        ); // 766.962 USDT
        s[18] = AssetSpec(
            "NFLXB", "Netflix (testnet)", 18, 2500, 61987300000000000000, 300, false, 0, 1000000000000000000
        ); // 61.9873 USDT
        s[19] = AssetSpec(
            "NOKB", "Nokia (testnet)", 18, 2500, 8009990000000000000, 300, false, 0, 1004115394700397672
        ); // 8.00999 USDT
        s[20] = AssetSpec(
            "NVDAB",
            "NVIDIA Corp (testnet)",
            18,
            2500,
            162413000000000000000,
            100,
            false,
            0,
            1000778223752807865
        ); // 162.413 USDT
        s[21] = AssetSpec(
            "QQQB",
            "Invesqo QQQ (testnet)",
            18,
            500,
            676113000000000000000,
            100,
            false,
            0,
            1000724838657573033
        ); // 676.113 USDT
        s[22] = AssetSpec(
            "SGOVon",
            "iShares 0-3 Month Treasury Bond ETF (Ondo Tokenized) (testnet)",
            18,
            2500,
            102904000000000000000,
            300,
            false,
            0,
            0
        ); // 102.904 USDT
        s[23] = AssetSpec(
            "SKHYB", "SK Hynix (testnet)", 18, 2500, 130353000000000000000, 300, false, 0, 1000000000000000000
        ); // 130.353 USDT
        s[24] = AssetSpec(
            "SNDKB",
            "Sandisk Corporation (testnet)",
            18,
            2500,
            863817000000000000000,
            300,
            false,
            0,
            1000000000000000000
        ); // 863.817 USDT
        s[25] = AssetSpec("SOL", "SOLANA (testnet)", 18, 2500, 75800600000000000000, 300, true, 1 hours, 0); // 75.8006 USDT
        s[26] = AssetSpec(
            "SPCXB", "SpaceX (testnet)", 18, 2500, 136068000000000000000, 300, false, 0, 1000000000000000000
        ); // 136.068 USDT
        s[27] = AssetSpec(
            "SPYB", "SPY (testnet)", 18, 100, 752689000000000000000, 300, false, 0, 1001729792036835231
        ); // 752.689 USDT
        s[28] = AssetSpec(
            "TLTon",
            "iShares 20+ Year Treasury Bond ETF (Ondo Tokenized) (testnet)",
            18,
            2500,
            83495600000000000000,
            300,
            false,
            0,
            0
        ); // 83.4956 USDT
        s[29] = AssetSpec("TRX", "TRON (testnet)", 6, 2500, 312407000000000000, 300, true, 1 hours, 0); // 0.312407 USDT
        s[30] = AssetSpec(
            "TSLAB",
            "Tesla, Inc. (testnet)",
            18,
            2500,
            388543000000000000000,
            300,
            false,
            0,
            1000000000000000000
        ); // 388.543 USDT
        s[31] = AssetSpec(
            "TSMB", "TSMC (testnet)", 18, 2500, 396058000000000000000, 300, false, 0, 1002110464141050983
        ); // 396.058 USDT
        s[32] =
            AssetSpec("WBNB", "Wrapped BNB (testnet)", 18, 500, 614427000000000000000, 100, true, 1 hours, 0); // 614.427 USDT
        s[33] = AssetSpec("XAUt", "Tether Gold (testnet)", 6, 500, 3866590000000000000000, 100, false, 0, 0); // 3866.59 USDT
        s[34] = AssetSpec("XRP", "XRP Token (testnet)", 18, 2500, 993055000000000000, 300, true, 1 hours, 0); // 0.993055 USDT
        s[35] = AssetSpec("USDC", "USD Coin (testnet)", 18, 100, 1000730000000000000, 50, true, 1 hours, 0); // 1.00073 USDT
        s[36] = AssetSpec("DAI", "Dai Token (testnet)", 18, 100, 1001540000000000000, 50, true, 1 hours, 0); // 1.00154 USDT
        s[37] = AssetSpec(
            "LTC", "Litecoin Token (testnet)", 18, 2500, 48359900000000000000, 300, true, 1 hours, 0
        ); // 48.3599 USDT
    }
}
