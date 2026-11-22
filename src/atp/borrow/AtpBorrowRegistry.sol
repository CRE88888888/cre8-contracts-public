// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { AtpRegistry } from "../AtpRegistry.sol";
import { AtpYieldRegistry } from "../yield/AtpYieldRegistry.sol";
import { YieldTypes as Y } from "../yield/YieldTypes.sol";
import { BorrowTypes as B } from "./BorrowTypes.sol";
import { BorrowReader } from "./BorrowReader.sol";
import {
    IVenusComptroller,
    IVBorrowToken,
    IMoolahCore,
    IListaOracle,
    IVenusOracle
} from "./BorrowInterfaces.sol";
import { MoolahParams } from "../yield/YieldInterfaces.sol";

/// @dev Rate getters the chain 97 mocks publish. Real markets do not, and read as 0 / unknown.
interface ISimulatedApr {
    function aprBps() external view returns (uint16);
    function incentiveAprBps() external view returns (uint16);
    function supplyIncentiveAprBps() external view returns (uint16);
    function borrowIncentiveAprBps() external view returns (uint16);
}

interface ISimulatedMoolahIncentives {
    function collateralIncentiveAprBps(bytes32 id) external view returns (uint16);
    function borrowIncentiveAprBps(bytes32 id) external view returns (uint16);
}

/// @notice Admission, consent, caps and the EARN_UX §D safety rules for `AtpBorrowExecutor` (#64).
/// Built by the executor and bound to it forever, like `AtpYieldRegistry`. The registry owner (one admin key,
/// `AtpRegistry.owner()`) lists markets, fixes each collateral asset's one market (§B.3) and may make the LTV
/// lines more conservative per market, never looser than the hard caps below. It can always stop new borrowing,
/// never block repayment, deleveraging or the return of collateral.
/// @dev Hard caps (§D), relative to the market's own factor F (Venus collateral factor, Lista LLTV; both are the
/// market's maximum borrow ratio and its liquidation line in these markets):
/// target LTV <= F / 2; deleverage LTV <= F x 2/3. New borrowing also needs: borrow-market utilization <= 85%
/// after the borrow, earn-vault utilization <= 90%, borrow rate <= vault rate. Above 95% vault utilization or with
/// a negative carry, anyone may unwind the position from its own vault shares.
contract AtpBorrowRegistry {
    uint256 internal constant MAX_MARKETS = 32;
    /// @notice Target-LTV ceilings per risk class (§D); the effective target is also never above F / 2.
    uint256 public constant INDEX_LARGE_CAP_LTV = 0.35e18;
    uint256 public constant STOCK_LTV = 0.3e18;
    uint256 public constant CRYPTO_LINKED_LTV = 0.2e18;
    uint256 public constant MAX_BORROW_UTILIZATION_BPS = 8_500;
    uint256 public constant MAX_VAULT_SUPPLY_UTILIZATION_BPS = 9_000;
    uint256 public constant VAULT_EXIT_UTILIZATION_BPS = 9_500;

    AtpRegistry public immutable registry;
    AtpYieldRegistry public immutable yields;
    address public immutable executor;
    address public immutable numeraire;
    /// @notice Stops new collateral and new borrowing everywhere. Repay, deleverage and withdrawal stay open.
    bool public borrowPaused;

    bytes32[] public marketIds;
    mapping(bytes32 => B.Market) private _markets;
    /// @notice The one market each collateral asset goes to; only it admits new collateral and borrowing.
    /// Positions in a previously designated market keep every exit. Unlisted assets (leveraged ETFs and very
    /// volatile assets, §D) have none, so strategy earn is closed for them.
    mapping(address => bytes32) public collateralMarket;

    struct LtvConfig {
        uint128 target;
        uint128 deleverage;
    }
    /// @notice Owner's more conservative lines per market (18 decimals); 0 = the hard cap.
    mapping(bytes32 => LtvConfig) public ltvConfig;

    mapping(bytes32 => uint256) public totalPrincipal;
    mapping(address => mapping(bytes32 => uint256)) public principal;
    /// @notice Earn-vault shares this route deposited for the account: the strategy's USDT (§三種錢). Only the
    /// executor's repay paths redeem them, always back into this same account's debt or the account itself.
    mapping(address => mapping(bytes32 => uint256)) public vaultShares;
    mapping(address => bytes32[]) private _positions;
    mapping(address => mapping(bytes32 => uint256)) private _positionIndex;

    struct Policy {
        uint256 maxDebt;
        uint256 strategyId;
        uint16 version;
        bool enabled;
    }
    /// @notice Account-owner consent per market: may post collateral and keep at most `maxDebt` (loan raw,
    /// interest included) outstanding. Pinned to the enrollment; re-enrolling needs fresh consent.
    mapping(address => mapping(bytes32 => Policy)) public policies;

    event MarketRegistered(
        bytes32 indexed marketId, B.Kind kind, address indexed collateral, address indexed loan, address core
    );
    event CollateralMarketSet(address indexed collateral, bytes32 indexed marketId);
    event MarketBorrowSet(bytes32 indexed marketId, bool enabled, bool retired);
    event BorrowCapSet(bytes32 indexed marketId, uint256 cap);
    event BorrowPausedSet(bool paused);
    event LtvConfigSet(bytes32 indexed marketId, uint256 target, uint256 deleverage);
    event BorrowPolicySet(address indexed account, bytes32 indexed marketId, uint256 maxDebt, bool enabled);
    event PrincipalReconciled(address indexed account, bytes32 indexed marketId, uint256 removed);

    error Unauthorized();
    error UnknownMarket();
    error BadMarket();
    error BadParameter();
    error AdmissionClosed();
    error NotDesignatedMarket(bytes32 designated);
    error ConsentRequired();
    error BorrowCapExceeded(uint256 requested, uint256 available);
    error InvalidConstructor();

    constructor(AtpRegistry registry_, AtpYieldRegistry yields_, address executor_, address numeraire_) {
        if (
            address(registry_).code.length == 0 || address(yields_).code.length == 0
                || numeraire_.code.length == 0 || address(yields_.registry()) != address(registry_)
        ) revert InvalidConstructor();
        if (executor_.code.length == 0 && msg.sender != executor_) revert InvalidConstructor();
        registry = registry_;
        yields = yields_;
        executor = executor_;
        numeraire = numeraire_;
    }

    modifier onlyOwner() {
        if (msg.sender != registry.owner()) revert Unauthorized();
        _;
    }

    modifier onlyExecutor() {
        if (msg.sender != executor) revert Unauthorized();
        _;
    }

    // ---- admin ----

    /// @notice List a market. The first market listed for a collateral asset becomes its designated market.
    /// `m.earnVault` is ignored and resolved from `m.vaultMarketId`.
    function registerMarket(bytes32 id, B.Market memory m) external onlyOwner {
        if (id == bytes32(0) || _markets[id].kind != B.Kind.NONE || marketIds.length == MAX_MARKETS) {
            revert BadMarket();
        }
        Y.Market memory vault = yields.market(m.vaultMarketId);
        m.earnVault = vault.receipt;
        if (
            m.retired || m.tier == B.Tier.NONE || m.loan != numeraire || m.collateral == m.loan
                || m.core.code.length == 0 || vault.kind != Y.Kind.LISTA || vault.asset != m.loan
                || IERC4626(vault.receipt).asset() != m.loan
        ) revert BadMarket();
        if (m.kind == B.Kind.VENUS) {
            IVenusComptroller c = IVenusComptroller(m.core);
            (bool collateralListed, uint256 factor,) = c.markets(m.collateralVToken);
            (bool loanListed,,) = c.markets(m.loanVToken);
            if (
                !collateralListed || factor == 0 || !loanListed || m.listaId != bytes32(0)
                    || IVBorrowToken(m.collateralVToken).underlying() != m.collateral
                    || IVBorrowToken(m.loanVToken).underlying() != m.loan
                    || IVBorrowToken(m.collateralVToken).comptroller() != m.core
                    || IVBorrowToken(m.loanVToken).comptroller() != m.core
            ) revert BadMarket();
            IVenusOracle oracle = IVenusOracle(c.oracle());
            if (
                oracle.getUnderlyingPrice(m.collateralVToken) == 0
                    || oracle.getUnderlyingPrice(m.loanVToken) == 0
            ) {
                revert BadMarket();
            }
        } else if (m.kind == B.Kind.LISTA) {
            MoolahParams memory p = IMoolahCore(m.core).idToMarketParams(m.listaId);
            if (
                p.loanToken != m.loan || p.collateralToken != m.collateral || p.lltv == 0 || p.lltv >= 1e18
                    || m.collateralVToken != address(0) || m.loanVToken != address(0)
                    || IListaOracle(p.oracle).peek(m.collateral) == 0
                    || IListaOracle(p.oracle).peek(m.loan) == 0
            ) revert BadMarket();
        } else {
            revert BadMarket();
        }
        _markets[id] = m;
        marketIds.push(id);
        emit MarketRegistered(id, m.kind, m.collateral, m.loan, m.core);
        emit MarketBorrowSet(id, m.borrowEnabled, false);
        emit BorrowCapSet(id, m.borrowCap);
        if (collateralMarket[m.collateral] == bytes32(0)) {
            collateralMarket[m.collateral] = id;
            emit CollateralMarketSet(m.collateral, id);
        }
    }

    /// @notice Move an asset's designated market. Existing positions elsewhere keep every exit.
    function setCollateralMarket(address asset, bytes32 id) external onlyOwner {
        if (market(id).collateral != asset) revert BadMarket();
        collateralMarket[asset] = id;
        emit CollateralMarketSet(asset, id);
    }

    /// @notice Retiring is permanent and stops new collateral and borrowing; exits stay open.
    function setMarketBorrow(bytes32 id, bool enabled, bool retire) external onlyOwner {
        B.Market storage m = _market(id);
        if ((m.retired || retire) && enabled) revert BadMarket();
        if (retire) m.retired = true;
        m.borrowEnabled = enabled;
        emit MarketBorrowSet(id, enabled, m.retired);
    }

    function setBorrowCap(bytes32 id, uint256 cap) external onlyOwner {
        _market(id).borrowCap = cap;
        emit BorrowCapSet(id, cap);
    }

    function setBorrowPaused(bool paused) external onlyOwner {
        borrowPaused = paused;
        emit BorrowPausedSet(paused);
    }

    /// @notice More conservative lines for one market; 0 restores the hard cap. Never above the caps.
    function setLtvConfig(bytes32 id, uint256 target, uint256 deleverage) external onlyOwner {
        uint256 targetCap = _targetCap(id);
        uint256 deleverageCap = liquidationLtv(id) * 2 / 3;
        uint256 t = target == 0 ? targetCap : target;
        uint256 d = deleverage == 0 ? deleverageCap : deleverage;
        if (t > targetCap || d > deleverageCap || t >= d) revert BadParameter();
        ltvConfig[id] = LtvConfig(uint128(target), uint128(deleverage));
        emit LtvConfigSet(id, t, d);
    }

    // ---- account consent ----

    /// @notice Account-owner call. Besides this, the owner grants the executor once on the protocol itself
    /// (Venus `comptroller.updateDelegate(executor, true)`, Lista `moolah.setAuthorization(executor, true)`) and
    /// approves it for the collateral, the numeraire and the earn vault's shares.
    function setBorrowPolicy(bytes32 id, uint256 maxDebt, bool enabled) external {
        market(id);
        if (msg.sender.code.length == 0 || !registry.isEnrolled(msg.sender) || (enabled && maxDebt == 0)) {
            revert ConsentRequired();
        }
        AtpRegistry.Enrollment memory e = registry.enrollments(msg.sender);
        policies[msg.sender][id] = Policy(maxDebt, e.strategyId, e.version, enabled);
        emit BorrowPolicySet(msg.sender, id, maxDebt, enabled);
    }

    // ---- executor hooks ----

    function beforeCollateral(address account, bytes32 id)
        external
        view
        onlyExecutor
        returns (B.Market memory m)
    {
        m = _admit(id);
        _consent(account, id);
    }

    function beforeBorrow(address account, bytes32 id, uint256 amount)
        external
        view
        onlyExecutor
        returns (B.Market memory m, uint256 maxDebt)
    {
        m = _admit(id);
        if (!m.borrowEnabled) revert AdmissionClosed();
        maxDebt = _consent(account, id);
        uint256 used = totalPrincipal[id];
        uint256 available = m.borrowCap > used ? m.borrowCap - used : 0;
        if (amount > available) revert BorrowCapExceeded(amount, available);
    }

    function recordCollateral(address account, bytes32 id) external onlyExecutor {
        _track(account, id);
    }

    function recordBorrow(address account, bytes32 id, uint256 amount, uint256 shares) external onlyExecutor {
        principal[account][id] += amount;
        totalPrincipal[id] += amount;
        vaultShares[account][id] += shares;
        _track(account, id);
    }

    /// @notice Repaid assets retire principal first; interest repaid beyond principal does not go negative.
    function recordRepay(address account, bytes32 id, uint256 repaid, uint256 sharesOut)
        external
        onlyExecutor
    {
        uint256 removed = Math.min(principal[account][id], repaid);
        principal[account][id] -= removed;
        totalPrincipal[id] -= removed;
        vaultShares[account][id] -= Math.min(vaultShares[account][id], sharesOut);
        _reconcile(account, id);
    }

    function recordWithdrawCollateral(address account, bytes32 id) external onlyExecutor {
        _reconcile(account, id);
    }

    /// @notice Permissionless: after a liquidation or an external repayment, lower tracked principal to the
    /// real debt (and tracked vault shares to what the account holds) and drop an empty position.
    function reconcile(address account, bytes32 id) external {
        market(id);
        _reconcile(account, id);
    }

    /// @notice Accrue the earn vault's markets and read its utilization (bps). Reverts while the vault cannot be
    /// read safely (paused, stale, configuration drift, rate anomaly), which closes new borrowing.
    function refreshVaultUtilization(bytes32 id) public returns (uint256) {
        return yields.refreshHealth(market(id).vaultMarketId).utilizationBps;
    }

    // ---- reads ----

    function marketCount() external view returns (uint256) {
        return marketIds.length;
    }

    function market(bytes32 id) public view returns (B.Market memory m) {
        m = _markets[id];
        if (m.kind == B.Kind.NONE) revert UnknownMarket();
    }

    /// @notice Markets where the account still has collateral, debt or vault shares from this route.
    function accountMarkets(address account) external view returns (bytes32[] memory) {
        return _positions[account];
    }

    function debt(bytes32 id, address account) external view returns (uint256) {
        return BorrowReader.debt(market(id), account);
    }

    function collateral(bytes32 id, address account) external view returns (uint256) {
        return BorrowReader.collateral(market(id), account);
    }

    /// @notice Strategy vault shares the account still holds for this route (tracked, capped by its balance).
    function heldVaultShares(bytes32 id, address account) public view returns (uint256) {
        return Math.min(vaultShares[account][id], IERC4626(market(id).earnVault).balanceOf(account));
    }

    /// @notice Health at the last accrual; `status` (eth_call) accrues first.
    function health(bytes32 id, address account) external view returns (B.Health memory) {
        return BorrowReader.health(market(id), account);
    }

    function liquidationLtv(bytes32 id) public view returns (uint256) {
        return BorrowReader.liquidationFactor(market(id));
    }

    /// @notice CRE8 borrows up to this LTV and deleveraging restores it: min(owner line, class ceiling, F / 2).
    function targetLtv(bytes32 id) public view returns (uint256) {
        uint256 cap = _targetCap(id);
        uint256 set = ltvConfig[id].target;
        return set == 0 ? cap : Math.min(set, cap);
    }

    /// @notice At or above this LTV anyone may deleverage the position: min(owner line, F x 2/3).
    function deleverageLtv(bytes32 id) public view returns (uint256) {
        uint256 cap = liquidationLtv(id) * 2 / 3;
        uint256 set = ltvConfig[id].deleverage;
        return set == 0 ? cap : Math.min(set, cap);
    }

    /// @notice Yearly vault rate (18 decimals): the simulated APR on chain 97 mocks. A vault without an on-chain
    /// rate reads as unknown, which keeps new borrowing closed (the negative-carry rule cannot be checked).
    function vaultRate(bytes32 id) public view returns (bool known, uint256 rate) {
        try ISimulatedApr(market(id).earnVault).aprBps() returns (uint16 bps) {
            return (true, uint256(bps) * 1e14);
        } catch {
            return (false, 0);
        }
    }

    /// @notice Incentive APRs (18 decimals) the market publishes: rewards on posted collateral, on debt (can make
    /// the net borrow rate negative) and on the earn vault. Rewards accrue to the account holding the position.
    function incentiveRates(bytes32 id)
        public
        view
        returns (uint256 collateralRate, uint256 borrowRate, uint256 vaultRate_)
    {
        B.Market memory m = market(id);
        if (m.kind == B.Kind.VENUS) {
            collateralRate =
                _bps(m.collateralVToken, ISimulatedApr.supplyIncentiveAprBps.selector, bytes32(0));
            borrowRate = _bps(m.loanVToken, ISimulatedApr.borrowIncentiveAprBps.selector, bytes32(0));
        } else {
            collateralRate =
                _bps(m.core, ISimulatedMoolahIncentives.collateralIncentiveAprBps.selector, m.listaId);
            borrowRate = _bps(m.core, ISimulatedMoolahIncentives.borrowIncentiveAprBps.selector, m.listaId);
        }
        vaultRate_ = _bps(m.earnVault, ISimulatedApr.incentiveAprBps.selector, bytes32(0));
    }

    /// @notice Is the carry negative: borrow rate net of its incentive above the vault rate plus its incentive?
    /// `known` is false while the vault publishes no rate (new borrowing then stays closed).
    function carry(bytes32 id) public view returns (bool known, bool negative) {
        uint256 vault;
        (known, vault) = vaultRate(id);
        (, uint256 borrowIncentive, uint256 vaultIncentive) = incentiveRates(id);
        negative = known && BorrowReader.borrowRate(market(id)) > vault + vaultIncentive + borrowIncentive;
    }

    /// @notice Use eth_call. Accrues the borrow market and the earn vault, then returns every number the backend
    /// and app need: whether new borrowing is open (and why not), whether to deleverage or unwind, the rates for
    /// the one "extra APY" number, LTV lines and the position. `account` may be zero for a pre-buy quote.
    function status(bytes32 id, address account) external returns (B.Status memory s) {
        B.Market memory m = market(id);
        BorrowReader.sync(m, account);
        s.borrowRate = BorrowReader.borrowRate(m);
        s.collateralRate = BorrowReader.collateralRate(m);
        bool known;
        (known, s.vaultRate) = vaultRate(id);
        (s.collateralIncentiveRate, s.borrowIncentiveRate, s.vaultIncentiveRate) = incentiveRates(id);
        (, bool negative) = carry(id);
        s.borrowUtilizationBps = BorrowReader.borrowUtilization(m);
        bool readable = known;
        try this.refreshVaultUtilization(id) returns (uint256 u) {
            s.vaultUtilizationBps = u;
        } catch {
            readable = false;
        }
        s.liquidationLtv = liquidationLtv(id);
        s.targetLtv = targetLtv(id);
        s.deleverageLtv = deleverageLtv(id);
        if (borrowPaused || m.retired || !m.borrowEnabled || collateralMarket[m.collateral] != id) {
            s.gate = B.Gate.CLOSED;
        } else if (!readable) {
            s.gate = B.Gate.VAULT_UNREADABLE;
        } else if (s.vaultUtilizationBps > MAX_VAULT_SUPPLY_UTILIZATION_BPS) {
            s.gate = B.Gate.VAULT_UTILIZATION;
        } else if (s.borrowUtilizationBps > MAX_BORROW_UTILIZATION_BPS) {
            s.gate = B.Gate.BORROW_UTILIZATION;
        } else if (negative) {
            s.gate = B.Gate.NEGATIVE_CARRY;
        }
        if (account != address(0)) {
            s.health = BorrowReader.health(m, account);
            s.ltv = BorrowReader.ltv(s.health);
            s.debt = BorrowReader.debt(m, account);
            s.vaultAssets = IERC4626(m.earnVault).previewRedeem(heldVaultShares(id, account));
            s.shouldDeleverage = s.debt != 0 && s.ltv >= s.deleverageLtv;
            s.shouldUnwind =
                s.debt != 0 && (negative || (readable && s.vaultUtilizationBps > VAULT_EXIT_UTILIZATION_BPS));
        }
    }

    // ---- internals ----

    function _targetCap(bytes32 id) private view returns (uint256) {
        B.Tier tier = market(id).tier;
        uint256 classCap = tier == B.Tier.INDEX_LARGE_CAP
            ? INDEX_LARGE_CAP_LTV
            : tier == B.Tier.STOCK ? STOCK_LTV : CRYPTO_LINKED_LTV;
        return Math.min(classCap, liquidationLtv(id) / 2);
    }

    /// @dev A bps getter answered as 18-decimal yearly rate; absent or failing getters read as 0.
    function _bps(address target, bytes4 selector, bytes32 arg) private view returns (uint256) {
        bytes memory data =
            arg == bytes32(0) ? abi.encodeWithSelector(selector) : abi.encodeWithSelector(selector, arg);
        (bool ok, bytes memory ret) = target.staticcall(data);
        if (!ok || ret.length < 32) return 0;
        return Math.min(abi.decode(ret, (uint256)), 10_000) * 1e14;
    }

    function _market(bytes32 id) private view returns (B.Market storage m) {
        m = _markets[id];
        if (m.kind == B.Kind.NONE) revert UnknownMarket();
    }

    function _admit(bytes32 id) private view returns (B.Market memory m) {
        m = market(id);
        if (borrowPaused || m.retired) revert AdmissionClosed();
        bytes32 designated = collateralMarket[m.collateral];
        if (designated != id) revert NotDesignatedMarket(designated);
    }

    function _consent(address account, bytes32 id) private view returns (uint256) {
        Policy memory p = policies[account][id];
        AtpRegistry.Enrollment memory e = registry.enrollments(account);
        if (
            !p.enabled || !registry.isEnrolled(account) || e.paused || p.strategyId != e.strategyId
                || p.version != e.version
        ) revert ConsentRequired();
        return p.maxDebt;
    }

    function _track(address account, bytes32 id) private {
        if (_positionIndex[account][id] == 0) {
            _positions[account].push(id);
            _positionIndex[account][id] = _positions[account].length;
        }
    }

    function _reconcile(address account, bytes32 id) private {
        B.Market memory m = _markets[id];
        uint256 actual = BorrowReader.debt(m, account);
        uint256 tracked = principal[account][id];
        if (tracked > actual) {
            principal[account][id] = actual;
            totalPrincipal[id] -= tracked - actual;
            emit PrincipalReconciled(account, id, tracked - actual);
        }
        uint256 shares = IERC4626(m.earnVault).balanceOf(account);
        if (vaultShares[account][id] > shares) vaultShares[account][id] = shares;
        uint256 index = _positionIndex[account][id];
        if (
            index != 0 && actual == 0 && vaultShares[account][id] == 0
                && BorrowReader.collateral(m, account) == 0
        ) {
            bytes32 last = _positions[account][_positions[account].length - 1];
            _positions[account][index - 1] = last;
            _positionIndex[account][last] = index;
            _positions[account].pop();
            delete _positionIndex[account][id];
        }
    }
}
