// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";

interface IVToken is IERC20 {
    function underlying() external view returns (address);
    function comptroller() external view returns (address);
    function interestRateModel() external view returns (address);
    function implementation() external view returns (address);
    function accrueInterest() external returns (uint256);
    function accrualBlockNumber() external view returns (uint256);
    function exchangeRateStored() external view returns (uint256);
    function getCash() external view returns (uint256);
    function totalBorrows() external view returns (uint256);
    function totalReserves() external view returns (uint256);
    function mint(uint256 assets) external returns (uint256);
    function redeem(uint256 shares) external returns (uint256);
}

struct MoolahParams {
    address loanToken;
    address collateralToken;
    address oracle;
    address irm;
    uint256 lltv;
}

struct MoolahMarket {
    uint128 totalSupplyAssets;
    uint128 totalSupplyShares;
    uint128 totalBorrowAssets;
    uint128 totalBorrowShares;
    uint128 lastUpdate;
    uint128 fee;
}

interface IMoolahRead {
    function paused() external view returns (bool);
    function idToMarketParams(bytes32 id) external view returns (MoolahParams memory);
    function market(bytes32 id) external view returns (MoolahMarket memory);
    function position(bytes32 id, address account) external view returns (uint256, uint128, uint128);
    function accrueInterest(MoolahParams memory params) external;
}

interface IListaVault is IERC4626 {
    function MOOLAH() external view returns (address);
    function fee() external view returns (uint96);
    function supplyQueueLength() external view returns (uint256);
    function withdrawQueueLength() external view returns (uint256);
    function supplyQueue(uint256 i) external view returns (bytes32);
    function withdrawQueue(uint256 i) external view returns (bytes32);
    function config(bytes32 id) external view returns (uint184 cap, bool enabled, uint64 removableAt);
}

interface IAToken is IERC20 {
    function UNDERLYING_ASSET_ADDRESS() external view returns (address);
    function POOL() external view returns (address);
    function scaledBalanceOf(address account) external view returns (uint256);
    function scaledTotalSupply() external view returns (uint256);
}

interface IAavePool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
    function getReserveNormalizedIncome(address asset) external view returns (uint256);
}
