// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

library BorrowTypes {
    enum Kind {
        NONE,
        VENUS,
        LISTA
    }

    /// @notice Risk class of the collateral (EARN_UX §D). Each has a hard target-LTV ceiling in the registry:
    /// index / large cap 35%, other single stocks 30%, crypto-linked stocks (MSTR, COIN...) 20%. Leveraged
    /// products have no class and are never listed.
    enum Tier {
        NONE,
        INDEX_LARGE_CAP,
        STOCK,
        CRYPTO_LINKED
    }

    /// @notice One admitted "post `collateral`, borrow `loan` into the earn vault" route (EARN_UX §B).
    /// Venus: `core` is the comptroller, `collateralVToken`/`loanVToken` the two markets, `listaId` unused.
    /// Lista: `core` is Moolah, `listaId` the isolated market id; the vToken fields are unused.
    /// `vaultMarketId` is a Lista (ERC4626) USDT market already admitted in `AtpYieldRegistry`, whose utilization
    /// checks are reused; `earnVault` is its vault, resolved at registration. Borrowed USDT goes straight there.
    struct Market {
        Kind kind;
        Tier tier;
        address collateral;
        address loan;
        address core;
        address collateralVToken;
        address loanVToken;
        bytes32 listaId;
        bytes32 vaultMarketId;
        address earnVault;
        /// @dev CRE8-wide cap on principal borrowed through this executor in this market, in loan raw units.
        uint256 borrowCap;
        bool borrowEnabled;
        bool retired;
    }

    /// @notice USD values with 18 decimals, read from the market's own oracle (the one that liquidates).
    /// Venus is account-wide over every market the account entered in that comptroller; Lista is per market.
    /// `healthFactor` = liquidationValue / debtValue (1e18 = liquidatable); type(uint256).max without debt.
    struct Health {
        uint256 collateralValue;
        uint256 liquidationValue;
        uint256 debtValue;
        uint256 healthFactor;
    }

    /// @notice Why new borrowing is closed (EARN_UX §D); the app shows "temporarily unavailable" for any non-zero.
    enum Gate {
        OPEN,
        CLOSED,
        BORROW_UTILIZATION,
        VAULT_UTILIZATION,
        NEGATIVE_CARRY,
        VAULT_UNREADABLE
    }

    /// @notice One snapshot for the backend (use eth_call on `AtpBorrowRegistry.status`). Rates are yearly with
    /// 18 decimals; LTVs are debt / collateral value with 18 decimals; utilizations in bps (rounded up).
    /// The one "extra APY" number (EARN_UX §B.3), with ratio = `ltv` for an open position or `targetLtv` before
    /// buying: (vaultRate + vaultIncentiveRate - borrowRate + borrowIncentiveRate) x ratio
    ///   + collateralRate + collateralIncentiveRate.
    /// Incentive rates are read from markets that publish them (the chain 97 mocks); 0 elsewhere, where the
    /// backend adds the protocols' off-chain reward programs itself.
    struct Status {
        Gate gate;
        bool shouldDeleverage;
        bool shouldUnwind;
        uint256 borrowRate;
        uint256 collateralRate;
        uint256 vaultRate;
        uint256 collateralIncentiveRate;
        uint256 borrowIncentiveRate;
        uint256 vaultIncentiveRate;
        uint256 borrowUtilizationBps;
        uint256 vaultUtilizationBps;
        uint256 ltv;
        uint256 targetLtv;
        uint256 deleverageLtv;
        uint256 liquidationLtv;
        uint256 debt;
        uint256 vaultAssets;
        Health health;
    }
}
