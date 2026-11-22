// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

interface IMockVTokenView {
    function comptroller() external view returns (address);
    function totalBorrows() external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function exchangeRateStored() external view returns (uint256);
    function borrowBalanceStored(address account) external view returns (uint256);
    function getAccountSnapshot(address account) external view returns (uint256, uint256, uint256, uint256);
}

interface IMockPriceOracle {
    function getUnderlyingPrice(address vToken) external view returns (uint256);
}

/// @notice Chain-97-only Venus Core Pool comptroller (#64): Compound v2 hooks, account liquidity, collateral
/// factors, close factor / liquidation incentive, action pauses, borrow caps and Venus borrow delegation
/// (`updateDelegate` / `approvedDelegates` / `enterMarketBehalf`). Error codes follow Compound's
/// ComptrollerErrorReporter (0 ok, 4 INSUFFICIENT_LIQUIDITY, 3 INSUFFICIENT_SHORTFALL, 9 MARKET_NOT_LISTED,
/// 12 NONZERO_BORROW_BALANCE, 13 PRICE_ERROR, 17 TOO_MUCH_REPAY); a paused action reverts like Venus does.
contract MockVenusComptroller {
    // Venus `Action` enum order.
    uint8 internal constant MINT = 0;
    uint8 internal constant REDEEM = 1;
    uint8 internal constant BORROW = 2;
    uint8 internal constant REPAY = 3;
    uint8 internal constant SEIZE = 4;
    uint8 internal constant LIQUIDATE = 5;
    uint8 internal constant TRANSFER = 6;
    uint8 internal constant ENTER_MARKET = 7;
    uint8 internal constant EXIT_MARKET = 8;

    address public immutable owner;
    address public oracle;
    uint256 public closeFactorMantissa = 0.5e18;
    uint256 public liquidationIncentiveMantissa = 1.1e18;

    struct MarketCfg {
        bool isListed;
        uint256 collateralFactorMantissa;
    }

    mapping(address => MarketCfg) internal _markets;
    address[] public allMarkets;
    mapping(address => address[]) internal _assetsIn;
    mapping(address => mapping(address => bool)) public checkMembership;
    mapping(address => mapping(address => bool)) public approvedDelegates;
    mapping(address => mapping(uint8 => bool)) public actionPaused;
    mapping(address => uint256) public borrowCaps;

    event MarketListed(address vToken);
    event NewCollateralFactor(address vToken, uint256 factor);
    event MarketEntered(address vToken, address account);
    event MarketExited(address vToken, address account);
    event DelegateUpdated(address indexed borrower, address indexed delegate, bool approved);
    event ActionPausedMarket(address indexed vToken, uint8 action, bool paused);
    event NewBorrowCap(address indexed vToken, uint256 cap);

    modifier onlyOwner() {
        require(msg.sender == owner, "lending mock: owner only");
        _;
    }

    constructor(address owner_, address oracle_) {
        require(block.chainid == 97, "lending mock: chain 97 only");
        require(owner_ != address(0) && oracle_.code.length != 0, "lending mock: config");
        owner = owner_;
        oracle = oracle_;
    }

    function isTestnetLendingMock() external pure returns (bool) {
        return true;
    }

    // ---- admin ----

    function supportMarket(address vToken) external onlyOwner returns (uint256) {
        require(!_markets[vToken].isListed, "market already listed");
        require(IMockVTokenView(vToken).comptroller() == address(this), "comptroller mismatch");
        _markets[vToken].isListed = true;
        allMarkets.push(vToken);
        emit MarketListed(vToken);
        return 0;
    }

    function setCollateralFactor(address vToken, uint256 factor) external onlyOwner returns (uint256) {
        require(_markets[vToken].isListed, "market not listed");
        require(factor <= 0.9e18, "collateral factor too high");
        _markets[vToken].collateralFactorMantissa = factor;
        emit NewCollateralFactor(vToken, factor);
        return 0;
    }

    function setCloseFactor(uint256 factor) external onlyOwner {
        require(factor >= 0.05e18 && factor <= 1e18, "close factor");
        closeFactorMantissa = factor;
    }

    function setLiquidationIncentive(uint256 incentive) external onlyOwner {
        require(incentive >= 1e18 && incentive <= 1.5e18, "incentive");
        liquidationIncentiveMantissa = incentive;
    }

    function setPriceOracle(address next) external onlyOwner {
        require(next.code.length != 0, "oracle");
        oracle = next;
    }

    /// @dev Single-market form of Venus `setActionsPaused(address[],Action[],bool)`.
    function setActionPaused(address vToken, uint8 action, bool paused) external onlyOwner {
        require(_markets[vToken].isListed && action <= EXIT_MARKET, "bad action");
        actionPaused[vToken][action] = paused;
        emit ActionPausedMarket(vToken, action, paused);
    }

    /// @notice 0 means unlimited (Compound semantics); collateral-only markets pause BORROW instead.
    function setMarketBorrowCap(address vToken, uint256 cap) external onlyOwner {
        borrowCaps[vToken] = cap;
        emit NewBorrowCap(vToken, cap);
    }

    // ---- account ----

    function markets(address vToken) external view returns (bool, uint256, bool) {
        MarketCfg memory m = _markets[vToken];
        return (m.isListed, m.collateralFactorMantissa, false);
    }

    function getAllMarkets() external view returns (address[] memory) {
        return allMarkets;
    }

    function getAssetsIn(address account) external view returns (address[] memory) {
        return _assetsIn[account];
    }

    function updateDelegate(address delegate, bool allowBorrows) external {
        require(delegate != address(0), "zero delegate");
        approvedDelegates[msg.sender][delegate] = allowBorrows;
        emit DelegateUpdated(msg.sender, delegate, allowBorrows);
    }

    function enterMarkets(address[] calldata vTokens) external returns (uint256[] memory results) {
        results = new uint256[](vTokens.length);
        for (uint256 i; i < vTokens.length; ++i) {
            results[i] = _enter(vTokens[i], msg.sender);
        }
    }

    function enterMarketBehalf(address onBehalf, address vToken) external returns (uint256) {
        require(onBehalf == msg.sender || approvedDelegates[onBehalf][msg.sender], "not an approved delegate");
        return _enter(vToken, onBehalf);
    }

    function exitMarket(address vToken) external returns (uint256) {
        require(!actionPaused[vToken][EXIT_MARKET], "action is paused");
        (uint256 err, uint256 balance, uint256 borrowed,) =
            IMockVTokenView(vToken).getAccountSnapshot(msg.sender);
        require(err == 0, "snapshot");
        if (borrowed != 0) return 12;
        uint256 allowed = _redeemAllowed(vToken, msg.sender, balance);
        if (allowed != 0) return allowed;
        if (!checkMembership[msg.sender][vToken]) return 0;
        checkMembership[msg.sender][vToken] = false;
        address[] storage list = _assetsIn[msg.sender];
        for (uint256 i; i < list.length; ++i) {
            if (list[i] == vToken) {
                list[i] = list[list.length - 1];
                list.pop();
                break;
            }
        }
        emit MarketExited(vToken, msg.sender);
        return 0;
    }

    function getAccountLiquidity(address account) external view returns (uint256, uint256, uint256) {
        return getHypotheticalAccountLiquidity(account, address(0), 0, 0);
    }

    function getHypotheticalAccountLiquidity(
        address account,
        address vTokenModify,
        uint256 redeemTokens,
        uint256 borrowAmount
    ) public view returns (uint256, uint256, uint256) {
        uint256 collateral;
        uint256 debt;
        address[] memory assets = _assetsIn[account];
        for (uint256 i; i < assets.length; ++i) {
            address v = assets[i];
            (uint256 err, uint256 balance, uint256 borrowed, uint256 rate) =
                IMockVTokenView(v).getAccountSnapshot(account);
            if (err != 0) return (15, 0, 0);
            uint256 price = IMockPriceOracle(oracle).getUnderlyingPrice(v);
            if (price == 0) return (13, 0, 0);
            // USD (1e18) per vToken raw unit, collateral-factor adjusted.
            uint256 perToken =
                Math.mulDiv(Math.mulDiv(_markets[v].collateralFactorMantissa, rate, 1e18), price, 1e18);
            collateral += Math.mulDiv(perToken, balance, 1e18);
            debt += Math.mulDiv(price, borrowed, 1e18);
            if (v == vTokenModify) {
                debt += Math.mulDiv(perToken, redeemTokens, 1e18);
                debt += Math.mulDiv(price, borrowAmount, 1e18);
            }
        }
        if (collateral > debt) return (0, collateral - debt, 0);
        return (0, 0, debt - collateral);
    }

    // ---- vToken hooks (Compound v2 policy hooks) ----

    function mintAllowed(address vToken, address, uint256) external view returns (uint256) {
        require(!actionPaused[vToken][MINT], "action is paused");
        return _markets[vToken].isListed ? 0 : 9;
    }

    function redeemAllowed(address vToken, address redeemer, uint256 redeemTokens)
        external
        view
        returns (uint256)
    {
        require(!actionPaused[vToken][REDEEM], "action is paused");
        return _redeemAllowed(vToken, redeemer, redeemTokens);
    }

    function borrowAllowed(address vToken, address borrower, uint256 borrowAmount)
        external
        returns (uint256)
    {
        require(!actionPaused[vToken][BORROW], "action is paused");
        if (!_markets[vToken].isListed) return 9;
        if (!checkMembership[borrower][vToken]) {
            require(msg.sender == vToken, "sender must be vToken");
            uint256 err = _enter(vToken, borrower);
            if (err != 0) return err;
        }
        if (IMockPriceOracle(oracle).getUnderlyingPrice(vToken) == 0) return 13;
        uint256 cap = borrowCaps[vToken];
        if (cap != 0) {
            require(IMockVTokenView(vToken).totalBorrows() + borrowAmount <= cap, "market borrow cap reached");
        }
        (uint256 e,, uint256 shortfall) = getHypotheticalAccountLiquidity(borrower, vToken, 0, borrowAmount);
        if (e != 0) return e;
        return shortfall > 0 ? 4 : 0;
    }

    function repayBorrowAllowed(address vToken, address, address, uint256) external view returns (uint256) {
        require(!actionPaused[vToken][REPAY], "action is paused");
        return _markets[vToken].isListed ? 0 : 9;
    }

    function liquidateBorrowAllowed(
        address vTokenBorrowed,
        address vTokenCollateral,
        address,
        address borrower,
        uint256 repayAmount
    ) external view returns (uint256) {
        require(!actionPaused[vTokenBorrowed][LIQUIDATE], "action is paused");
        if (!_markets[vTokenBorrowed].isListed || !_markets[vTokenCollateral].isListed) return 9;
        (uint256 err,, uint256 shortfall) = getHypotheticalAccountLiquidity(borrower, address(0), 0, 0);
        if (err != 0) return err;
        if (shortfall == 0) return 3;
        uint256 maxClose = Math.mulDiv(
            closeFactorMantissa, IMockVTokenView(vTokenBorrowed).borrowBalanceStored(borrower), 1e18
        );
        return repayAmount > maxClose ? 17 : 0;
    }

    function seizeAllowed(address vTokenCollateral, address vTokenBorrowed, address, address, uint256)
        external
        view
        returns (uint256)
    {
        require(!actionPaused[vTokenCollateral][SEIZE], "action is paused");
        if (!_markets[vTokenCollateral].isListed || !_markets[vTokenBorrowed].isListed) return 9;
        require(
            IMockVTokenView(vTokenCollateral).comptroller() == IMockVTokenView(vTokenBorrowed).comptroller(),
            "comptroller mismatch"
        );
        return 0;
    }

    function transferAllowed(address vToken, address src, address, uint256 tokens)
        external
        view
        returns (uint256)
    {
        require(!actionPaused[vToken][TRANSFER], "action is paused");
        return _redeemAllowed(vToken, src, tokens);
    }

    function liquidateCalculateSeizeTokens(
        address vTokenBorrowed,
        address vTokenCollateral,
        uint256 repayAmount
    ) external view returns (uint256, uint256) {
        uint256 priceBorrowed = IMockPriceOracle(oracle).getUnderlyingPrice(vTokenBorrowed);
        uint256 priceCollateral = IMockPriceOracle(oracle).getUnderlyingPrice(vTokenCollateral);
        if (priceBorrowed == 0 || priceCollateral == 0) return (13, 0);
        uint256 rate = IMockVTokenView(vTokenCollateral).exchangeRateStored();
        // seizeTokens = repay * incentive * priceBorrowed / (priceCollateral * exchangeRate)
        uint256 numerator = Math.mulDiv(liquidationIncentiveMantissa, priceBorrowed, 1e18);
        uint256 denominator = Math.mulDiv(priceCollateral, rate, 1e18);
        return (0, Math.mulDiv(repayAmount, numerator, denominator));
    }

    // ---- internals ----

    function _enter(address vToken, address account) private returns (uint256) {
        require(!actionPaused[vToken][ENTER_MARKET], "action is paused");
        if (!_markets[vToken].isListed) return 9;
        if (checkMembership[account][vToken]) return 0;
        checkMembership[account][vToken] = true;
        _assetsIn[account].push(vToken);
        emit MarketEntered(vToken, account);
        return 0;
    }

    function _redeemAllowed(address vToken, address redeemer, uint256 redeemTokens)
        private
        view
        returns (uint256)
    {
        if (!_markets[vToken].isListed) return 9;
        if (!checkMembership[redeemer][vToken]) return 0;
        (uint256 err,, uint256 shortfall) = getHypotheticalAccountLiquidity(redeemer, vToken, redeemTokens, 0);
        if (err != 0) return err;
        return shortfall > 0 ? 4 : 0;
    }
}
