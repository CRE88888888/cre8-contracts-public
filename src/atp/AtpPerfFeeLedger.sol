// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IERC20, SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { AtpRegistry } from "./AtpRegistry.sol";
import { AtpMultiPoolOracle } from "./AtpMultiPoolOracle.sol";
import { PancakeV3TwapOracle } from "./PancakeV3TwapOracle.sol";
import { IPancakeV3Pool } from "./interfaces/IPancakeV3Pool.sol";
import { AtpYieldRegistry } from "./yield/AtpYieldRegistry.sol";
import { YieldTypes as Y } from "./yield/YieldTypes.sol";

/// @notice Optional USDT deposit/withdrawal accounting, independent of the executor and Kernel.
/// Only the account calls start/withdraw (owner's sudo UserOp; never grant these to session keys).
/// Oracle or token failures revert this route atomically. The owner can ALWAYS transfer directly from
/// Kernel instead. A reporter observes bypasses off-chain and can only stop accounting, never move funds.
contract AtpPerfFeeLedger is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant BPS = 10_000;
    uint16 public constant MIN_CREATOR_FEE_BPS = 500;
    uint16 public constant MAX_CREATOR_FEE_BPS = 2_000;
    uint16 public constant MAX_PLATFORM_SHARE_BPS = 2_000;
    uint256 public constant PLATFORM_NOTICE = 7 days;

    AtpRegistry public immutable registry;
    AtpMultiPoolOracle public immutable oracle;
    AtpYieldRegistry public immutable yieldRegistry;
    IERC20 public immutable numeraire;
    address public immutable platformRecipient;

    enum Status {
        NEW,
        ACTIVE,
        STOPPED
    }

    struct Account {
        uint256 principal;
        uint256 strategyId;
        uint256 epoch;
        Status status;
    }

    struct Withdrawal {
        uint256 value;
        uint256 profit;
        uint256 fee;
        uint256 platformFee;
        uint256 remainingPrincipal;
        address creator;
        uint16 performanceFeeBps;
        bytes32 configHash;
    }

    mapping(address => Account) public accounts;
    mapping(address => bool) public reporters;
    uint16 private _platformShareBps = 1_000;
    uint16 public pendingPlatformShareBps;
    uint256 public platformShareActiveAt;

    event PlatformShareScheduled(uint16 bps, uint256 activeAt);
    event ReporterSet(address indexed reporter, bool allowed);
    event ServiceStarted(address indexed account, uint256 indexed epoch, uint256 indexed strategyId);
    event ServiceStopped(
        address indexed account, uint256 indexed epoch, address indexed reporter, bytes32 evidence
    );
    event Deposited(address indexed account, address indexed payer, uint256 amount, uint256 principal);
    event Withdrawn(
        address indexed account,
        address indexed recipient,
        address indexed creator,
        uint256 gross,
        uint256 value,
        uint256 profit,
        uint256 fee,
        uint256 platformFee,
        uint256 principal,
        uint16 performanceFeeBps,
        bytes32 configHash
    );

    error InvalidConfig();
    error Unauthorized();
    error InvalidFee();
    error ServiceNotActive();
    error AlreadyActive();
    error NotEnrolled();
    error StrategyChanged();
    error VersionNotActive();
    error InvalidAmount();
    error InvalidRecipient();
    error TransferMismatch();
    error DeadlineExpired();
    error BelowMinimum();
    error InvalidQuote();

    constructor(
        AtpRegistry registry_,
        AtpMultiPoolOracle oracle_,
        AtpYieldRegistry yieldRegistry_,
        address platformRecipient_
    ) {
        if (
            address(registry_).code.length == 0 || address(oracle_).code.length == 0
                || address(yieldRegistry_).code.length == 0 || platformRecipient_ == address(0)
                || platformRecipient_ == address(this)
        ) revert InvalidConfig();
        address quote = registry_.numeraire();
        if (
            quote.code.length == 0 || quote != oracle_.numeraire()
                || address(yieldRegistry_.registry()) != address(registry_)
        ) revert InvalidConfig();
        registry = registry_;
        oracle = oracle_;
        yieldRegistry = yieldRegistry_;
        numeraire = IERC20(quote);
        platformRecipient = platformRecipient_;
    }

    modifier onlyOwner() {
        if (msg.sender != registry.owner()) revert Unauthorized();
        _;
    }

    function platformShareBps() public view returns (uint16) {
        return platformShareActiveAt != 0 && block.timestamp >= platformShareActiveAt
            ? pendingPlatformShareBps
            : _platformShareBps;
    }

    /// @notice All changes take effect prospectively after seven days, including reductions to zero.
    function schedulePlatformShare(uint16 bps) external onlyOwner nonReentrant {
        if (bps > MAX_PLATFORM_SHARE_BPS) revert InvalidFee();
        _platformShareBps = platformShareBps();
        pendingPlatformShareBps = bps;
        platformShareActiveAt = block.timestamp + PLATFORM_NOTICE;
        emit PlatformShareScheduled(bps, platformShareActiveAt);
    }

    function setReporter(address reporter, bool allowed) external onlyOwner nonReentrant {
        if (reporter == address(0)) revert InvalidConfig();
        reporters[reporter] = allowed;
        emit ReporterSet(reporter, allowed);
    }

    /// @notice Only an explicit account call can start/restart service. Existing balances gain NO basis.
    /// The epoch lets off-chain monitors reject obsolete reports after an owner restarts.
    function start() external nonReentrant {
        if (msg.sender.code.length == 0) revert Unauthorized();
        Account storage a = accounts[msg.sender];
        if (a.status == Status.ACTIVE) revert AlreadyActive();
        (AtpRegistry.Enrollment memory e,) = _enrollment(msg.sender);
        a.principal = 0;
        a.strategyId = e.strategyId;
        ++a.epoch;
        a.status = Status.ACTIVE;
        emit ServiceStarted(msg.sender, a.epoch, a.strategyId);
    }

    /// @notice One stop per epoch. No balance heuristic: losses/trades/yield are not bypass evidence.
    /// Reporter cannot alter principal, fees, approvals, enrollment or token balances, or restart service.
    function stopService(address account, uint256 epoch, bytes32 evidence) external nonReentrant {
        if (!reporters[msg.sender]) revert Unauthorized();
        Account storage a = accounts[account];
        if (a.status != Status.ACTIVE || a.epoch != epoch) revert ServiceNotActive();
        a.status = Status.STOPPED;
        emit ServiceStopped(account, epoch, msg.sender, evidence);
    }

    /// @notice Any external payer may fund an ACTIVE account. Self-deposit cannot create fake basis.
    /// Direct ERC20 transfers bypass this function and never increase principal.
    function deposit(address account, uint256 amount) external nonReentrant {
        _activeEnrollment(account);
        if (amount == 0 || msg.sender == account) revert InvalidAmount();
        uint256 beforeBalance = numeraire.balanceOf(account);
        uint256 payerBefore = numeraire.balanceOf(msg.sender);
        numeraire.safeTransferFrom(msg.sender, account, amount);
        if (
            numeraire.balanceOf(account) != beforeBalance + amount
                || numeraire.balanceOf(msg.sender) + amount != payerBefore
        ) revert TransferMismatch();
        Account storage a = accounts[account];
        a.principal += amount;
        emit Deposited(account, msg.sender, amount, a.principal);
    }

    function previewWithdraw(address account, uint256 gross) public view returns (Withdrawal memory w) {
        (AtpRegistry.Enrollment memory e, AtpRegistry.Version memory current) = _activeEnrollment(account);
        if (gross == 0 || gross > numeraire.balanceOf(account)) revert InvalidAmount();
        w.value = _accountValue(account, e.strategyId);
        if (gross > w.value) revert InvalidAmount();
        uint256 principal = accounts[account].principal;
        if (w.value > principal) w.profit = Math.mulDiv(gross, w.value - principal, w.value);
        w.performanceFeeBps = current.performanceFeeBps;
        w.configHash = current.configHash;
        w.fee = Math.mulDiv(w.profit, w.performanceFeeBps, BPS);
        w.platformFee = Math.mulDiv(w.fee, platformShareBps(), BPS);
        // Round remaining basis UP, including V <= P. A full withdrawal always clears it.
        w.remainingPrincipal = Math.mulDiv(principal, w.value - gross, w.value, Math.Rounding.Ceil);
        (w.creator,,,) = registry.strategies(e.strategyId);
    }

    /// @notice Sell/redeem to USDT first. This route charges even during a registry pause/settings exit.
    /// minNet/deadline protect the account's quote; no caller can debit any other account's allowance.
    function withdraw(uint256 gross, address recipient, uint256 minNet, uint256 deadline)
        external
        nonReentrant
        returns (Withdrawal memory w)
    {
        if (block.timestamp > deadline) revert DeadlineExpired();
        if (recipient == address(0) || recipient == address(this) || recipient == msg.sender) {
            revert InvalidRecipient();
        }
        w = previewWithdraw(msg.sender, gross);
        uint256 net = gross - w.fee;
        if (net < minNet) revert BelowMinimum();
        accounts[msg.sender].principal = w.remainingPrincipal;
        uint256 beforeBalance = numeraire.balanceOf(address(this));
        uint256 accountBefore = numeraire.balanceOf(msg.sender);
        numeraire.safeTransferFrom(msg.sender, address(this), gross);
        if (
            numeraire.balanceOf(address(this)) != beforeBalance + gross
                || numeraire.balanceOf(msg.sender) + gross != accountBefore
        ) revert TransferMismatch();
        _payExact(recipient, net);
        if (w.platformFee != 0) _payExact(platformRecipient, w.platformFee);
        if (w.fee > w.platformFee) _payExact(w.creator, w.fee - w.platformFee);
        if (numeraire.balanceOf(address(this)) != beforeBalance) revert TransferMismatch();
        emit Withdrawn(
            msg.sender,
            recipient,
            w.creator,
            gross,
            w.value,
            w.profit,
            w.fee,
            w.platformFee,
            w.remainingPrincipal,
            w.performanceFeeBps,
            w.configHash
        );
    }

    function _payExact(address recipient, uint256 amount) private {
        uint256 beforeBalance = numeraire.balanceOf(recipient);
        numeraire.safeTransfer(recipient, amount);
        if (numeraire.balanceOf(recipient) != beforeBalance + amount) revert TransferMismatch();
    }

    /// @notice Includes the registry's deduplicated effective history, so a removed
    /// asset cannot disappear from partial-exit NAV. Unlisted gifts are outside the service's portfolio.
    /// Yield receipts use the existing registry's tracked, conservatively capped claims, counted once.
    /// Every held-asset read must succeed. Valid quotes may floor to zero; stale/failed prices must revert.
    function accountValue(address account) public view returns (uint256 value) {
        (AtpRegistry.Enrollment memory e,) = _activeEnrollment(account);
        return _accountValue(account, e.strategyId);
    }

    function _accountValue(address account, uint256 strategyId) private view returns (uint256 value) {
        value = numeraire.balanceOf(account);
        address[] memory assets = registry.historicalAssets(strategyId);
        for (uint256 i; i < assets.length; ++i) {
            address asset = assets[i];
            if (asset == address(numeraire) || yieldRegistry.receiptMarket(asset) != bytes32(0)) continue;
            uint256 held = IERC20(asset).balanceOf(account);
            if (held != 0) value += _conservativeValue(asset, held);
        }
        bytes32[] memory positions = yieldRegistry.accountMarkets(account);
        for (uint256 i; i < positions.length; ++i) {
            Y.Market memory m = yieldRegistry.market(positions[i]);
            if (IERC20(m.receipt).balanceOf(account) == 0) continue;
            uint256 underlying = yieldRegistry.receiptAssets(positions[i], account);
            // receiptAssets has already checked identity/rate. A successful zero claim is dust,
            // not a missing price, and needs no underlying oracle quote.
            if (underlying == 0) continue;
            value += m.asset == address(numeraire) ? underlying : _conservativeValue(m.asset, underlying);
        }
    }

    function _conservativeValue(address asset, uint256 amount) private view returns (uint256) {
        // Check sources at the price source's 1e18 raw-unit scale, independent of held dust.
        // Using the holding could round a healthy secondary to zero against a ceil pool quote of one.
        // The router still checks both windows/freshness/deviation; its execution floor is not NAV.
        oracle.previewSwap(asset, address(numeraire), 1e18);
        PancakeV3TwapOracle pair = oracle.oracleOf(asset);
        bool inIsToken0 = asset == pair.token0();
        IPancakeV3Pool pool = pair.pool();
        uint256 twap = _navWindow(pool, amount, pair.twapWindow(), inIsToken0);
        uint256 recent = _navWindow(pool, amount, pair.RECENT_WINDOW(), inIsToken0);
        // Source validity was checked above. A valid amount that floors to zero is legitimate dust.
        return Math.min(twap, recent);
    }

    /// @dev Router validation above remains mandatory. Re-read each mean for the dedicated NAV path:
    /// floor the tick for token0 sales, ceil it for token1 sales (whose price is the reciprocal).
    function _navWindow(IPancakeV3Pool pool, uint256 amount, uint32 window, bool inIsToken0)
        private
        view
        returns (uint256)
    {
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = window;
        int56[] memory ticks;
        try pool.observe(secondsAgos) returns (int56[] memory observed, uint160[] memory) {
            ticks = observed;
        } catch {
            revert PancakeV3TwapOracle.TwapUnavailable();
        }
        if (ticks.length != 2) revert PancakeV3TwapOracle.TwapUnavailable();
        int56 delta;
        unchecked {
            delta = ticks[1] - ticks[0];
        }
        int56 divisor = int56(uint56(window));
        int56 mean = delta / divisor;
        if (delta % divisor != 0) {
            if (inIsToken0 && delta < 0) --mean;
            else if (!inIsToken0 && delta > 0) ++mean;
        }
        if (mean < -887_272 || mean > 887_272) revert PancakeV3TwapOracle.InvalidPoolPrice();
        return PerfFeeNavMath.quote(amount, inIsToken0 ? mean : -mean);
    }

    /// @dev Enrollment.version is the original consent record (also used by yield policy), not the fee.
    /// version(id, 0) follows P11 activation/cancellation and commits the fee in the full configHash.
    function _enrollment(address account)
        private
        view
        returns (AtpRegistry.Enrollment memory e, AtpRegistry.Version memory current)
    {
        if (!registry.isEnrolled(account)) revert NotEnrolled();
        e = registry.enrollments(account);
        current = registry.version(e.strategyId, 0);
        if (current.activeAt > block.timestamp) revert VersionNotActive();
        if (
            current.performanceFeeBps < MIN_CREATOR_FEE_BPS || current.performanceFeeBps > MAX_CREATOR_FEE_BPS
        ) {
            revert InvalidFee();
        }
    }

    function _activeEnrollment(address account)
        private
        view
        returns (AtpRegistry.Enrollment memory e, AtpRegistry.Version memory current)
    {
        Account storage a = accounts[account];
        if (a.status != Status.ACTIVE) revert ServiceNotActive();
        (e, current) = _enrollment(account);
        if (a.strategyId != e.strategyId) revert StrategyChanged();
    }
}

/// @dev Direct raw-unit price bounds, without a rounded-up sqrt price or reciprocal of a lower bound.
/// Each multiply/divide floors a positive rational, so the result never exceeds amount * 1.0001^tick.
/// Q192 for prices below one preserves precision even at MIN_TICK; Q128 above one fits MAX_TICK.
library PerfFeeNavMath {
    function quote(uint256 amount, int56 saleTick) internal pure returns (uint256) {
        uint256 unit = saleTick < 0 ? 1 << 192 : 1 << 128;
        uint256 factor = saleTick < 0 ? unit * 10_000 / 10_001 : unit * 10_001 / 10_000;
        uint256 exponent = uint256(uint56(saleTick < 0 ? -saleTick : saleTick));
        uint256 price = unit;
        while (exponent != 0) {
            if (exponent & 1 != 0) price = Math.mulDiv(price, factor, unit);
            exponent >>= 1;
            if (exponent != 0) factor = Math.mulDiv(factor, factor, unit);
        }
        return Math.mulDiv(amount, price, unit);
    }
}
