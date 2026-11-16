// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { SafeERC20, IERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { TestnetToken } from "../TestnetToken.sol";

/// @notice Chain-97-only Compound v2 ABI mock. APR is simulated, fixed and owner adjustable, in bps.
contract MockVenus is ERC20 {
    using SafeERC20 for IERC20;
    TestnetToken public immutable underlying;
    address public immutable owner;
    uint16 public aprBps;
    uint256 public exchangeRateStored;
    uint256 public totalBorrows;
    uint256 public totalReserves;
    uint256 public lastAccrual;
    uint256 public accrualBlockNumber;
    bool public supplyPaused;
    bool public redeemPaused;
    uint256 public mintError;
    uint256 public redeemError;
    uint256 public supplyCapAssets;
    uint256 public constant BLOCKS_PER_YEAR = 70_080_000;
    event SimulatedAprSet(uint16 aprBps);
    modifier onlyOwner() {
        require(msg.sender == owner, "yield mock: owner only");
        _;
    }

    constructor(TestnetToken asset, address owner_, uint16 apr) ERC20("Mock Venus receipt", "mvToken") {
        require(block.chainid == 97, "yield mock: chain 97 only");
        require(
            address(asset).code.length != 0 && owner_ != address(0) && asset.decimals() <= 18
                && apr <= 10_000,
            "yield mock: config"
        );
        underlying = asset;
        owner = owner_;
        aprBps = apr;
        exchangeRateStored = 10 ** (uint256(asset.decimals()) + 10);
        lastAccrual = block.timestamp;
        accrualBlockNumber = block.number;
    }

    function decimals() public pure override returns (uint8) {
        return 8;
    }

    function isTestnetYieldMock() external pure returns (bool) {
        return true;
    }

    function comptroller() external view returns (address) {
        return address(this);
    }

    function interestRateModel() external view returns (address) {
        return address(this);
    }

    function implementation() external view returns (address) {
        return address(this);
    }

    function actionPaused(address market, uint8 action) external view returns (bool) {
        require(market == address(this), "market mismatch");
        return action == 0 ? supplyPaused : redeemPaused;
    }

    function getCash() public view returns (uint256) {
        return underlying.balanceOf(address(this)) - totalBorrows;
    }

    function supplyCaps(address market) external view returns (uint256) {
        require(market == address(this), "market mismatch");
        return supplyCapAssets;
    }

    function supplyRatePerBlock() external view returns (uint256) {
        return uint256(aprBps) * 1e18 / (10_000 * BLOCKS_PER_YEAR);
    }

    function accrueInterest() public returns (uint256) {
        accrualBlockNumber = block.number;
        uint256 elapsed = block.timestamp - lastAccrual;
        if (elapsed != 0) {
            uint256 liability = Math.mulDiv(totalSupply(), exchangeRateStored, 1e18);
            uint256 interest = Math.mulDiv(liability, uint256(aprBps) * elapsed, 365 days * 10_000);
            if (interest != 0 && totalSupply() != 0) {
                underlying.mint(address(this), interest);
                exchangeRateStored += Math.mulDiv(interest, 1e18, totalSupply());
            }
            lastAccrual = block.timestamp;
        }
        return 0;
    }

    function mint(uint256 assets) public virtual returns (uint256) {
        accrueInterest();
        if (mintError != 0) return mintError;
        if (supplyPaused) return 1;
        if (supplyCapAssets != 0 && getCash() + totalBorrows - totalReserves + assets > supplyCapAssets) {
            return 3;
        }
        uint256 shares = Math.mulDiv(assets, 1e18, exchangeRateStored);
        IERC20(address(underlying)).safeTransferFrom(msg.sender, address(this), assets);
        _mint(msg.sender, shares);
        return 0;
    }

    function redeem(uint256 shares) public virtual returns (uint256) {
        accrueInterest();
        if (redeemError != 0) return redeemError;
        uint256 assets = Math.mulDiv(shares, exchangeRateStored, 1e18);
        if (redeemPaused || assets > getCash()) return 2;
        _burn(msg.sender, shares);
        IERC20(address(underlying)).safeTransfer(msg.sender, assets);
        return 0;
    }

    function setAprBps(uint16 apr) external onlyOwner {
        require(apr <= 10_000, "APR cap");
        accrueInterest();
        aprBps = apr;
        emit SimulatedAprSet(apr);
    }

    /// @notice Simulates unavailable cash by internal accounting; underlying never leaves this mock.
    function setLiquidity(uint256 desired) external onlyOwner {
        accrueInterest();
        uint256 cash = underlying.balanceOf(address(this));
        require(desired <= cash, "liquidity exceeds assets");
        totalBorrows = cash - desired;
    }
}
