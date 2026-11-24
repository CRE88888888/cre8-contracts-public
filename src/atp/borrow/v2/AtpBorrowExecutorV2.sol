// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { MoolahParams } from "../../yield/YieldInterfaces.sol";
import { IVenusComptroller, IVBorrowToken, IMoolahCore } from "../BorrowInterfaces.sol";
import { RoutingTypes as R } from "./RoutingTypes.sol";
import { StrategyBox } from "./StrategyBox.sol";
import { IStrategyVaultAdapter } from "./IStrategyVaultAdapter.sol";
import { IAtpBorrowExecutorV2 as IExec } from "./IAtpBorrowExecutorV2.sol";
import { AtpBorrowRegistryV2 } from "./AtpBorrowRegistryV2.sol";
import { AtpBorrowLensV2 } from "./AtpBorrowLensV2.sol";
import { RoutingExecutorBase } from "./RoutingExecutorBase.sol";

/// @title AtpBorrowExecutorV2
/// @notice Strategy Earn with dynamic routes (docs/borrow-routing-v2.zh-TW.md): post an asset as collateral on
/// Venus or Lista Moolah, borrow USDT / USDC / USD1 / U against it and deposit that same token into an
/// allowlisted supply vault (Lista vault, Venus vToken, Aave v3), then repay, deleverage, close, migrate to
/// another route or switch vault. A new contract next to v1 (`AtpBorrowExecutor`), which stays as deployed.
/// @dev Where the money can be: the account's collateral position, and the account's strategy box (a clone
/// only this contract controls) holding vault receipts. Borrowed tokens go venue -> this contract -> vault in
/// one call; repayments go box / vault -> this contract -> venue. No function takes a receiver. The only ways
/// out are back into the same portfolio account (collateral, leftovers once the token's debt is zero, rewards,
/// rescued receipts) and reward tokens to the recipient the account owner signed. This contract holds no
/// balance between calls and leaves no allowance behind. `msg.sender` must be the account itself, except
/// `executeDeleverage` and `collectRewards`, which anyone may call and which can only repay the account's own
/// debt from its own box / move its own rewards into it.
/// This contract implements open, reduce, deleverage and migrate. Every other entry point of
/// `IAtpBorrowExecutorV2` (switch vault, release, rescue, rewards) lives in `extension` and runs here by
/// delegatecall through the fallback: one address, one interface, two code halves (24 KB limit).
contract AtpBorrowExecutorV2 is RoutingExecutorBase {
    using SafeERC20 for IERC20;

    AtpBorrowRegistryV2 private immutable _reg;
    AtpBorrowLensV2 private immutable _lens;
    address public immutable boxImplementation;
    /// @notice `AtpBorrowExecutorV2Extension`: stateless code this contract delegatecalls for the selectors it
    /// does not implement. Fixed at deployment.
    address public immutable extension;
    address public immutable venusComptroller;
    address public immutable moolah;

    /// @param lens_ The `AtpBorrowLensV2` deployed for the same registry.
    /// @param extension_ The `AtpBorrowExecutorV2Extension` (both are separate deployments only because of
    /// the code-size limits; the deployment script checks their code).
    constructor(AtpBorrowRegistryV2 borrowRegistry_, AtpBorrowLensV2 lens_, address extension_) {
        if (
            address(borrowRegistry_).code.length == 0 || borrowRegistry_.executor() != address(this)
                || address(lens_).code.length == 0
                || address(lens_.borrowRegistry()) != address(borrowRegistry_) || extension_.code.length == 0
        ) revert IExec.InvalidConfig();
        _reg = borrowRegistry_;
        _lens = lens_;
        extension = extension_;
        venusComptroller = borrowRegistry_.venusComptroller();
        moolah = borrowRegistry_.moolah();
        boxImplementation = address(new StrategyBox(address(this)));
    }

    /// @dev Everything not implemented above is the extension's, run as this contract.
    fallback() external {
        address target = extension;
        assembly {
            calldatacopy(0, 0, calldatasize())
            let ok := delegatecall(gas(), target, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch ok
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }

    function borrowRegistry() external view returns (address) {
        return address(_reg);
    }

    function lens() external view returns (address) {
        return address(_lens);
    }

    function boxOf(address account) external view returns (address) {
        return _boxOf(account);
    }

    function _registry() internal view override returns (AtpBorrowRegistryV2) {
        return _reg;
    }

    function _lensOf() internal view override returns (AtpBorrowLensV2) {
        return _lens;
    }

    function _boxImplementation() internal view override returns (address) {
        return boxImplementation;
    }

    // ---- actions ----

    function executeOpen(
        address account,
        bytes32 routeId,
        bytes32 vaultId,
        uint256 collateralAmount,
        uint256 borrowAmount,
        uint256 deadline
    ) external nonReentrant {
        _caller(account, deadline);
        if (collateralAmount == 0 && borrowAmount == 0) revert IExec.ZeroAmount();
        (R.Route memory r, R.Vault memory v, address adapter) =
            _reg.beforeOpen(account, routeId, vaultId, borrowAmount);
        address core = _core(r);
        _lens.sync(routeId, account);
        if (collateralAmount != 0) {
            IERC20 token = IERC20(r.collateral);
            uint256 base = token.balanceOf(address(this));
            token.safeTransferFrom(account, address(this), collateralAmount);
            if (token.balanceOf(address(this)) - base != collateralAmount) revert IExec.InexactTransfer();
            _supplyCollateral(r, core, routeId, account, collateralAmount);
            if (token.balanceOf(address(this)) != base) revert IExec.InexactTransfer();
        }
        uint256 debtValue;
        uint256 budgetValue;
        if (borrowAmount != 0) {
            _borrowIntoVault(r, core, routeId, v, adapter, vaultId, account, borrowAmount);
            // New debt must fit the budget outright. A collateral-only top-up reads no price at all.
            R.Health memory none;
            R.Health memory h = _lens.requireBudget(routeId, account, none, true);
            (debtValue, budgetValue) = (h.debtValue, h.budgetValue);
        }
        _reg.recordOpen(account, routeId, borrowAmount);
        emit IExec.Opened(account, routeId, vaultId, collateralAmount, borrowAmount, debtValue, budgetValue);
    }

    function executeReduce(
        address account,
        bytes32 routeId,
        bytes32 vaultId,
        uint256 repayAmount,
        uint256 withdrawAmount,
        uint256 maxCashIn,
        uint256 deadline
    ) external nonReentrant {
        _caller(account, deadline);
        if (repayAmount == 0 && withdrawAmount == 0) revert IExec.ZeroAmount();
        R.Route memory r = _reg.route(routeId);
        address core = _core(r);
        _lens.sync(routeId, account);
        // Prices are read only when collateral leaves: a plain repayment never depends on an oracle.
        R.Health memory before;
        if (withdrawAmount != 0) before = _lens.healthIfDebt(routeId, account);
        uint256 pay;
        uint256 fromBox;
        bool vaultFailed;
        if (repayAmount != 0) {
            uint256 owed = _lens.debt(routeId, account);
            pay = repayAmount == MAX ? _lens.routeDebt(routeId, account) : Math.min(repayAmount, owed);
            if (pay != 0) {
                // Closing the token: this route carries all of the account's debt in it.
                bool closing = pay == owed && _lens.tokenDebt(account, r.loan) == owed;
                (pay, fromBox, vaultFailed) =
                    _repay(r, core, Repay(routeId, vaultId, account, pay, owed, maxCashIn, false, closing));
            }
        }
        uint256 out;
        if (withdrawAmount != 0) {
            out = _withdrawCollateral(r, core, routeId, account, withdrawAmount, account);
            _lens.requireBudget(routeId, account, before, false);
        }
        _reg.recordReduce(account, routeId, pay);
        // Strategy closed for this token: what is left in the vault goes back into the same account. Skipped
        // when the vault already failed to pay in this call (it would only fail, and burn gas, again).
        uint256 released;
        if (vaultId != bytes32(0) && !vaultFailed && _lens.tokenDebt(account, r.loan) == 0) {
            released = _release(account, vaultId, r.loan, true);
        }
        if (pay == 0 && out == 0 && released == 0) revert IExec.NothingToRepay();
        emit IExec.Reduced(
            account, routeId, vaultId, pay, fromBox, pay - fromBox, out, _lens.debt(routeId, account)
        );
    }

    function executeDeleverage(address account, bytes32 routeId, bytes32 vaultId, uint256 maxRepay)
        external
        nonReentrant
        returns (uint256 pay)
    {
        R.Route memory r = _reg.route(routeId);
        uint256 owed;
        uint256 before;
        (pay, owed, before) = _lens.deleveragePlan(routeId, vaultId, account, maxRepay);
        (pay,,) = _repay(r, _core(r), Repay(routeId, vaultId, account, pay, owed, 0, true, false));
        _reg.recordReduce(account, routeId, pay);
        emit IExec.Deleveraged(
            account, routeId, vaultId, pay, before, _lens.health(routeId, account).debtValue
        );
    }

    function executeMigrate(
        address account,
        bytes32 fromRouteId,
        bytes32 fromVaultId,
        bytes32 toRouteId,
        bytes32 toVaultId,
        uint256 borrowAmount,
        uint256 maxCashIn,
        uint256 deadline
    ) external nonReentrant {
        _caller(account, deadline);
        if (fromRouteId == toRouteId) revert IExec.SameRoute();
        R.Route memory from = _reg.route(fromRouteId);
        R.Route memory to = _reg.route(toRouteId);
        if (from.collateral != to.collateral) revert IExec.CollateralMismatch();
        address fromCore = _core(from);
        address toCore = _core(to);
        _lens.sync(fromRouteId, account);
        _lens.sync(toRouteId, account);

        R.Health memory before = _lens.health(fromRouteId, account);
        // 1. Old debt first: the old position only gets safer before its collateral moves.
        uint256 repaid = _lens.routeDebt(fromRouteId, account);
        if (repaid != 0) {
            uint256 owed = _lens.debt(fromRouteId, account);
            bool closing = repaid == owed && _lens.tokenDebt(account, from.loan) == owed;
            _repay(
                from,
                fromCore,
                Repay(fromRouteId, fromVaultId, account, repaid, owed, maxCashIn, false, closing)
            );
        }
        // 2. Collateral: old venue -> this contract -> new venue. Two Venus routes share the same vToken.
        bool sameAccount = from.venue == R.Venue.VENUS && to.venue == R.Venue.VENUS;
        uint256 moved;
        if (!sameAccount) {
            IERC20 token = IERC20(from.collateral);
            uint256 base = token.balanceOf(address(this));
            moved = _withdrawCollateral(from, fromCore, fromRouteId, account, MAX, address(this));
            _supplyCollateral(to, toCore, toRouteId, account, moved);
            if (token.balanceOf(address(this)) != base) revert IExec.InexactTransfer();
        }
        _reg.recordReduce(account, fromRouteId, repaid);
        // Two Venus routes of one collateral share its vTokens: the position carries over to the new route.
        if (sameAccount) _reg.recordSwap(account, fromRouteId, toRouteId);
        // 3. New debt straight into the new vault, admitted like any open (after the old principal retired).
        (, R.Vault memory v, address adapter) = _reg.beforeOpen(account, toRouteId, toVaultId, borrowAmount);
        if (borrowAmount != 0) {
            _borrowIntoVault(to, toCore, toRouteId, v, adapter, toVaultId, account, borrowAmount);
        }
        // 4. New debt must fit the budget outright; what stays on Venus (other routes) may not end worse.
        _lens.requireBudget(toRouteId, account, before, borrowAmount != 0 || !sameAccount);
        if (from.venue == R.Venue.VENUS && !sameAccount) {
            _lens.requireBudget(fromRouteId, account, before, false);
        }
        _reg.recordOpen(account, toRouteId, borrowAmount);
        emit IExec.Migrated(
            account, fromRouteId, toRouteId, fromVaultId, toVaultId, repaid, moved, borrowAmount
        );
    }

    // ---- internals: venue ----

    function _core(R.Route memory r) private view returns (address) {
        return r.venue == R.Venue.VENUS ? venusComptroller : moolah;
    }

    function _params(address core, bytes32 id) private view returns (MoolahParams memory) {
        return IMoolahCore(core).idToMarketParams(id);
    }

    /// @dev `amount` of the collateral token is already in this contract.
    function _supplyCollateral(
        R.Route memory r,
        address core,
        bytes32 routeId,
        address account,
        uint256 amount
    ) private {
        IERC20 token = IERC20(r.collateral);
        uint256 before = _lens.collateral(routeId, account);
        if (r.venue == R.Venue.VENUS) {
            token.forceApprove(r.collateralVToken, amount);
            _ok(IVBorrowToken(r.collateralVToken).mintBehalf(account, amount));
            token.forceApprove(r.collateralVToken, 0);
            if (!IVenusComptroller(core).checkMembership(account, r.collateralVToken)) {
                _ok(IVenusComptroller(core).enterMarketBehalf(account, r.collateralVToken));
            }
        } else {
            token.forceApprove(core, amount);
            IMoolahCore(core).supplyCollateral(_params(core, r.listaId), amount, account, "");
            token.forceApprove(core, 0);
        }
        if (_lens.collateral(routeId, account) <= before) revert IExec.InexactTransfer();
    }

    /// @dev Sends the collateral to `to` (the account, or this contract during a migration).
    function _withdrawCollateral(
        R.Route memory r,
        address core,
        bytes32 routeId,
        address account,
        uint256 amount,
        address to
    ) private returns (uint256 received) {
        IERC20 token = IERC20(r.collateral);
        uint256 base = token.balanceOf(address(this));
        uint256 before = token.balanceOf(to);
        if (r.venue == R.Venue.VENUS) {
            IVBorrowToken v = IVBorrowToken(r.collateralVToken);
            if (amount == MAX) {
                uint256 shares = v.balanceOf(account);
                if (shares == 0) revert IExec.ZeroAmount();
                _ok(v.redeemBehalf(account, shares));
            } else {
                _ok(v.redeemUnderlyingBehalf(account, amount));
            }
            received = token.balanceOf(address(this)) - base;
            if (received == 0 || (amount != MAX && received != amount)) revert IExec.InexactTransfer();
            if (to != address(this)) token.safeTransfer(to, received);
        } else {
            received = amount == MAX ? _lens.collateral(routeId, account) : amount;
            if (received == 0) revert IExec.ZeroAmount();
            IMoolahCore(core).withdrawCollateral(_params(core, r.listaId), received, account, to);
        }
        if (token.balanceOf(to) - before != received) revert IExec.InexactTransfer();
    }

    /// @dev Borrow exactly `amount` for the account and deposit it into the vault for the account's box.
    function _borrowIntoVault(
        R.Route memory r,
        address core,
        bytes32 routeId,
        R.Vault memory v,
        address adapter,
        bytes32 vaultId,
        address account,
        uint256 amount
    ) private {
        R.Gate gate = _lens.gate(routeId, vaultId);
        if (gate != R.Gate.OPEN) revert IExec.GateClosed(uint8(gate));
        IERC20 loan = IERC20(r.loan);
        uint256 base = loan.balanceOf(address(this));
        uint256 accountCash = loan.balanceOf(account);
        if (r.venue == R.Venue.VENUS) {
            _ok(IVBorrowToken(r.loanVToken).borrowBehalf(account, amount));
        } else {
            (uint256 assets,) =
                IMoolahCore(core).borrow(_params(core, r.listaId), amount, 0, account, address(this));
            if (assets != amount) revert IExec.InexactTransfer();
        }
        if (loan.balanceOf(address(this)) - base != amount) revert IExec.InexactTransfer();
        (uint256 utilization,) = _lens.borrowMarket(routeId);
        if (utilization > r.maxUtilizationBps) revert IExec.GateClosed(uint8(R.Gate.BORROW_UTILIZATION));
        _deposit(v, adapter, vaultId, account, amount);
        if (loan.balanceOf(address(this)) != base || loan.balanceOf(account) != accountCash) {
            revert IExec.InexactTransfer();
        }
    }

    struct Repay {
        bytes32 routeId;
        bytes32 vaultId;
        address account;
        uint256 pay;
        uint256 owed;
        uint256 maxCashIn;
        bool orLess;
        bool closing;
    }

    /// @dev Repay `p.pay` of the route's debt. Sources, in order: the loan token sitting in the account's box,
    /// the box's holding in `p.vaultId` (when given), then the account's own loan token up to `p.maxCashIn`.
    /// `orLess` (deleverage): repay what the box and vault give instead of failing, never leaving a remainder
    /// below the venue's minimum loan. `closing`: this repayment ends the account's debt in the token, so the
    /// whole holding is taken out and what exceeds the debt is paid to the account.
    /// Returns what was repaid, how much of it came from the box / vault, and whether the vault refused.
    function _repay(R.Route memory r, address core, Repay memory p)
        private
        returns (uint256 pay, uint256 fromBox, bool vaultFailed)
    {
        IERC20 loan = IERC20(r.loan);
        uint256 base = loan.balanceOf(address(this));
        vaultFailed = _pull(r.loan, p);
        fromBox = Math.min(loan.balanceOf(address(this)) - base, p.pay);
        pay = p.pay;
        if (pay - fromBox > p.maxCashIn) {
            if (!p.orLess) revert IExec.VaultShortfall(pay, fromBox + p.maxCashIn);
            // Deleverage with a short holding: repay what there is, but never leave the venue a remainder
            // below its minimum loan (it would revert); keep a little more than the minimum instead.
            pay = _lens.clampRepay(p.routeId, fromBox + p.maxCashIn, p.owed);
            if (pay == 0) revert IExec.VaultShortfall(p.owed, fromBox);
            fromBox = Math.min(fromBox, pay);
        }
        if (pay != fromBox) loan.safeTransferFrom(p.account, address(this), pay - fromBox);
        if (r.venue == R.Venue.VENUS) {
            loan.forceApprove(r.loanVToken, pay);
            _ok(IVBorrowToken(r.loanVToken).repayBorrowBehalf(p.account, pay));
            loan.forceApprove(r.loanVToken, 0);
        } else {
            loan.forceApprove(core, pay);
            if (pay == p.owed) {
                // Repay by shares so no dust share is left behind.
                (, uint128 shares,) = IMoolahCore(core).position(r.listaId, p.account);
                IMoolahCore(core).repay(_params(core, r.listaId), 0, shares, p.account, "");
            } else {
                IMoolahCore(core).repay(_params(core, r.listaId), pay, 0, p.account, "");
            }
            loan.forceApprove(core, 0);
        }
        // What the box / vault gave beyond the repayment: to the account when the token's debt is over,
        // otherwise back into the box, where the next repayment uses it first.
        uint256 surplus = loan.balanceOf(address(this)) - base;
        if (surplus != 0) {
            loan.safeTransfer(p.closing ? p.account : _boxOf(p.account), surplus);
            if (p.closing) emit IExec.Released(p.account, p.vaultId, surplus);
        }
        uint256 left = _lens.debt(p.routeId, p.account);
        // Debt falls by `pay`; a partial Moolah repay converts assets to shares rounding down, which can leave
        // one raw unit more. A full repay must leave nothing.
        if (left < p.owed - pay || left > p.owed - pay + 1 || (pay == p.owed && left != 0)) {
            revert IExec.InexactTransfer();
        }
    }

    /// @dev Bring the box's money for a repayment into this contract: its idle loan token, then (when a vault
    /// is named and more is needed) one withdrawal from that vault.
    /// A Lista vault walks its whole withdraw queue on every call (millions of gas): it is called at most
    /// once, for "up to" the amount needed (the adapter never reverts for a short holding, and may hand back
    /// a little more than asked). A vault that cannot pay at all is not retried: `failed` tells the caller.
    function _pull(address loan, Repay memory p) private returns (bool failed) {
        uint256 got = _boxSend(p.account, loan, address(this));
        if (p.vaultId == bytes32(0) || (got >= p.pay && !p.closing)) return false;
        (R.Vault memory v, address adapter) = _reg.vaultFor(p.vaultId);
        if (v.token != loan) revert IExec.TokenMismatch();
        address box = _boxOf(p.account);
        if (IERC20(v.receipt).balanceOf(box) == 0) return false;
        try IStrategyVaultAdapter(adapter)
            .withdraw(v.target, v.token, p.closing ? MAX : p.pay - got, box, address(this)) { }
        catch {
            failed = true;
        }
        _untrack(p.account, p.vaultId, v);
    }

    function _ok(uint256 code) private pure {
        if (code != 0) revert IExec.ProtocolError(code);
    }
}
