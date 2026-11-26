// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { MoolahParams, MoolahMarket } from "../yield/YieldInterfaces.sol";

/// @notice The Venus Core Pool comptroller calls the borrow route uses (Compound v2 ABI plus Venus delegation).
interface IVenusComptroller {
    function oracle() external view returns (address);
    function markets(address vToken)
        external
        view
        returns (bool isListed, uint256 collateralFactor, bool isVenus);
    function getAssetsIn(address account) external view returns (address[] memory);
    function checkMembership(address account, address vToken) external view returns (bool);
    function getAccountLiquidity(address account) external view returns (uint256, uint256, uint256);
    function enterMarkets(address[] calldata vTokens) external returns (uint256[] memory);
    function enterMarketBehalf(address onBehalf, address vToken) external returns (uint256);
    function updateDelegate(address delegate, bool allowBorrows) external;
    function approvedDelegates(address borrower, address delegate) external view returns (bool);
    function actionPaused(address market, uint8 action) external view returns (bool);
}

interface IVenusOracle {
    /// @dev USD price scaled so that `price * rawAmount / 1e18` is the USD value with 18 decimals.
    function getUnderlyingPrice(address vToken) external view returns (uint256);
}

interface IVBorrowToken {
    function underlying() external view returns (address);
    function borrowRatePerBlock() external view returns (uint256);
    function totalBorrows() external view returns (uint256);
    function totalReserves() external view returns (uint256);
    function getCash() external view returns (uint256);
    function supplyRatePerBlock() external view returns (uint256);
    function comptroller() external view returns (address);
    function accrueInterest() external returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function exchangeRateStored() external view returns (uint256);
    function borrowBalanceStored(address account) external view returns (uint256);
    function borrowBalanceCurrent(address account) external returns (uint256);
    function getAccountSnapshot(address account) external view returns (uint256, uint256, uint256, uint256);
    function mintBehalf(address receiver, uint256 mintAmount) external returns (uint256);
    function redeemBehalf(address redeemer, uint256 redeemTokens) external returns (uint256);
    function redeemUnderlyingBehalf(address redeemer, uint256 redeemAmount) external returns (uint256);
    function borrowBehalf(address borrower, uint256 borrowAmount) external returns (uint256);
    function repayBorrowBehalf(address borrower, uint256 repayAmount) external returns (uint256);
}

/// @notice Lista lending oracle: USD price with 8 decimals per whole token.
interface IListaOracle {
    function peek(address asset) external view returns (uint256);
}

/// @notice Lista Moolah core (Morpho Blue ABI) calls the borrow route uses.
interface IMoolahCore {
    function paused() external view returns (bool);
    function idToMarketParams(bytes32 id) external view returns (MoolahParams memory);
    function market(bytes32 id) external view returns (MoolahMarket memory);
    function position(bytes32 id, address account) external view returns (uint256, uint128, uint128);
    function isAuthorized(address authorizer, address authorized) external view returns (bool);
    function accrueInterest(MoolahParams memory params) external;
    function supplyCollateral(MoolahParams memory params, uint256 assets, address onBehalf, bytes memory data)
        external;
    function withdrawCollateral(
        MoolahParams memory params,
        uint256 assets,
        address onBehalf,
        address receiver
    ) external;
    function borrow(
        MoolahParams memory params,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        address receiver
    ) external returns (uint256, uint256);
    function repay(
        MoolahParams memory params,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        bytes memory data
    ) external returns (uint256, uint256);
}

/// @notice Morpho / Moolah interest rate model read (borrow rate per second, 18 decimals).
interface IMoolahIrm {
    function borrowRateView(MoolahParams memory params, MoolahMarket memory market)
        external
        view
        returns (uint256);
}
