// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { BorrowTypes as BT } from "../../src/atp/borrow/BorrowTypes.sol";
import { TestnetAssets } from "./TestnetAssets.sol";

/// @notice Chain 97 Strategy Earn simulation (#64, docs EARN_UX §B/§C/§D): each collateral asset's one market
/// (fixed here, not user-selectable), the protocol factor, and the simulated rates. Rates follow §C (borrow
/// ~2.5%, USDT vault ~4.5%); the CRE8 LTV lines are not here: the registry derives them from the factor
/// (target F/2, deleverage 2F/3). Leveraged ETFs (TQQQB, SOXLB) and very volatile assets are deliberately absent. Target LTV per class
/// (registry): index 35%, stock 30%, crypto-linked 20%, each also <= F/2.
library TestnetBorrowBook {
    struct Spec {
        string symbol;
        BT.Kind kind;
        BT.Tier tier;
        /// @dev Venus collateral factor / Lista LLTV, 1e18 = 100%.
        uint256 factor;
        /// @dev Simulated collateral incentive APR (bps).
        uint16 collateralIncentiveBps;
    }

    /// @notice Simulated USDT borrow APR (bps) on every market (§C: ~2-3%).
    uint16 internal constant BORROW_APR_BPS = 250;
    /// @notice Simulated APR of the strategy earn vault (§C: ~4-5%) and its incentive.
    uint16 internal constant VAULT_APR_BPS = 450;
    uint16 internal constant VAULT_INCENTIVE_BPS = 50;
    /// @notice Simulated borrow incentive (bps) on Lista markets, like Lista's borrow rebates.
    uint16 internal constant LISTA_BORROW_INCENTIVE_BPS = 50;
    /// @notice CRE8-wide principal cap per market (USDT raw).
    uint256 internal constant BORROW_CAP = 100_000e18;
    /// @notice Background liquidity: Venus vUSDT, each Lista market, and the earn vault.
    uint256 internal constant VENUS_SEED = 500_000e18;
    uint256 internal constant LISTA_SEED = 250_000e18;
    uint256 internal constant VAULT_SEED = 250_000e18;
    uint256 internal constant COUNT = 5;

    /// @dev One row per asset: the asset's designated market. Venus factors follow Venus' live bStock
    /// collateral factors (TSLAB / NVDAB 60%, SPCXB 50%).
    function specs() internal pure returns (Spec[] memory s) {
        s = new Spec[](COUNT);
        s[0] = Spec("NVDAB", BT.Kind.VENUS, BT.Tier.STOCK, 0.6e18, 50);
        s[1] = Spec("TSLAB", BT.Kind.VENUS, BT.Tier.STOCK, 0.6e18, 50);
        s[2] = Spec("SPCXB", BT.Kind.VENUS, BT.Tier.STOCK, 0.5e18, 50);
        s[3] = Spec("QQQB", BT.Kind.LISTA, BT.Tier.INDEX_LARGE_CAP, 0.7e18, 100);
        s[4] = Spec("MSTRB", BT.Kind.LISTA, BT.Tier.CRYPTO_LINKED, 0.5e18, 100);
    }

    /// @notice The strategy earn vault's market id in `AtpYieldRegistry` (supply disabled there: strategy only).
    function vaultMarketId() internal pure returns (bytes32) {
        return keccak256("cre8.testnet.borrow.earnVault.v1");
    }

    function id(Spec memory s, address collateral) internal pure returns (bytes32) {
        return keccak256(abi.encode("cre8.testnet.borrow.v1", s.kind, collateral));
    }

    function label(Spec memory s) internal pure returns (string memory) {
        return string.concat("borrow.", s.kind == BT.Kind.VENUS ? "Venus" : "Lista", ".", s.symbol);
    }

    /// @notice Deployment baseline price in USD with 8 decimals (USDT-quoted, from `TestnetAssets`).
    /// Token addresses come from deployments/testnet-97.json: recomputing them from today's init code would not
    /// match tokens deployed by earlier versions of `TestnetToken`.
    function priceE8(string memory symbol) internal pure returns (uint256) {
        TestnetAssets.AssetSpec[] memory assets = TestnetAssets.specs();
        for (uint256 i; i < assets.length; ++i) {
            if (keccak256(bytes(symbol)) == keccak256(bytes(assets[i].symbol))) {
                return assets[i].priceE18 / 1e10;
            }
        }
        revert(string.concat("missing borrow asset: ", symbol));
    }
}
