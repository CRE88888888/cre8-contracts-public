// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { YieldTypes as Y } from "./YieldTypes.sol";
import {
    IVToken,
    IListaVault,
    IMoolahRead,
    MoolahParams,
    MoolahMarket,
    IAToken,
    IAavePool
} from "./YieldInterfaces.sol";

/// @notice Read-only protocol adapters. Queue traversal is bounded; unavailable data always reverts.
/// Lista capacity treats the entire position as potentially allocated to EVERY queue entry and takes
/// the smallest liquidity instead of summing shared core cash. This deliberately understates capacity.
library YieldReader {
    uint256 internal constant MAX_QUEUE = 16;
    error InvalidMarket();
    error BadRate();
    error ProtocolError(uint256 code);
    error UnsafeMarket();

    function validate(Y.Market memory m) internal view {
        if (
            m.chainId != block.chainid || m.asset.code.length == 0 || m.receipt.code.length == 0
                || m.target.code.length == 0 || m.minRate == 0 || m.minRate > m.maxRate
                || m.asset == m.receipt
        ) revert InvalidMarket();
        (bool mockOk, bytes memory mockMarker) =
            m.target.staticcall(abi.encodeWithSignature("isTestnetYieldMock()"));
        if (block.chainid != 97 && mockOk && mockMarker.length == 32 && abi.decode(mockMarker, (bool))) {
            revert InvalidMarket();
        }
        if (m.kind == Y.Kind.VENUS) {
            if (
                m.target != m.receipt || IVToken(m.target).underlying() != m.asset
                    || IVToken(m.target).comptroller() != m.riskSource
            ) revert InvalidMarket();
        } else if (m.kind == Y.Kind.LISTA) {
            if (
                m.target != m.receipt || IListaVault(m.target).asset() != m.asset
                    || IListaVault(m.target).MOOLAH() != m.riskSource
            ) revert InvalidMarket();
        } else if (m.kind == Y.Kind.AAVE) {
            if (
                IAToken(m.receipt).UNDERLYING_ASSET_ADDRESS() != m.asset
                    || IAToken(m.receipt).POOL() != m.target || m.riskSource != m.target
            ) revert InvalidMarket();
            bytes memory data = _read(m.target, abi.encodeWithSignature("getReserveData(address)", m.asset));
            if (address(uint160(_word(data, 8))) != m.receipt) revert InvalidMarket();
        } else {
            revert InvalidMarket();
        }
    }

    /// @notice Supply/valuation admission requires an observable implementation, not just proxy runtime code.
    /// A proxy without a trustworthy implementation getter is rejected. This intentionally keeps such
    /// mainnet markets closed pending a reviewed implementation-proof source; typed exits stay independent.
    function identity(Y.Market memory m) internal view returns (bytes32) {
        address targetImpl = _implementation(m.target);
        address receiptImpl = m.receipt == m.target ? targetImpl : _implementation(m.receipt);
        address riskImpl = m.riskSource == m.target ? targetImpl : _implementation(m.riskSource);
        address model = m.kind == Y.Kind.VENUS ? IVToken(m.target).interestRateModel() : address(0);
        return keccak256(
            abi.encode(
                m.asset.codehash,
                m.target.codehash,
                m.receipt.codehash,
                m.riskSource.codehash,
                targetImpl,
                targetImpl.codehash,
                receiptImpl,
                receiptImpl.codehash,
                riskImpl,
                riskImpl.codehash,
                model,
                model.codehash
            )
        );
    }

    function _implementation(address target) private view returns (address impl) {
        bytes memory data = _read(target, abi.encodeWithSignature("implementation()"));
        if (data.length != 32) revert UnsafeMarket();
        impl = abi.decode(data, (address));
        if (impl.code.length == 0) revert UnsafeMarket();
    }

    function sync(Y.Market memory m) internal {
        if (m.kind == Y.Kind.VENUS) {
            uint256 code = IVToken(m.target).accrueInterest();
            if (code != 0) revert ProtocolError(code);
        } else if (m.kind == Y.Kind.LISTA) {
            IListaVault vault = IListaVault(m.target);
            uint256 n = vault.withdrawQueueLength();
            uint256 q = vault.supplyQueueLength();
            if (n > MAX_QUEUE || q > MAX_QUEUE) revert UnsafeMarket();
            IMoolahRead core = IMoolahRead(m.riskSource);
            for (uint256 i; i < n + q; ++i) {
                bytes32 id = i < n ? vault.withdrawQueue(i) : vault.supplyQueue(i - n);
                if (i < n) {
                    (uint256 held,,) = core.position(id, m.target);
                    if (held == 0) continue;
                }
                core.accrueInterest(core.idToMarketParams(id));
            }
        }
    }

    /// @dev Rate is raw underlying per 1e18 accounting units. Aave accounting units are scaled balances.
    function rate(Y.Market memory m) internal view returns (uint256 r) {
        if (m.kind == Y.Kind.VENUS) {
            r = IVToken(m.receipt).exchangeRateStored();
        } else if (m.kind == Y.Kind.LISTA) {
            // Probe large enough to preserve precision even with ERC4626's virtual-share offset.
            r = IListaVault(m.receipt).convertToAssets(1e18);
        } else if (m.kind == Y.Kind.AAVE) {
            r = IAavePool(m.target).getReserveNormalizedIncome(m.asset) / 1e9;
        } else {
            revert InvalidMarket();
        }
        if (r == 0) revert BadRate();
    }

    function units(Y.Market memory m, address account) internal view returns (uint256) {
        return m.kind == Y.Kind.AAVE
            ? IAToken(m.receipt).scaledBalanceOf(account)
            : IERC20(m.receipt).balanceOf(account);
    }

    function assets(Y.Market memory m, uint256 shares, bool roundUp) internal view returns (uint256) {
        uint256 r = rate(m);
        if (shares == 0) return 0;
        if (m.kind == Y.Kind.LISTA) {
            IListaVault vault = IListaVault(m.receipt);
            if (roundUp) {
                uint256 supply = vault.totalSupply();
                if (supply == 0) revert BadRate();
                return Math.mulDiv(shares, vault.totalAssets() + 1, supply, Math.Rounding.Ceil);
            }
            return Math.min(vault.convertToAssets(shares), vault.previewRedeem(shares));
        }
        if (m.kind == Y.Kind.AAVE) {
            return Math.mulDiv(
                shares,
                IAavePool(m.target).getReserveNormalizedIncome(m.asset),
                1e27,
                roundUp ? Math.Rounding.Ceil : Math.Rounding.Floor
            );
        }
        return Math.mulDiv(shares, r, 1e18, roundUp ? Math.Rounding.Ceil : Math.Rounding.Floor);
    }

    function quoteSupply(Y.Market memory m, address account, uint256 amount) internal view returns (uint256) {
        uint256 current = rate(m);
        if (m.kind == Y.Kind.LISTA) return IListaVault(m.receipt).previewDeposit(amount);
        if (m.kind == Y.Kind.VENUS) return Math.mulDiv(amount, 1e18, current);
        uint256 index = IAavePool(m.target).getReserveNormalizedIncome(m.asset);
        uint256 scaled = IAToken(m.receipt).scaledBalanceOf(account);
        // Aave v3 TokenMath: mint scaled amount and aToken balances both round DOWN.
        uint256 minted = Math.mulDiv(amount, 1e27, index);
        return Math.mulDiv(scaled + minted, index, 1e27) - Math.mulDiv(scaled, index, 1e27);
    }

    function quoteWithdraw(Y.Market memory m, uint256 shares) internal view returns (uint256) {
        if (m.kind == Y.Kind.VENUS) return assets(m, shares, false);
        rate(m);
        if (m.kind == Y.Kind.LISTA) return IListaVault(m.receipt).previewRedeem(shares);
        return shares; // Aave API shares = raw aToken amount, matching Pool.withdraw.
    }

    function supplyCapacity(Y.Market memory m, address account) internal view returns (uint256) {
        if (m.kind == Y.Kind.VENUS) {
            uint256 cap = _venusCap(m);
            if (cap == 0) return type(uint256).max;
            IVToken v = IVToken(m.target);
            uint256 supplied = v.getCash() + v.totalBorrows() - v.totalReserves();
            return cap > supplied ? cap - supplied : 0;
        }
        if (m.kind == Y.Kind.LISTA) return IListaVault(m.target).maxDeposit(account);
        bytes memory data = _read(m.target, abi.encodeWithSignature("getReserveData(address)", m.asset));
        uint256 config = _word(data, 0);
        uint8 decimals = IERC20Metadata(m.asset).decimals();
        if (decimals > 18 || ((config >> 48) & 255) != decimals) revert InvalidMarket();
        uint256 wholeCap = (config >> 116) & ((1 << 36) - 1);
        if (wholeCap == 0) return type(uint256).max;
        uint256 cap = wholeCap * 10 ** decimals;
        uint256 supplied = IERC20(m.receipt).totalSupply();
        return cap > supplied ? cap - supplied : 0;
    }

    function _venusCap(Y.Market memory m) private view returns (uint256) {
        bytes memory data = _read(m.riskSource, abi.encodeWithSignature("supplyCaps(address)", m.target));
        if (data.length != 32) revert UnsafeMarket();
        return abi.decode(data, (uint256));
    }

    function health(Y.Market memory m) internal view returns (Y.Health memory h) {
        validate(m);
        rate(m);
        if (m.kind == Y.Kind.VENUS) {
            IVToken v = IVToken(m.target);
            if (v.accrualBlockNumber() != block.number) revert UnsafeMarket();
            uint256 cash = v.getCash();
            uint256 borrows = v.totalBorrows();
            uint256 reserves = v.totalReserves();
            h.supply = cash + borrows - reserves;
            h.liquidity = cash > reserves ? cash - reserves : 0;
            h.utilizationBps = _util(borrows, h.supply);
            // Core Venus action enum: MINT=0. Unknown/malformed pause ABI fails closed.
            bytes memory pause = _read(
                m.riskSource, abi.encodeWithSignature("actionPaused(address,uint8)", m.target, uint8(0))
            );
            if (abi.decode(pause, (bool))) revert UnsafeMarket();
            h.configuration = keccak256(
                abi.encode(
                    m.target.codehash, v.implementation(), v.interestRateModel(), m.riskSource, _venusCap(m)
                )
            );
        } else if (m.kind == Y.Kind.LISTA) {
            IListaVault vault = IListaVault(m.target);
            IMoolahRead core = IMoolahRead(m.riskSource);
            if (core.paused()) revert UnsafeMarket();
            uint256 n = vault.supplyQueueLength();
            uint256 w = vault.withdrawQueueLength();
            if (n == 0 || n > MAX_QUEUE || w > MAX_QUEUE) revert UnsafeMarket();
            h.supply = vault.totalAssets();
            h.liquidity = IERC20(m.asset).balanceOf(m.riskSource);
            bytes32 hash = keccak256(abi.encode(m.target.codehash, m.riskSource, vault.fee()));
            for (uint256 i; i < n + w; ++i) {
                bytes32 id = i < n ? vault.supplyQueue(i) : vault.withdrawQueue(i - n);
                MoolahParams memory p = core.idToMarketParams(id);
                MoolahMarket memory state = core.market(id);
                (uint256 position,,) = core.position(id, m.target);
                (uint184 cap, bool enabled, uint64 removableAt) = vault.config(id);
                hash = keccak256(abi.encode(hash, id, p, cap, enabled, removableAt));
                // An old, zero-exposure withdraw entry cannot permanently block recovery.
                if (i >= n && position == 0) continue;
                if (p.loanToken != m.asset || p.irm.code.length == 0) revert UnsafeMarket();
                if (block.chainid == 56) {
                    if (p.irm != 0xFe7dAe87Ebb11a7BEB9F534BB23267992d9cDe7c) revert UnsafeMarket();
                    bytes memory broker = _read(m.riskSource, abi.encodeWithSignature("brokers(bytes32)", id));
                    bytes memory provider = _read(
                        m.riskSource, abi.encodeWithSignature("providers(bytes32,address)", id, m.asset)
                    );
                    if (
                        broker.length != 32 || provider.length != 32
                            || abi.decode(broker, (address)) != address(0)
                            || abi.decode(provider, (address)) != address(0)
                    ) revert UnsafeMarket();
                }
                if (state.lastUpdate > block.timestamp || block.timestamp - state.lastUpdate > 60) {
                    revert UnsafeMarket();
                }
                // A supply destination is relevant even before it has a position.
                h.supply = Math.min(h.supply, state.totalSupplyAssets);
                h.liquidity =
                    Math.min(h.liquidity, uint256(state.totalSupplyAssets) - state.totalBorrowAssets);
                h.utilizationBps =
                    Math.max(h.utilizationBps, _util(state.totalBorrowAssets, state.totalSupplyAssets));
            }
            h.configuration = hash;
        } else {
            bytes memory data = _read(m.target, abi.encodeWithSignature("getReserveData(address)", m.asset));
            uint256 config = _word(data, 0);
            if ((config & (1 << 56)) == 0 || (config & ((1 << 57) | (1 << 60))) != 0) revert UnsafeMarket();
            h.supply = IERC20(m.receipt).totalSupply();
            h.liquidity = Math.min(
                IERC20(m.asset).balanceOf(m.receipt),
                abi.decode(
                    _read(m.target, abi.encodeWithSignature("getVirtualUnderlyingBalance(address)", m.asset)),
                    (uint256)
                )
            );
            address debt = address(uint160(_word(data, 10)));
            uint256 borrowed = IERC20(debt).totalSupply();
            h.utilizationBps = _util(borrowed, h.liquidity + borrowed);
            h.configuration = keccak256(abi.encode(m.target.codehash, config, m.receipt, debt));
        }
        if (h.supply == 0) revert UnsafeMarket();
    }

    function _util(uint256 borrows, uint256 supply) private pure returns (uint256) {
        if (supply == 0 || borrows > supply) revert UnsafeMarket();
        return Math.mulDiv(borrows, 10_000, supply, Math.Rounding.Ceil);
    }

    function _read(address target, bytes memory data) private view returns (bytes memory ret) {
        bool ok;
        (ok, ret) = target.staticcall(data);
        if (!ok || ret.length == 0) revert UnsafeMarket();
    }

    function _word(bytes memory data, uint256 index) private pure returns (uint256 value) {
        if (data.length < (index + 1) * 32) revert UnsafeMarket();
        assembly { value := mload(add(add(data, 32), mul(index, 32))) }
    }
}
