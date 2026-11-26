// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { BorrowTypes as B } from "./BorrowTypes.sol";
import { MoolahParams, MoolahMarket } from "../yield/YieldInterfaces.sol";
import {
    IVenusComptroller,
    IVenusOracle,
    IVBorrowToken,
    IListaOracle,
    IMoolahCore,
    IMoolahIrm
} from "./BorrowInterfaces.sol";

/// @notice Reads a borrow position from the protocol's own state and oracle, the numbers that decide liquidation.
/// Only the real Venus / Moolah ABIs are used, so swapping the chain 97 mocks for the live markets changes no code.
library BorrowReader {
    error BadKind();
    error ProtocolRead(uint256 code);
    error NoPrice(address asset);

    /// @dev Venus' interest rate models annualize per-block rates with this factor.
    uint256 internal constant VENUS_BLOCKS_PER_YEAR = 70_080_000;
    uint256 internal constant VIRTUAL_SHARES = 1e6;
    uint256 internal constant VIRTUAL_ASSETS = 1;

    /// @notice Accrue interest so the stored reads below are current (Venus: every entered market).
    function sync(B.Market memory m, address account) internal {
        if (m.kind == B.Kind.VENUS) {
            IVBorrowToken(m.loanVToken).accrueInterest();
            address[] memory assets = IVenusComptroller(m.core).getAssetsIn(account);
            for (uint256 i; i < assets.length; ++i) {
                if (assets[i] != m.loanVToken) IVBorrowToken(assets[i]).accrueInterest();
            }
        } else if (m.kind == B.Kind.LISTA) {
            IMoolahCore(m.core).accrueInterest(params(m));
        } else {
            revert BadKind();
        }
    }

    function params(B.Market memory m) internal view returns (MoolahParams memory) {
        return IMoolahCore(m.core).idToMarketParams(m.listaId);
    }

    /// @notice Outstanding debt in loan raw units, interest included up to the last accrual.
    function debt(B.Market memory m, address account) internal view returns (uint256) {
        if (m.kind == B.Kind.VENUS) return IVBorrowToken(m.loanVToken).borrowBalanceStored(account);
        if (m.kind != B.Kind.LISTA) revert BadKind();
        (, uint128 shares,) = IMoolahCore(m.core).position(m.listaId, account);
        MoolahMarket memory s = IMoolahCore(m.core).market(m.listaId);
        return toAssetsUp(shares, s.totalBorrowAssets, s.totalBorrowShares);
    }

    /// @notice Posted collateral in collateral raw units (Venus: vToken balance converted at the stored rate).
    function collateral(B.Market memory m, address account) internal view returns (uint256) {
        if (m.kind == B.Kind.VENUS) {
            IVBorrowToken v = IVBorrowToken(m.collateralVToken);
            return Math.mulDiv(v.balanceOf(account), v.exchangeRateStored(), 1e18);
        }
        if (m.kind != B.Kind.LISTA) revert BadKind();
        (,, uint128 posted) = IMoolahCore(m.core).position(m.listaId, account);
        return posted;
    }

    function health(B.Market memory m, address account) internal view returns (B.Health memory h) {
        if (m.kind == B.Kind.VENUS) h = _venus(m, account);
        else if (m.kind == B.Kind.LISTA) h = _lista(m, account);
        else revert BadKind();
        h.healthFactor =
            h.debtValue == 0 ? type(uint256).max : Math.mulDiv(h.liquidationValue, 1e18, h.debtValue);
    }

    function _venus(B.Market memory m, address account) private view returns (B.Health memory h) {
        IVenusComptroller c = IVenusComptroller(m.core);
        IVenusOracle oracle = IVenusOracle(c.oracle());
        address[] memory assets = c.getAssetsIn(account);
        bool debtCounted;
        for (uint256 i; i < assets.length; ++i) {
            (uint256 err, uint256 vBalance, uint256 borrowed, uint256 rate) =
                IVBorrowToken(assets[i]).getAccountSnapshot(account);
            if (err != 0) revert ProtocolRead(err);
            uint256 price = oracle.getUnderlyingPrice(assets[i]);
            if (price == 0) revert NoPrice(assets[i]);
            (, uint256 factor,) = c.markets(assets[i]);
            uint256 value = Math.mulDiv(Math.mulDiv(vBalance, rate, 1e18), price, 1e18);
            h.collateralValue += value;
            h.liquidationValue += Math.mulDiv(value, factor, 1e18);
            h.debtValue += Math.mulDiv(borrowed, price, 1e18);
            if (assets[i] == m.loanVToken) debtCounted = true;
        }
        if (!debtCounted) {
            uint256 borrowed = IVBorrowToken(m.loanVToken).borrowBalanceStored(account);
            if (borrowed != 0) {
                uint256 price = oracle.getUnderlyingPrice(m.loanVToken);
                if (price == 0) revert NoPrice(m.loanVToken);
                h.debtValue += Math.mulDiv(borrowed, price, 1e18);
            }
        }
    }

    function _lista(B.Market memory m, address account) private view returns (B.Health memory h) {
        IMoolahCore core = IMoolahCore(m.core);
        MoolahParams memory p = core.idToMarketParams(m.listaId);
        (, uint128 shares, uint128 posted) = core.position(m.listaId, account);
        MoolahMarket memory s = core.market(m.listaId);
        uint256 borrowed = toAssetsUp(shares, s.totalBorrowAssets, s.totalBorrowShares);
        h.collateralValue = _usd(p.oracle, p.collateralToken, posted);
        h.liquidationValue = Math.mulDiv(h.collateralValue, p.lltv, 1e18);
        h.debtValue = borrowed == 0 ? 0 : _usd(p.oracle, p.loanToken, borrowed);
    }

    /// @dev Lista oracle prices are USD with 8 decimals per whole token; result is USD with 18 decimals.
    function _usd(address oracle, address token, uint256 amount) private view returns (uint256) {
        uint256 price = IListaOracle(oracle).peek(token);
        if (price == 0) revert NoPrice(token);
        return Math.mulDiv(amount, price * 1e10, 10 ** IERC20Metadata(token).decimals());
    }

    /// @notice The protocol's liquidation threshold for this collateral: Venus collateral factor, Lista LLTV.
    function liquidationFactor(B.Market memory m) internal view returns (uint256 factor) {
        if (m.kind == B.Kind.VENUS) (, factor,) = IVenusComptroller(m.core).markets(m.collateralVToken);
        else if (m.kind == B.Kind.LISTA) factor = params(m).lltv;
        else revert BadKind();
    }

    /// @notice Current yearly borrow rate (18 decimals, simple annualization of the per-block / per-second rate).
    function borrowRate(B.Market memory m) internal view returns (uint256) {
        if (m.kind == B.Kind.VENUS) {
            return IVBorrowToken(m.loanVToken).borrowRatePerBlock() * VENUS_BLOCKS_PER_YEAR;
        }
        if (m.kind != B.Kind.LISTA) revert BadKind();
        MoolahParams memory p = params(m);
        return IMoolahIrm(p.irm).borrowRateView(p, IMoolahCore(m.core).market(m.listaId)) * 365 days;
    }

    /// @notice What the posted collateral itself earns: Venus vToken supply rate; Moolah collateral earns nothing.
    function collateralRate(B.Market memory m) internal view returns (uint256) {
        if (m.kind == B.Kind.VENUS) {
            return IVBorrowToken(m.collateralVToken).supplyRatePerBlock() * VENUS_BLOCKS_PER_YEAR;
        }
        if (m.kind != B.Kind.LISTA) revert BadKind();
        return 0;
    }

    /// @notice Loan-market utilization in bps, rounded up: Venus borrows / (cash + borrows - reserves),
    /// Moolah totalBorrowAssets / totalSupplyAssets. An empty market reads as 100%.
    function borrowUtilization(B.Market memory m) internal view returns (uint256) {
        uint256 borrows;
        uint256 supplied;
        if (m.kind == B.Kind.VENUS) {
            IVBorrowToken v = IVBorrowToken(m.loanVToken);
            borrows = v.totalBorrows();
            supplied = v.getCash() + borrows - v.totalReserves();
        } else if (m.kind == B.Kind.LISTA) {
            MoolahMarket memory s = IMoolahCore(m.core).market(m.listaId);
            borrows = s.totalBorrowAssets;
            supplied = s.totalSupplyAssets;
        } else {
            revert BadKind();
        }
        if (supplied == 0) return 10_000;
        return Math.mulDiv(borrows, 10_000, supplied, Math.Rounding.Ceil);
    }

    /// @notice Loan-to-value: debt value / collateral value (18 decimals); 0 without debt.
    function ltv(B.Health memory h) internal pure returns (uint256) {
        if (h.debtValue == 0) return 0;
        if (h.collateralValue == 0) return type(uint256).max;
        return Math.mulDiv(h.debtValue, 1e18, h.collateralValue, Math.Rounding.Ceil);
    }

    function toAssetsUp(uint256 shares, uint256 totalAssets, uint256 totalShares)
        internal
        pure
        returns (uint256)
    {
        return Math.mulDiv(
            shares, totalAssets + VIRTUAL_ASSETS, totalShares + VIRTUAL_SHARES, Math.Rounding.Ceil
        );
    }
}
