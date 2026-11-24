// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { MoolahParams, MoolahMarket } from "../../../../../src/atp/yield/YieldInterfaces.sol";

interface IPeek {
    function peek(address asset) external view returns (uint256);
}

/// @notice Test-only Moolah with the one rule the chain 97 mock does not have and Lista's mainnet Moolah does:
/// a position may not be left with a debt below `minLoanValue` (USD, 8 decimals): borrow and repay revert with
/// "remain borrow too low", and `minLoan(params)` publishes the floor in loan units. Morpho share math, one
/// fixed borrow APR, its own IRM. Kept out of `src/testnet` so the deployed mock's code is unchanged.
contract MinLoanMoolah {
    using SafeERC20 for IERC20;

    uint256 internal constant VIRTUAL_SHARES = 1e6;
    uint256 internal constant VIRTUAL_ASSETS = 1;

    struct Position {
        uint256 supplyShares;
        uint128 borrowShares;
        uint128 collateral;
    }

    uint256 public minLoanValue = 15e8;
    uint256 public aprBps = 250;
    mapping(bytes32 => MoolahParams) internal _params;
    mapping(bytes32 => MoolahMarket) internal _market;
    mapping(bytes32 => mapping(address => Position)) internal _position;
    mapping(address => mapping(address => bool)) public isAuthorized;

    function marketId(MoolahParams memory p) public pure returns (bytes32) {
        return keccak256(abi.encode(p));
    }

    function createMarket(MoolahParams memory p) external returns (bytes32 id) {
        id = marketId(p);
        _params[id] = p;
        _market[id].lastUpdate = uint128(block.timestamp);
    }

    function setMinLoanValue(uint256 value) external {
        minLoanValue = value;
    }

    function paused() external pure returns (bool) {
        return false;
    }

    function idToMarketParams(bytes32 id) external view returns (MoolahParams memory) {
        return _params[id];
    }

    function market(bytes32 id) external view returns (MoolahMarket memory) {
        return _market[id];
    }

    function position(bytes32 id, address user) external view returns (uint256, uint128, uint128) {
        Position memory x = _position[id][user];
        return (x.supplyShares, x.borrowShares, x.collateral);
    }

    function borrowRateView(MoolahParams memory, MoolahMarket memory) external view returns (uint256) {
        return aprBps * 1e14 / 365 days;
    }

    /// @notice The smallest debt a position may keep, in loan raw units.
    function minLoan(MoolahParams memory p) public view returns (uint256) {
        return Math.mulDiv(
            minLoanValue,
            10 ** IERC20Metadata(p.loanToken).decimals(),
            IPeek(p.oracle).peek(p.loanToken),
            Math.Rounding.Ceil
        );
    }

    function setAuthorization(address authorized, bool allowed) external {
        isAuthorized[msg.sender][authorized] = allowed;
    }

    function accrueInterest(MoolahParams memory p) external {
        _accrue(marketId(p));
    }

    function supply(MoolahParams memory p, uint256 assets, uint256, address onBehalf, bytes calldata)
        external
        returns (uint256, uint256)
    {
        bytes32 id = marketId(p);
        _accrue(id);
        uint256 shares = _down(assets, _market[id].totalSupplyShares, _market[id].totalSupplyAssets);
        _position[id][onBehalf].supplyShares += shares;
        _market[id].totalSupplyShares += uint128(shares);
        _market[id].totalSupplyAssets += uint128(assets);
        IERC20(p.loanToken).safeTransferFrom(msg.sender, address(this), assets);
        return (assets, shares);
    }

    function supplyCollateral(MoolahParams memory p, uint256 assets, address onBehalf, bytes calldata)
        external
    {
        _position[marketId(p)][onBehalf].collateral += uint128(assets);
        IERC20(p.collateralToken).safeTransferFrom(msg.sender, address(this), assets);
    }

    function withdrawCollateral(MoolahParams memory p, uint256 assets, address onBehalf, address receiver)
        external
    {
        bytes32 id = marketId(p);
        _auth(onBehalf);
        _accrue(id);
        _position[id][onBehalf].collateral -= uint128(assets);
        require(_healthy(p, id, onBehalf), "insufficient collateral");
        IERC20(p.collateralToken).safeTransfer(receiver, assets);
    }

    function borrow(MoolahParams memory p, uint256 assets, uint256, address onBehalf, address receiver)
        external
        returns (uint256, uint256)
    {
        bytes32 id = marketId(p);
        _auth(onBehalf);
        _accrue(id);
        uint256 shares = _up(assets, _market[id].totalBorrowShares, _market[id].totalBorrowAssets);
        _position[id][onBehalf].borrowShares += uint128(shares);
        _market[id].totalBorrowShares += uint128(shares);
        _market[id].totalBorrowAssets += uint128(assets);
        require(_healthy(p, id, onBehalf), "insufficient collateral");
        require(_market[id].totalBorrowAssets <= _market[id].totalSupplyAssets, "insufficient liquidity");
        _checkMinLoan(p, id, onBehalf);
        IERC20(p.loanToken).safeTransfer(receiver, assets);
        return (assets, shares);
    }

    function repay(MoolahParams memory p, uint256 assets, uint256 shares, address onBehalf, bytes calldata)
        external
        returns (uint256, uint256)
    {
        bytes32 id = marketId(p);
        _accrue(id);
        if (assets != 0) {
            shares = _down(assets, _market[id].totalBorrowShares, _market[id].totalBorrowAssets);
        } else {
            assets = _assetsUp(shares, _market[id].totalBorrowAssets, _market[id].totalBorrowShares);
        }
        _position[id][onBehalf].borrowShares -= uint128(shares);
        _market[id].totalBorrowShares -= uint128(shares);
        _market[id].totalBorrowAssets -= uint128(Math.min(_market[id].totalBorrowAssets, assets));
        _checkMinLoan(p, id, onBehalf);
        IERC20(p.loanToken).safeTransferFrom(msg.sender, address(this), assets);
        return (assets, shares);
    }

    function _checkMinLoan(MoolahParams memory p, bytes32 id, address user) private view {
        uint256 shares = _position[id][user].borrowShares;
        if (shares == 0) return;
        uint256 owed = _assetsUp(shares, _market[id].totalBorrowAssets, _market[id].totalBorrowShares);
        require(owed >= minLoan(p), "remain borrow too low");
    }

    function _healthy(MoolahParams memory p, bytes32 id, address user) private view returns (bool) {
        Position memory x = _position[id][user];
        if (x.borrowShares == 0) return true;
        uint256 owed = _assetsUp(x.borrowShares, _market[id].totalBorrowAssets, _market[id].totalBorrowShares);
        uint256 debtValue =
            owed * IPeek(p.oracle).peek(p.loanToken) / 10 ** IERC20Metadata(p.loanToken).decimals();
        uint256 collateralValue = uint256(x.collateral) * IPeek(p.oracle).peek(p.collateralToken) / 10
            ** IERC20Metadata(p.collateralToken).decimals();
        return debtValue <= collateralValue * p.lltv / 1e18;
    }

    function _auth(address onBehalf) private view {
        require(msg.sender == onBehalf || isAuthorized[onBehalf][msg.sender], "unauthorized");
    }

    function _accrue(bytes32 id) private {
        MoolahMarket storage m = _market[id];
        uint256 elapsed = block.timestamp - m.lastUpdate;
        if (elapsed == 0) return;
        m.lastUpdate = uint128(block.timestamp);
        uint256 interest = uint256(m.totalBorrowAssets) * aprBps * elapsed / (10_000 * 365 days);
        m.totalBorrowAssets += uint128(interest);
        m.totalSupplyAssets += uint128(interest);
    }

    function _down(uint256 assets, uint256 totalShares, uint256 totalAssets) private pure returns (uint256) {
        return Math.mulDiv(assets, totalShares + VIRTUAL_SHARES, totalAssets + VIRTUAL_ASSETS);
    }

    function _up(uint256 assets, uint256 totalShares, uint256 totalAssets) private pure returns (uint256) {
        return
            Math.mulDiv(
                assets, totalShares + VIRTUAL_SHARES, totalAssets + VIRTUAL_ASSETS, Math.Rounding.Ceil
            );
    }

    function _assetsUp(uint256 shares, uint256 totalAssets, uint256 totalShares)
        private
        pure
        returns (uint256)
    {
        return Math.mulDiv(
            shares, totalAssets + VIRTUAL_ASSETS, totalShares + VIRTUAL_SHARES, Math.Rounding.Ceil
        );
    }
}
