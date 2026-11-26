// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { YieldTypes as Y } from "./YieldTypes.sol";
import { YieldReader } from "./YieldReader.sol";
import { IVToken, IListaVault, IAavePool } from "./YieldInterfaces.sol";

/// @notice Typed mainnet-compatible actions, inlined into the executor. No configurable calldata or receiver.
library YieldActions {
    using SafeERC20 for IERC20;
    error ProtocolError(uint256 code);
    error InexactTransfer();
    error InsufficientOutput(uint256 received, uint256 minimum);

    function supply(Y.Market memory m, address account, uint256 amount, uint256 minimum)
        internal
        returns (uint256 received)
    {
        IERC20 asset = IERC20(m.asset);
        IERC20 receipt = IERC20(m.receipt);
        uint256 base = asset.balanceOf(address(this));
        uint256 receiptBase = receipt.balanceOf(address(this));
        uint256 before = receipt.balanceOf(account);
        uint256 accountAssets = asset.balanceOf(account);
        asset.safeTransferFrom(account, address(this), amount);
        if (asset.balanceOf(address(this)) - base != amount) revert InexactTransfer();
        asset.forceApprove(m.target, amount);
        if (m.kind == Y.Kind.VENUS) {
            uint256 code = IVToken(m.target).mint(amount);
            if (code != 0) revert ProtocolError(code);
            receipt.safeTransfer(account, receipt.balanceOf(address(this)) - receiptBase);
        } else if (m.kind == Y.Kind.LISTA) {
            uint256 declared = IListaVault(m.target).deposit(amount, account);
            if (declared != receipt.balanceOf(account) - before) revert InexactTransfer();
        } else if (m.kind == Y.Kind.AAVE) {
            IAavePool(m.target).supply(m.asset, amount, account, 0);
        } else {
            revert InexactTransfer();
        }
        asset.forceApprove(m.target, 0);
        if (asset.balanceOf(address(this)) != base || receipt.balanceOf(address(this)) != receiptBase) {
            revert InexactTransfer();
        }
        received = receipt.balanceOf(account) - before;
        if (accountAssets - asset.balanceOf(account) != amount) revert InexactTransfer();
        if (received < minimum || received == 0) revert InsufficientOutput(received, minimum);
    }

    function withdraw(Y.Market memory m, address account, uint256 shares, uint256 minimum)
        internal
        returns (uint256 received)
    {
        IERC20 receipt = IERC20(m.receipt);
        IERC20 asset = IERC20(m.asset);
        uint256 receiptBase = receipt.balanceOf(address(this));
        uint256 assetBase = asset.balanceOf(address(this));
        uint256 before = asset.balanceOf(account);
        uint256 beforeUnits = YieldReader.units(m, account);
        uint256 expectedUnits = m.kind == Y.Kind.AAVE
            ? Math.mulDiv(
                shares, 1e27, IAavePool(m.target).getReserveNormalizedIncome(m.asset), Math.Rounding.Ceil
            )
            : shares;
        receipt.safeTransferFrom(account, address(this), shares);
        if (beforeUnits - YieldReader.units(m, account) != expectedUnits) revert InexactTransfer();
        // Rebasing Aave transfers may round one raw unit; Pool.withdraw and the real output check bind assets.
        uint256 pulled = receipt.balanceOf(address(this)) - receiptBase;
        if (m.kind != Y.Kind.AAVE && pulled != shares) revert InexactTransfer();
        if (m.kind == Y.Kind.VENUS) {
            uint256 code = IVToken(m.target).redeem(shares);
            if (code != 0) revert ProtocolError(code);
            asset.safeTransfer(account, asset.balanceOf(address(this)) - assetBase);
        } else if (m.kind == Y.Kind.LISTA) {
            uint256 available = IListaVault(m.target).maxRedeem(address(this));
            if (available < shares) {
                // Moolah maxRedeem round-trips shares -> assets -> shares, rounding down twice.
                // It may understate an otherwise fully liquid position by <= one raw underlying unit.
                // Permit only that integer-rounding gap, then let the real atomic redeem prove liquidity.
                // The caller's full previewRedeem minimum is unchanged; no loss tolerance is introduced.
                uint256 rate = IListaVault(m.target).convertToAssets(1e18);
                if (rate == 0 || shares - available > Math.ceilDiv(1e18, rate)) revert InexactTransfer();
            }
            uint256 declared = IListaVault(m.target).redeem(shares, account, address(this));
            if (declared != asset.balanceOf(account) - before) revert InexactTransfer();
        } else if (m.kind == Y.Kind.AAVE) {
            uint256 declared = IAavePool(m.target).withdraw(m.asset, shares, account);
            if (declared != asset.balanceOf(account) - before) revert InexactTransfer();
        } else {
            revert InexactTransfer();
        }
        uint256 residual = receipt.balanceOf(address(this)) - receiptBase;
        if (residual != 0) receipt.safeTransfer(account, residual);
        if (asset.balanceOf(address(this)) != assetBase) revert InexactTransfer();
        received = asset.balanceOf(account) - before;
        if (received < minimum || received == 0) revert InsufficientOutput(received, minimum);
    }
}
