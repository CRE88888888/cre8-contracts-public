// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { RoutingTypes as R } from "./RoutingTypes.sol";

/// @notice Venue reads of Strategy Earn routing v2. Address: `AtpBorrowExecutorV2.lens()`.
interface IAtpBorrowLensV2 {
    error ProtocolRead(uint256 code);
    // Raised by the checks the executor delegates here (same errors as `IAtpBorrowExecutorV2`).
    error LtvTooHigh(uint256 debtValue, uint256 budgetValue);
    error TokenMismatch();
    error NothingToRepay();
    error NothingToDo();
    error VaultShortfall(uint256 needed, uint256 available);
    error DebtOutstanding(uint256 debt);
    error GateClosed(uint8 gate);

    /// @notice Accrue the route's venue (anyone may call).
    function sync(bytes32 routeId, address account) external;
    function syncToken(address account, address token) external;

    /// @notice (target LTV, deleverage LTV, venue factor F) of a route.
    function routeLines(bytes32 routeId) external view returns (uint256 target, uint256 deleverage, uint256 f);
    function targetLtv(bytes32 routeId) external view returns (uint256);
    function deleverageLtv(bytes32 routeId) external view returns (uint256);
    function liquidationLtv(bytes32 routeId) external view returns (uint256);

    /// @notice The venues this lens is pinned to (copied from the registry at construction).
    function venusComptroller() external view returns (address);
    function moolah() external view returns (address);

    /// @notice Stored reads (last accrual). Lista: the market's debt. Venus: the whole debt in the loan token.
    function debt(bytes32 routeId, address account) external view returns (uint256);
    /// @notice Debt attributed to this route: Lista = `debt`; Venus = debt x principal share (all of it when
    /// this is the only Venus route with principal in that loan token). With no principal left in the token
    /// (interest that outlived it) the whole debt is one route's: the account's first Venus position in that
    /// token in `accountRoutes`; every other route reads 0, and so does every route when the account holds
    /// no such position (debt this registry did not open). `executeReduce` with `repayAmount` = max repays
    /// this amount. For the account's debt in a token use `tokenDebt`, not a sum of these.
    function routeDebt(bytes32 routeId, address account) external view returns (uint256);
    /// @notice The account's debt in `token` over all its routes.
    function tokenDebt(address account, address token) external view returns (uint256);
    function collateral(bytes32 routeId, address account) external view returns (uint256);
    function borrowMarket(bytes32 routeId) external view returns (uint256 utilizationBps, uint256 liquidity);
    function health(bytes32 routeId, address account) external view returns (R.Health memory);
    /// @notice What `executeDeleverage` would repay now from the health line, loan raw units (0 = below it).
    function deleverageAmount(bytes32 routeId, address account) external view returns (uint256);
    /// @notice Smallest debt the venue lets a position keep, loan raw units (Moolah `minLoan`; 0 = none).
    function minLoan(bytes32 routeId) external view returns (uint256);
    /// @notice Smallest debt a partial repayment may leave on the route: `minLoan` plus 1% (0 = none). A
    /// repayment that cannot reach the whole debt is cut to leave this much, so a debt at or below it can only
    /// be repaid in full: `executeDeleverage` (box money only) repays nothing of it when the box holds less.
    function minDebt(bytes32 routeId) external view returns (uint256);
    /// @notice Loan token sitting directly in the account's box (not in a vault): strategy money, used first
    /// by the next repayment and paid out with a release. Add it to the vault holdings for the net value.
    function idleOf(address account, address token) external view returns (uint256);

    /// @notice Use eth_call: accrues first.
    function routeStatus(bytes32 routeId, address account) external returns (R.RouteStatus memory);
    function vaultStatus(bytes32 vaultId, address account) external returns (R.VaultStatus memory);
    /// @notice Use eth_call: is new borrowing through this pair open, and the carry numbers behind it.
    function quote(bytes32 routeId, bytes32 vaultId) external returns (R.Quote memory);
}
