// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Script, console } from "forge-std/Script.sol";
import { TestnetPriceFeed } from "../../src/testnet/TestnetPriceFeed.sol";
import { TestnetAssets } from "./TestnetAssets.sol";
import { TestnetBook } from "./TestnetBook.sol";

/// @title PushFeedsTestnet
/// @notice Chain 97 keeper action (cre8-contracts#30): pushes every mock feed's baseline (the `TestnetAssets`
/// price, USDT/USD = 1) as KEEPER, so the 11 secondary sources are fresh again. The router rejects a feed older
/// than its max age (1 hour for 10 assets, 1 day for AVAX), so on a live testnet the keeper must push at least
/// that often or those assets stop trading; a price-replay keeper (X1, T3) replaces this fixed baseline.
/// @dev `forge script script/testnet/PushFeedsTestnet.s.sol --rpc-url <97> --broadcast` with the keeper as signer
/// (`--unlocked --sender <KEEPER>` on a fork). Feed addresses are recomputed from `TestnetBook`, no file is read.
contract PushFeedsTestnet is Script {
    uint8 internal constant FEED_DECIMALS = 8;

    function run() external {
        require(block.chainid == 97, "PushFeedsTestnet: chain 97 only");
        TestnetAssets.AssetSpec[] memory specs = TestnetAssets.specs();
        vm.startBroadcast(TestnetBook.KEEPER);
        _push("feed.USDT/USD", "USDT / USD (testnet)", 1e8, 1e8);
        for (uint256 i; i < specs.length; ++i) {
            if (!specs[i].hasFeed) continue;
            int256 answer = int256(specs[i].priceE18 / 1e10);
            _push(
                string.concat("feed.", specs[i].symbol, "/USD"),
                string.concat(specs[i].symbol, " / USD (testnet)"),
                answer,
                answer
            );
        }
        vm.stopBroadcast();
    }

    /// @dev The feed address depends on its constructor arguments, so `initialAnswer` must be the deploy-time
    /// value (the spec price); `answer` is what gets pushed now.
    function _push(string memory label, string memory description, int256 initialAnswer, int256 answer)
        internal
    {
        bytes memory initCode = abi.encodePacked(
            type(TestnetPriceFeed).creationCode,
            abi.encode(FEED_DECIMALS, description, TestnetBook.DEPLOYER, TestnetBook.KEEPER, initialAnswer)
        );
        TestnetPriceFeed feed = TestnetPriceFeed(TestnetBook.create2Address(label, initCode));
        require(address(feed).code.length != 0, string.concat(label, ": not deployed"));
        feed.push(answer);
        console.log(string.concat("push ", label), uint256(answer));
    }
}
