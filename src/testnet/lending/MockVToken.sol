// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20, IERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

interface IMockComptroller {
    function mintAllowed(address vToken, address minter, uint256 amount) external view returns (uint256);
    function redeemAllowed(address vToken, address redeemer, uint256 tokens) external view returns (uint256);
    function borrowAllowed(address vToken, address borrower, uint256 amount) external returns (uint256);
    function repayBorrowAllowed(address vToken, address payer, address borrower, uint256 amount)
        external
        view
        returns (uint256);
    function liquidateBorrowAllowed(
        address vTokenBorrowed,
        address vTokenCollateral,
        address liquidator,
        address borrower,
        uint256 repayAmount
    ) external view returns (uint256);
    function seizeAllowed(
        address vTokenCollateral,
        address vTokenBorrowed,
        address liquidator,
        address borrower,
        uint256 seizeTokens
    ) external view returns (uint256);
    function transferAllowed(address vToken, address src, address dst, uint256 tokens)
        external
        view
        returns (uint256);
    function liquidateCalculateSeizeTokens(
        address vTokenBorrowed,
        address vTokenCollateral,
        uint256 repayAmount
    ) external view returns (uint256, uint256);
    function approvedDelegates(address borrower, address delegate) external view returns (bool);
    function oracle() external view returns (address);
}

interface IMockUnderlyingPrice {
    function getUnderlyingPrice(address vToken) external view returns (uint256);
}

interface IMockMintable {
    function mint(address to, uint256 amount) external;
}

interface IMockSeize {
    function seize(address liquidator, address borrower, uint256 seizeTokens) external returns (uint256);
    function accrueInterest() external returns (uint256);
}

/// @notice Chain-97-only Venus vToken with borrowing (#64). Compound v2 accounting: borrow index, total borrows,
/// exchange rate = (cash + borrows - reserves) / supply, so lenders earn exactly what borrowers pay. The borrow
/// APR is simulated, fixed and owner adjustable (bps, simple interest per second). Venus delegate entry points
/// (`mintBehalf`, `redeemBehalf`, `redeemUnderlyingBehalf`, `borrowBehalf`, `repayBorrowBehalf`) send the
/// borrowed / redeemed underlying to `msg.sender`, as Venus does. Token error codes follow Compound's
/// TokenErrorReporter: 3 COMPTROLLER_REJECTION, 14 TOKEN_INSUFFICIENT_CASH.
contract MockVToken is ERC20 {
    using SafeERC20 for IERC20;

    uint256 public constant BLOCKS_PER_YEAR = 70_080_000;
    uint256 internal constant COMPTROLLER_REJECTION = 3;
    uint256 internal constant TOKEN_INSUFFICIENT_CASH = 14;

    address public immutable underlying;
    address public immutable comptroller;
    address public immutable owner;
    uint256 internal immutable initialExchangeRate;
    uint16 public borrowAprBps;
    uint256 public reserveFactorMantissa;
    uint256 public totalBorrows;
    uint256 public totalReserves;
    uint256 public borrowIndex = 1e18;
    uint256 public accrualBlockNumber;
    uint256 public lastAccrualTime;

    struct BorrowSnapshot {
        uint256 principal;
        uint256 interestIndex;
    }

    mapping(address => BorrowSnapshot) internal _borrows;

    /// @notice Simulated incentives (bps of the position's USD value per year), like Venus' XVS speeds: on supply
    /// (collateral) and on debt. Paid in `rewardToken` (testnet USDT: 1 raw unit per 1e-18 USD) to the account
    /// that holds the position, never to anyone else; this mock must be a minter of it.
    address public rewardToken;
    uint16 public supplyIncentiveAprBps;
    uint16 public borrowIncentiveAprBps;
    mapping(address => uint256) public rewardAccrued;
    mapping(address => uint256) public rewardStamp;

    event Borrow(address borrower, uint256 borrowAmount, uint256 accountBorrows, uint256 totalBorrows);
    event RepayBorrow(
        address payer, address borrower, uint256 repayAmount, uint256 accountBorrows, uint256 total
    );
    event LiquidateBorrow(
        address liquidator,
        address borrower,
        uint256 repayAmount,
        address vTokenCollateral,
        uint256 seizeTokens
    );
    event SimulatedBorrowAprSet(uint16 aprBps);
    event SimulatedIncentivesSet(address rewardToken, uint16 supplyAprBps, uint16 borrowAprBps);
    event RewardClaimed(address indexed account, uint256 amount);

    modifier onlyOwner() {
        require(msg.sender == owner, "lending mock: owner only");
        _;
    }

    constructor(
        address underlying_,
        address comptroller_,
        address owner_,
        uint16 borrowAprBps_,
        string memory symbol_
    ) ERC20(string.concat("Mock Venus ", symbol_), string.concat("v", symbol_)) {
        require(block.chainid == 97, "lending mock: chain 97 only");
        require(
            underlying_.code.length != 0 && comptroller_.code.length != 0 && owner_ != address(0)
                && borrowAprBps_ <= 10_000 && IERC20Metadata(underlying_).decimals() <= 18,
            "lending mock: config"
        );
        underlying = underlying_;
        comptroller = comptroller_;
        owner = owner_;
        borrowAprBps = borrowAprBps_;
        initialExchangeRate = 10 ** (uint256(IERC20Metadata(underlying_).decimals()) + 10);
        accrualBlockNumber = block.number;
        lastAccrualTime = block.timestamp;
    }

    function decimals() public pure override returns (uint8) {
        return 8;
    }

    function isTestnetLendingMock() external pure returns (bool) {
        return true;
    }

    // ---- views ----

    function getCash() public view returns (uint256) {
        return IERC20(underlying).balanceOf(address(this));
    }

    function exchangeRateStored() public view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return initialExchangeRate;
        return Math.mulDiv(getCash() + totalBorrows - totalReserves, 1e18, supply);
    }

    function borrowBalanceStored(address account) public view returns (uint256) {
        BorrowSnapshot memory s = _borrows[account];
        if (s.principal == 0) return 0;
        return Math.mulDiv(s.principal, borrowIndex, s.interestIndex, Math.Rounding.Ceil);
    }

    function getAccountSnapshot(address account) external view returns (uint256, uint256, uint256, uint256) {
        return (0, balanceOf(account), borrowBalanceStored(account), exchangeRateStored());
    }

    function borrowRatePerBlock() public view returns (uint256) {
        return uint256(borrowAprBps) * 1e18 / (10_000 * BLOCKS_PER_YEAR);
    }

    function supplyRatePerBlock() external view returns (uint256) {
        uint256 supplied = getCash() + totalBorrows - totalReserves;
        if (supplied == 0) return 0;
        uint256 utilization = Math.mulDiv(totalBorrows, 1e18, supplied);
        return Math.mulDiv(
            Math.mulDiv(borrowRatePerBlock(), utilization, 1e18), 1e18 - reserveFactorMantissa, 1e18
        );
    }

    // ---- interest ----

    function accrueInterest() public returns (uint256) {
        accrualBlockNumber = block.number;
        uint256 elapsed = block.timestamp - lastAccrualTime;
        if (elapsed == 0) return 0;
        lastAccrualTime = block.timestamp;
        uint256 factor = Math.mulDiv(uint256(borrowAprBps) * elapsed, 1e18, 10_000 * 365 days);
        if (factor == 0) return 0;
        uint256 interest = Math.mulDiv(totalBorrows, factor, 1e18);
        totalBorrows += interest;
        totalReserves += Math.mulDiv(interest, reserveFactorMantissa, 1e18);
        borrowIndex += Math.mulDiv(borrowIndex, factor, 1e18);
        return 0;
    }

    function borrowBalanceCurrent(address account) external returns (uint256) {
        accrueInterest();
        return borrowBalanceStored(account);
    }

    function exchangeRateCurrent() external returns (uint256) {
        accrueInterest();
        return exchangeRateStored();
    }

    function balanceOfUnderlying(address account) external returns (uint256) {
        accrueInterest();
        return Math.mulDiv(balanceOf(account), exchangeRateStored(), 1e18);
    }

    // ---- supply side ----

    function mint(uint256 amount) external returns (uint256) {
        return _mintFresh(msg.sender, msg.sender, amount);
    }

    function mintBehalf(address receiver, uint256 amount) external returns (uint256) {
        return _mintFresh(msg.sender, receiver, amount);
    }

    function redeem(uint256 tokens) external returns (uint256) {
        return _redeemFresh(msg.sender, msg.sender, tokens, 0);
    }

    function redeemUnderlying(uint256 amount) external returns (uint256) {
        return _redeemFresh(msg.sender, msg.sender, 0, amount);
    }

    function redeemBehalf(address redeemer, uint256 tokens) external returns (uint256) {
        _requireDelegate(redeemer);
        return _redeemFresh(redeemer, msg.sender, tokens, 0);
    }

    function redeemUnderlyingBehalf(address redeemer, uint256 amount) external returns (uint256) {
        _requireDelegate(redeemer);
        return _redeemFresh(redeemer, msg.sender, 0, amount);
    }

    // ---- borrow side ----

    function borrow(uint256 amount) external returns (uint256) {
        return _borrowFresh(msg.sender, msg.sender, amount);
    }

    function borrowBehalf(address borrower, uint256 amount) external returns (uint256) {
        _requireDelegate(borrower);
        return _borrowFresh(borrower, msg.sender, amount);
    }

    function repayBorrow(uint256 amount) external returns (uint256) {
        accrueInterest();
        (uint256 err,) = _repayFresh(msg.sender, msg.sender, amount);
        return err;
    }

    function repayBorrowBehalf(address borrower, uint256 amount) external returns (uint256) {
        accrueInterest();
        (uint256 err,) = _repayFresh(msg.sender, borrower, amount);
        return err;
    }

    /// @notice Anyone may repay part of an underwater borrower's debt and seize collateral vTokens at the
    /// comptroller's incentive. On chain 97 the owner rehearses this by marking the collateral price down.
    function liquidateBorrow(address borrower, uint256 repayAmount, address vTokenCollateral)
        external
        returns (uint256)
    {
        require(borrower != msg.sender, "liquidator is borrower");
        require(repayAmount != 0 && repayAmount != type(uint256).max, "bad close amount");
        accrueInterest();
        if (vTokenCollateral != address(this)) IMockSeize(vTokenCollateral).accrueInterest();
        uint256 allowed = IMockComptroller(comptroller)
            .liquidateBorrowAllowed(address(this), vTokenCollateral, msg.sender, borrower, repayAmount);
        if (allowed != 0) return COMPTROLLER_REJECTION;
        (uint256 err, uint256 repaid) = _repayFresh(msg.sender, borrower, repayAmount);
        require(err == 0, "liquidate repay failed");
        (uint256 calc, uint256 seizeTokens) = IMockComptroller(comptroller)
            .liquidateCalculateSeizeTokens(address(this), vTokenCollateral, repaid);
        require(calc == 0, "liquidate calculate failed");
        require(IERC20(vTokenCollateral).balanceOf(borrower) >= seizeTokens, "LIQUIDATE_SEIZE_TOO_MUCH");
        if (vTokenCollateral == address(this)) {
            require(_seize(address(this), msg.sender, borrower, seizeTokens) == 0, "seize failed");
        } else {
            require(
                IMockSeize(vTokenCollateral).seize(msg.sender, borrower, seizeTokens) == 0, "seize failed"
            );
        }
        emit LiquidateBorrow(msg.sender, borrower, repaid, vTokenCollateral, seizeTokens);
        return 0;
    }

    function seize(address liquidator, address borrower, uint256 seizeTokens) external returns (uint256) {
        return _seize(msg.sender, liquidator, borrower, seizeTokens);
    }

    // ---- transfers check account liquidity, like Compound ----

    function transfer(address to, uint256 amount) public override returns (bool) {
        _transferAllowed(msg.sender, to, amount);
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        _transferAllowed(from, to, amount);
        return super.transferFrom(from, to, amount);
    }

    // ---- admin ----

    function setBorrowAprBps(uint16 apr) external onlyOwner {
        require(apr <= 10_000, "APR cap");
        accrueInterest();
        borrowAprBps = apr;
        emit SimulatedBorrowAprSet(apr);
    }

    /// @notice Set the simulated incentive APRs (bps); `token` pays them (0 = no payout token yet).
    function setIncentives(address token, uint16 supplyAprBps, uint16 borrowAprBps) external onlyOwner {
        require(supplyAprBps <= 10_000 && borrowAprBps <= 10_000, "incentive cap");
        accrueInterest();
        rewardToken = token;
        supplyIncentiveAprBps = supplyAprBps;
        borrowIncentiveAprBps = borrowAprBps;
        emit SimulatedIncentivesSet(token, supplyAprBps, borrowAprBps);
    }

    /// @notice Rewards earned so far by `account`'s own position (accrued + pending).
    function rewardOf(address account) external view returns (uint256) {
        return rewardAccrued[account] + _pendingReward(account);
    }

    /// @notice Anyone may trigger; rewards always go to `account`, the position holder.
    function claimReward(address account) external returns (uint256 amount) {
        accrueInterest();
        _accrueReward(account);
        amount = rewardAccrued[account];
        if (amount == 0) return 0;
        rewardAccrued[account] = 0;
        IMockMintable(rewardToken).mint(account, amount);
        emit RewardClaimed(account, amount);
    }

    function setReserveFactor(uint256 factor) external onlyOwner {
        require(factor <= 0.5e18, "reserve factor");
        accrueInterest();
        reserveFactorMantissa = factor;
    }

    // ---- internals ----

    function _requireDelegate(address account) private view {
        require(
            account == msg.sender || IMockComptroller(comptroller).approvedDelegates(account, msg.sender),
            "not an approved delegate"
        );
    }

    function _transferAllowed(address from, address to, uint256 amount) private view {
        require(
            IMockComptroller(comptroller).transferAllowed(address(this), from, to, amount) == 0,
            "transfer rejected"
        );
    }

    function _mintFresh(address payer, address receiver, uint256 amount) private returns (uint256) {
        accrueInterest();
        if (IMockComptroller(comptroller).mintAllowed(address(this), receiver, amount) != 0) {
            return COMPTROLLER_REJECTION;
        }
        uint256 rate = exchangeRateStored();
        uint256 cash = getCash();
        IERC20(underlying).safeTransferFrom(payer, address(this), amount);
        require(getCash() - cash == amount, "inexact transfer in");
        uint256 tokens = Math.mulDiv(amount, 1e18, rate);
        require(tokens != 0, "zero mint");
        _mint(receiver, tokens);
        return 0;
    }

    function _redeemFresh(address redeemer, address receiver, uint256 tokensIn, uint256 amountIn)
        private
        returns (uint256)
    {
        require(tokensIn == 0 || amountIn == 0, "one of tokens or amount");
        accrueInterest();
        uint256 rate = exchangeRateStored();
        uint256 tokens = tokensIn != 0 ? tokensIn : Math.mulDiv(amountIn, 1e18, rate, Math.Rounding.Ceil);
        uint256 amount = tokensIn != 0 ? Math.mulDiv(tokensIn, rate, 1e18) : amountIn;
        require(tokens != 0 && amount != 0, "zero redeem");
        if (IMockComptroller(comptroller).redeemAllowed(address(this), redeemer, tokens) != 0) {
            return COMPTROLLER_REJECTION;
        }
        if (getCash() < amount) return TOKEN_INSUFFICIENT_CASH;
        _burn(redeemer, tokens);
        IERC20(underlying).safeTransfer(receiver, amount);
        return 0;
    }

    function _borrowFresh(address borrower, address receiver, uint256 amount) private returns (uint256) {
        accrueInterest();
        require(amount != 0, "zero borrow");
        if (IMockComptroller(comptroller).borrowAllowed(address(this), borrower, amount) != 0) {
            return COMPTROLLER_REJECTION;
        }
        if (getCash() < amount) return TOKEN_INSUFFICIENT_CASH;
        uint256 accountBorrows = borrowBalanceStored(borrower) + amount;
        _accrueReward(borrower);
        _borrows[borrower] = BorrowSnapshot(accountBorrows, borrowIndex);
        totalBorrows += amount;
        IERC20(underlying).safeTransfer(receiver, amount);
        emit Borrow(borrower, amount, accountBorrows, totalBorrows);
        return 0;
    }

    function _repayFresh(address payer, address borrower, uint256 amount) private returns (uint256, uint256) {
        if (IMockComptroller(comptroller).repayBorrowAllowed(address(this), payer, borrower, amount) != 0) {
            return (COMPTROLLER_REJECTION, 0);
        }
        uint256 owed = borrowBalanceStored(borrower);
        uint256 repay = amount == type(uint256).max ? owed : amount;
        require(repay <= owed, "repay exceeds debt");
        uint256 cash = getCash();
        IERC20(underlying).safeTransferFrom(payer, address(this), repay);
        require(getCash() - cash == repay, "inexact transfer in");
        uint256 left = owed - repay;
        _accrueReward(borrower);
        _borrows[borrower] = BorrowSnapshot(left, borrowIndex);
        // Per-account ceil rounding can make the sum exceed the total by a few raw units.
        totalBorrows = totalBorrows > repay ? totalBorrows - repay : 0;
        emit RepayBorrow(payer, borrower, repay, left, totalBorrows);
        return (0, repay);
    }

    function _seize(address seizer, address liquidator, address borrower, uint256 tokens)
        private
        returns (uint256)
    {
        uint256 allowed = IMockComptroller(comptroller)
            .seizeAllowed(address(this), seizer, liquidator, borrower, tokens);
        if (allowed != 0) return allowed;
        require(borrower != liquidator, "liquidator is borrower");
        _transfer(borrower, liquidator, tokens);
        return 0;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0)) _accrueReward(from);
        if (to != address(0)) _accrueReward(to);
        super._update(from, to, value);
    }

    function _accrueReward(address account) private {
        rewardAccrued[account] += _pendingReward(account);
        rewardStamp[account] = block.timestamp;
    }

    function _pendingReward(address account) private view returns (uint256) {
        uint256 last = rewardStamp[account];
        if (last == 0 || last >= block.timestamp) return 0;
        if (supplyIncentiveAprBps == 0 && borrowIncentiveAprBps == 0) return 0;
        uint256 price =
            IMockUnderlyingPrice(IMockComptroller(comptroller).oracle()).getUnderlyingPrice(address(this));
        uint256 supplied =
            Math.mulDiv(Math.mulDiv(balanceOf(account), exchangeRateStored(), 1e18), price, 1e18);
        uint256 owed = Math.mulDiv(borrowBalanceStored(account), price, 1e18);
        uint256 weighted = supplied * supplyIncentiveAprBps + owed * borrowIncentiveAprBps;
        return Math.mulDiv(weighted, block.timestamp - last, 10_000 * 365 days);
    }
}
