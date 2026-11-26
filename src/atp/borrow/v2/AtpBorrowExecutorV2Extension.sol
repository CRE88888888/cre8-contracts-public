// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { RoutingTypes as R } from "./RoutingTypes.sol";
import { StrategyBox } from "./StrategyBox.sol";
import { IStrategyVaultAdapter } from "./IStrategyVaultAdapter.sol";
import { IAtpBorrowExecutorV2 as IExec } from "./IAtpBorrowExecutorV2.sol";
import { AtpBorrowRegistryV2 } from "./AtpBorrowRegistryV2.sol";
import { AtpBorrowLensV2 } from "./AtpBorrowLensV2.sol";
import { RoutingExecutorBase } from "./RoutingExecutorBase.sol";

interface IExecutorPins {
    function borrowRegistry() external view returns (address);
    function lens() external view returns (address);
    function boxImplementation() external view returns (address);
}

/// @title AtpBorrowExecutorV2Extension
/// @notice The second half of `AtpBorrowExecutorV2`'s code: the entry points that only touch the strategy box
/// and its vaults (switch vault, release, rescue, rewards). The executor delegatecalls here for every selector
/// it does not implement itself, so these functions run as the executor: same address, same reentrancy flag,
/// same boxes. This contract has no state and no immutables of its own (it reads the executor's pins through
/// `address(this)`), and refuses to run when called directly.
contract AtpBorrowExecutorV2Extension is RoutingExecutorBase {
    using SafeERC20 for IERC20;

    address private immutable _self = address(this);

    error OnlyDelegated();

    modifier delegated() {
        if (address(this) == _self) revert OnlyDelegated();
        _;
    }

    function _registry() internal view override returns (AtpBorrowRegistryV2) {
        return AtpBorrowRegistryV2(IExecutorPins(address(this)).borrowRegistry());
    }

    function _lensOf() internal view override returns (AtpBorrowLensV2) {
        return AtpBorrowLensV2(IExecutorPins(address(this)).lens());
    }

    function _boxImplementation() internal view override returns (address) {
        return IExecutorPins(address(this)).boxImplementation();
    }

    /// @notice See `IAtpBorrowExecutorV2.executeSwitchVault`. The destination must pass the same deposit
    /// gates as a new borrow's vault: open, not above the 90% utilization line where that can be read, and
    /// the account's consent live and not paused.
    function executeSwitchVault(
        address account,
        bytes32 fromVaultId,
        bytes32 toVaultId,
        uint256 amount,
        uint256 deadline
    ) external delegated nonReentrant {
        _caller(account, deadline);
        if (amount == 0) revert IExec.ZeroAmount();
        if (fromVaultId == toVaultId) revert IExec.SameRoute();
        AtpBorrowRegistryV2 reg = _registry();
        (R.Vault memory from, address fromAdapter) = reg.vaultFor(fromVaultId);
        (R.Vault memory to, address toAdapter) = reg.beforeSwitch(account, toVaultId);
        if (from.token != to.token) revert IExec.TokenMismatch();
        _lensOf().requireDepositOpen(toVaultId);
        IERC20 token = IERC20(from.token);
        uint256 base = token.balanceOf(address(this));
        IStrategyVaultAdapter(fromAdapter)
            .withdraw(from.target, from.token, amount, _boxOf(account), address(this));
        uint256 received = token.balanceOf(address(this)) - base;
        if (received == 0) revert IExec.InexactTransfer();
        _untrack(account, fromVaultId, from);
        _deposit(to, toAdapter, toVaultId, account, received);
        if (token.balanceOf(address(this)) != base) revert IExec.InexactTransfer();
        emit IExec.VaultSwitched(account, fromVaultId, toVaultId, received);
    }

    /// @notice See `IAtpBorrowExecutorV2.executeRelease`.
    function executeRelease(address account, bytes32 vaultId, uint256 deadline)
        external
        delegated
        nonReentrant
    {
        _caller(account, deadline);
        address token = _registry().vault(vaultId).token;
        _lensOf().requireNoDebt(account, token);
        if (_release(account, vaultId, token, false) == 0) revert IExec.NothingToDo();
    }

    /// @notice See `IAtpBorrowExecutorV2.executeRescue`: the receipts themselves, as they are, back to the
    /// account. It never calls the vault or its adapter, so it works when either is broken.
    function executeRescue(address account, bytes32 vaultId, uint256 deadline)
        external
        delegated
        nonReentrant
    {
        _caller(account, deadline);
        AtpBorrowRegistryV2 reg = _registry();
        R.Vault memory v = reg.vault(vaultId);
        _lensOf().requireNoDebt(account, v.token);
        uint256 amount = _boxSend(account, v.receipt, account);
        if (amount == 0) revert IExec.NothingToDo();
        reg.recordVault(account, vaultId, false);
        emit IExec.Rescued(account, vaultId, v.receipt, amount);
    }

    /// @notice See `IAtpBorrowExecutorV2.collectRewards`.
    function collectRewards(address account, address token)
        external
        delegated
        nonReentrant
        returns (uint256 amount)
    {
        (bool ok,) = _registry().rewardRoute(account, token, false);
        if (!ok) revert IExec.RewardNotAllowed(token);
        amount = _boxSend(account, token, account);
        if (amount != 0) emit IExec.RewardsCollected(account, token, amount);
    }

    /// @notice See `IAtpBorrowExecutorV2.executeSweepRewards`.
    function executeSweepRewards(address account, address token, uint256 accountAmount, uint256 deadline)
        external
        delegated
        nonReentrant
    {
        _caller(account, deadline);
        // From the account itself only for tokens its strategy never trades: holdings are not rewards.
        (bool ok, address recipient) = _registry().rewardRoute(account, token, accountAmount != 0);
        if (!ok) revert IExec.RewardNotAllowed(token);
        uint256 amount = _boxSend(account, token, recipient);
        if (accountAmount != 0 && recipient != account) {
            accountAmount = Math.min(accountAmount, IERC20(token).balanceOf(account));
            IERC20(token).safeTransferFrom(account, recipient, accountAmount);
            amount += accountAmount;
        }
        if (amount == 0) revert IExec.NothingToDo();
        emit IExec.RewardsSwept(account, token, recipient, amount);
    }
}
