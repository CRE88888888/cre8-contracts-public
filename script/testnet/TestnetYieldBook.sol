// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { YieldTypes as Y } from "../../src/atp/yield/YieldTypes.sol";
import { TestnetAssets } from "./TestnetAssets.sol";
import { TestnetBook } from "./TestnetBook.sol";

/// @notice C3's 2026-11-16 final table, row for row. The table says 32 but contains 30 rows;
/// this book adds no unspecified markets. All 20 requested assets exist in TestnetAssets.
library TestnetYieldBook {
    struct Spec {
        string symbol;
        Y.Kind kind;
        uint16 aprBps;
    }
    uint256 internal constant COUNT = 30;

    function specs() internal pure returns (Spec[] memory s) {
        s = new Spec[](COUNT);
        s[0] = Spec("USDT", Y.Kind.VENUS, 500);
        s[1] = Spec("USDT", Y.Kind.LISTA, 300);
        s[2] = Spec("USDT", Y.Kind.AAVE, 300);
        s[3] = Spec("WBNB", Y.Kind.VENUS, 2);
        s[4] = Spec("WBNB", Y.Kind.LISTA, 21);
        s[5] = Spec("WBNB", Y.Kind.AAVE, 1);
        s[6] = Spec("BTCB", Y.Kind.VENUS, 12);
        s[7] = Spec("BTCB", Y.Kind.LISTA, 1);
        s[8] = Spec("BTCB", Y.Kind.AAVE, 1);
        s[9] = Spec("ETH", Y.Kind.VENUS, 34);
        s[10] = Spec("ETH", Y.Kind.AAVE, 57);
        s[11] = Spec("USDC", Y.Kind.VENUS, 460);
        s[12] = Spec("USDC", Y.Kind.LISTA, 230);
        s[13] = Spec("USDC", Y.Kind.AAVE, 344);
        s[14] = Spec("XRP", Y.Kind.VENUS, 5);
        s[15] = Spec("DOGE", Y.Kind.VENUS, 1);
        s[16] = Spec("LTC", Y.Kind.VENUS, 4);
        s[17] = Spec("SOL", Y.Kind.VENUS, 35);
        s[18] = Spec("LINK", Y.Kind.VENUS, 5);
        s[19] = Spec("ADA", Y.Kind.VENUS, 4);
        s[20] = Spec("TRX", Y.Kind.VENUS, 1);
        s[21] = Spec("DAI", Y.Kind.VENUS, 253);
        s[22] = Spec("UNI", Y.Kind.VENUS, 5);
        s[23] = Spec("BCH", Y.Kind.VENUS, 15);
        s[24] = Spec("AAVE", Y.Kind.VENUS, 1);
        s[25] = Spec("DOT", Y.Kind.VENUS, 1);
        s[26] = Spec("FIL", Y.Kind.VENUS, 1);
        s[27] = Spec("NVDAB", Y.Kind.VENUS, 1);
        s[28] = Spec("TSLAB", Y.Kind.VENUS, 1);
        s[29] = Spec("SPCXB", Y.Kind.VENUS, 1);
    }

    function protocol(Y.Kind kind) internal pure returns (string memory) {
        if (kind == Y.Kind.VENUS) return "Venus";
        if (kind == Y.Kind.LISTA) return "Lista";
        require(kind == Y.Kind.AAVE, "unknown protocol");
        return "Aave";
    }

    function label(Spec memory s) internal pure returns (string memory) {
        return string.concat("yield.", protocol(s.kind), ".", s.symbol);
    }

    function id(Spec memory s, address asset) internal pure returns (bytes32) {
        return keccak256(abi.encode("cre8.testnet.yield.v1", s.kind, asset));
    }

    function asset(Spec memory s, address usdt) internal pure returns (address token, uint256 seed) {
        if (keccak256(bytes(s.symbol)) == keccak256("USDT")) return (usdt, 1_000_000e18);
        TestnetAssets.AssetSpec[] memory assets = TestnetAssets.specs();
        for (uint256 i; i < assets.length; ++i) {
            if (keccak256(bytes(s.symbol)) == keccak256(bytes(assets[i].symbol))) {
                token = TestnetBook.tokenAddress(assets[i], TestnetBook.DEPLOYER);
                seed = 1_000_000e18 * 10 ** assets[i].decimals / assets[i].priceE18;
                require(seed != 0, "zero background seed");
                return (token, seed);
            }
        }
        revert(string.concat("missing yield asset: ", s.symbol));
    }
}
