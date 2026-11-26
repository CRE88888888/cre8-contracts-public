// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { IVenusComptroller, IVenusOracle, IVBorrowToken, IMoolahCore } from "../BorrowInterfaces.sol";
import { RoutingTypes as R } from "./RoutingTypes.sol";
import { RouteReader } from "./RouteReader.sol";
import { IStrategyVaultAdapter } from "./IStrategyVaultAdapter.sol";
import { IAtpBorrowLensV2 } from "./IAtpBorrowLensV2.sol";
import { AtpBorrowRegistryV2 } from "./AtpBorrowRegistryV2.sol";

interface IBoxOf {
    function boxOf(address account) external view returns (address);
}

/// @title AtpBorrowLensV2
/// @notice Every venue read of routing v2: positions, health, safety lines, gates, rates and the status
/// snapshots the backend uses. Stateless; built by `AtpBorrowExecutorV2`, which relies on it for the health and
/// gate checks (the registry holds configuration and accounting, this contract only reads it and the venues).
/// @dev Health: Lista per market; Venus per account over every market the account entered:
/// debt value <= budget = sum(collateral value x target LTV), deleverage at sum(collateral value x line).
contract AtpBorrowLensV2 is IAtpBorrowLensV2 {
    AtpBorrowRegistryV2 public immutable borrowRegistry;
    address public immutable executor;
    address public immutable venusComptroller;
    address public immutable moolah;

    constructor(AtpBorrowRegistryV2 registry_) {
        borrowRegistry = registry_;
        executor = registry_.executor();
        venusComptroller = registry_.venusComptroller();
        moolah = registry_.moolah();
    }

    // ---- accrual (anyone) ----

    /// @notice Accrue the route's venue so stored reads are current (Venus: every market the account entered).
    function sync(bytes32 id, address account) external {
        R.Route memory r = borrowRegistry.route(id);
        RouteReader.sync(r, _core(r), account);
    }

    /// @notice Accrue every venue market that can hold the account's debt in `token`.
    function syncToken(address account, address token) public {
        address vToken = borrowRegistry.venusMarket(token);
        if (vToken != address(0)) IVBorrowToken(vToken).accrueInterest();
        bytes32[] memory ids = borrowRegistry.accountRoutes(account);
        for (uint256 i; i < ids.length; ++i) {
            R.Route memory r = borrowRegistry.route(ids[i]);
            if (r.venue == R.Venue.LISTA && r.loan == token) RouteReader.sync(r, moolah, account);
        }
    }

    // ---- positions ----

    function debt(bytes32 id, address account) public view returns (uint256) {
        R.Route memory r = borrowRegistry.route(id);
        return RouteReader.debt(r, _core(r), account);
    }

    function routeDebt(bytes32 id, address account) public view returns (uint256 owed) {
        R.Route memory r = borrowRegistry.route(id);
        owed = RouteReader.debt(r, _core(r), account);
        if (r.venue == R.Venue.VENUS && owed != 0) {
            uint256 all = borrowRegistry.venusPrincipal(account, r.loan);
            if (all == 0) {
                // No principal left in the token (interest that outlived it): the debt is one route's only,
                // the account's first Venus position in the loan token. Not a position, not its debt.
                bytes32[] memory ids = borrowRegistry.accountRoutes(account);
                for (uint256 i; i < ids.length; ++i) {
                    if (ids[i] == id) return owed;
                    R.Route memory other = borrowRegistry.route(ids[i]);
                    if (other.venue == R.Venue.VENUS && other.loan == r.loan) break;
                }
                return 0;
            }
            uint256 mine = borrowRegistry.principal(account, id);
            if (mine < all) owed = Math.mulDiv(owed, mine, all, Math.Rounding.Ceil);
        }
    }

    function tokenDebt(address account, address token) public view returns (uint256 owed) {
        address vToken = borrowRegistry.venusMarket(token);
        if (vToken != address(0)) owed = IVBorrowToken(vToken).borrowBalanceStored(account);
        bytes32[] memory ids = borrowRegistry.accountRoutes(account);
        for (uint256 i; i < ids.length; ++i) {
            R.Route memory r = borrowRegistry.route(ids[i]);
            if (r.venue == R.Venue.LISTA && r.loan == token) owed += RouteReader.debt(r, moolah, account);
        }
    }

    function collateral(bytes32 id, address account) public view returns (uint256) {
        R.Route memory r = borrowRegistry.route(id);
        return RouteReader.collateral(r, _core(r), account);
    }

    /// @notice (utilization bps rounded up, loan raw units borrowable now) of the route's borrow market.
    function borrowMarket(bytes32 id) public view returns (uint256 utilizationBps, uint256 liquidity) {
        R.Route memory r = borrowRegistry.route(id);
        return RouteReader.borrowMarket(r, _core(r));
    }

    // ---- lines and health ----

    /// @notice (target LTV, deleverage LTV, venue factor F) of a route:
    /// target = min(tier ceiling, F / 2, owner line), deleverage = min(F x 2/3, owner line).
    function routeLines(bytes32 id) public view returns (uint256 target, uint256 deleverage, uint256 f) {
        R.Route memory r = borrowRegistry.route(id);
        f = RouteReader.factor(r, _core(r));
        bytes32 key = r.venue == R.Venue.VENUS ? bytes32(uint256(uint160(r.collateral))) : id;
        (target, deleverage) = _lines(key, r.collateral, f);
    }

    function liquidationLtv(bytes32 id) external view returns (uint256 f) {
        (,, f) = routeLines(id);
    }

    function targetLtv(bytes32 id) public view returns (uint256 target) {
        (target,,) = routeLines(id);
    }

    function deleverageLtv(bytes32 id) external view returns (uint256 deleverage) {
        (, deleverage,) = routeLines(id);
    }

    function health(bytes32 id, address account) public view returns (R.Health memory h) {
        R.Route memory r = borrowRegistry.route(id);
        if (r.venue == R.Venue.VENUS) {
            h = _venusHealth(account);
        } else {
            (h.collateralValue, h.debtValue) = RouteReader.listaValues(r, moolah, account);
            (uint256 target, uint256 deleverage, uint256 f) = routeLines(id);
            h.liquidationValue = Math.mulDiv(h.collateralValue, f, 1e18);
            h.budgetValue = Math.mulDiv(h.collateralValue, target, 1e18);
            h.deleverageValue = Math.mulDiv(h.collateralValue, deleverage, 1e18);
        }
        h.healthFactor =
            h.debtValue == 0 ? type(uint256).max : Math.mulDiv(h.liquidationValue, 1e18, h.debtValue);
    }

    /// @notice Executor check after an action that can add risk: debt value must be within the budget (Lista:
    /// this market; Venus: the whole account). `strict` (new debt) allows no excess at all.
    /// Otherwise (collateral left, with or without a repayment) a position that interest or prices already
    /// pushed past its budget (or whose asset lost its tier: budget zero) may still shrink, but only if it ends no
    /// closer to trouble on either measure: debt / budget not higher than `before`, and health factor
    /// (liquidation value / debt) not lower than `before`. Taking collateral out without repaying, or swapping
    /// the mix towards collateral the venue values less, fails; repaying at least in proportion passes, so a
    /// position without a budget can still be wound down in steps.
    function requireBudget(bytes32 id, address account, R.Health calldata before, bool strict)
        external
        view
        returns (R.Health memory h)
    {
        h = healthIfDebt(id, account);
        if (h.debtValue <= h.budgetValue) return h;
        if (
            strict || h.debtValue * before.budgetValue > before.debtValue * h.budgetValue
                || h.debtValue * before.liquidationValue > before.debtValue * h.liquidationValue
        ) revert LtvTooHigh(h.debtValue, h.budgetValue);
    }

    /// @notice `health`, or all zeros when the position has no debt at all (Lista: in this market; Venus: in
    /// any market of the account). A position without debt needs no price: its collateral can always leave.
    function healthIfDebt(bytes32 id, address account) public view returns (R.Health memory h) {
        R.Route memory r = borrowRegistry.route(id);
        if (r.venue == R.Venue.LISTA) {
            if (RouteReader.debt(r, moolah, account) == 0) return h;
        } else {
            address[] memory assets = IVenusComptroller(venusComptroller).getAssetsIn(account);
            bool owes;
            for (uint256 i; i < assets.length && !owes; ++i) {
                owes = IVBorrowToken(assets[i]).borrowBalanceStored(account) != 0;
            }
            if (!owes) return h;
        }
        return health(id, account);
    }

    /// @notice Accrue, then what `executeDeleverage` may repay now from the account's box: at or above the
    /// deleverage line, the amount back to the budget, capped by `maxRepay`. Reverts below the line. Vault
    /// utilization is not a trigger: only the account itself moves money for that (`executeReduce`,
    /// `executeSwitchVault`), because utilization can be pushed around within one block.
    function deleveragePlan(bytes32 routeId, bytes32 vaultId, address account, uint256 maxRepay)
        external
        returns (uint256 pay, uint256 owed, uint256 debtValue)
    {
        R.Route memory r = borrowRegistry.route(routeId);
        RouteReader.sync(r, _core(r), account);
        (R.Vault memory v,) = borrowRegistry.vaultFor(vaultId);
        if (v.token != r.loan) revert TokenMismatch();
        owed = RouteReader.debt(r, _core(r), account);
        if (owed == 0) revert NothingToRepay();
        debtValue = health(routeId, account).debtValue;
        pay = deleverageAmount(routeId, account);
        if (pay == 0) revert NothingToDo();
        pay = Math.min(pay, maxRepay);
        address box = IBoxOf(executor).boxOf(account);
        if (pay == 0 || (IERC20(v.receipt).balanceOf(box) == 0 && IERC20(v.token).balanceOf(box) == 0)) {
            revert VaultShortfall(owed, 0);
        }
    }

    /// @notice Accrue every market that can hold the account's debt in `token`; revert unless it is zero.
    function requireNoDebt(address account, address token) external {
        syncToken(account, token);
        uint256 owed = tokenDebt(account, token);
        if (owed != 0) revert DebtOutstanding(owed);
    }

    /// @notice The deposit gate of a vault for money that is already strategy money (vault switch): the
    /// vault's pool may not be above the 90% utilization line, where that can be read on chain.
    function requireDepositOpen(bytes32 vaultId) external {
        (R.Vault memory v, address adapter) = borrowRegistry.vaultFor(vaultId);
        IStrategyVaultAdapter a = IStrategyVaultAdapter(adapter);
        a.accrue(v.target, v.token);
        (bool known, uint256 utilization) = a.utilizationBps(v.target, v.token);
        if (known && utilization > borrowRegistry.MAX_VAULT_SUPPLY_UTILIZATION_BPS()) {
            revert GateClosed(uint8(R.Gate.VAULT_UTILIZATION));
        }
    }

    /// @notice What a repayment of up to `available` may actually repay of a debt of `owed`: the venue
    /// refuses to be left with less than its minimum loan (Moolah `minLoan`), so a repayment that would leave
    /// a smaller remainder is cut to leave the minimum plus a 1% margin for the interest of the next blocks.
    function clampRepay(bytes32 id, uint256 available, uint256 owed) external view returns (uint256) {
        if (available >= owed) return owed;
        uint256 floor = minDebt(id);
        if (owed - available >= floor) return available;
        return owed > floor ? owed - floor : 0;
    }

    /// @notice Loan token of the vault sitting directly in the account's box (not in any vault): strategy
    /// money like a vault holding, used first by the next repayment and paid out with a release.
    function idleOf(address account, address token) external view returns (uint256) {
        return IERC20(token).balanceOf(IBoxOf(executor).boxOf(account));
    }

    function deleverageAmount(bytes32 id, address account) public view returns (uint256 pay) {
        R.Route memory r = borrowRegistry.route(id);
        uint256 owed = RouteReader.debt(r, _core(r), account);
        if (owed == 0) return 0;
        R.Health memory h = health(id, account);
        if (h.debtValue < h.deleverageValue) return 0;
        uint256 excess = h.debtValue - Math.min(h.debtValue, h.budgetValue);
        if (r.venue == R.Venue.VENUS) {
            // Venus prices: USD (18 decimals) per raw unit x 1e18.
            uint256 price =
                IVenusOracle(IVenusComptroller(venusComptroller).oracle()).getUnderlyingPrice(r.loanVToken);
            pay = Math.mulDiv(excess, 1e18, price, Math.Rounding.Ceil) + 1;
        } else {
            pay = Math.mulDiv(owed, excess, h.debtValue, Math.Rounding.Ceil) + 1;
        }
        pay = Math.min(pay, owed);
        // A venue minimum (Moolah `minLoan`) forbids leaving a smaller debt: repay it all instead. The 1%
        // margin covers the interest that accrues before the transaction lands.
        if (owed - pay < minDebt(id)) pay = owed;
    }

    /// @notice Smallest debt a partial repayment may leave on the route: the venue minimum plus 1% (0 = none).
    function minDebt(bytes32 id) public view returns (uint256 floor) {
        floor = minLoan(id);
        floor += floor / 100;
    }

    function minLoan(bytes32 id) public view returns (uint256) {
        R.Route memory r = borrowRegistry.route(id);
        if (r.venue != R.Venue.LISTA) return 0;
        (bool ok, bytes memory ret) = moolah.staticcall(
            abi.encodeWithSignature(
                "minLoan((address,address,address,address,uint256))",
                IMoolahCore(moolah).idToMarketParams(r.listaId)
            )
        );
        return ok && ret.length == 32 ? abi.decode(ret, (uint256)) : 0;
    }

    // ---- gates and snapshots (use eth_call: they accrue first) ----

    /// @notice The gate for new borrowing through (route, vault); accrues both first.
    function gate(bytes32 routeId, bytes32 vaultId) external returns (R.Gate) {
        return quote(routeId, vaultId).gate;
    }

    function quote(bytes32 routeId, bytes32 vaultId) public returns (R.Quote memory q) {
        R.Route memory r = borrowRegistry.route(routeId);
        (R.Vault memory v, address adapter) = borrowRegistry.vaultFor(vaultId);
        address core = _core(r);
        RouteReader.sync(r, core, address(0));
        IStrategyVaultAdapter a = IStrategyVaultAdapter(adapter);
        a.accrue(v.target, v.token);
        q.targetLtv = targetLtv(routeId);
        q.borrowRate = RouteReader.borrowRate(r, core, borrowRegistry.venusBlocksPerYear());
        (, q.borrowIncentiveRate,) = borrowRegistry.freshReport(routeId);
        bool known;
        (known, q.vaultRate, q.vaultIncentiveRate) = _vaultRate(vaultId, v, a);
        q.carry = int256(q.vaultRate + q.vaultIncentiveRate + q.borrowIncentiveRate) - int256(q.borrowRate);
        (uint256 utilization,) = RouteReader.borrowMarket(r, core);
        (bool utilizationKnown, uint256 vaultUtilization) = a.utilizationBps(v.target, v.token);
        if (!borrowRegistry.routeOpen(routeId) || !borrowRegistry.vaultOpen(vaultId)) {
            q.gate = R.Gate.CLOSED;
        } else if (v.token != r.loan) {
            q.gate = R.Gate.TOKEN_MISMATCH;
        } else if (!known) {
            q.gate = R.Gate.VAULT_UNREADABLE;
        } else if (utilizationKnown && vaultUtilization > borrowRegistry.MAX_VAULT_SUPPLY_UTILIZATION_BPS()) {
            q.gate = R.Gate.VAULT_UTILIZATION;
        } else if (utilization > r.maxUtilizationBps) {
            q.gate = R.Gate.BORROW_UTILIZATION;
        } else if (q.carry < 0) {
            q.gate = R.Gate.NEGATIVE_CARRY;
        }
    }

    function routeStatus(bytes32 id, address account) external returns (R.RouteStatus memory s) {
        R.Route memory r = borrowRegistry.route(id);
        address core = _core(r);
        RouteReader.sync(r, core, account);
        uint256 blocksPerYear = borrowRegistry.venusBlocksPerYear();
        s.open = borrowRegistry.routeOpen(id);
        s.borrowRate = RouteReader.borrowRate(r, core, blocksPerYear);
        s.collateralRate = RouteReader.collateralRate(r, blocksPerYear);
        (, s.borrowIncentiveRate, s.collateralIncentiveRate) = borrowRegistry.freshReport(id);
        (s.borrowUtilizationBps, s.availableLiquidity) = RouteReader.borrowMarket(r, core);
        uint256 used = borrowRegistry.totalPrincipal(id);
        s.borrowCapLeft = r.borrowCap > used ? r.borrowCap - used : 0;
        (s.targetLtv, s.deleverageLtv, s.liquidationLtv) = routeLines(id);
        if (account == address(0)) return s;
        s.health = health(id, account);
        s.collateral = RouteReader.collateral(r, core, account);
        s.debt = RouteReader.debt(r, core, account);
        s.routeDebt = routeDebt(id, account);
        s.principal = borrowRegistry.principal(account, id);
        s.openedAt = borrowRegistry.openedAt(account, id);
        s.collateralValue = r.venue == R.Venue.VENUS
            ? Math.mulDiv(
                s.collateral,
                IVenusOracle(IVenusComptroller(core).oracle()).getUnderlyingPrice(r.collateralVToken),
                1e18
            )
            : s.health.collateralValue;
        if (s.health.debtValue != 0) {
            s.ltv = s.health.collateralValue == 0
                ? type(uint256).max
                : Math.mulDiv(s.health.debtValue, 1e18, s.health.collateralValue, Math.Rounding.Ceil);
            s.shouldDeleverage = s.health.debtValue >= s.health.deleverageValue;
        }
    }

    function vaultStatus(bytes32 id, address account) external returns (R.VaultStatus memory s) {
        (R.Vault memory v, address adapter) = borrowRegistry.vaultFor(id);
        IStrategyVaultAdapter a = IStrategyVaultAdapter(adapter);
        a.accrue(v.target, v.token);
        s.open = borrowRegistry.vaultOpen(id);
        (s.rateOnChain,) = a.supplyRate(v.target, v.token);
        (s.rateKnown, s.supplyRate, s.incentiveRate) = _vaultRate(id, v, a);
        (s.utilizationKnown, s.utilizationBps) = a.utilizationBps(v.target, v.token);
        s.shouldExit = s.utilizationKnown && s.utilizationBps > borrowRegistry.VAULT_EXIT_UTILIZATION_BPS();
        if (account != address(0)) {
            s.assets = a.assetsOf(v.target, v.token, IBoxOf(executor).boxOf(account));
            s.since = borrowRegistry.vaultSince(account, id);
        }
    }

    // ---- internals ----

    function _core(R.Route memory r) private view returns (address) {
        return r.venue == R.Venue.VENUS ? venusComptroller : moolah;
    }

    /// @dev (target, deleverage) for a collateral with venue factor `f`. An asset without a tier has no
    /// target (no budget), and keeps its deleverage line.
    function _lines(bytes32 key, address asset, uint256 f)
        private
        view
        returns (uint256 target, uint256 deleverage)
    {
        (uint128 ownerTarget, uint128 ownerDeleverage) = borrowRegistry.ltvConfig(key);
        R.Tier tier = borrowRegistry.assetTier(asset);
        uint256 ceiling = tier == R.Tier.INDEX_LARGE_CAP
            ? borrowRegistry.INDEX_LARGE_CAP_LTV()
            : tier == R.Tier.STOCK
                ? borrowRegistry.STOCK_LTV()
                : tier == R.Tier.CRYPTO_LINKED ? borrowRegistry.CRYPTO_LINKED_LTV() : 0;
        target = Math.min(ceiling, f / 2);
        if (ownerTarget != 0) target = Math.min(target, ownerTarget);
        deleverage = f * 2 / 3;
        if (ownerDeleverage != 0) deleverage = Math.min(deleverage, ownerDeleverage);
    }

    /// @dev Account-wide over every market the account entered in the Venus comptroller.
    function _venusHealth(address account) private view returns (R.Health memory h) {
        IVenusComptroller c = IVenusComptroller(venusComptroller);
        IVenusOracle oracle = IVenusOracle(c.oracle());
        address[] memory assets = c.getAssetsIn(account);
        for (uint256 i; i < assets.length; ++i) {
            address vToken = assets[i];
            (uint256 err, uint256 vBalance, uint256 borrowed, uint256 rate) =
                IVBorrowToken(vToken).getAccountSnapshot(account);
            if (err != 0) revert ProtocolRead(err);
            if (vBalance == 0 && borrowed == 0) continue;
            uint256 price = oracle.getUnderlyingPrice(vToken);
            if (price == 0) revert RouteReader.NoPrice(vToken);
            h.debtValue += Math.mulDiv(borrowed, price, 1e18);
            if (vBalance == 0) continue;
            (, uint256 f,) = c.markets(vToken);
            uint256 value = Math.mulDiv(Math.mulDiv(vBalance, rate, 1e18), price, 1e18);
            h.collateralValue += value;
            h.liquidationValue += Math.mulDiv(value, f, 1e18);
            // Collateral the registry does not list adds no budget, but its deleverage line still counts.
            address underlying = borrowRegistry.venusUnderlying(vToken);
            (uint256 target, uint256 deleverage) = underlying == address(0)
                ? (uint256(0), f * 2 / 3)
                : _lines(bytes32(uint256(uint160(underlying))), underlying, f);
            h.budgetValue += Math.mulDiv(value, target, 1e18);
            h.deleverageValue += Math.mulDiv(value, deleverage, 1e18);
        }
    }

    /// @dev On-chain rate where the adapter can read it, otherwise the fresh reported base rate.
    function _vaultRate(bytes32 id, R.Vault memory v, IStrategyVaultAdapter a)
        private
        view
        returns (bool known, uint256 rate, uint256 incentive)
    {
        (bool fresh, uint256 base, uint256 reported) = borrowRegistry.freshReport(id);
        (known, rate) = a.supplyRate(v.target, v.token);
        if (!known && fresh) (known, rate) = (true, base);
        if (fresh) incentive = reported;
    }
}
