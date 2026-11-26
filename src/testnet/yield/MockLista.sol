// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { ERC20, IERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ERC4626 } from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { TestnetToken } from "../TestnetToken.sol";
import { MoolahParams, MoolahMarket } from "../../atp/yield/YieldInterfaces.sol";

/// @notice Chain-97-only ERC4626 vault with a bounded Moolah-style queue and partial-liquidity semantics.
contract MockLista is ERC4626 {
    using SafeERC20 for IERC20;
    address public immutable owner;
    uint16 public aprBps;
    uint16 public exitFeeBps;
    uint256 public lastAccrual;
    uint256 public totalBorrows;
    bool public paused;
    bool public supplyPaused;
    uint96 public fee;
    address public riskCore;
    uint256 public lastTotalAssets;
    uint256 public supplyCapAssets;
    address public immutable feeRecipient;
    bytes32 public constant MARKET = keccak256("CRE8 mock Lista adaptive market");
    event SimulatedAprSet(uint16 aprBps);
    modifier onlyOwner() {
        require(msg.sender == owner, "yield mock: owner only");
        _;
    }

    constructor(TestnetToken asset_, address owner_, uint16 apr)
        ERC20("Mock Lista vault", "mLista")
        ERC4626(IERC20(address(asset_)))
    {
        require(block.chainid == 97, "yield mock: chain 97 only");
        require(
            address(asset_).code.length != 0 && owner_ != address(0) && apr <= 10_000, "yield mock: config"
        );
        owner = owner_;
        aprBps = apr;
        lastAccrual = block.timestamp;
        riskCore = address(this);
        feeRecipient = owner_;
    }

    function _decimalsOffset() internal view override returns (uint8) {
        uint8 d = TestnetToken(asset()).decimals();
        return d < 18 ? 18 - d : 0;
    }

    function implementation() external view returns (address) {
        return address(this);
    }

    function isTestnetYieldMock() external pure returns (bool) {
        return true;
    }

    function MOOLAH() external view returns (address) {
        return riskCore;
    }

    function supplyQueueLength() external pure returns (uint256) {
        return 1;
    }

    function withdrawQueueLength() external pure returns (uint256) {
        return 1;
    }

    function supplyQueue(uint256 i) external pure returns (bytes32) {
        require(i == 0, "queue bounds");
        return MARKET;
    }

    function withdrawQueue(uint256 i) external pure returns (bytes32) {
        require(i == 0, "queue bounds");
        return MARKET;
    }

    function config(bytes32 id) external view returns (uint184, bool, uint64) {
        require(id == MARKET, "unknown market");
        return (supplyCapAssets == 0 ? type(uint184).max : uint184(supplyCapAssets), true, 0);
    }

    function idToMarketParams(bytes32 id) external view returns (MoolahParams memory) {
        require(id == MARKET, "unknown market");
        return MoolahParams(asset(), address(0), address(0), address(this), 0);
    }

    function market(bytes32 id) external view returns (MoolahMarket memory) {
        require(id == MARKET, "unknown market");
        return MoolahMarket(
            uint128(totalAssets()),
            uint128(totalSupply()),
            uint128(totalBorrows),
            uint128(totalBorrows),
            uint128(lastAccrual),
            0
        );
    }

    function position(bytes32 id, address vault) external view returns (uint256, uint128, uint128) {
        require(id == MARKET, "unknown market");
        return (vault == address(this) ? totalSupply() : 0, 0, 0);
    }

    function _interest() private view returns (uint256) {
        return Math.mulDiv(
            super.totalAssets(), uint256(aprBps) * (block.timestamp - lastAccrual), 365 days * 10_000
        );
    }

    function totalAssets() public view override returns (uint256) {
        return super.totalAssets() + _interest();
    }

    function accrueInterest(MoolahParams memory) external {
        accrue();
    }

    function accrue() public {
        uint256 interest = _interest();
        lastAccrual = block.timestamp;
        if (interest != 0) TestnetToken(asset()).mint(address(this), interest);
    }

    function _pendingFeeShares(uint256 assets) private view returns (uint256) {
        uint256 interest = assets > lastTotalAssets ? assets - lastTotalAssets : 0;
        uint256 feeAssets = Math.mulDiv(interest, fee, 1e18);
        return feeAssets == 0
            ? 0
            : Math.mulDiv(feeAssets, totalSupply() + 10 ** _decimalsOffset(), assets - feeAssets + 1);
    }

    function _accrueFee() private {
        accrue();
        uint256 assets = totalAssets();
        uint256 shares = _pendingFeeShares(assets);
        if (shares != 0) _mint(feeRecipient, shares);
        lastTotalAssets = assets;
    }

    function _convertToShares(uint256 assets, Math.Rounding rounding)
        internal
        view
        override
        returns (uint256)
    {
        uint256 managed = totalAssets();
        return Math.mulDiv(
            assets,
            totalSupply() + _pendingFeeShares(managed) + 10 ** _decimalsOffset(),
            managed + 1,
            rounding
        );
    }

    function _convertToAssets(uint256 shares, Math.Rounding rounding)
        internal
        view
        override
        returns (uint256)
    {
        uint256 managed = totalAssets();
        return Math.mulDiv(
            shares,
            managed + 1,
            totalSupply() + _pendingFeeShares(managed) + 10 ** _decimalsOffset(),
            rounding
        );
    }

    function maxDeposit(address) public view override returns (uint256) {
        if (paused || supplyPaused) return 0;
        if (supplyCapAssets == 0) return type(uint256).max;
        return supplyCapAssets > totalAssets() ? supplyCapAssets - totalAssets() : 0;
    }

    function maxMint(address account) public view override returns (uint256) {
        uint256 available = maxDeposit(account);
        return available == type(uint256).max ? available : convertToShares(available);
    }

    function maxWithdraw(address account) public view override returns (uint256) {
        return paused
            ? 0
            : Math.min(
                previewRedeem(balanceOf(account)),
                IERC20(asset()).balanceOf(address(this)) - totalBorrows + _interest()
            );
    }

    function maxRedeem(address account) public view override returns (uint256) {
        if (paused) return 0;
        uint256 cash = Math.min(
            previewRedeem(balanceOf(account)),
            IERC20(asset()).balanceOf(address(this)) - totalBorrows + _interest()
        );
        uint256 shares = super.convertToShares(Math.mulDiv(cash, 10_000, 10_000 - exitFeeBps));
        return Math.min(balanceOf(account), shares);
    }

    function previewRedeem(uint256 shares) public view override returns (uint256) {
        return Math.mulDiv(super.previewRedeem(shares), 10_000 - exitFeeBps, 10_000);
    }

    function deposit(uint256 assets, address receiver) public override returns (uint256) {
        _accrueFee();
        uint256 shares = super.deposit(assets, receiver);
        lastTotalAssets = totalAssets();
        return shares;
    }

    function mint(uint256 shares, address receiver) public override returns (uint256) {
        _accrueFee();
        uint256 assets = super.mint(shares, receiver);
        lastTotalAssets = totalAssets();
        return assets;
    }

    function withdraw(uint256 assets, address receiver, address account) public override returns (uint256) {
        _accrueFee();
        uint256 shares = super.withdraw(assets, receiver, account);
        lastTotalAssets = totalAssets();
        return shares;
    }

    function previewWithdraw(uint256 assets) public view override returns (uint256) {
        return super.previewWithdraw(Math.mulDiv(assets, 10_000, 10_000 - exitFeeBps, Math.Rounding.Ceil));
    }

    /// @dev Like MoolahVault, redeem optimistically calls the real withdrawal instead of treating the
    /// conservatively rounded maxRedeem as a hard bound. Cash/pause and exact assets still bind atomically.
    function redeem(uint256 shares, address receiver, address account)
        public
        override
        returns (uint256 assets)
    {
        _accrueFee();
        assets = previewRedeem(shares);
        require(
            !paused && assets <= IERC20(asset()).balanceOf(address(this)) - totalBorrows,
            "withdraw unavailable"
        );
        _withdraw(msg.sender, receiver, account, assets, shares);
        lastTotalAssets = totalAssets();
    }

    function setAprBps(uint16 apr) external onlyOwner {
        require(apr <= 10_000, "APR cap");
        accrue();
        aprBps = apr;
        emit SimulatedAprSet(apr);
    }

    function setLiquidity(uint256 desired) external onlyOwner {
        accrue();
        uint256 cash = IERC20(asset()).balanceOf(address(this));
        require(desired <= cash, "liquidity exceeds assets");
        totalBorrows = cash - desired;
    }
}
