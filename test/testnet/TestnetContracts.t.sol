// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { AtpRegistry } from "../../src/atp/AtpRegistry.sol";
import { AtpMultiPoolOracle } from "../../src/atp/AtpMultiPoolOracle.sol";
import { PushFeedPriceSource } from "../../src/atp/PushFeedPriceSource.sol";
import { IAggregatorV3 } from "../../src/atp/interfaces/IAggregatorV3.sol";
import { TestnetToken, TestnetBStock, TestnetUSDT } from "../../src/testnet/TestnetToken.sol";
import { TestnetPriceFeed } from "../../src/testnet/TestnetPriceFeed.sol";
import { TestnetOwnedDeployer } from "../../src/testnet/TestnetOwnedDeployer.sol";
import { DeployTestnet } from "../../script/DeployTestnet.s.sol";
import { TestnetAssets } from "../../script/testnet/TestnetAssets.sol";
import { PokePoolsTestnet } from "../../script/testnet/PokePoolsTestnet.s.sol";
import { AtpMainnetSpecs } from "../../script/AtpMainnetSpecs.sol";

/// @dev Exposes the mainnet oracle book so the testnet list can be checked against it.
contract MainnetSpecsHarness is AtpMainnetSpecs {
    function specs() external pure returns (OracleSpec[] memory) {
        return _oracleSpecs();
    }
}

/// @dev Exposes the keeper poke's baseline price.
contract PokePoolsHarness is PokePoolsTestnet {
    function sqrtPrice(uint256 priceE18, uint8 decimals, bool assetIsToken0) external pure returns (uint160) {
        return _sqrtPriceX96(priceE18, decimals, assetIsToken0);
    }
}

/// @dev Exposes the deploy script's oracle constants.
contract DeployTestnetHarness is DeployTestnet {
    function oracleConstants()
        external
        pure
        returns (uint32 twapWindow, uint32 maxOracleAge, uint32 usdtUsdMaxAge, uint16 deviationBps)
    {
        return (TWAP_WINDOW, MAX_ORACLE_AGE, USDT_USD_MAX_AGE, SECONDARY_MAX_DEVIATION_BPS);
    }

    function feeAndFaucetConstants()
        external
        pure
        returns (uint16 defaultFeeBps, uint256 minBatchFee, uint256 faucetDailyLimit, uint256 keeperUsdtStock)
    {
        return (DEFAULT_FEE_BPS, MIN_BATCH_FEE, FAUCET_DAILY_LIMIT, KEEPER_USDT_STOCK);
    }
}

/// @notice Unit tests for the chain-97-only mocks of cre8-contracts#30 and the deploy script's price math.
contract TestnetContractsTest is Test {
    address internal constant OWNER = address(0xD0);
    address internal constant KEEPER = address(0xEE);
    address internal constant ALICE = address(0xA1);
    address internal constant BOB = address(0xB0);

    // ---- TestnetToken ----

    function test_token_keepsDecimals_andOnlyMintersMint() public {
        TestnetToken doge = new TestnetToken("Dogecoin (testnet)", "DOGE", 8, OWNER);
        assertEq(doge.decimals(), 8);
        assertTrue(doge.isMinter(OWNER));

        vm.expectRevert(TestnetToken.NotMinter.selector);
        vm.prank(KEEPER);
        doge.mint(ALICE, 1);

        vm.expectRevert(TestnetToken.NotOwner.selector);
        vm.prank(KEEPER);
        doge.setMinter(KEEPER, true);

        vm.prank(OWNER);
        doge.setMinter(KEEPER, true);
        vm.prank(KEEPER);
        doge.mint(ALICE, 5e8);
        assertEq(doge.balanceOf(ALICE), 5e8);

        vm.prank(OWNER);
        doge.setMinter(KEEPER, false);
        vm.expectRevert(TestnetToken.NotMinter.selector);
        vm.prank(KEEPER);
        doge.mint(ALICE, 1);
    }

    /// @dev Same numbers as mainnet AAPLB at block 133542361: uiMultiplier 1001135424170860199,
    /// toUIAmount(1e18) = 1001135424170860199, fromUIAmount(1e18) = 998865863555072425.
    function test_bStock_uiAmounts_matchMainnetRounding() public {
        TestnetBStock aapl =
            new TestnetBStock("Apple (testnet)", "AAPLB", 18, OWNER, 1_001_135_424_170_860_199);
        assertEq(aapl.toUIAmount(1e18), 1_001_135_424_170_860_199);
        assertEq(aapl.fromUIAmount(1e18), 998_865_863_555_072_425);

        vm.prank(OWNER);
        aapl.mint(ALICE, 2e18);
        assertEq(aapl.balanceOfUI(ALICE), 2_002_270_848_341_720_398);
        assertEq(aapl.balanceOf(ALICE), 2e18, "raw balance untouched");

        vm.prank(OWNER);
        aapl.setUiMultiplier(2e18); // a 2-for-1 split, display only
        assertEq(aapl.balanceOfUI(ALICE), 4e18);

        vm.expectRevert(TestnetBStock.InvalidMultiplier.selector);
        vm.prank(OWNER);
        aapl.setUiMultiplier(0);
        vm.expectRevert(TestnetToken.NotOwner.selector);
        aapl.setUiMultiplier(1e18);
    }

    // ---- TestnetUSDT faucet ----

    address internal constant FAUCET = address(0xFA);

    function _usdtWithFaucet() internal returns (TestnetUSDT usdt) {
        usdt = new TestnetUSDT(OWNER, 1_000e18);
        vm.prank(OWNER);
        usdt.setFaucet(FAUCET, true);
    }

    function test_faucet_capsEachAddressPerWindow() public {
        TestnetUSDT usdt = _usdtWithFaucet();
        vm.warp(1_000_000);

        vm.prank(FAUCET);
        usdt.claimFor(ALICE, 600e18);
        vm.prank(FAUCET);
        usdt.claimFor(ALICE, 400e18);
        assertEq(usdt.balanceOf(ALICE), 1_000e18);

        vm.expectRevert(abi.encodeWithSelector(TestnetUSDT.ClaimLimitExceeded.selector, 1, 0));
        vm.prank(FAUCET);
        usdt.claimFor(ALICE, 1);

        // Another address has its own window.
        vm.prank(FAUCET);
        usdt.claimFor(BOB, 1_000e18);

        // The window resets 24 hours after Alice's first claim, not after her last.
        vm.warp(1_000_000 + 1 days - 1);
        (uint256 remaining, uint256 endsAt) = usdt.claimable(ALICE);
        assertEq(remaining, 0);
        assertEq(endsAt, 1_000_000 + 1 days);
        vm.warp(1_000_000 + 1 days);
        vm.prank(FAUCET);
        usdt.claimFor(ALICE, 1_000e18);
        assertEq(usdt.balanceOf(ALICE), 2_000e18);

        vm.expectRevert(TestnetUSDT.ZeroAmount.selector);
        vm.prank(FAUCET);
        usdt.claimFor(ALICE, 0);
        vm.expectRevert(TestnetToken.ZeroAddress.selector);
        vm.prank(FAUCET);
        usdt.claimFor(address(0), 1);
    }

    /// @dev cre8-contracts#47 #7: the faucet role and uncapped minting are separate. A minter is not a faucet,
    /// a faucet cannot mint, and only the owner appoints either.
    function test_faucet_claimFor_isFaucetOnly_andFaucetCannotMint() public {
        TestnetUSDT usdt = _usdtWithFaucet();
        vm.prank(OWNER);
        usdt.setMinter(KEEPER, true);

        vm.expectRevert(TestnetUSDT.NotFaucet.selector);
        vm.prank(KEEPER);
        usdt.claimFor(ALICE, 1e18);
        vm.expectRevert(TestnetUSDT.NotFaucet.selector);
        vm.prank(BOB);
        usdt.claimFor(ALICE, 1e18);

        vm.expectRevert(TestnetToken.NotMinter.selector);
        vm.prank(FAUCET);
        usdt.mint(FAUCET, 1);

        vm.expectRevert(TestnetToken.NotOwner.selector);
        vm.prank(FAUCET);
        usdt.setFaucet(BOB, true);
        vm.expectRevert(TestnetToken.ZeroAddress.selector);
        vm.prank(OWNER);
        usdt.setFaucet(address(0), true);

        vm.prank(OWNER);
        usdt.setDailyLimit(2_000e18);
        vm.prank(FAUCET);
        usdt.claimFor(ALICE, 2_000e18);
        assertEq(usdt.balanceOf(ALICE), 2_000e18);

        vm.prank(OWNER);
        usdt.setFaucet(FAUCET, false);
        vm.expectRevert(TestnetUSDT.NotFaucet.selector);
        vm.prank(FAUCET);
        usdt.claimFor(BOB, 1);
    }

    /// @dev The welcome grant: exactly `WELCOME_AMOUNT` once per address, faucet only, outside the daily window.
    function test_faucet_welcomeFor_oncePerAddress() public {
        TestnetUSDT usdt = _usdtWithFaucet();
        assertEq(usdt.WELCOME_AMOUNT(), 10_000e18);

        vm.expectRevert(TestnetUSDT.NotFaucet.selector);
        vm.prank(ALICE);
        usdt.welcomeFor(ALICE);

        vm.expectEmit(true, true, false, true, address(usdt));
        emit TestnetUSDT.Welcomed(ALICE, 10_000e18, FAUCET);
        vm.prank(FAUCET);
        usdt.welcomeFor(ALICE);
        assertEq(usdt.balanceOf(ALICE), 10_000e18);
        assertTrue(usdt.welcomed(ALICE));
        (uint256 remaining,) = usdt.claimable(ALICE);
        assertEq(remaining, 1_000e18, "the daily window is untouched");

        vm.expectRevert(abi.encodeWithSelector(TestnetUSDT.AlreadyWelcomed.selector, ALICE));
        vm.prank(FAUCET);
        usdt.welcomeFor(ALICE);
        vm.expectRevert(TestnetToken.ZeroAddress.selector);
        vm.prank(FAUCET);
        usdt.welcomeFor(address(0));
    }

    /// @dev cre8-contracts#47 #3: there is no self-service `claim` any more; any EOA calling it gets nothing.
    function test_faucet_hasNoPublicClaim() public {
        TestnetUSDT usdt = new TestnetUSDT(OWNER, 1_000e18);
        vm.prank(ALICE);
        (bool ok,) = address(usdt).call(abi.encodeWithSignature("claim(uint256)", 1_000e18));
        assertFalse(ok, "public claim must not exist");
        assertEq(usdt.balanceOf(ALICE), 0);
    }

    // ---- TestnetPriceFeed ----

    function test_feed_onlyKeeperPushes_andRoundsAdvance() public {
        vm.warp(10_000);
        TestnetPriceFeed feed = new TestnetPriceFeed(8, "BNB / USD (testnet)", OWNER, KEEPER, 614e8);
        (uint80 round, int256 answer,, uint256 updatedAt, uint80 answeredIn) = feed.latestRoundData();
        assertEq(round, 1);
        assertEq(answer, 614e8);
        assertEq(updatedAt, 10_000);
        assertEq(answeredIn, 1);

        vm.expectRevert(TestnetPriceFeed.NotKeeper.selector);
        vm.prank(OWNER);
        feed.push(1);

        vm.warp(10_060);
        vm.prank(KEEPER);
        feed.push(620e8);
        (round, answer,, updatedAt,) = feed.latestRoundData();
        assertEq(round, 2);
        assertEq(answer, 620e8);
        assertEq(updatedAt, 10_060);
        (, answer,,,) = feed.getRoundData(1);
        assertEq(answer, 614e8, "history kept");
        vm.expectRevert(TestnetPriceFeed.NoRound.selector);
        feed.getRoundData(3);

        vm.expectRevert(TestnetPriceFeed.NotOwner.selector);
        vm.prank(KEEPER);
        feed.setKeeper(ALICE);
        vm.prank(OWNER);
        feed.setKeeper(ALICE);
        vm.prank(ALICE);
        feed.push(1);
    }

    /// @dev The mock is consumed by the real adapter: fresh prices convert, stale / zero / negative revert.
    function test_feed_drivesPushFeedPriceSource_andItsFailClosedPaths() public {
        vm.warp(100_000);
        TestnetToken usdt = new TestnetToken("Testnet USDT", "USDT", 18, OWNER);
        TestnetToken btc = new TestnetToken("BTCB Token (testnet)", "BTCB", 18, OWNER);
        TestnetPriceFeed btcUsd = new TestnetPriceFeed(8, "BTCB / USD", OWNER, KEEPER, 67_000e8);
        TestnetPriceFeed usdtUsd = new TestnetPriceFeed(8, "USDT / USD", OWNER, KEEPER, 1e8);
        PushFeedPriceSource source = new PushFeedPriceSource(
            IAggregatorV3(address(btcUsd)),
            IAggregatorV3(address(usdtUsd)),
            address(btc),
            address(usdt),
            1 hours,
            1 hours
        );
        assertEq(source.price(), 67_000e18, "USDT per 1e18 BTCB");

        vm.prank(KEEPER);
        usdtUsd.push(0.5e8); // USDT de-pegs to $0.50: one BTCB is worth twice as many USDT
        assertEq(source.price(), 134_000e18);

        vm.warp(100_000 + 1 hours + 1);
        vm.expectRevert();
        source.price(); // both feeds older than maxAge

        vm.startPrank(KEEPER);
        usdtUsd.push(1e8);
        btcUsd.push(0);
        vm.expectRevert();
        source.price();
        btcUsd.push(-1);
        vm.expectRevert();
        source.price();
        vm.stopPrank();
    }

    // ---- TestnetOwnedDeployer ----

    function test_ownedDeployer_handsOwnershipToTheCaller_atASaltBoundAddress() public {
        TestnetOwnedDeployer factory = new TestnetOwnedDeployer();
        bytes memory initCode = type(AtpRegistry).creationCode;
        bytes32 salt = keccak256("registry");

        address predicted = factory.predict(ALICE, salt, keccak256(initCode));
        vm.prank(ALICE);
        address deployed = factory.deploy(salt, initCode);
        assertEq(deployed, predicted);
        AtpRegistry registry = AtpRegistry(deployed);
        assertEq(registry.owner(), address(factory));
        assertEq(registry.pendingOwner(), ALICE);
        vm.prank(ALICE);
        registry.acceptOwnership();
        assertEq(registry.owner(), ALICE);

        // Same salt and code from someone else: a different address that Alice's can never collide with.
        vm.prank(BOB);
        address bobs = factory.deploy(salt, initCode);
        assertTrue(bobs != deployed);
        assertEq(AtpRegistry(bobs).pendingOwner(), BOB);

        // Alice cannot deploy twice at the same address.
        vm.expectRevert(TestnetOwnedDeployer.DeployFailed.selector);
        vm.prank(ALICE);
        factory.deploy(salt, initCode);
    }

    function test_ownedDeployer_worksForTheRouter() public {
        TestnetOwnedDeployer factory = new TestnetOwnedDeployer();
        TestnetToken usdt = new TestnetToken("Testnet USDT", "USDT", 18, OWNER);
        bytes memory initCode =
            abi.encodePacked(type(AtpMultiPoolOracle).creationCode, abi.encode(address(usdt)));
        vm.prank(ALICE);
        AtpMultiPoolOracle router = AtpMultiPoolOracle(factory.deploy(keccak256("router"), initCode));
        vm.prank(ALICE);
        router.acceptOwnership();
        assertEq(router.owner(), ALICE);
        assertEq(router.numeraire(), address(usdt));
    }

    // ---- DeployTestnet price math ----

    /// @dev For every asset of the testnet list, both token orders: the sqrtPriceX96 the pool is initialized
    /// with converts 1 whole asset back to its spec price within 1 ppm.
    function test_sqrtPriceX96_roundTripsEverySpecPrice() public {
        DeployTestnet script = new DeployTestnet();
        TestnetAssets.AssetSpec[] memory specs = TestnetAssets.specs();
        assertEq(specs.length, TestnetAssets.COUNT);
        for (uint256 i; i < specs.length; ++i) {
            uint256 oneAsset = 10 ** specs[i].decimals;
            for (uint256 order; order < 2; ++order) {
                bool assetIsToken0 = order == 0;
                uint256 sqrtP = script.sqrtPriceX96(specs[i].priceE18, specs[i].decimals, assetIsToken0);
                uint256 ratioX128 = Math.mulDiv(sqrtP, sqrtP, 1 << 64); // token1 per token0, X128
                uint256 usdtOut = assetIsToken0
                    ? Math.mulDiv(oneAsset, ratioX128, 1 << 128)
                    : Math.mulDiv(oneAsset, 1 << 128, ratioX128);
                assertApproxEqRel(usdtOut, specs[i].priceE18, 1e12, specs[i].symbol);
            }
        }
    }

    // ---- oracle book vs mainnet (cre8-contracts#25) ----

    /// @dev The first `LAUNCH_COUNT` entries are the mainnet book: same assets in the same order, with the
    /// mainnet `maxSlippageBps` tier (S 50 / A 100 / B 300) and a secondary feed on exactly the assets that have
    /// one on mainnet. The testnet-only entries after them (#39) are checked by `test_specs_testnetExtension`.
    function test_specs_matchMainnetTiersAndFeedChoice() public {
        TestnetAssets.AssetSpec[] memory t = TestnetAssets.specs();
        AtpMainnetSpecs.OracleSpec[] memory m = new MainnetSpecsHarness().specs();
        assertEq(TestnetAssets.LAUNCH_COUNT, m.length, "launch asset count");
        assertGe(t.length, m.length, "the launch assets lead the list");
        uint256 tierS;
        uint256 tierA;
        for (uint256 i; i < m.length; ++i) {
            assertEq(t[i].symbol, m[i].symbol, "order");
            assertEq(t[i].maxSlippageBps, m[i].maxSlippageBps, t[i].symbol);
            assertEq(t[i].hasFeed, m[i].usdFeed != address(0), t[i].symbol);
            if (t[i].maxSlippageBps == 50) ++tierS;
            if (t[i].maxSlippageBps == 100) ++tierA;
        }
        assertEq(tierS, 2, "tier S: USDC, DAI");
        assertEq(tierA, 6, "tier A: WBNB, BTCB, ETH, QQQB, XAUt, NVDAB");
    }

    /// @dev #39: 38 launch assets + 40 other tokens of the 16 showcase funds + 14 crypto. Every testnet-only
    /// entry is tier B (300 bps) without a secondary feed; every symbol is unique (it names the CREATE2 salt and the manifest
    /// key, and `deploy-97.sh` reads `asset.<letters>.pool`), never USDT, and every entry is a pool Pancake V3
    /// can create (fee tier, decimals, non-zero price).
    function test_specs_testnetExtension() public pure {
        TestnetAssets.AssetSpec[] memory t = TestnetAssets.specs();
        assertEq(t.length, TestnetAssets.COUNT);
        assertEq(
            TestnetAssets.COUNT, 38 + 40 + 14 + 13, "launch + showcase-fund tokens + crypto + #61 lineup"
        );
        uint256 bStocks;
        for (uint256 i; i < t.length; ++i) {
            bytes memory sym = bytes(t[i].symbol);
            assertGt(sym.length, 0, "empty symbol");
            for (uint256 k; k < sym.length; ++k) {
                bool letter = (sym[k] >= "A" && sym[k] <= "Z") || (sym[k] >= "a" && sym[k] <= "z");
                assertTrue(letter, t[i].symbol);
            }
            assertTrue(keccak256(sym) != keccak256("USDT"), "USDT is the numeraire");
            for (uint256 j; j < i; ++j) {
                assertTrue(keccak256(sym) != keccak256(bytes(t[j].symbol)), t[i].symbol);
            }
            uint24 fee = t[i].fee;
            assertTrue(fee == 100 || fee == 500 || fee == 2500 || fee == 10_000, t[i].symbol);
            assertGt(t[i].priceE18, 0, t[i].symbol);
            assertGt(bytes(t[i].name).length, 0, t[i].symbol);
            if (t[i].uiMultiplier != 0) ++bStocks;
            if (i < TestnetAssets.LAUNCH_COUNT) continue;
            assertEq(t[i].maxSlippageBps, 300, t[i].symbol);
            assertFalse(t[i].hasFeed, t[i].symbol);
            assertEq(t[i].maxFeedAge, 0, t[i].symbol);
            assertTrue(t[i].decimals == 18 || t[i].decimals == 9, t[i].symbol); // TONCOIN: 9, as on BSC
        }
        assertEq(bStocks, 24 + 20 + 13, "bStock mocks: 24 launch + 20 showcase-fund tokens + 13 lineup (#61)");
    }

    /// @dev #39: the testnet-only entries are exactly the issue's list, in this order: the 40 other tokens of the
    /// 16 showcase funds (ASCII order), then the 14 crypto; then #61's 13 launch-lineup bStocks. Nothing else
    /// rides along.
    function test_specs_testnetExtension_exactList() public pure {
        string memory want = "ABBVon ALABB AMATB AMDB APHon APLDon AVGOB AXPon BEB BLKon CBRSB CEGon CIENon COHRB "
            "CORZon CRDOB CRMB CRWVB CVXon GEVB GLDon GOOGon GPROB IEFon IRENB IVVon KOon LLYB MAon NBISB NEMon ORCLB "
            "PANWon PYPLB SHAZB STXB UBERon VRTon VSTB Von "
            "ADA LINK BCH NEAR UNI ZEC TONCOIN DOT SHIB PEPE AAVE Cake FIL ATOM "
            "AMCB ANTB BMNRB BNCB COINB CYPHB GMEB MRVLB PDDB PENGB RDDTB SOXLB TQQQB ";
        TestnetAssets.AssetSpec[] memory t = TestnetAssets.specs();
        assertEq(t.length - TestnetAssets.LAUNCH_COUNT, 40 + 14 + 13, "testnet-only count");
        string memory got;
        for (uint256 i = TestnetAssets.LAUNCH_COUNT; i < t.length; ++i) {
            got = string.concat(got, t[i].symbol, " ");
        }
        assertEq(got, want);
    }

    /// @dev `PokePoolsTestnet` aims each keeper swap at the same baseline the pool was initialized with.
    function test_pokeBaseline_matchesDeployPrice() public {
        DeployTestnet script = new DeployTestnet();
        PokePoolsHarness poke = new PokePoolsHarness();
        TestnetAssets.AssetSpec[] memory t = TestnetAssets.specs();
        for (uint256 i; i < t.length; ++i) {
            assertEq(
                poke.sqrtPrice(t[i].priceE18, t[i].decimals, true),
                script.sqrtPriceX96(t[i].priceE18, t[i].decimals, true)
            );
            assertEq(
                poke.sqrtPrice(t[i].priceE18, t[i].decimals, false),
                script.sqrtPriceX96(t[i].priceE18, t[i].decimals, false)
            );
        }
    }

    /// @dev Feed max ages deliberately stay at the testnet keeper's cadence (1 hour, AVAX 1 day), not mainnet's
    /// 3 x Chainlink heartbeat: the mock feeds have no heartbeat but the keeper's push interval. Every age is
    /// inside the adapter's bounds; an asset without a feed has none.
    function test_specs_feedAgesFitTheAdapterAndTheKeeper() public pure {
        TestnetAssets.AssetSpec[] memory t = TestnetAssets.specs();
        uint256 withFeed;
        for (uint256 i; i < t.length; ++i) {
            if (!t[i].hasFeed) {
                assertEq(t[i].maxFeedAge, 0, t[i].symbol);
                continue;
            }
            ++withFeed;
            bool avax = keccak256(bytes(t[i].symbol)) == keccak256("AVAX");
            assertEq(t[i].maxFeedAge, avax ? 1 days : 1 hours, t[i].symbol);
        }
        assertEq(withFeed, 11);
    }

    /// @dev cre8-contracts#47 #1 / #3: the parameter table's max(0.1%, 0.30 USDT) per batch (before #47 the
    /// default fee stayed 0, so only the 0.30 minimum applied) and 1,000 USDT per recipient per day (was 10,000).
    /// KEEPER's one-off USDT stock covers `PokePoolsTestnet`'s 20 pokes of 1,000 USDT for every pool.
    function test_deployConstants_feeAndFaucetMatchTheParameterTable() public {
        (uint16 defaultFeeBps, uint256 minBatchFee, uint256 faucetDailyLimit, uint256 keeperUsdtStock) =
            new DeployTestnetHarness().feeAndFaucetConstants();
        assertEq(defaultFeeBps, 10, "0.1%");
        assertEq(minBatchFee, 0.3e18, "0.30 USDT");
        assertEq(faucetDailyLimit, 1_000e18, "1,000 per day");
        assertGe(keeperUsdtStock, 1_000e18 * 20 * TestnetAssets.COUNT, "keeper stock >= 20 rounds of buys");
    }

    /// @dev cre8-contracts#47 #8: a pool created by someone else first is only used when its price is within 1%
    /// of the spec price (compared as prices, i.e. the squared sqrtPriceX96 ratio), in both token orders.
    function test_poolPriceWithinBounds_onePercentBothWays() public {
        DeployTestnet script = new DeployTestnet();
        TestnetAssets.AssetSpec[] memory specs = TestnetAssets.specs();
        for (uint256 i; i < specs.length; ++i) {
            for (uint256 order; order < 2; ++order) {
                uint160 expected = script.sqrtPriceX96(specs[i].priceE18, specs[i].decimals, order == 0);
                assertTrue(script.poolPriceWithinBounds(expected, expected), specs[i].symbol);
                // Prices 0.99x / 1.01x (sqrt ratio sqrt(0.99), sqrt(1.01)) shifted one ppm inward: accepted.
                uint160 low = uint160(Math.mulDiv(expected, Math.sqrt(0.990001e36), 1e18));
                uint160 high = uint160(Math.mulDiv(expected, Math.sqrt(1.009999e36), 1e18));
                assertTrue(script.poolPriceWithinBounds(low, expected), specs[i].symbol);
                assertTrue(script.poolPriceWithinBounds(high, expected), specs[i].symbol);
                // Just outside 1%: rejected.
                uint160 tooLow = uint160(Math.mulDiv(expected, Math.sqrt(0.9899e36), 1e18));
                uint160 tooHigh = uint160(Math.mulDiv(expected, Math.sqrt(1.0101e36), 1e18));
                assertFalse(script.poolPriceWithinBounds(tooLow, expected), specs[i].symbol);
                assertFalse(script.poolPriceWithinBounds(tooHigh, expected), specs[i].symbol);
            }
        }
        assertFalse(script.poolPriceWithinBounds(1, 0), "no expectation");
        assertFalse(script.poolPriceWithinBounds(1 << 96, 2 << 96), "4x");
    }

    /// @dev cre8-contracts#47 #5: signer keys come from the environment and must derive the expected role
    /// address; an unset variable loads nothing (fork mode). Anvil's public test key #0 stands in.
    function test_rememberKey_fromEnvironment_checksTheAddress() public {
        DeployTestnet script = new DeployTestnet();
        uint256 key = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
        address derived = vm.addr(key);
        script.rememberKey("CRE8_TEST_UNSET_KEY_47", derived); // unset: no-op

        vm.setEnv("CRE8_TEST_KEY_47", vm.toString(bytes32(key)));
        vm.expectRevert(bytes("CRE8_TEST_KEY_47 does not derive the expected address"));
        script.rememberKey("CRE8_TEST_KEY_47", OWNER);
        script.rememberKey("CRE8_TEST_KEY_47", derived);
    }

    /// @dev Window and pool age as on mainnet; USDT/USD gets its own max age (#25) inside the adapter's bounds.
    function test_deployConstants_matchMainnetWindowsAndOwnUsdtUsdAge() public {
        (uint32 twapWindow, uint32 maxOracleAge, uint32 usdtUsdMaxAge, uint16 deviationBps) =
            new DeployTestnetHarness().oracleConstants();
        assertEq(twapWindow, 30 minutes);
        assertEq(maxOracleAge, 1 hours);
        assertEq(deviationBps, 200);
        assertEq(usdtUsdMaxAge, 1 hours);
        assertGe(usdtUsdMaxAge, 1 minutes, "adapter floor");
        assertLe(usdtUsdMaxAge, 1 days, "adapter ceiling");
    }

    /// @dev As the router wires it for AVAX: asset feed 1 day, USDT/USD 1 hour. A day-old AVAX answer still
    /// prices; a USDT/USD answer older than an hour stops it (before #25 it borrowed AVAX's day); exactly at
    /// the bound is still fresh.
    function test_secondary_usdtUsdAgeIsIndependentOfTheAssetAge() public {
        vm.warp(1_000_000);
        TestnetToken usdt = new TestnetToken("Testnet USDT", "USDT", 18, OWNER);
        TestnetToken avax = new TestnetToken("Avalanche (testnet)", "AVAX", 18, OWNER);
        TestnetPriceFeed avaxUsd = new TestnetPriceFeed(8, "AVAX / USD", OWNER, KEEPER, 8e8);
        TestnetPriceFeed usdtUsd = new TestnetPriceFeed(8, "USDT / USD", OWNER, KEEPER, 1e8);
        (,, uint32 usdtUsdMaxAge,) = new DeployTestnetHarness().oracleConstants();
        PushFeedPriceSource source = new PushFeedPriceSource(
            IAggregatorV3(address(avaxUsd)),
            IAggregatorV3(address(usdtUsd)),
            address(avax),
            address(usdt),
            1 days,
            usdtUsdMaxAge
        );

        vm.warp(1_000_000 + usdtUsdMaxAge);
        assertEq(source.price(), 8e18, "both at or inside their bounds");

        vm.warp(1_000_000 + usdtUsdMaxAge + 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                PushFeedPriceSource.StaleFeed.selector, address(usdtUsd), uint256(1_000_000)
            )
        );
        source.price();

        vm.prank(KEEPER);
        usdtUsd.push(1e8);
        assertEq(source.price(), 8e18, "fresh USDT/USD, AVAX one hour old");
    }
}
