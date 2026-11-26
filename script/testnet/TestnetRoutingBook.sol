// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Chain 97 simulation for Strategy Earn routing v2 (docs/borrow-routing-v2.zh-TW.md): the three extra
/// loan tokens, their simulated rates on each venue, and which collaterals get the extra Lista markets.
/// USDT keeps its #64 venues (vUSDT, the Lista USDT markets); every #64 / #67 market becomes a v2 USDT route.
/// The numbers are testnet stand-ins chosen so that different routes win for different assets; they are not
/// product decisions and the owner can change every one of them on the mocks.
library TestnetRoutingBook {
    struct Loan {
        string name;
        string symbol;
        /// @dev Simulated borrow APR (bps) of the Venus market and of every Lista market in this token.
        uint16 venusBorrowBps;
        uint16 listaBorrowBps;
        /// @dev ERC4626 earn vault: simulated APR and incentive APR (paid in the mock reward token).
        uint16 vaultBps;
        uint16 vaultIncentiveBps;
        /// @dev Aave mock supply APR (bps); 0 = no Aave reserve (mainnet Aave has only USDT and USDC).
        uint16 aaveBps;
    }

    /// @notice The existing loan token. Venus / Lista borrow rates are the #64 ones already on chain (2.5%).
    function usdt() internal pure returns (Loan memory) {
        return Loan("", "USDT", 250, 250, 450, 50, 420);
    }

    function loans() internal pure returns (Loan[] memory l) {
        l = new Loan[](3);
        l[0] = Loan("Testnet USD Coin", "USDC", 300, 220, 400, 50, 380);
        l[1] = Loan("Testnet World Liberty Financial USD", "USD1", 200, 180, 360, 100, 0);
        l[2] = Loan("Testnet United Stables", "U", 350, 300, 520, 0, 0);
    }

    /// @notice Collaterals that get a Lista market in each extra loan token. NVDAB and TSLAB (Venus in #64) also
    /// get a Lista USDT market, so one asset can be moved between venues without changing the loan token.
    function listaCollaterals() internal pure returns (string[] memory s) {
        s = new string[](8);
        s[0] = "NVDAB";
        s[1] = "TSLAB";
        s[2] = "QQQB";
        s[3] = "MSTRB";
        s[4] = "BTCB";
        s[5] = "WBNB";
        s[6] = "SPYB";
        s[7] = "XAUt";
    }

    uint16 internal constant LISTA_COLLATERAL_INCENTIVE_BPS = 100;
    uint16 internal constant LISTA_BORROW_INCENTIVE_BPS = 50;
    /// @notice CRE8-wide principal cap per route (loan raw units, all four tokens have 18 decimals here).
    uint256 internal constant ROUTE_CAP = 100_000e18;
    /// @notice Background liquidity: each new Venus market, each new Lista market, each vault / Aave pool.
    uint256 internal constant VENUS_SEED = 500_000e18;
    uint256 internal constant LISTA_SEED = 250_000e18;
    uint256 internal constant VAULT_SEED = 250_000e18;
    /// @notice The reward-proof login text a strategy box may confirm (Lista's).
    bytes internal constant REWARD_PROOF_SUFFIX = "\nThank you for your support of listaDAO.";
}
