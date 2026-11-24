// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Shared types of Strategy Earn routing v2 (docs/borrow-routing-v2.zh-TW.md).
/// Rates are yearly with 18 decimals; LTVs are debt value / collateral value with 18 decimals; USD values have
/// 18 decimals and come from the lending venue's own oracle (the one that liquidates).
library RoutingTypes {
    enum Venue {
        NONE,
        VENUS,
        LISTA
    }

    enum VaultKind {
        NONE,
        ERC4626, // Lista Moolah vaults (MetaMorpho style)
        VENUS, // Venus core pool vToken supply
        AAVE // Aave v3 Pool supply (aToken)
    }

    /// @notice Risk class of a collateral asset. Hard target-LTV ceilings: 35% / 30% / 20%.
    enum Tier {
        NONE,
        INDEX_LARGE_CAP,
        STOCK,
        CRYPTO_LINKED
    }

    /// @notice Why new borrowing through a (route, vault) pair is closed right now.
    enum Gate {
        OPEN,
        CLOSED, // paused, disabled, retired, loan token or tier removed
        BORROW_UTILIZATION, // borrow market above the route's limit (95% by default) after the borrow
        VAULT_UTILIZATION, // vault above 90% (only where it can be read on chain)
        NEGATIVE_CARRY, // vault rate + incentives < borrow rate
        VAULT_UNREADABLE, // no on-chain vault rate and no fresh reported rate
        TOKEN_MISMATCH // vault token differs from the route's loan token
    }

    /// @notice One "post `collateral` on `venue`, borrow `loan`" route.
    /// id = keccak256(abi.encode(uint8(venue), collateral, loan, listaId)); `listaId` is zero for Venus.
    /// Venus: `collateralVToken` / `loanVToken` are the two core-pool markets. Lista: `listaId` is the Moolah market.
    struct Route {
        Venue venue;
        address collateral;
        address loan;
        bytes32 listaId;
        address collateralVToken;
        address loanVToken;
        /// @dev CRE8-wide cap on principal borrowed through this route, in loan raw units.
        uint256 borrowCap;
        /// @dev No new borrowing when the borrow market would be above this utilization afterwards (bps).
        /// 9500 unless the owner sets another value for the route.
        uint16 maxUtilizationBps;
        bool enabled;
        bool retired;
    }

    /// @notice One allowlisted supply vault for a loan token.
    /// id = keccak256(abi.encode(uint8(kind), token, target)).
    /// `target`: the ERC4626 vault, the vToken, or the Aave Pool. `receipt`: vault share / vToken / aToken.
    struct Vault {
        VaultKind kind;
        address token;
        address target;
        address receipt;
        bool enabled;
        bool retired;
    }

    /// @notice Account-owner consent, signed once for every route and vault on the allowlist.
    /// `maxDebt`: ceiling on the account's tracked principal over all routes, as USD with 18 decimals counting
    /// each loan token at 1 USD. `rewardRecipient`: where `executeSweepRewards` sends reward tokens (zero =
    /// rewards only move from the strategy box into the account). Pinned to the enrollment's strategy id.
    struct Policy {
        uint256 maxDebt;
        address rewardRecipient;
        uint256 strategyId;
        bool enabled;
    }

    /// @notice Venue health. Venus numbers are account-wide (every entered market of the comptroller);
    /// Lista numbers are for the one market. `budgetValue` = sum(collateral value x target LTV): debt may not
    /// exceed it after any action that adds risk. `deleverageValue` = sum(collateral value x deleverage LTV).
    struct Health {
        uint256 collateralValue;
        uint256 liquidationValue;
        uint256 debtValue;
        uint256 budgetValue;
        uint256 deleverageValue;
        uint256 healthFactor;
    }

    /// @notice Snapshot of one route for one account (`routeStatus`, use eth_call). `account` may be zero.
    struct RouteStatus {
        bool open; // route admits new collateral and borrowing (pause, enable, retire, tier, loan token)
        bool shouldDeleverage; // debt value >= deleverage value: anyone may call executeDeleverage
        uint256 borrowRate;
        uint256 collateralRate; // what the posted collateral itself earns (Venus supply rate; 0 on Lista)
        uint256 borrowIncentiveRate; // reported, 0 when stale
        uint256 collateralIncentiveRate; // reported, 0 when stale
        uint256 borrowUtilizationBps;
        uint256 availableLiquidity; // loan raw units borrowable from the venue now
        uint256 borrowCapLeft; // loan raw units left under the CRE8 route cap
        uint256 targetLtv;
        uint256 deleverageLtv;
        uint256 liquidationLtv;
        uint256 ltv; // Lista: this market. Venus: account-wide debt value / collateral value
        uint256 collateral; // posted collateral of this route, collateral raw units
        uint256 collateralValue; // USD 18 decimals
        uint256 debt; // Lista: this market's debt. Venus: the account's whole debt in this loan token
        uint256 routeDebt; // debt attributed to this route (Venus: by tracked principal share)
        uint256 principal; // tracked principal of this route, loan raw units
        uint64 openedAt; // first borrow of the current position, 0 without principal
        Health health;
    }

    /// @notice Snapshot of one vault (`vaultStatus`, use eth_call). `account` may be zero.
    struct VaultStatus {
        bool open; // vault admits new deposits
        bool rateOnChain; // supplyRate was read from the protocol; otherwise it is the reported rate
        bool rateKnown; // false: no on-chain rate and no fresh report -> new borrowing is closed
        bool utilizationKnown;
        bool shouldExit; // utilization above 95% (only where known): the backend should move the money out
        uint256 supplyRate;
        uint256 incentiveRate; // reported, 0 when stale
        uint256 utilizationBps;
        uint256 assets; // what the account's strategy box holds in this vault, loan raw units
        uint64 since; // when the box started its current holding in this vault, 0 when empty
    }

    /// @notice Pre-trade quote for a (route, vault) pair.
    struct Quote {
        Gate gate;
        uint256 targetLtv;
        uint256 borrowRate;
        uint256 borrowIncentiveRate;
        uint256 vaultRate;
        uint256 vaultIncentiveRate;
        /// @dev vaultRate + vaultIncentiveRate + borrowIncentiveRate - borrowRate (can be negative).
        int256 carry;
    }
}
