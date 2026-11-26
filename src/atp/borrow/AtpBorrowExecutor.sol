// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { AtpRegistry } from "../AtpRegistry.sol";
import { AtpYieldRegistry } from "../yield/AtpYieldRegistry.sol";
import { AtpBorrowRegistry } from "./AtpBorrowRegistry.sol";
import { BorrowTypes as B } from "./BorrowTypes.sol";
import { BorrowReader } from "./BorrowReader.sol";
import { IVenusComptroller, IVBorrowToken, IMoolahCore } from "./BorrowInterfaces.sol";

interface IAtpExecutorPins {
    function registry() external view returns (AtpRegistry);
    function yieldRegistry() external view returns (AtpYieldRegistry);
    function numeraire() external view returns (address);
    function globalPaused() external view returns (bool);
}

/// @title AtpBorrowExecutor
/// @notice Strategy Earn for one portfolio account (#64, docs EARN_UX §B/§D): post the asset as collateral in
/// its one designated market, borrow USDT at a conservative LTV straight into a whitelisted USDT vault, and
/// unwind (vault -> repay -> collateral back). A separate contract next to `AtpExecutor` (whose address, yield
/// registry and session policies are already wired into the backend, and which has ~2.8 KB of code room left);
/// it shares that executor's registry, yield registry, numeraire and global kill switch.
/// @dev The strategy's USDT never becomes free cash (EARN_UX §三種錢): borrowed USDT goes from the protocol to
/// this contract and into the earn vault for the same account in one call, and every repay path takes vault
/// shares from that account only to pay that account's debt. No function takes a receiver; leftover vault
/// shares after a full repayment are redeemed into the same portfolio account, never elsewhere.
/// Trust model as `AtpExecutor.executeSupply`: `msg.sender` must be the account itself (a session key reaches
/// here only through the account's own `execute()`), except `executeDeleverage`, which anyone may call once the
/// position crosses a safety line: it can only repay the account's own debt from its own strategy vault shares.
/// This contract holds no balance between calls and leaves no allowance behind.
contract AtpBorrowExecutor is ReentrancyGuard {
    using SafeERC20 for IERC20;

    AtpRegistry public immutable registry;
    IAtpExecutorPins public immutable atpExecutor;
    address public immutable numeraire;
    AtpBorrowRegistry public immutable borrowRegistry;

    event CollateralSupplied(
        address indexed account, bytes32 indexed marketId, uint256 amount, uint256 collateral
    );
    event Borrowed(
        address indexed account, bytes32 indexed marketId, uint256 amount, uint256 vaultShares, uint256 ltv
    );
    event Repaid(
        address indexed account,
        bytes32 indexed marketId,
        uint256 amount,
        uint256 vaultSharesUsed,
        uint256 debt
    );
    event Deleveraged(
        address indexed account, bytes32 indexed marketId, uint256 repaid, uint256 ltvBefore, uint256 ltvAfter
    );
    event CollateralWithdrawn(
        address indexed account, bytes32 indexed marketId, uint256 amount, uint256 collateral, uint256 ltv
    );

    error NotAccount();
    error NotContract();
    error DeadlineExpired();
    error ExecutorPaused();
    error ZeroAmount();
    error InvalidConfig();
    error ProtocolError(uint256 code);
    error InexactTransfer();
    error NothingToRepay();
    error NothingToDo();
    error InsufficientVaultShares(uint256 needed, uint256 held);
    error DebtAboveConsent(uint256 debt, uint256 maxDebt);
    error LtvTooHigh(uint256 ltv, uint256 maximum);
    error BorrowGateClosed(B.Gate gate);

    constructor(AtpRegistry registry_, address atpExecutor_) {
        if (address(registry_).code.length == 0 || atpExecutor_.code.length == 0) revert InvalidConfig();
        IAtpExecutorPins core = IAtpExecutorPins(atpExecutor_);
        if (address(core.registry()) != address(registry_)) revert InvalidConfig();
        registry = registry_;
        atpExecutor = core;
        numeraire = core.numeraire();
        borrowRegistry = new AtpBorrowRegistry(registry_, core.yieldRegistry(), address(this), numeraire);
    }

    // ---- actions ----

    /// @notice Pull `amount` collateral from the account and post it for the account (Venus also enters the market).
    function executeSupplyCollateral(address account, bytes32 marketId, uint256 amount, uint256 deadline)
        external
        nonReentrant
    {
        _caller(account, deadline);
        _live();
        if (amount == 0) revert ZeroAmount();
        B.Market memory m = borrowRegistry.beforeCollateral(account, marketId);
        IERC20 token = IERC20(m.collateral);
        uint256 base = token.balanceOf(address(this));
        uint256 before = BorrowReader.collateral(m, account);
        token.safeTransferFrom(account, address(this), amount);
        if (token.balanceOf(address(this)) - base != amount) revert InexactTransfer();
        if (m.kind == B.Kind.VENUS) {
            token.forceApprove(m.collateralVToken, amount);
            _ok(IVBorrowToken(m.collateralVToken).mintBehalf(account, amount));
            token.forceApprove(m.collateralVToken, 0);
            IVenusComptroller c = IVenusComptroller(m.core);
            if (!c.checkMembership(account, m.collateralVToken)) {
                _ok(c.enterMarketBehalf(account, m.collateralVToken));
            }
        } else {
            token.forceApprove(m.core, amount);
            IMoolahCore(m.core).supplyCollateral(BorrowReader.params(m), amount, account, "");
            token.forceApprove(m.core, 0);
        }
        if (token.balanceOf(address(this)) != base) revert InexactTransfer();
        uint256 posted = BorrowReader.collateral(m, account);
        if (posted <= before) revert InexactTransfer();
        borrowRegistry.recordCollateral(account, marketId);
        emit CollateralSupplied(account, marketId, amount, posted);
    }

    /// @notice Borrow exactly `amount` of USDT against the account's collateral and deposit it into the earn
    /// vault for the account, in this call. Needs: consent and its debt ceiling, the CRE8 cap, the gates
    /// (vault utilization <= 90%, no negative carry net of incentives, borrow-market utilization <= 85% after),
    /// and the
    /// position's LTV <= target LTV afterwards.
    function executeBorrow(address account, bytes32 marketId, uint256 amount, uint256 deadline)
        external
        nonReentrant
    {
        _caller(account, deadline);
        _live();
        if (amount == 0) revert ZeroAmount();
        (B.Market memory m, uint256 maxDebt) = borrowRegistry.beforeBorrow(account, marketId, amount);
        BorrowReader.sync(m, account);
        if (
            borrowRegistry.refreshVaultUtilization(marketId)
                > borrowRegistry.MAX_VAULT_SUPPLY_UTILIZATION_BPS()
        ) {
            revert BorrowGateClosed(B.Gate.VAULT_UTILIZATION);
        }
        (bool known, bool negative) = borrowRegistry.carry(marketId);
        if (!known) revert BorrowGateClosed(B.Gate.VAULT_UNREADABLE);
        if (negative) revert BorrowGateClosed(B.Gate.NEGATIVE_CARRY);

        IERC20 loan = IERC20(m.loan);
        uint256 base = loan.balanceOf(address(this));
        uint256 accountCash = loan.balanceOf(account);
        if (m.kind == B.Kind.VENUS) {
            _ok(IVBorrowToken(m.loanVToken).borrowBehalf(account, amount));
        } else {
            (uint256 assets,) =
                IMoolahCore(m.core).borrow(BorrowReader.params(m), amount, 0, account, address(this));
            if (assets != amount) revert InexactTransfer();
        }
        if (loan.balanceOf(address(this)) - base != amount) revert InexactTransfer();
        if (BorrowReader.borrowUtilization(m) > borrowRegistry.MAX_BORROW_UTILIZATION_BPS()) {
            revert BorrowGateClosed(B.Gate.BORROW_UTILIZATION);
        }
        IERC4626 vault = IERC4626(m.earnVault);
        uint256 sharesBefore = vault.balanceOf(account);
        loan.forceApprove(address(vault), amount);
        uint256 shares = vault.deposit(amount, account);
        loan.forceApprove(address(vault), 0);
        if (
            shares == 0 || vault.balanceOf(account) - sharesBefore != shares
                || loan.balanceOf(address(this)) != base || loan.balanceOf(account) != accountCash
        ) revert InexactTransfer();

        uint256 owed = BorrowReader.debt(m, account);
        if (owed > maxDebt) revert DebtAboveConsent(owed, maxDebt);
        uint256 ltv = _checkLtv(m, marketId, account);
        borrowRegistry.recordBorrow(account, marketId, amount, shares);
        emit Borrowed(account, marketId, amount, shares, ltv);
    }

    /// @notice Repay up to `amount` (capped at the debt; `type(uint256).max` = all). `fromVault`: pay from this
    /// position's own vault shares first (closing the strategy), any remainder from the portfolio account's own
    /// USDT; otherwise only from USDT already in the portfolio account (e.g. sale proceeds). After a full repayment the remaining strategy shares are redeemed into the account;
    /// with no debt left, `fromVault` releases them on their own.
    /// Open during pauses and after retirement.
    function executeRepay(address account, bytes32 marketId, uint256 amount, bool fromVault, uint256 deadline)
        external
        nonReentrant
    {
        _caller(account, deadline);
        if (amount == 0) revert ZeroAmount();
        B.Market memory m = borrowRegistry.market(marketId);
        BorrowReader.sync(m, account);
        uint256 owed = BorrowReader.debt(m, account);
        if (owed != 0) {
            _repay(m, marketId, account, Math.min(amount, owed), owed, fromVault, true);
            return;
        }
        // No debt left (repaid from cash earlier, or liquidated): release the strategy's remaining vault
        // shares into the same account.
        uint256 held = borrowRegistry.heldVaultShares(marketId, account);
        if (!fromVault || held == 0) revert NothingToRepay();
        IERC4626(m.earnVault).redeem(held, account, account);
        borrowRegistry.recordRepay(account, marketId, 0, held);
        emit Repaid(account, marketId, 0, held, 0);
    }

    /// @notice Anyone may call. LTV at or above the deleverage line: repay from the position's own vault shares
    /// back to the target LTV. Negative carry or earn-vault utilization above 95%: repay all it can (unwind).
    /// Repayment is capped by what the vault can pay out now; the backend sells collateral for any rest.
    function executeDeleverage(address account, bytes32 marketId) external nonReentrant {
        B.Market memory m = borrowRegistry.market(marketId);
        BorrowReader.sync(m, account);
        uint256 owed = BorrowReader.debt(m, account);
        if (owed == 0) revert NothingToRepay();
        B.Health memory h = BorrowReader.health(m, account);
        uint256 ltvBefore = BorrowReader.ltv(h);
        uint256 pay;
        if (ltvBefore >= borrowRegistry.deleverageLtv(marketId)) {
            // Debt value at target = targetLtv x collateral value; repay the rest, rounded up by a raw unit.
            uint256 targetValue = Math.mulDiv(borrowRegistry.targetLtv(marketId), h.collateralValue, 1e18);
            pay = Math.min(
                owed, Math.mulDiv(owed, h.debtValue - targetValue, h.debtValue, Math.Rounding.Ceil) + 1
            );
        } else if (_shouldUnwind(marketId)) {
            pay = owed;
        } else {
            revert NothingToDo();
        }
        IERC4626 vault = IERC4626(m.earnVault);
        uint256 available = Math.min(
            vault.previewRedeem(borrowRegistry.heldVaultShares(marketId, account)), vault.maxWithdraw(account)
        );
        pay = Math.min(pay, available);
        if (pay == 0) revert InsufficientVaultShares(owed, 0);
        _repay(m, marketId, account, pay, owed, true, false);
        emit Deleveraged(account, marketId, pay, ltvBefore, BorrowReader.ltv(BorrowReader.health(m, account)));
    }

    /// @notice Return `amount` collateral (raw underlying; `type(uint256).max` = all) to the account. With debt
    /// left, the LTV must stay at or below the target. Open during pauses and after retirement.
    function executeWithdrawCollateral(address account, bytes32 marketId, uint256 amount, uint256 deadline)
        external
        nonReentrant
    {
        _caller(account, deadline);
        if (amount == 0) revert ZeroAmount();
        B.Market memory m = borrowRegistry.market(marketId);
        BorrowReader.sync(m, account);
        IERC20 token = IERC20(m.collateral);
        uint256 base = token.balanceOf(address(this));
        uint256 before = token.balanceOf(account);
        uint256 received;
        if (m.kind == B.Kind.VENUS) {
            IVBorrowToken v = IVBorrowToken(m.collateralVToken);
            if (amount == type(uint256).max) {
                uint256 shares = v.balanceOf(account);
                if (shares == 0) revert ZeroAmount();
                _ok(v.redeemBehalf(account, shares));
            } else {
                _ok(v.redeemUnderlyingBehalf(account, amount));
            }
            received = token.balanceOf(address(this)) - base;
            if (received == 0 || (amount != type(uint256).max && received != amount)) {
                revert InexactTransfer();
            }
            token.safeTransfer(account, received);
        } else {
            received = amount == type(uint256).max ? BorrowReader.collateral(m, account) : amount;
            if (received == 0) revert ZeroAmount();
            IMoolahCore(m.core).withdrawCollateral(BorrowReader.params(m), received, account, account);
        }
        if (token.balanceOf(account) - before != received || token.balanceOf(address(this)) != base) {
            revert InexactTransfer();
        }
        uint256 ltv = BorrowReader.debt(m, account) == 0 ? 0 : _checkLtv(m, marketId, account);
        borrowRegistry.recordWithdrawCollateral(account, marketId);
        emit CollateralWithdrawn(account, marketId, received, BorrowReader.collateral(m, account), ltv);
    }

    // ---- internals ----

    function _repay(
        B.Market memory m,
        bytes32 marketId,
        address account,
        uint256 pay,
        uint256 owed,
        bool fromVault,
        bool cashFallback
    ) private {
        IERC20 loan = IERC20(m.loan);
        IERC4626 vault = IERC4626(m.earnVault);
        uint256 base = loan.balanceOf(address(this));
        uint256 held = borrowRegistry.heldVaultShares(marketId, account);
        uint256 sharesUsed;
        uint256 fromCash = pay;
        if (fromVault) {
            // Vault first. When the strategy's shares are worth no more than `pay` (closing, or a vault a few
            // raw units short from share rounding) redeem them all; the account's own USDT covers the rest.
            uint256 worth = vault.previewRedeem(held);
            if (pay < worth) {
                sharesUsed = vault.withdraw(pay, address(this), account);
                fromCash = 0;
            } else if (held != 0) {
                fromCash = pay - vault.redeem(held, address(this), account);
                sharesUsed = held;
            }
            if (fromCash != 0 && !cashFallback) revert InsufficientVaultShares(pay, worth);
        }
        if (fromCash != 0) loan.safeTransferFrom(account, address(this), fromCash);
        if (loan.balanceOf(address(this)) - base != pay) revert InexactTransfer();
        if (m.kind == B.Kind.VENUS) {
            loan.forceApprove(m.loanVToken, pay);
            _ok(IVBorrowToken(m.loanVToken).repayBorrowBehalf(account, pay));
            loan.forceApprove(m.loanVToken, 0);
        } else {
            loan.forceApprove(m.core, pay);
            if (pay == owed) {
                // Repay by shares so no dust share is left behind.
                (, uint128 shares,) = IMoolahCore(m.core).position(m.listaId, account);
                IMoolahCore(m.core).repay(BorrowReader.params(m), 0, shares, account, "");
            } else {
                IMoolahCore(m.core).repay(BorrowReader.params(m), pay, 0, account, "");
            }
            loan.forceApprove(m.core, 0);
        }
        if (loan.balanceOf(address(this)) != base) revert InexactTransfer();
        uint256 left = BorrowReader.debt(m, account);
        // Debt falls by `pay`; a partial Moolah repay converts assets to shares rounding down, which can leave
        // one raw unit more. A full repay must leave nothing.
        if (left < owed - pay || left > owed - pay + 1 || (pay == owed && left != 0)) {
            revert InexactTransfer();
        }
        if (left == 0 && held > sharesUsed) {
            // Strategy closed: what is left in the vault for this route goes back into the same account.
            uint256 rest = held - sharesUsed;
            if (vault.previewRedeem(rest) <= vault.maxWithdraw(account)) {
                vault.redeem(rest, account, account);
                sharesUsed = held;
            }
        }
        borrowRegistry.recordRepay(account, marketId, pay, sharesUsed);
        emit Repaid(account, marketId, pay, sharesUsed, left);
    }

    function _shouldUnwind(bytes32 marketId) private returns (bool) {
        (, bool negative) = borrowRegistry.carry(marketId);
        if (negative) return true;
        try borrowRegistry.refreshVaultUtilization(marketId) returns (uint256 u) {
            return u > borrowRegistry.VAULT_EXIT_UTILIZATION_BPS();
        } catch {
            return false;
        }
    }

    function _caller(address account, uint256 deadline) private view {
        if (msg.sender != account) revert NotAccount();
        if (account.code.length == 0) revert NotContract();
        if (block.timestamp > deadline) revert DeadlineExpired();
    }

    function _live() private view {
        if (atpExecutor.globalPaused()) revert ExecutorPaused();
    }

    function _ok(uint256 code) private pure {
        if (code != 0) revert ProtocolError(code);
    }

    function _checkLtv(B.Market memory m, bytes32 marketId, address account)
        private
        view
        returns (uint256 ltv)
    {
        ltv = BorrowReader.ltv(BorrowReader.health(m, account));
        uint256 maximum = borrowRegistry.targetLtv(marketId);
        if (ltv > maximum) revert LtvTooHigh(ltv, maximum);
    }
}
