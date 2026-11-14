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

    function test_faucet_capsEachAddressPerWindow() public {
        TestnetUSDT usdt = new TestnetUSDT(OWNER, 1_000e18);
        vm.warp(1_000_000);

        vm.prank(ALICE);
        usdt.claim(600e18);
        vm.prank(ALICE);
        usdt.claim(400e18);
        assertEq(usdt.balanceOf(ALICE), 1_000e18);

        vm.expectRevert(abi.encodeWithSelector(TestnetUSDT.ClaimLimitExceeded.selector, 1, 0));
        vm.prank(ALICE);
        usdt.claim(1);

        // Another address has its own window.
        vm.prank(BOB);
        usdt.claim(1_000e18);

        // The window resets 24 hours after Alice's first claim, not after her last.
        vm.warp(1_000_000 + 1 days - 1);
        (uint256 remaining, uint256 endsAt) = usdt.claimable(ALICE);
        assertEq(remaining, 0);
        assertEq(endsAt, 1_000_000 + 1 days);
        vm.warp(1_000_000 + 1 days);
        vm.prank(ALICE);
        usdt.claim(1_000e18);
        assertEq(usdt.balanceOf(ALICE), 2_000e18);

        vm.expectRevert(TestnetUSDT.ZeroAmount.selector);
        vm.prank(ALICE);
        usdt.claim(0);
    }

    function test_faucet_claimFor_isMinterOnly_andSharesTheRecipientCap() public {
        TestnetUSDT usdt = new TestnetUSDT(OWNER, 1_000e18);
        vm.prank(OWNER);
        usdt.setMinter(KEEPER, true);

        vm.expectRevert(TestnetToken.NotMinter.selector);
        vm.prank(BOB);
        usdt.claimFor(ALICE, 1e18);

        vm.prank(KEEPER);
        usdt.claimFor(ALICE, 700e18);
        vm.expectRevert(abi.encodeWithSelector(TestnetUSDT.ClaimLimitExceeded.selector, 400e18, 300e18));
        vm.prank(ALICE);
        usdt.claim(400e18);

        // Minting stays uncapped for liquidity and keeper work.
        vm.prank(KEEPER);
        usdt.mint(KEEPER, 1_000_000e18);

        vm.prank(OWNER);
        usdt.setDailyLimit(2_000e18);
        vm.prank(ALICE);
        usdt.claim(1_300e18);
        assertEq(usdt.balanceOf(ALICE), 2_000e18);
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
        assertEq(specs.length, 38);
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
}
