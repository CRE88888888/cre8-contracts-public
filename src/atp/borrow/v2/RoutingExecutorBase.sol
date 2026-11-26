// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { RoutingTypes as R } from "./RoutingTypes.sol";
import { StrategyBox } from "./StrategyBox.sol";
import { IStrategyVaultAdapter } from "./IStrategyVaultAdapter.sol";
import { IAtpBorrowExecutorV2 as IExec } from "./IAtpBorrowExecutorV2.sol";
import { AtpBorrowRegistryV2 } from "./AtpBorrowRegistryV2.sol";
import { AtpBorrowLensV2 } from "./AtpBorrowLensV2.sol";

/// @notice What `AtpBorrowExecutorV2` and its extension share: the caller rule, the strategy box and the vault
/// plumbing. The executor is one address with one storage (the reentrancy flag in slot 0); its code is split in
/// two contracts only because of the 24 KB limit, and the extension runs by delegatecall, so both parts see the
/// same `address(this)`, the same flag and the same boxes.
abstract contract RoutingExecutorBase is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 internal constant MAX = type(uint256).max;

    function _registry() internal view virtual returns (AtpBorrowRegistryV2);

    function _lensOf() internal view virtual returns (AtpBorrowLensV2);

    function _boxImplementation() internal view virtual returns (address);

    function _boxOf(address account) internal view returns (address) {
        return Clones.predictDeterministicAddress(_boxImplementation(), bytes32(uint256(uint160(account))));
    }

    function _caller(address account, uint256 deadline) internal view {
        if (msg.sender != account) revert IExec.NotAccount();
        if (account.code.length == 0) revert IExec.NotContract();
        if (block.timestamp > deadline) revert IExec.DeadlineExpired();
    }

    function _box(address account) internal returns (address box) {
        box = _boxOf(account);
        if (box.code.length == 0) {
            Clones.cloneDeterministic(_boxImplementation(), bytes32(uint256(uint160(account))));
            StrategyBox(box).init(account);
            emit IExec.BoxCreated(account, box);
        }
    }

    /// @dev `amount` of the vault's token is in this contract; supply it for the account's box.
    function _deposit(R.Vault memory v, address adapter, bytes32 vaultId, address account, uint256 amount)
        internal
    {
        address box = _box(account);
        IERC20 receipt = IERC20(v.receipt);
        if (receipt.allowance(box, adapter) == 0) StrategyBox(box).approve(receipt, adapter);
        uint256 before = receipt.balanceOf(box);
        IERC20(v.token).safeTransfer(adapter, amount);
        uint256 credited = IStrategyVaultAdapter(adapter).deposit(v.target, v.token, amount, box);
        // Share rounding on the way in may lose dust (a Venus vToken unit is ~1e8 raw units), never more
        // than a basis point: a vault that takes a deposit fee, or whose share price was inflated, is refused.
        if (receipt.balanceOf(box) <= before || credited < amount - amount / 10_000 - 2) {
            revert IExec.InexactTransfer();
        }
        _registry().recordVault(account, vaultId, true);
    }

    /// @dev Exit paths only ever remove a vault from the account's list (a full list can never block an exit).
    function _untrack(address account, bytes32 vaultId, R.Vault memory v) internal {
        if (IERC20(v.receipt).balanceOf(_boxOf(account)) == 0) {
            _registry().recordVault(account, vaultId, false);
        }
    }

    /// @dev Everything the account's box holds of `token` goes to `to`.
    function _boxSend(address account, address token, address to) internal returns (uint256 amount) {
        address box = _boxOf(account);
        if (box.code.length == 0) return 0;
        amount = IERC20(token).balanceOf(box);
        if (amount != 0) StrategyBox(box).send(IERC20(token), to, amount);
    }

    /// @dev Pay the box's whole holding in the vault to the account, with any of the vault's token that sits
    /// in the box itself. `soft`: a vault that cannot pay now leaves the holding in the box for a later
    /// `executeRelease` instead of failing the close. One call into the vault at most.
    function _release(address account, bytes32 vaultId, address token, bool soft)
        internal
        returns (uint256 out)
    {
        (R.Vault memory v, address adapter) = _registry().vaultFor(vaultId);
        if (v.token != token) revert IExec.TokenMismatch();
        address box = _boxOf(account);
        if (box.code.length == 0) return 0;
        if (IERC20(v.receipt).balanceOf(box) != 0) {
            try IStrategyVaultAdapter(adapter).withdraw(v.target, v.token, MAX, box, account) returns (
                uint256 x
            ) {
                out = x;
            } catch {
                if (!soft) revert IExec.VaultShortfall(0, 0);
            }
            _untrack(account, vaultId, v);
        }
        out += _boxSend(account, token, account);
        if (out != 0) emit IExec.Released(account, vaultId, out);
    }
}
