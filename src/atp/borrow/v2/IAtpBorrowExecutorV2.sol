// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Strategy Earn routing v2: the only contract that moves strategy money.
/// Every `execute*` except `executeDeleverage` (and `collectRewards`) requires `msg.sender == account` (the portfolio's Kernel account;
/// a session key gets here only through the account's own `execute()`), and no function takes a receiver.
/// Amounts are raw units of the route's loan token or collateral token. `type(uint256).max` means "all".
interface IAtpBorrowExecutorV2 {
    event BoxCreated(address indexed account, address box);
    event Opened(
        address indexed account,
        bytes32 indexed routeId,
        bytes32 indexed vaultId,
        uint256 collateralIn,
        uint256 borrowed,
        uint256 debtValue,
        uint256 budgetValue
    );
    event Reduced(
        address indexed account,
        bytes32 indexed routeId,
        bytes32 indexed vaultId,
        uint256 repaid,
        uint256 fromVault,
        uint256 fromCash,
        uint256 collateralOut,
        uint256 debtLeft
    );
    event Deleveraged(
        address indexed account,
        bytes32 indexed routeId,
        bytes32 indexed vaultId,
        uint256 repaid,
        uint256 debtValueBefore,
        uint256 debtValueAfter
    );
    event Migrated(
        address indexed account,
        bytes32 indexed fromRouteId,
        bytes32 indexed toRouteId,
        bytes32 fromVaultId,
        bytes32 toVaultId,
        uint256 repaid,
        uint256 collateralMoved,
        uint256 borrowed
    );
    event VaultSwitched(
        address indexed account, bytes32 indexed fromVaultId, bytes32 indexed toVaultId, uint256 assets
    );
    event Released(address indexed account, bytes32 indexed vaultId, uint256 assets);
    event Rescued(address indexed account, bytes32 indexed vaultId, address receipt, uint256 amount);
    event RewardsCollected(address indexed account, address indexed token, uint256 amount);
    event RewardsSwept(
        address indexed account, address indexed token, address indexed recipient, uint256 amount
    );

    error NotAccount();
    error NotContract();
    error DeadlineExpired();
    error ZeroAmount();
    error InvalidConfig();
    error ProtocolError(uint256 code);
    error InexactTransfer();
    error NothingToRepay();
    error NothingToDo();
    error TokenMismatch();
    error CollateralMismatch();
    error SameRoute();
    error GateClosed(uint8 gate);
    error LtvTooHigh(uint256 debtValue, uint256 budgetValue);
    error VaultShortfall(uint256 needed, uint256 available);
    error DebtOutstanding(uint256 debt);
    error RewardNotAllowed(address token);

    /// @notice The registry this executor built and is bound to forever.
    function borrowRegistry() external view returns (address);

    /// @notice The read contract (`IAtpBorrowLensV2`) this executor uses for health and gates.
    function lens() external view returns (address);

    /// @notice `AtpBorrowExecutorV2Extension`: the stateless second half of this contract's code, run by
    /// delegatecall for switch vault, release, rescue and rewards. Callers only ever call the executor.
    function extension() external view returns (address);

    /// @notice The `StrategyBox` code every account's box is a clone of.
    function boxImplementation() external view returns (address);

    /// @notice The venues this executor is pinned to (copied from the registry at construction).
    function venusComptroller() external view returns (address);
    function moolah() external view returns (address);

    /// @notice The account's strategy box (deterministic; deployed on first deposit). Vault receipts of the
    /// strategy live here and nowhere else; only this executor can move them.
    function boxOf(address account) external view returns (address);

    /// @notice Post `collateralAmount` on the route and/or borrow `borrowAmount` of the route's loan token
    /// straight into `vaultId` (same token) for the account's box. Either amount may be zero, not both.
    /// Needs consent, the open gates of route and vault, the caps, and debt <= budget afterwards.
    function executeOpen(
        address account,
        bytes32 routeId,
        bytes32 vaultId,
        uint256 collateralAmount,
        uint256 borrowAmount,
        uint256 deadline
    ) external;

    /// @notice Repay and/or take collateral back: repay, partial close and close in one call.
    /// `repayAmount`: capped at the route's debt (`max` = all of it; on Venus the route's share of the shared
    /// debt, see `routeDebt`). Paid from the box's holding in `vaultId` first, then from the account's own
    /// loan token up to `maxCashIn`. `withdrawAmount`: collateral returned to the account (`max` = all posted).
    /// With debt left, debt <= budget must hold afterwards. When the account ends with no debt in this loan
    /// token, what is left in `vaultId` is paid out to the account. Always open (pauses, retired routes).
    function executeReduce(
        address account,
        bytes32 routeId,
        bytes32 vaultId,
        uint256 repayAmount,
        uint256 withdrawAmount,
        uint256 maxCashIn,
        uint256 deadline
    ) external;

    /// @notice Anyone may call. At or above the deleverage line: repay from the account's box (its idle loan
    /// token and its `vaultId` holding) back to the budget; when the box holds less, repay what it holds
    /// (never leaving the venue less than its minimum loan). `maxRepay` caps the repayment. The health line
    /// is the only trigger.
    function executeDeleverage(address account, bytes32 routeId, bytes32 vaultId, uint256 maxRepay)
        external
        returns (uint256 repaid);

    /// @notice Atomic move of a whole position to another route for the same collateral: repay the old route
    /// from `fromVaultId` (plus account cash up to `maxCashIn`), move all its collateral, borrow `borrowAmount`
    /// on the new route into `toVaultId`. Loan tokens may differ; nothing is swapped. Reverts as a whole when
    /// the old vault cannot cover the old debt (then: executeReduce + executeOpen with cash in between).
    function executeMigrate(
        address account,
        bytes32 fromRouteId,
        bytes32 fromVaultId,
        bytes32 toRouteId,
        bytes32 toVaultId,
        uint256 borrowAmount,
        uint256 maxCashIn,
        uint256 deadline
    ) external;

    /// @notice Move `amount` (`max` = all) of the box's deposit from one vault to another of the same token.
    function executeSwitchVault(
        address account,
        bytes32 fromVaultId,
        bytes32 toVaultId,
        uint256 amount,
        uint256 deadline
    ) external;

    /// @notice With no debt left in the vault's token, pay the box's whole holding in `vaultId` to the account.
    function executeRelease(address account, bytes32 vaultId, uint256 deadline) external;

    /// @notice Last resort when a vault or its adapter is broken: with no debt left in the vault's token, send
    /// the box's receipts of `vaultId` (vault shares / vTokens / aTokens) to the account as they are, without
    /// calling the vault. Meant for the account owner; it must NOT be among a session key's allowed selectors
    /// (the receipts leave the strategy box and become ordinary account holdings).
    function executeRescue(address account, bytes32 vaultId, uint256 deadline) external;

    /// @notice Anyone may call (no deadline, relayer-batchable). Move everything the account's box holds of an
    /// allowlisted reward token into the account itself. Rewards stay in the portfolio account afterwards.
    function collectRewards(address account, address token) external returns (uint256 amount);

    /// @notice Exit path (sell-all / withdraw / delete). Move an allowlisted reward token (LISTA, XVS...) out: everything the box holds plus up to
    /// `accountAmount` from the account itself, to the recipient the owner set in the policy. Without a
    /// recipient only box -> account happens. Refused for tokens the account's strategy trades.
    function executeSweepRewards(address account, address token, uint256 accountAmount, uint256 deadline)
        external;
}
