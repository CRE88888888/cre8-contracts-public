// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { RoutingTypes as R } from "../src/atp/borrow/v2/RoutingTypes.sol";

/// @notice BSC mainnet (chain 56) book for Strategy Earn routing v2: the venue pins, the four loan tokens, and
/// the first allowlist the owner registers (docs/borrow-routing-v2.zh-TW.md §11). Nothing here fixes an
/// asset's route: the backend picks among whatever is on the allowlist at open time, and the owner extends
/// the allowlist with further `registerRoute` / `registerVault` calls as markets appear.
/// Every address and market id was read from chain on 2026-11-24; the deploy script re-checks each of them
/// (code, symbols, market parameters) and refuses to continue on any mismatch.
abstract contract BorrowRoutingMainnetSpecs {
    // ---- venues ----
    address internal constant VENUS_COMPTROLLER = 0xfD36E2c2a6789Db23113685031d7F16329158384;
    address internal constant LISTA_MOOLAH = 0x8F73b65B4caAf64FBA2aF91cC5D4a2A1318E5D8C;
    address internal constant AAVE_V3_POOL = 0x6807dc923806fE8Fd134338EABCA509979a7e0cB;

    // ---- loan tokens (all 18 decimals on BSC) and their Venus markets ----
    address internal constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address internal constant USDC = 0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d;
    address internal constant USD1 = 0x8d0D000Ee44948FC98c9B98A4FA4921476f08B0d;
    address internal constant U = 0xcE24439F2D9C6a2289F741120FE202248B666666;
    address internal constant V_USDT = 0xfD5840Cd36d94D7229439859C0112a4185BC0255;
    address internal constant V_USDC = 0xecA88125a5ADbe82614ffC12D0DB554E2e2867C8;
    address internal constant V_USD1 = 0x0C1DA220D301155b87318B90692Da8dc43B67340;
    address internal constant V_U = 0x3d5E269787d562b74aCC55F18Bd26C5D09Fa245E;

    // ---- reward tokens ----
    address internal constant LISTA = 0xFceB31A79F71AC9CBDCF853519c1b12D379EdC46;
    address internal constant XVS = 0xcF6BB5389c92Bdda8a3747Ddb454cB7a64626C63;

    // ---- Lista vaults (ERC4626). The Gauntlet USDT vault has an empty supply queue and is left out. ----
    address internal constant LISTA_VAULT_USD1 = 0xfa27f172e0b6ebcEF9c51ABf817E2cb142FbE627;
    address internal constant LISTA_VAULT_U = 0x9A17Fd5Cb8EFc25d11567e713aE795A89775a759;
    address internal constant LISTA_VAULT_USDC = 0x8a06Ac91265dBEBE6D4606f45b10993E9a571869;

    /// @notice CRE8-wide principal cap of each route at launch (loan raw units). A launch value, not a product
    /// rule: the owner changes it per route with `setRouteCap`.
    uint256 internal constant ROUTE_CAP = 50_000e18;
    /// @notice The only text a strategy box confirms through ERC-1271: Lista's reward-proof login message.
    bytes internal constant REWARD_PROOF_SUFFIX = "\nThank you for your support of listaDAO.";

    /// @dev A Venus core-pool collateral market. Routes are registered for it in all four loan tokens.
    struct VenusCollateral {
        string symbol;
        address asset;
        address vToken;
        R.Tier tier;
    }

    /// @dev A Lista Moolah market, pinned by id AND by what Moolah must return for that id: the collateral
    /// token, the oracle and the loan token (one of the four above). Symbols are only labels.
    struct ListaMarket {
        bytes32 id;
        string label;
        address collateral;
        address loan;
        address oracle;
        R.Tier tier;
    }

    struct VaultSpec {
        R.VaultKind kind;
        address token;
        address target;
    }

    function _loans() internal pure returns (address[4] memory) {
        return [USDT, USDC, USD1, U];
    }

    function _loanVTokens() internal pure returns (address[4] memory) {
        return [V_USDT, V_USDC, V_USD1, V_U];
    }

    function _rewardTokens() internal pure returns (address[2] memory) {
        return [LISTA, XVS];
    }

    /// @notice Venus bStock collateral (collateral factors 60% / 60% / 50% on 2026-11-24, so target 30% / 30% /
    /// 25%). vNVDAB's supply cap was full that day: the route exists, the venue decides whether it has room.
    function _venusCollaterals() internal pure returns (VenusCollateral[] memory c) {
        c = new VenusCollateral[](3);
        c[0] = VenusCollateral(
            "NVDAB",
            0x02Fca66C1D1aFB4E2A7884261eB00F63598a7436,
            0xEb8Ca841cBe1BC4832A10b15c7dAB1081eDaD371,
            R.Tier.STOCK
        );
        c[1] = VenusCollateral(
            "TSLAB",
            0x5b1910eAaD6450E50f816082Aa078C41F10C292f,
            0x97421799419Eb782628e73e7220d8E0A207469a3,
            R.Tier.STOCK
        );
        c[2] = VenusCollateral(
            "SPCXB",
            0xbe9D156892E55e7154BcD3cB0FEA677F9D3103E1,
            0xC36dFaCc7a125859C106F29b9F2d874CCF29A55A,
            R.Tier.STOCK
        );
    }

    address internal constant NVDAB = 0x02Fca66C1D1aFB4E2A7884261eB00F63598a7436;
    address internal constant TSLAB = 0x5b1910eAaD6450E50f816082Aa078C41F10C292f;
    address internal constant QQQB = 0x205812CdBed920aFf76C6580abD681a46D11efc7;
    address internal constant SPYB = 0x7138b48df7D98D7e3cc221BfE7192D0a178182D8;
    /// @dev The oracle every one of these Moolah markets was created with.
    address internal constant LISTA_BSTOCK_ORACLE = 0x526D09c604A17D98cb1f260a7774A239990dbDfb;

    /// @notice Lista bStock markets (api.lista.org zone 5) with at least ~20k USD to lend on 2026-11-24.
    function _listaMarkets() internal pure returns (ListaMarket[] memory m) {
        m = new ListaMarket[](8);
        address o = LISTA_BSTOCK_ORACLE;
        m[0] = ListaMarket(
            0xaa1b8576712e33031668c93baa6ca53818a687d43e216d91ca09eeaff674d8b1,
            "NVDAB/USD1",
            NVDAB,
            USD1,
            o,
            R.Tier.STOCK
        );
        m[1] = ListaMarket(
            0x2c5ae93255b92d59b25cafc9d735eb4c7f45bf5701b4eb71513aa6f1bb4d1a45,
            "TSLAB/USDC",
            TSLAB,
            USDC,
            o,
            R.Tier.STOCK
        );
        m[2] = ListaMarket(
            0x3af25f66f76bd1024a1d5165bef8a49c30d7c6ef1a2292821551a3adf998e387,
            "QQQB/USDC",
            QQQB,
            USDC,
            o,
            R.Tier.INDEX_LARGE_CAP
        );
        m[3] = ListaMarket(
            0x78f0f036e0549defcb4c6b9039a72ce14f952326ce4bba229d761c00a2749dc4,
            "QQQB/USD1",
            QQQB,
            USD1,
            o,
            R.Tier.INDEX_LARGE_CAP
        );
        m[4] = ListaMarket(
            0x4f16587fa2d8d359a4a83d84931edbcb4eddd4b3bf3bafaf94ce8ac70328c92d,
            "QQQB/U",
            QQQB,
            U,
            o,
            R.Tier.INDEX_LARGE_CAP
        );
        m[5] = ListaMarket(
            0x9986fc26a854d69991a695fadf6e6f93e49a39ea7d9528c7b12caf7a5da523da,
            "SPYB/USDC",
            SPYB,
            USDC,
            o,
            R.Tier.INDEX_LARGE_CAP
        );
        m[6] = ListaMarket(
            0x2f2dcbb5ad16f1a99a894108f7d1851b1f9f40bf386c1d3dbd152ae18187f509,
            "SPYB/USD1",
            SPYB,
            USD1,
            o,
            R.Tier.INDEX_LARGE_CAP
        );
        m[7] = ListaMarket(
            0x25ef82024774e310311b7ee9117cb6d2e8a55de4a4381ef555c911c1cca3857c,
            "SPYB/U",
            SPYB,
            U,
            o,
            R.Tier.INDEX_LARGE_CAP
        );
    }

    /// @notice Supply vaults: Lista vaults for USDC / USD1 / U, Venus supply for all four, Aave v3 for the two
    /// reserves it has (USDT, USDC).
    function _vaults() internal pure returns (VaultSpec[] memory v) {
        v = new VaultSpec[](9);
        v[0] = VaultSpec(R.VaultKind.ERC4626, USDC, LISTA_VAULT_USDC);
        v[1] = VaultSpec(R.VaultKind.ERC4626, USD1, LISTA_VAULT_USD1);
        v[2] = VaultSpec(R.VaultKind.ERC4626, U, LISTA_VAULT_U);
        v[3] = VaultSpec(R.VaultKind.VENUS, USDT, V_USDT);
        v[4] = VaultSpec(R.VaultKind.VENUS, USDC, V_USDC);
        v[5] = VaultSpec(R.VaultKind.VENUS, USD1, V_USD1);
        v[6] = VaultSpec(R.VaultKind.VENUS, U, V_U);
        v[7] = VaultSpec(R.VaultKind.AAVE, USDT, AAVE_V3_POOL);
        v[8] = VaultSpec(R.VaultKind.AAVE, USDC, AAVE_V3_POOL);
    }
}
