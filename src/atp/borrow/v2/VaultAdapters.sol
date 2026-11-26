// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { IStrategyVaultAdapter } from "./IStrategyVaultAdapter.sol";
import { RoutingTypes as R } from "./RoutingTypes.sol";

interface IAdapterExecutor {
    function borrowRegistry() external view returns (address);
}

interface IAdapterRegistry {
    function venusComptroller() external view returns (address);
    function venusBlocksPerYear() external view returns (uint256);
}

interface IAdapterVToken is IERC20 {
    function underlying() external view returns (address);
    function comptroller() external view returns (address);
    function accrueInterest() external returns (uint256);
    function exchangeRateStored() external view returns (uint256);
    function supplyRatePerBlock() external view returns (uint256);
    function getCash() external view returns (uint256);
    function totalBorrows() external view returns (uint256);
    function totalReserves() external view returns (uint256);
    function mintBehalf(address receiver, uint256 amount) external returns (uint256);
    function redeem(uint256 tokens) external returns (uint256);
    function redeemUnderlying(uint256 amount) external returns (uint256);
}

interface IAdapterComptroller {
    function markets(address vToken) external view returns (bool, uint256, bool);
}

interface IAdapterAToken is IERC20 {
    function UNDERLYING_ASSET_ADDRESS() external view returns (address);
    function POOL() external view returns (address);
}

interface IAdapterAavePool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
}

/// @dev Shared guard: adapters only obey the executor that was fixed at deployment.
abstract contract VaultAdapterBase is IStrategyVaultAdapter {
    using SafeERC20 for IERC20;

    address public immutable executor;

    error NotExecutor();
    error BadVault();
    error ProtocolError(uint256 code);

    constructor(address executor_) {
        if (executor_.code.length == 0) revert BadVault();
        executor = executor_;
    }

    modifier onlyExecutor() {
        if (msg.sender != executor) revert NotExecutor();
        _;
    }

    function _ok(uint256 code) internal pure {
        if (code != 0) revert ProtocolError(code);
    }

    function _util(uint256 borrows, uint256 supplied) internal pure returns (uint256) {
        if (supplied == 0) return 10_000;
        return Math.min(Math.mulDiv(borrows, 10_000, supplied, Math.Rounding.Ceil), 10_000);
    }
}

/// @notice ERC4626 vaults (Lista Moolah vaults). `target` = the vault = the receipt.
/// The rate and utilization of a Lista vault depend on every market in its withdraw queue (22 to 142 on
/// mainnet), which is too much to walk in a transaction, so both read as unknown here and the registry falls
/// back to the reported rate.
/// @dev Every state-changing call into a Lista vault, and every `totalAssets()` / `preview*` read, walks that
/// queue (about 2M gas a read and 6M a withdrawal on the USD1 vault). So this adapter prices shares from the
/// vault's stored `lastTotalAssets()` where the vault has one (it is refreshed by every deposit and
/// withdrawal, anyone's), and calls the vault exactly once per deposit or withdrawal.
contract Erc4626VaultAdapter is VaultAdapterBase {
    using SafeERC20 for IERC20;

    /// @notice A vault must already hold this many whole tokens to be listed: an empty or near-empty ERC4626
    /// vault can have its share price inflated by a donation.
    uint256 public constant MIN_LISTED_ASSETS = 1_000;

    constructor(address executor_) VaultAdapterBase(executor_) { }

    function kind() external pure returns (uint8) {
        return uint8(R.VaultKind.ERC4626);
    }

    function validate(address target, address token) external view returns (address) {
        if (target.code.length == 0 || IERC4626(target).asset() != token) revert BadVault();
        // Checked once here, not on every deposit: a deposit must be redeemable for its value (no entry or
        // exit fee), and the vault must be large enough that nobody can move its share price with a donation.
        uint256 probe = 10 ** IERC20Metadata(token).decimals();
        if (
            IERC4626(target).totalAssets() < MIN_LISTED_ASSETS * probe
                || IERC4626(target).previewRedeem(IERC4626(target).previewDeposit(probe))
                    < probe - probe / 10_000
        ) revert BadVault();
        return target;
    }

    function deposit(address target, address token, uint256 assets, address holder)
        external
        onlyExecutor
        returns (uint256)
    {
        uint256 shares = IERC20(target).balanceOf(holder);
        IERC20(token).forceApprove(target, assets);
        IERC4626(target).deposit(assets, holder);
        IERC20(token).forceApprove(target, 0);
        shares = IERC20(target).balanceOf(holder) - shares;
        // What the shares that actually arrived are worth now, at the share price the deposit just stored.
        (bool stored, uint256 total) = _lastTotalAssets(target);
        if (!stored) return IERC4626(target).previewRedeem(shares);
        return Math.mulDiv(shares, total + 1, IERC20(target).totalSupply() + _virtualShares(target, token));
    }

    /// @dev "Up to": redeems the shares that cover `assets`, or all of them when the holder has fewer. Never
    /// reverts for a short holding. With a stored total the share count is an upper estimate (interest since
    /// the last update is not in it), so `to` may receive slightly more than asked.
    function withdraw(address target, address token, uint256 assets, address holder, address to)
        external
        onlyExecutor
        returns (uint256 received)
    {
        uint256 shares = IERC20(target).balanceOf(holder);
        if (shares == 0) return 0;
        if (assets != type(uint256).max) {
            (bool stored, uint256 total) = _lastTotalAssets(target);
            uint256 need = stored
                ? Math.mulDiv(
                    assets,
                    IERC20(target).totalSupply() + _virtualShares(target, token),
                    total + 1,
                    Math.Rounding.Ceil
                )
                : IERC4626(target).previewWithdraw(assets);
            if (need < shares) shares = need;
        }
        uint256 before = IERC20(token).balanceOf(to);
        IERC4626(target).redeem(shares, to, holder);
        received = IERC20(token).balanceOf(to) - before;
    }

    function accrue(address, address) external { }

    function assetsOf(address target, address, address holder) external view returns (uint256) {
        uint256 shares = IERC20(target).balanceOf(holder);
        return shares == 0 ? 0 : IERC4626(target).previewRedeem(shares);
    }

    function supplyRate(address, address) external pure returns (bool, uint256) {
        return (false, 0);
    }

    function utilizationBps(address, address) external pure returns (bool, uint256) {
        return (false, 0);
    }

    /// @dev MetaMorpho-style vaults (Lista) store the total they last accounted for.
    function _lastTotalAssets(address target) private view returns (bool, uint256) {
        (bool ok, bytes memory ret) = target.staticcall(abi.encodeWithSignature("lastTotalAssets()"));
        if (!ok || ret.length != 32) return (false, 0);
        uint256 total = abi.decode(ret, (uint256));
        return (total != 0, total);
    }

    /// @dev 10 ** (share decimals - asset decimals): the virtual shares of the ERC4626 inflation offset.
    function _virtualShares(address target, address token) private view returns (uint256) {
        return 10 ** (IERC20Metadata(target).decimals() - IERC20Metadata(token).decimals());
    }
}

/// @notice Venus core pool supply. `target` = the vToken = the receipt. The box only ever holds vTokens of
/// loan tokens it never borrows against, so moving them needs no comptroller liquidity.
contract VenusVaultAdapter is VaultAdapterBase {
    using SafeERC20 for IERC20;

    IAdapterRegistry public immutable registry;

    constructor(address executor_) VaultAdapterBase(executor_) {
        registry = IAdapterRegistry(IAdapterExecutor(executor_).borrowRegistry());
    }

    function kind() external pure returns (uint8) {
        return uint8(R.VaultKind.VENUS);
    }

    function validate(address target, address token) external view returns (address) {
        address comptroller = registry.venusComptroller();
        if (target.code.length == 0 || comptroller == address(0)) revert BadVault();
        IAdapterVToken v = IAdapterVToken(target);
        (bool listed,,) = IAdapterComptroller(comptroller).markets(target);
        if (!listed || v.underlying() != token || v.comptroller() != comptroller) revert BadVault();
        return target;
    }

    function deposit(address target, address token, uint256 assets, address holder)
        external
        onlyExecutor
        returns (uint256)
    {
        IAdapterVToken v = IAdapterVToken(target);
        uint256 before = v.balanceOf(holder);
        IERC20(token).forceApprove(target, assets);
        _ok(v.mintBehalf(holder, assets));
        IERC20(token).forceApprove(target, 0);
        return Math.mulDiv(v.balanceOf(holder) - before, v.exchangeRateStored(), 1e18);
    }

    function withdraw(address target, address token, uint256 assets, address holder, address to)
        external
        onlyExecutor
        returns (uint256 received)
    {
        IAdapterVToken v = IAdapterVToken(target);
        _ok(v.accrueInterest());
        uint256 held = v.balanceOf(holder);
        if (held == 0) return 0;
        uint256 base = IERC20(token).balanceOf(address(this));
        // "Up to": the vTokens that cover `assets`, rounded up, or all of them when the holder has fewer.
        uint256 tokens = assets == type(uint256).max
            ? held
            : Math.mulDiv(assets, 1e18, v.exchangeRateStored(), Math.Rounding.Ceil) + 1;
        if (tokens >= held) {
            IERC20(target).safeTransferFrom(holder, address(this), held);
            _ok(v.redeem(held));
        } else {
            IERC20(target).safeTransferFrom(holder, address(this), tokens);
            _ok(v.redeemUnderlying(assets));
            uint256 rest = v.balanceOf(address(this));
            if (rest != 0) IERC20(target).safeTransfer(holder, rest);
        }
        received = IERC20(token).balanceOf(address(this)) - base;
        IERC20(token).safeTransfer(to, received);
    }

    function accrue(address target, address) external {
        _ok(IAdapterVToken(target).accrueInterest());
    }

    function assetsOf(address target, address, address holder) external view returns (uint256) {
        IAdapterVToken v = IAdapterVToken(target);
        return Math.mulDiv(v.balanceOf(holder), v.exchangeRateStored(), 1e18);
    }

    function supplyRate(address target, address) external view returns (bool, uint256) {
        return (true, IAdapterVToken(target).supplyRatePerBlock() * registry.venusBlocksPerYear());
    }

    function utilizationBps(address target, address) external view returns (bool, uint256) {
        IAdapterVToken v = IAdapterVToken(target);
        uint256 borrows = v.totalBorrows();
        uint256 gross = v.getCash() + borrows;
        uint256 reserves = v.totalReserves();
        return (true, _util(borrows, gross > reserves ? gross - reserves : 0));
    }
}

/// @notice Aave v3 supply. `target` = the Pool; the receipt is the reserve's aToken.
contract AaveVaultAdapter is VaultAdapterBase {
    using SafeERC20 for IERC20;

    constructor(address executor_) VaultAdapterBase(executor_) { }

    function kind() external pure returns (uint8) {
        return uint8(R.VaultKind.AAVE);
    }

    function validate(address target, address token) external view returns (address receipt) {
        if (target.code.length == 0) revert BadVault();
        receipt = address(uint160(_reserveWord(target, token, 8)));
        if (
            receipt.code.length == 0 || IAdapterAToken(receipt).UNDERLYING_ASSET_ADDRESS() != token
                || IAdapterAToken(receipt).POOL() != target
        ) revert BadVault();
    }

    function deposit(address target, address token, uint256 assets, address holder)
        external
        onlyExecutor
        returns (uint256)
    {
        IERC20 aToken = IERC20(address(uint160(_reserveWord(target, token, 8))));
        uint256 before = aToken.balanceOf(holder);
        IERC20(token).forceApprove(target, assets);
        IAdapterAavePool(target).supply(token, assets, holder, 0);
        IERC20(token).forceApprove(target, 0);
        return aToken.balanceOf(holder) - before;
    }

    function withdraw(address target, address token, uint256 assets, address holder, address to)
        external
        onlyExecutor
        returns (uint256 received)
    {
        IERC20 aToken = IERC20(address(uint160(_reserveWord(target, token, 8))));
        uint256 held = aToken.balanceOf(holder);
        bool all = assets == type(uint256).max;
        if (held == 0) return 0;
        // aToken balances are scaled: a transfer can land a unit short. Move a little more than asked (never
        // more than is held), withdraw exactly what was asked, and hand the rest straight back.
        aToken.safeTransferFrom(holder, address(this), all ? held : Math.min(held, assets + 2));
        uint256 before = IERC20(token).balanceOf(to);
        IAdapterAavePool(target)
            .withdraw(token, all ? type(uint256).max : Math.min(assets, aToken.balanceOf(address(this))), to);
        uint256 rest = aToken.balanceOf(address(this));
        if (rest != 0) aToken.safeTransfer(holder, rest);
        received = IERC20(token).balanceOf(to) - before;
    }

    function accrue(address, address) external { }

    function assetsOf(address target, address token, address holder) external view returns (uint256) {
        return IERC20(address(uint160(_reserveWord(target, token, 8)))).balanceOf(holder);
    }

    /// @dev `currentLiquidityRate` is a yearly rate in ray.
    function supplyRate(address target, address token) external view returns (bool, uint256) {
        return (true, _reserveWord(target, token, 2) / 1e9);
    }

    function utilizationBps(address target, address token) external view returns (bool, uint256) {
        address aToken = address(uint160(_reserveWord(target, token, 8)));
        uint256 borrowed = IERC20(address(uint160(_reserveWord(target, token, 10)))).totalSupply();
        (bool ok, bytes memory ret) =
            target.staticcall(abi.encodeWithSignature("getVirtualUnderlyingBalance(address)", token));
        uint256 liquidity = IERC20(token).balanceOf(aToken);
        if (ok && ret.length == 32) liquidity = Math.min(liquidity, abi.decode(ret, (uint256)));
        return (true, _util(borrowed, liquidity + borrowed));
    }

    /// @dev Word `index` of `Pool.getReserveData(token)` (2 = currentLiquidityRate, 8 = aToken, 10 = variable
    /// debt token), the layout Aave v3 keeps across versions.
    function _reserveWord(address pool, address token, uint256 index) private view returns (uint256 value) {
        (bool ok, bytes memory data) =
            pool.staticcall(abi.encodeWithSignature("getReserveData(address)", token));
        if (!ok || data.length < (index + 1) * 32) revert BadVault();
        assembly {
            value := mload(add(add(data, 32), mul(index, 32)))
        }
    }
}
