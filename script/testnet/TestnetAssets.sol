// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title TestnetAssets
/// @notice The testnet asset list (chain 97 only), 105 mocks plus testnet USDT. Mainnet still admits only the 38
/// of `AtpMainnetSpecs`.
/// - Entries 0-37 (`LAUNCH_COUNT`) are the 38 launch assets as testnet mocks (cre8-contracts#30): the list,
///   order, `maxSlippageBps` tier (cre8-contracts#25: S 50 / A 100 / B 300) and secondary-feed choice of
///   `AtpMainnetSpecs`; symbol, decimals, Pancake V3 fee tier and bStock `uiMultiplier` of the mainnet token and
///   pool; and a fixed starting price.
/// - Entries 38-77 (cre8-contracts#39) are the other 40 tokens the 16 testnet showcase funds hold (Leopold
///   Aschenbrenner, Gavin Baker, Ken Griffin, AI Buildout, Ray Dalio, Lyn Alden, David Einhorn, Berkshire,
///   Pelosi, Mag7, Bill Ackman, Druckenmiller, Treasury Reserve, Ming-Chi Kuo, Raoul Pal, Multi-Asset
///   Balanced): the union of their cre8-app `src/reference/data/funds.json` `backtest.targets[]` with
///   `weight > 0`, minus USDT and the launch assets, in ASCII symbol order (the issue's order). The BSC
///   (chain 56) token is the one `assets.json` lists for the symbol.
/// - Entries 78-91 (cre8-contracts#39) are crypto: ADA, LINK, BCH, NEAR, UNI, ZEC and TONCOIN (the CoinGecko
///   top 30 by market cap, stablecoins excluded, 2026-11-15, that have a Binance-Peg or official BEP20 token
///   and are not listed yet); DOT, SHIB, PEPE, AAVE, Cake, FIL, ATOM (named in the issue). Their BSC tokens:
///   ADA, LINK, BCH, NEAR and UNI are the ones `assets.json` lists (Binance-Peg; for UNI that is
///   0xBf5140A22578168FD562DCcF235E5D43A02ce9B1, not CoinGecko's `uniswap` BSC address, whose on-chain symbol is
///   NUNI); the others are the `binance-smart-chain` platform address of the coin (or of its `binance-peg-*`
///   entry) in CoinGecko's coin list, 2026-11-15.
/// - Entries 92-104 (cre8-contracts#61) are the 13 bStocks the 21 launch-lineup funds hold that the list lacked
///   (docs `research/2026-11-20-launch-lineup/新增模擬資產.csv`), in the issue's order. Testnet only, like 38-91
///   (tier B, no secondary feed). Symbol, name, decimals and `uiMultiplier` read from the BSC token, read-only, at
///   block 134535867 (2026-11-20); they match the CSV. Price: the CSV's starting price per raw token (Binance spot
///   ticker x `uiMultiplier`, 2026-11-19 16:12 UTC), except ANTB, which has no quote: a pure test constant of 300
///   USDT. Fee tier: the #39 rule below (mainnet USDT pool with >= 1,000 USDT, else 2500), read at the same block.
/// - Entries 38-91 are testnet only: `maxSlippageBps` 300, no secondary feed. Symbol, name, decimals and
///   bStock `uiMultiplier` were read from the BSC token, read-only, at block 133693735 (2026-11-15). Price and
///   fee tier: a mainnet Pancake V3 pool against USDT that holds at least 1,000 USDT gives its fee and spot price
///   (the one holding the most USDT); the many smaller pools are left out, because most are empty and quote
///   nonsense (e.g. 3.4e38 USDT per DOT). Otherwise fee 2500 and, for a stock or ETF token, the catalog's last
///   close (`history`, USD per share, times `uiMultiplier` for a bStock; an Ondo token's accrued distributions
///   are not added), or for crypto the CoinGecko USD price of 2026-11-15. Each entry's comment names its source.
///   All prices are rounded to 6 significant digits.
/// @dev `maxFeedAge` is NOT mainnet's 3 x Chainlink heartbeat (81-180 s for the fast feeds): the mock feeds are
/// pushed by the testnet price keeper (backend `src/keeper`, a push every 60-300 s step, and it checks each
/// source's `maxAge` against these values), so they keep 1 hour (AVAX 1 day). The secondary sources are
/// deployed by the router with CREATE, so these ages do not move any address.
/// @dev Entries 0-37 were generated from BSC mainnet, read-only, at block 133542361 (2026-11-14): `decimals()`,
/// `name()`, `uiMultiplier()` of each token and `fee()` / `slot0()` of each `DeployAtpMainnet` pool; their prices
/// are the pool spot. All prices are in USDT (18 decimals) per whole token: a fixed baseline, not a live market. `uiMultiplier` 0 = not a bStock (plain `TestnetToken`); 1e18 = 1x.
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

    uint256 internal constant COUNT = 105;
    /// @dev The first entries are the mainnet launch assets, in `AtpMainnetSpecs` order.
    uint256 internal constant LAUNCH_COUNT = 38;

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

        // ---- cre8-contracts#39: the other tokens of the 16 showcase funds (see the header) ----
        s[38] = AssetSpec(
            "ABBVon", "AbbVie (Ondo Tokenized) (testnet)", 18, 2500, 293300000000000000000, 300, false, 0, 0
        ); // 293.3 USDT; catalog close 2026-11-09
        s[39] = AssetSpec(
            "ALABB",
            "Astera Labs (testnet)",
            18,
            2500,
            216870000000000000000,
            300,
            false,
            0,
            1000000000000000000
        ); // 216.87 USDT; catalog close 2026-11-09
        s[40] = AssetSpec(
            "AMATB",
            "Applied Materials (testnet)",
            18,
            2500,
            370827000000000000000,
            300,
            false,
            0,
            1000748400440519121
        ); // 370.827 USDT; catalog close 2026-11-09 x uiMultiplier
        s[41] = AssetSpec(
            "AMDB",
            "Advanced Micro Devices Inc (testnet)",
            18,
            2500,
            508580000000000000000,
            300,
            false,
            0,
            1000000000000000000
        ); // 508.58 USDT; catalog close 2026-11-09
        s[42] = AssetSpec(
            "APHon", "Amphenol (Ondo Tokenized) (testnet)", 18, 2500, 80710000000000000000, 300, false, 0, 0
        ); // 80.71 USDT; catalog close 2026-11-09
        s[43] = AssetSpec(
            "APLDon",
            "Applied Digital (Ondo Tokenized) (testnet)",
            18,
            2500,
            16720000000000000000,
            300,
            false,
            0,
            0
        ); // 16.72 USDT; catalog close 2026-11-09
        s[44] = AssetSpec(
            "AVGOB", "Broadcom (testnet)", 18, 2500, 319885000000000000000, 300, false, 0, 1001269208611258122
        ); // 319.885 USDT; catalog close 2026-11-09 x uiMultiplier
        s[45] = AssetSpec(
            "AXPon",
            "American Express (Ondo Tokenized) (testnet)",
            18,
            2500,
            324310000000000000000,
            300,
            false,
            0,
            0
        ); // 324.31 USDT; catalog close 2026-11-09
        s[46] = AssetSpec(
            "BEB",
            "Bloom Energy (testnet)",
            18,
            2500,
            193880000000000000000,
            300,
            false,
            0,
            1000000000000000000
        ); // 193.88 USDT; catalog close 2026-11-09
        s[47] = AssetSpec(
            "BLKon",
            "Blackrock, Inc. (Ondo Tokenized) (testnet)",
            18,
            2500,
            1214710000000000000000,
            300,
            false,
            0,
            0
        ); // 1214.71 USDT; catalog close 2026-11-09
        s[48] = AssetSpec(
            "CBRSB", "Cerebras (testnet)", 18, 2500, 96700000000000000000, 300, false, 0, 1000000000000000000
        ); // 96.7 USDT; catalog close 2026-11-09
        s[49] = AssetSpec(
            "CEGon",
            "Constellation Energy (Ondo Tokenized) (testnet)",
            18,
            2500,
            276090000000000000000,
            300,
            false,
            0,
            0
        ); // 276.09 USDT; catalog close 2026-11-09
        s[50] = AssetSpec(
            "CIENon", "Ciena (Ondo Tokenized) (testnet)", 18, 2500, 269330000000000000000, 300, false, 0, 0
        ); // 269.33 USDT; catalog close 2026-11-09
        s[51] = AssetSpec(
            "COHRB", "Coherent (testnet)", 18, 2500, 225190000000000000000, 300, false, 0, 1000000000000000000
        ); // 225.19 USDT; catalog close 2026-11-09
        s[52] = AssetSpec(
            "CORZon",
            "Core Scientific (Ondo Tokenized) (testnet)",
            18,
            2500,
            12720000000000000000,
            300,
            false,
            0,
            0
        ); // 12.72 USDT; catalog close 2026-11-09
        s[53] = AssetSpec(
            "CRDOB",
            "Credo Technology (testnet)",
            18,
            2500,
            132890000000000000000,
            300,
            false,
            0,
            1000000000000000000
        ); // 132.89 USDT; catalog close 2026-11-09
        s[54] = AssetSpec(
            "CRMB",
            "Salesforce (testnet)",
            18,
            2500,
            215204000000000000000,
            300,
            false,
            0,
            1001229509379034956
        ); // 215.204 USDT; catalog close 2026-11-09 x uiMultiplier
        s[55] = AssetSpec(
            "CRWVB", "CoreWeave (testnet)", 18, 2500, 48980000000000000000, 300, false, 0, 1000000000000000000
        ); // 48.98 USDT; catalog close 2026-11-09
        s[56] = AssetSpec(
            "CVXon", "Chevron (Ondo Tokenized) (testnet)", 18, 2500, 210780000000000000000, 300, false, 0, 0
        ); // 210.78 USDT; catalog close 2026-11-09
        s[57] = AssetSpec(
            "GEVB",
            "GE Vernova Inc (testnet)",
            18,
            2500,
            829340000000000000000,
            300,
            false,
            0,
            1000000000000000000
        ); // 829.34 USDT; catalog close 2026-11-09
        s[58] = AssetSpec(
            "GLDon",
            "SPDR Gold Shares (Ondo Tokenized) (testnet)",
            18,
            2500,
            379530000000000000000,
            300,
            false,
            0,
            0
        ); // 379.53 USDT; catalog close 2026-11-09
        s[59] = AssetSpec(
            "GOOGon",
            "Alphabet Inc. Class C (Ondo Tokenized) (testnet)",
            18,
            2500,
            286010000000000000000,
            300,
            false,
            0,
            0
        ); // 286.01 USDT; catalog close 2026-11-09
        s[60] = AssetSpec(
            "GPROB", "GoPro (testnet)", 18, 2500, 880000000000000000, 300, false, 0, 1000000000000000000
        ); // 0.88 USDT; catalog close 2026-11-09
        s[61] = AssetSpec(
            "IEFon",
            "iShares 7-10 Year Treasury Bond ETF (Ondo Tokenized) (testnet)",
            18,
            2500,
            91800000000000000000,
            300,
            false,
            0,
            0
        ); // 91.8 USDT; catalog close 2026-11-09
        s[62] = AssetSpec(
            "IRENB",
            "IREN Limited (testnet)",
            18,
            2500,
            21410000000000000000,
            300,
            false,
            0,
            1000000000000000000
        ); // 21.41 USDT; catalog close 2026-11-09
        s[63] = AssetSpec(
            "IVVon",
            "iShares Core S&P 500 ETF (Ondo Tokenized) (testnet)",
            18,
            2500,
            756050000000000000000,
            300,
            false,
            0,
            0
        ); // 756.05 USDT; catalog close 2026-11-09
        s[64] = AssetSpec(
            "KOon", "Coca-Cola (Ondo Tokenized) (testnet)", 18, 2500, 96030000000000000000, 300, false, 0, 0
        ); // 96.03 USDT; catalog close 2026-11-09
        s[65] = AssetSpec(
            "LLYB",
            "Eli Lilly (testnet)",
            18,
            2500,
            1430490000000000000000,
            300,
            false,
            0,
            1000844349625262753
        ); // 1430.49 USDT; mainnet pool 2500 (1580 USDT in pool)
        s[66] = AssetSpec(
            "MAon", "Mastercard (Ondo Tokenized) (testnet)", 18, 2500, 655810000000000000000, 300, false, 0, 0
        ); // 655.81 USDT; catalog close 2026-11-09
        s[67] = AssetSpec(
            "NBISB", "Nebius (testnet)", 18, 2500, 141450000000000000000, 300, false, 0, 1000000000000000000
        ); // 141.45 USDT; catalog close 2026-11-09
        s[68] = AssetSpec(
            "NEMon", "Newmont (Ondo Tokenized) (testnet)", 18, 2500, 125160000000000000000, 300, false, 0, 0
        ); // 125.16 USDT; catalog close 2026-11-09
        s[69] = AssetSpec(
            "ORCLB", "Oracle (testnet)", 18, 2500, 120098000000000000000, 300, false, 0, 1002571827467211643
        ); // 120.098 USDT; catalog close 2026-11-09 x uiMultiplier
        s[70] = AssetSpec(
            "PANWon",
            "Palo Alto Networks (Ondo Tokenized) (testnet)",
            18,
            2500,
            330890000000000000000,
            300,
            false,
            0,
            0
        ); // 330.89 USDT; catalog close 2026-11-09
        s[71] = AssetSpec(
            "PYPLB", "Paypal (testnet)", 18, 2500, 60156400000000000000, 300, false, 0, 1001771778812964209
        ); // 60.1564 USDT; catalog close 2026-11-09 x uiMultiplier
        s[72] = AssetSpec(
            "SHAZB", "SharonAI (testnet)", 18, 2500, 23930000000000000000, 300, false, 0, 1000000000000000000
        ); // 23.93 USDT; catalog close 2026-11-09
        s[73] = AssetSpec(
            "STXB", "Seagate (testnet)", 18, 2500, 506423000000000000000, 300, false, 0, 1000559247178444730
        ); // 506.423 USDT; catalog close 2026-11-09 x uiMultiplier
        s[74] = AssetSpec(
            "UBERon", "Uber (Ondo Tokenized) (testnet)", 18, 2500, 71170000000000000000, 300, false, 0, 0
        ); // 71.17 USDT; catalog close 2026-11-09
        s[75] = AssetSpec(
            "VRTon", "Vertiv (Ondo Tokenized) (testnet)", 18, 2500, 200470000000000000000, 300, false, 0, 0
        ); // 200.47 USDT; catalog close 2026-11-09
        s[76] = AssetSpec(
            "VSTB",
            "Vistra Corp (testnet)",
            18,
            2500,
            133920000000000000000,
            300,
            false,
            0,
            1000000000000000000
        ); // 133.92 USDT; catalog close 2026-11-09
        s[77] = AssetSpec(
            "Von", "Visa (Ondo Tokenized) (testnet)", 18, 2500, 422160000000000000000, 300, false, 0, 0
        ); // 422.16 USDT; catalog close 2026-11-09

        // ---- cre8-contracts#39: crypto (see the header) ----
        s[78] = AssetSpec("ADA", "Cardano Token (testnet)", 18, 2500, 150164000000000000, 300, false, 0, 0); // 0.150164 USDT; mainnet pool 2500 (11859 USDT in pool)
        s[79] =
            AssetSpec("LINK", "ChainLink Token (testnet)", 18, 10000, 9127500000000000000, 300, false, 0, 0); // 9.1275 USDT; mainnet pool 10000 (3685 USDT in pool)
        s[80] = AssetSpec(
            "BCH", "Bitcoin Cash Token (testnet)", 18, 2500, 204300000000000000000, 300, false, 0, 0
        ); // 204.3 USDT; CoinGecko bitcoin-cash 2026-11-15
        s[81] = AssetSpec("NEAR", "NEAR Protocol (testnet)", 18, 2500, 3133340000000000000, 300, false, 0, 0); // 3.13334 USDT; mainnet pool 2500 (6470 USDT in pool)
        s[82] = AssetSpec("UNI", "Uniswap (testnet)", 18, 10000, 5024790000000000000, 300, false, 0, 0); // 5.02479 USDT; mainnet pool 10000 (6451 USDT in pool)
        s[83] = AssetSpec("ZEC", "Zcash Token (testnet)", 18, 2500, 897060000000000000000, 300, false, 0, 0); // 897.06 USDT; mainnet pool 2500 (74668 USDT in pool)
        s[84] = AssetSpec(
            "TONCOIN", "Wrapped TON Coin (testnet)", 9, 2500, 1051000000000000000, 300, false, 0, 0
        ); // 1.051 USDT; CoinGecko the-open-network 2026-11-15
        s[85] = AssetSpec("DOT", "Polkadot Token (testnet)", 18, 2500, 719267000000000000, 300, false, 0, 0); // 0.719267 USDT; CoinGecko polkadot 2026-11-15
        s[86] = AssetSpec("SHIB", "SHIBA INU (testnet)", 18, 2500, 3880000000000, 300, false, 0, 0); // 0.00000388 USDT; CoinGecko shiba-inu 2026-11-15
        s[87] = AssetSpec("PEPE", "Pepe (testnet)", 18, 2500, 3928280000000, 300, false, 0, 0); // 0.00000392828 USDT; mainnet pool 2500 (23032 USDT in pool)
        s[88] = AssetSpec("AAVE", "Aave Token (testnet)", 18, 2500, 105860000000000000000, 300, false, 0, 0); // 105.86 USDT; CoinGecko aave 2026-11-15
        s[89] =
            AssetSpec("Cake", "PancakeSwap Token (testnet)", 18, 2500, 1615720000000000000, 300, false, 0, 0); // 1.61572 USDT; mainnet pool 2500 (496744 USDT in pool)
        s[90] = AssetSpec("FIL", "Filecoin (testnet)", 18, 2500, 614694000000000000, 300, false, 0, 0); // 0.614694 USDT; CoinGecko filecoin 2026-11-15
        s[91] = AssetSpec("ATOM", "Cosmos Token (testnet)", 18, 2500, 1280000000000000000, 300, false, 0, 0); // 1.28 USDT; CoinGecko cosmos 2026-11-15
        // ---- cre8-contracts#61: the 13 tokens the 21 launch-lineup funds add (see the header) ----
        s[92] = AssetSpec(
            "AMCB",
            "AMC Entertainment Holdings (testnet)",
            18,
            2500,
            2920000000000000000,
            300,
            false,
            0,
            1000000000000000000
        ); // 2.92 USDT; Binance spot AMCBUSDT; mainnet pool 2500 (24792 USDT in pool)
        s[93] = AssetSpec(
            "ANTB", "Anthropic (testnet)", 18, 2500, 300000000000000000000, 300, false, 0, 1000000000000000000
        ); // 300 USDT; TEST CONSTANT: no Binance spot quote and no mainnet pool with USDT depth (docs launch-lineup), not a market price
        s[94] = AssetSpec(
            "BMNRB",
            "BitMine Immersion Technologies (testnet)",
            18,
            2500,
            15710000000000000000,
            300,
            false,
            0,
            1000000000000000000
        ); // 15.71 USDT; Binance spot; mainnet pool 2500 (10388 USDT in pool)
        s[95] = AssetSpec(
            "BNCB",
            "CEA Industries (testnet)",
            18,
            2500,
            3530000000000000000,
            300,
            false,
            0,
            1000000000000000000
        ); // 3.53 USDT; Binance spot; mainnet pool 2500 (31369 USDT in pool)
        s[96] = AssetSpec(
            "COINB", "Coinbase (testnet)", 18, 2500, 112370000000000000000, 300, false, 0, 1000000000000000000
        ); // 112.37 USDT; Binance spot; no mainnet pool >= 1,000 USDT, fee 2500
        s[97] = AssetSpec(
            "CYPHB",
            "Cypherpunk Technologies (testnet)",
            18,
            2500,
            1850000000000000000,
            300,
            false,
            0,
            1000000000000000000
        ); // 1.85 USDT; Binance spot; no mainnet pool >= 1,000 USDT, fee 2500
        s[98] = AssetSpec(
            "GMEB", "GameStop (testnet)", 18, 2500, 26310000000000000000, 300, false, 0, 1000000000000000000
        ); // 26.31 USDT; Binance spot; mainnet pool 2500 (86890 USDT in pool)
        s[99] = AssetSpec(
            "MRVLB",
            "Marvell Technology (testnet)",
            18,
            10000,
            147983000000000000000,
            300,
            false,
            0,
            1000153284671603306
        ); // 147.983 USDT; Binance spot 147.96 x uiMultiplier; mainnet pool 10000 (5403 USDT in pool)
        s[100] = AssetSpec(
            "PDDB",
            "PDD Holdings Inc (testnet)",
            18,
            2500,
            86360000000000000000,
            300,
            false,
            0,
            1000000000000000000
        ); // 86.36 USDT; Binance spot; mainnet pool 2500 (101386 USDT in pool)
        s[101] = AssetSpec(
            "PENGB",
            "Penguin Solutions Inc (testnet)",
            18,
            2500,
            45030000000000000000,
            300,
            false,
            0,
            1000000000000000000
        ); // 45.03 USDT; Binance spot; no mainnet pool >= 1,000 USDT, fee 2500
        s[102] = AssetSpec(
            "RDDTB", "Reddit (testnet)", 18, 2500, 92970000000000000000, 300, false, 0, 1000000000000000000
        ); // 92.97 USDT; Binance spot; no mainnet pool >= 1,000 USDT, fee 2500
        s[103] = AssetSpec(
            "SOXLB",
            "Semicon Bull 3X ETF (testnet)",
            18,
            2500,
            50872500000000000000,
            300,
            false,
            0,
            1000441939278863313
        ); // 50.8725 USDT; Binance spot 50.85 x uiMultiplier; mainnet pool 2500 (20937 USDT in pool)
        s[104] = AssetSpec(
            "TQQQB",
            "ProShares UltraPro QQQ (testnet)",
            18,
            2500,
            53091500000000000000,
            300,
            false,
            0,
            1001347622058686173
        ); // 53.0915 USDT; Binance spot 53.02 x uiMultiplier; mainnet pool 2500 (29570 USDT in pool)
    }
}
