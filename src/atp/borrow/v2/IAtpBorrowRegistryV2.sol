// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { RoutingTypes as R } from "./RoutingTypes.sol";

/// @notice Allowlists, consent, caps, rate reports and accounting of Strategy Earn routing v2. Venue reads
/// (positions, health, gates, snapshots) are on `IAtpBorrowLensV2`.
interface IAtpBorrowRegistryV2 {
    event LoanTokenSet(address indexed token, bool allowed);
    event AssetTierSet(address indexed asset, R.Tier tier);
    event VenusMarketSet(address indexed underlying, address vToken);
    event AdapterSet(R.VaultKind indexed kind, address adapter);
    event RouteRegistered(
        bytes32 indexed routeId,
        R.Venue venue,
        address indexed collateral,
        address indexed loan,
        bytes32 listaId
    );
    event RouteSet(bytes32 indexed routeId, bool enabled, bool retired);
    event RouteCapSet(bytes32 indexed routeId, uint256 cap);
    event RouteMaxUtilizationSet(bytes32 indexed routeId, uint16 bps);
    event VaultRegistered(
        bytes32 indexed vaultId,
        R.VaultKind kind,
        address indexed token,
        address indexed target,
        address receipt
    );
    event VaultSet(bytes32 indexed vaultId, bool enabled, bool retired);
    event PausedSet(bool paused);
    event LtvConfigSet(bytes32 indexed key, uint256 target, uint256 deleverage);
    event RateReporterSet(address reporter);
    event RewardTokenSet(address indexed token, bool allowed);
    event VenusBlocksPerYearSet(uint256 blocksPerYear);
    event RewardProofSuffixSet(bytes suffix);
    event RouteRatesReported(bytes32 indexed routeId, uint256 borrowIncentive, uint256 collateralIncentive);
    event VaultRatesReported(bytes32 indexed vaultId, uint256 baseRate, uint256 incentive);
    event StrategyPolicySet(address indexed account, uint256 maxDebt, address rewardRecipient, bool enabled);
    event PrincipalReconciled(address indexed account, bytes32 indexed routeId, uint256 removed);

    error Unauthorized();
    error UnknownRoute();
    error UnknownVault();
    error BadRoute();
    error BadVault();
    error BadParameter();
    error AdmissionClosed();
    error ConsentRequired();
    error BorrowCapExceeded(uint256 requested, uint256 available);
    error DebtAboveConsent(uint256 principalUsd, uint256 maxDebt);
    error TooManyPositions();
    error ForeignDebt();
    error InvalidConstructor();

    struct RouteReport {
        bytes32 routeId;
        uint256 borrowIncentive;
        uint256 collateralIncentive;
    }

    struct VaultReport {
        bytes32 vaultId;
        uint256 baseRate;
        uint256 incentive;
    }

    // ---- ids ----

    /// @notice keccak256(abi.encode(uint8(venue), collateral, loan, listaId)); listaId = 0 for Venus.
    function routeIdOf(R.Venue venue, address collateral, address loan, bytes32 listaId)
        external
        pure
        returns (bytes32);

    /// @notice keccak256(abi.encode(uint8(kind), token, target)).
    function vaultIdOf(R.VaultKind kind, address token, address target) external pure returns (bytes32);

    // ---- admin (AtpRegistry.owner()) ----

    function setLoanToken(address token, bool allowed) external;
    function setAssetTier(address asset, R.Tier tier) external;
    function setVenusMarket(address underlying, address vToken) external;
    /// @notice Set once per kind.
    function setAdapter(R.VaultKind kind, address adapter) external;
    function registerRoute(
        R.Venue venue,
        address collateral,
        address loan,
        bytes32 listaId,
        uint256 borrowCap
    ) external returns (bytes32 routeId);
    /// @notice Retiring is permanent. Disabled / retired routes keep every exit.
    function setRoute(bytes32 routeId, bool enabled, bool retire) external;
    function setRouteCap(bytes32 routeId, uint256 cap) external;
    /// @notice Borrow-market utilization above which the route takes no new borrowing (default 9500 bps).
    function setRouteMaxUtilization(bytes32 routeId, uint16 bps) external;
    function registerVault(R.VaultKind kind, address token, address target) external returns (bytes32 vaultId);
    function setVault(bytes32 vaultId, bool enabled, bool retire) external;
    /// @notice Stops new collateral, borrowing, migrations and vault switches. Exits stay open.
    function setPaused(bool paused) external;
    /// @notice More conservative lines (0 = hard cap). Venus: applies to the route's collateral on every
    /// Venus route (health is account-wide); Lista: to that market.
    function setLtvConfig(bytes32 routeId, uint256 target, uint256 deleverage) external;
    function setRateReporter(address reporter) external;
    function setRewardToken(address token, bool allowed) external;
    function setVenusBlocksPerYear(uint256 blocksPerYear) external;
    /// @notice The exact ending of the only message a strategy box will ever confirm through ERC-1271 (the
    /// reward-proof login text of the venue, e.g. Lista's). Empty disables box signatures.
    function setRewardProofSuffix(bytes calldata suffix) external;

    // ---- rate reporter ----

    /// @notice Off-chain reward programs and vault rates that cannot be read on chain (yearly, 18 decimals,
    /// each <= 50%). A report is used for 48 hours, then reads as zero / unknown.
    function reportRates(RouteReport[] calldata routes, VaultReport[] calldata vaults) external;

    // ---- account consent ----

    /// @notice Account-owner call (the account must be enrolled). One consent for all allowlisted routes.
    function setStrategyPolicy(uint256 maxDebt, address rewardRecipient, bool enabled) external;

    // ---- permissionless ----

    /// @notice After a liquidation or an outside repayment: lower tracked principal to the real debt and drop
    /// empty positions.
    function reconcile(address account, bytes32 routeId) external;

    // ---- reads ----

    function executor() external view returns (address);
    function venusComptroller() external view returns (address);
    function moolah() external view returns (address);
    function paused() external view returns (bool);
    function rateReporter() external view returns (address);
    function loanTokenAllowed(address token) external view returns (bool);
    function rewardTokenAllowed(address token) external view returns (bool);
    function rewardProofSuffix() external view returns (bytes memory);
    function assetTier(address asset) external view returns (R.Tier);
    function venusMarket(address underlying) external view returns (address);
    function adapterOf(R.VaultKind kind) external view returns (address);

    function routeCount() external view returns (uint256);
    function routeIds(uint256 index) external view returns (bytes32);
    function route(bytes32 routeId) external view returns (R.Route memory);
    function vaultCount() external view returns (uint256);
    function vaultIds(uint256 index) external view returns (bytes32);
    function vault(bytes32 vaultId) external view returns (R.Vault memory);

    function policy(address account) external view returns (R.Policy memory);
    /// @notice Tracked principal of the account over all routes, USD 18 decimals at 1 USD per loan token.
    function accountPrincipalUsd(address account) external view returns (uint256);
    function principal(address account, bytes32 routeId) external view returns (uint256);
    function totalPrincipal(bytes32 routeId) external view returns (uint256);
    /// @notice When the account's current position on this route first borrowed (0 without principal).
    function openedAt(address account, bytes32 routeId) external view returns (uint64);
    /// @notice When the account's box started its current holding in this vault (0 when empty).
    function vaultSince(address account, bytes32 vaultId) external view returns (uint64);
    /// @notice Routes where the account still has collateral or tracked principal.
    function accountRoutes(address account) external view returns (bytes32[] memory);
    /// @notice Vaults the account's box has deposited into and not emptied.
    function accountVaults(address account) external view returns (bytes32[] memory);

    /// @notice Is new risk on this route / a new deposit into this vault admitted right now?
    function routeOpen(bytes32 routeId) external view returns (bool);
    function vaultOpen(bytes32 vaultId) external view returns (bool);
    /// @notice A fresh (<= 48h) report: route = (borrow incentive, collateral incentive), vault = (base rate,
    /// incentive).
    function freshReport(bytes32 id) external view returns (bool fresh, uint256 a, uint256 b);
}
