// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { ERC20, IERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { TestnetToken } from "../TestnetToken.sol";

contract MockAaveDebt is ERC20 {
    address immutable pool;

    constructor() ERC20("Mock Aave debt", "mDebt") {
        pool = msg.sender;
    }

    function adjust(address account, uint256 amount, bool increase) external {
        require(msg.sender == pool, "pool only");
        if (increase) _mint(account, amount);
        else _burn(account, amount);
    }
}

/// @notice Rebasing aToken: balances and totalSupply use scaled units and the simulated liquidity index.
contract MockAToken is IERC20 {
    using SafeERC20 for IERC20;
    TestnetToken public immutable UNDERLYING_ASSET_ADDRESS;
    address public immutable POOL;
    string public constant name = "Mock Aave receipt";
    string public constant symbol = "maToken";
    uint256 internal scaledSupply;
    mapping(address => uint256) public scaledBalanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public index = 1e27;
    uint256 public updatedAt;
    uint16 public aprBps;
    modifier onlyPool() {
        require(msg.sender == POOL, "pool only");
        _;
    }

    constructor(TestnetToken asset, uint16 apr) {
        UNDERLYING_ASSET_ADDRESS = asset;
        POOL = msg.sender;
        aprBps = apr;
        updatedAt = block.timestamp;
    }

    function implementation() external view returns (address) {
        return address(this);
    }

    function decimals() external view returns (uint8) {
        return UNDERLYING_ASSET_ADDRESS.decimals();
    }

    function normalizedIncome() public view returns (uint256) {
        return index + Math.mulDiv(index, uint256(aprBps) * (block.timestamp - updatedAt), 365 days * 10_000);
    }

    function balanceOf(address account) public view returns (uint256) {
        return _rayMul(scaledBalanceOf[account], normalizedIncome());
    }

    function totalSupply() public view returns (uint256) {
        return _rayMul(scaledSupply, normalizedIncome());
    }

    function scaledTotalSupply() external view returns (uint256) {
        return scaledSupply;
    }

    function accrue() public {
        uint256 next = normalizedIncome();
        uint256 interest = _rayMul(scaledSupply, next) - _rayMul(scaledSupply, index);
        index = next;
        updatedAt = block.timestamp;
        if (interest != 0) UNDERLYING_ASSET_ADDRESS.mint(address(this), interest);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) private {
        require(to != address(0), "zero receiver");
        uint256 scaled = _rayDiv(amount, normalizedIncome());
        require(scaled != 0 || amount == 0, "zero scaled");
        scaledBalanceOf[from] -= scaled;
        scaledBalanceOf[to] += scaled;
        emit Transfer(from, to, amount);
    }

    function mint(address to, uint256 amount) external onlyPool {
        accrue();
        uint256 scaled = Math.mulDiv(amount, 1e27, index);
        require(scaled != 0, "zero scaled");
        scaledSupply += scaled;
        scaledBalanceOf[to] += scaled;
        emit Transfer(address(0), to, amount);
    }

    function redeem(address from, address to, uint256 amount) external onlyPool {
        accrue();
        uint256 scaled = _rayDiv(amount, index);
        require(scaled != 0, "zero scaled");
        scaledSupply -= scaled;
        scaledBalanceOf[from] -= scaled;
        emit Transfer(from, address(0), amount);
        require(
            amount
                <= UNDERLYING_ASSET_ADDRESS.balanceOf(address(this))
                    - MockAavePool(POOL).debt().totalSupply(),
            "withdraw unavailable"
        );
        IERC20(address(UNDERLYING_ASSET_ADDRESS)).safeTransfer(to, amount);
    }

    function setAprBps(uint16 apr) external onlyPool {
        accrue();
        aprBps = apr;
    }

    function _rayMul(uint256 a, uint256 b) private pure returns (uint256) {
        return Math.mulDiv(a, b, 1e27);
    }

    function _rayDiv(uint256 a, uint256 b) private pure returns (uint256) {
        return Math.mulDiv(a, 1e27, b, Math.Rounding.Ceil);
    }
}

/// @notice Chain-97-only Pool supply/withdraw mock. No public borrow, flash-loan or arbitrary-call API.
contract MockAavePool {
    using SafeERC20 for IERC20;
    TestnetToken public immutable asset;
    address public immutable owner;
    address public immutable receipt;
    MockAaveDebt public immutable debt;
    bool public supplyPaused;
    bool public paused;
    uint256 public supplyCapWhole;
    event SimulatedAprSet(uint16 aprBps);
    modifier onlyOwner() {
        require(msg.sender == owner, "yield mock: owner only");
        _;
    }

    constructor(TestnetToken asset_, address owner_, uint16 apr) {
        require(block.chainid == 97, "yield mock: chain 97 only");
        require(
            address(asset_).code.length != 0 && owner_ != address(0) && apr <= 10_000, "yield mock: config"
        );
        asset = asset_;
        owner = owner_;
        receipt = address(new MockAToken(asset_, apr));
        debt = new MockAaveDebt();
    }

    function implementation() external view returns (address) {
        return address(this);
    }

    function isTestnetYieldMock() external pure returns (bool) {
        return true;
    }

    function getReserveNormalizedIncome(address token) external view returns (uint256) {
        require(token == address(asset), "asset mismatch");
        return MockAToken(receipt).normalizedIncome();
    }

    function getVirtualUnderlyingBalance(address token) external view returns (uint256) {
        require(token == address(asset), "asset mismatch");
        return asset.balanceOf(receipt) - debt.totalSupply();
    }

    struct ReserveData {
        uint256 configuration;
        uint128 liquidityIndex;
        uint128 currentLiquidityRate;
        uint128 variableBorrowIndex;
        uint128 currentVariableBorrowRate;
        uint128 currentStableBorrowRate;
        uint40 lastUpdateTimestamp;
        uint16 id;
        address aTokenAddress;
        address stableDebtTokenAddress;
        address variableDebtTokenAddress;
        address interestRateStrategyAddress;
        uint128 accruedToTreasury;
        uint128 unbacked;
        uint128 isolationModeTotalDebt;
    }

    function getReserveData(address token) external view returns (ReserveData memory r) {
        require(token == address(asset), "asset mismatch");
        r.configuration = (uint256(1) << 56) | (supplyPaused ? uint256(1) << 57 : 0)
            | (paused ? uint256(1) << 60 : 0) | (uint256(asset.decimals()) << 48) | (supplyCapWhole << 116);
        r.liquidityIndex = uint128(MockAToken(receipt).normalizedIncome());
        r.currentLiquidityRate = uint128(uint256(MockAToken(receipt).aprBps()) * 1e27 / 10_000);
        r.variableBorrowIndex = 1e27;
        r.lastUpdateTimestamp = uint40(block.timestamp);
        r.aTokenAddress = receipt;
        r.variableDebtTokenAddress = address(debt);
        r.interestRateStrategyAddress = address(this);
    }

    function supply(address token, uint256 amount, address receiver, uint16 referral) external {
        require(token == address(asset) && !paused && !supplyPaused && referral == 0, "supply disabled");
        if (supplyCapWhole != 0) {
            require(
                MockAToken(receipt).totalSupply() + amount <= supplyCapWhole * 10 ** asset.decimals(),
                "supply cap"
            );
        }
        IERC20(token).safeTransferFrom(msg.sender, receipt, amount);
        MockAToken(receipt).mint(receiver, amount);
    }

    function withdraw(address token, uint256 amount, address receiver) external returns (uint256) {
        require(token == address(asset) && !paused, "withdraw disabled");
        if (amount == type(uint256).max) amount = MockAToken(receipt).balanceOf(msg.sender);
        MockAToken(receipt).redeem(msg.sender, receiver, amount);
        return amount;
    }

    function setAprBps(uint16 apr) external onlyOwner {
        require(apr <= 10_000, "APR cap");
        MockAToken(receipt).setAprBps(apr);
        emit SimulatedAprSet(apr);
    }

    function setLiquidity(uint256 desired) external onlyOwner {
        MockAToken(receipt).accrue();
        uint256 backing = asset.balanceOf(receipt);
        require(desired <= backing, "liquidity exceeds assets");
        uint256 nextDebt = backing - desired;
        uint256 previous = debt.totalSupply();
        if (nextDebt > previous) debt.adjust(address(this), nextDebt - previous, true);
        else if (nextDebt < previous) debt.adjust(address(this), previous - nextDebt, false);
    }
}
