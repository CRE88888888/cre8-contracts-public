// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { RoutingTypes as R } from "./RoutingTypes.sol";
import { MoolahParams, MoolahMarket } from "../../yield/YieldInterfaces.sol";
import {
    IVenusComptroller,
    IVBorrowToken,
    IListaOracle,
    IMoolahCore,
    IMoolahIrm
} from "../BorrowInterfaces.sol";

/// @notice Venue reads for routing v2, using only the real Venus core / Lista Moolah ABIs. `core` is the Venus
/// comptroller or Moolah, whichever the route's venue is.
library RouteReader {
    error BadVenue();
    error NoPrice(address asset);

    uint256 internal constant VIRTUAL_SHARES = 1e6;
    uint256 internal constant VIRTUAL_ASSETS = 1;

    /// @notice Accrue interest so stored reads are current (Venus: every market the account entered).
    function sync(R.Route memory r, address core, address account) internal {
        if (r.venue == R.Venue.VENUS) {
            IVBorrowToken(r.loanVToken).accrueInterest();
            address[] memory assets = IVenusComptroller(core).getAssetsIn(account);
            for (uint256 i; i < assets.length; ++i) {
                if (assets[i] != r.loanVToken) IVBorrowToken(assets[i]).accrueInterest();
            }
        } else if (r.venue == R.Venue.LISTA) {
            IMoolahCore(core).accrueInterest(IMoolahCore(core).idToMarketParams(r.listaId));
        } else {
            revert BadVenue();
        }
    }

    /// @notice Debt in loan raw units. Venus: the account's whole debt in the loan token (shared by routes).
    function debt(R.Route memory r, address core, address account) internal view returns (uint256) {
        if (r.venue == R.Venue.VENUS) return IVBorrowToken(r.loanVToken).borrowBalanceStored(account);
        (, uint128 shares,) = IMoolahCore(core).position(r.listaId, account);
        if (shares == 0) return 0;
        MoolahMarket memory s = IMoolahCore(core).market(r.listaId);
        return toAssetsUp(shares, s.totalBorrowAssets, s.totalBorrowShares);
    }

    /// @notice Posted collateral in collateral raw units.
    function collateral(R.Route memory r, address core, address account) internal view returns (uint256) {
        if (r.venue == R.Venue.VENUS) {
            IVBorrowToken v = IVBorrowToken(r.collateralVToken);
            return Math.mulDiv(v.balanceOf(account), v.exchangeRateStored(), 1e18);
        }
        (,, uint128 posted) = IMoolahCore(core).position(r.listaId, account);
        return posted;
    }

    /// @notice The venue's own factor F: Venus collateral factor, Lista LLTV.
    function factor(R.Route memory r, address core) internal view returns (uint256 f) {
        if (r.venue == R.Venue.VENUS) (, f,) = IVenusComptroller(core).markets(r.collateralVToken);
        else f = IMoolahCore(core).idToMarketParams(r.listaId).lltv;
    }

    function borrowRate(R.Route memory r, address core, uint256 venusBlocksPerYear)
        internal
        view
        returns (uint256)
    {
        if (r.venue == R.Venue.VENUS) {
            return IVBorrowToken(r.loanVToken).borrowRatePerBlock() * venusBlocksPerYear;
        }
        MoolahParams memory p = IMoolahCore(core).idToMarketParams(r.listaId);
        return IMoolahIrm(p.irm).borrowRateView(p, IMoolahCore(core).market(r.listaId)) * 365 days;
    }

    function collateralRate(R.Route memory r, uint256 venusBlocksPerYear) internal view returns (uint256) {
        if (r.venue != R.Venue.VENUS) return 0;
        return IVBorrowToken(r.collateralVToken).supplyRatePerBlock() * venusBlocksPerYear;
    }

    /// @notice (utilization bps rounded up, loan raw units that can be borrowed now).
    function borrowMarket(R.Route memory r, address core)
        internal
        view
        returns (uint256 utilizationBps, uint256 liquidity)
    {
        uint256 borrows;
        uint256 supplied;
        if (r.venue == R.Venue.VENUS) {
            IVBorrowToken v = IVBorrowToken(r.loanVToken);
            borrows = v.totalBorrows();
            uint256 cash = v.getCash();
            uint256 reserves = v.totalReserves();
            supplied = cash + borrows > reserves ? cash + borrows - reserves : 0;
            liquidity = cash > reserves ? cash - reserves : 0;
        } else {
            MoolahMarket memory s = IMoolahCore(core).market(r.listaId);
            borrows = s.totalBorrowAssets;
            supplied = s.totalSupplyAssets;
            liquidity = supplied > borrows ? supplied - borrows : 0;
        }
        utilizationBps = supplied == 0
            ? 10_000
            : Math.min(Math.mulDiv(borrows, 10_000, supplied, Math.Rounding.Ceil), 10_000);
    }

    /// @notice Lista market values in USD (18 decimals): (collateral value, debt value).
    function listaValues(R.Route memory r, address core, address account)
        internal
        view
        returns (uint256 collateralValue, uint256 debtValue)
    {
        MoolahParams memory p = IMoolahCore(core).idToMarketParams(r.listaId);
        (, uint128 shares, uint128 posted) = IMoolahCore(core).position(r.listaId, account);
        if (posted != 0) collateralValue = _usd(p.oracle, p.collateralToken, posted);
        if (shares != 0) {
            MoolahMarket memory s = IMoolahCore(core).market(r.listaId);
            debtValue =
                _usd(p.oracle, p.loanToken, toAssetsUp(shares, s.totalBorrowAssets, s.totalBorrowShares));
        }
    }

    /// @dev Lista oracle prices are USD with 8 decimals per whole token; result is USD with 18 decimals.
    function _usd(address oracle, address token, uint256 amount) private view returns (uint256) {
        uint256 price = IListaOracle(oracle).peek(token);
        if (price == 0) revert NoPrice(token);
        return Math.mulDiv(amount, price * 1e10, 10 ** IERC20Metadata(token).decimals());
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
