// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { AtpRegistry } from "../../AtpRegistry.sol";
import { MoolahParams } from "../../yield/YieldInterfaces.sol";
import {
    IVenusComptroller,
    IVenusOracle,
    IVBorrowToken,
    IListaOracle,
    IMoolahCore
} from "../BorrowInterfaces.sol";
import { RoutingTypes as R } from "./RoutingTypes.sol";
import { RouteReader } from "./RouteReader.sol";
import { IStrategyVaultAdapter } from "./IStrategyVaultAdapter.sol";
import { IAtpBorrowRegistryV2 } from "./IAtpBorrowRegistryV2.sol";

interface IGlobalPause {
    function globalPaused() external view returns (bool);
}

interface IAdapterExecutor {
    function executor() external view returns (address);
}

/// @title AtpBorrowRegistryV2
/// @notice Allowlists, consent, caps, safety lines and reads for `AtpBorrowExecutorV2` (routing v2,
/// docs/borrow-routing-v2.zh-TW.md). Nothing about a particular asset's route is fixed here: the owner lists
/// loan tokens, routes (venue x collateral x loan token) and supply vaults; the backend picks a pair per open.
/// @dev Safety lines, relative to the venue's own factor F (Venus collateral factor, Lista LLTV):
/// target LTV = min(tier ceiling, F / 2, owner line); deleverage LTV = min(F x 2/3, owner line).
/// Lista is checked per market. Venus is checked per account: debt value <= sum(collateral value x target).
/// The owner (`AtpRegistry.owner()`) can always stop new risk, never an exit.
contract AtpBorrowRegistryV2 is IAtpBorrowRegistryV2 {
    uint256 public constant INDEX_LARGE_CAP_LTV = 0.35e18;
    uint256 public constant STOCK_LTV = 0.3e18;
    uint256 public constant CRYPTO_LINKED_LTV = 0.2e18;
    /// @notice Default for a new route (user decision 2026-11-24: 95%; Lista's rate model steers its markets
    /// to about 90%, so the testnet-era 85% line kept the main markets shut). The owner may set another value
    /// per route.
    uint256 public constant MAX_BORROW_UTILIZATION_BPS = 9_500;
    uint256 public constant MAX_VAULT_SUPPLY_UTILIZATION_BPS = 9_000;
    uint256 public constant VAULT_EXIT_UTILIZATION_BPS = 9_500;
    /// @notice A reported rate is used this long, then reads as zero (incentives) or unknown (vault rate).
    uint256 public constant REPORT_TTL = 48 hours;
    uint256 public constant MAX_REPORTED_RATE = 0.5e18;
    /// @notice Routes (and vaults) one account may hold at once; keeps every per-account loop bounded.
    uint256 public constant MAX_POSITIONS = 24;

    AtpRegistry public immutable registry;
    IGlobalPause public immutable atpExecutor;
    address public immutable executor;
    address public immutable venusComptroller;
    address public immutable moolah;

    bool public paused;
    address public rateReporter;
    uint256 public venusBlocksPerYear = 70_080_000;
    bytes public rewardProofSuffix;

    mapping(address => bool) public loanTokenAllowed;
    /// @dev 10 ** (18 - decimals), kept after a token is disallowed so open positions still account.
    mapping(address => uint256) private _loanScale;
    mapping(address => bool) public rewardTokenAllowed;
    mapping(address => bool) public isReceipt;
    mapping(address => bool) public isCollateral;
    mapping(address => R.Tier) public assetTier;
    mapping(address => address) public venusMarket;
    mapping(address => address) public venusUnderlying;
    mapping(R.VaultKind => address) public adapterOf;

    bytes32[] public routeIds;
    mapping(bytes32 => R.Route) private _routes;
    bytes32[] public vaultIds;
    mapping(bytes32 => R.Vault) private _vaults;

    struct LtvConfig {
        uint128 target;
        uint128 deleverage;
    }

    /// @dev Key: Lista route id; Venus: the collateral asset (lines apply account-wide per collateral).
    mapping(bytes32 => LtvConfig) public ltvConfig;

    struct Report {
        uint64 time;
        uint96 a;
        uint96 b;
    }

    /// @dev Route: a = borrow incentive, b = collateral incentive. Vault: a = base rate, b = incentive.
    mapping(bytes32 => Report) public reports;

    mapping(address => R.Policy) private _policies;
    mapping(address => uint256) public accountPrincipalUsd;
    mapping(address => mapping(bytes32 => uint256)) public principal;
    mapping(bytes32 => uint256) public totalPrincipal;
    /// @dev Sum of the account's Venus route principals per loan token (the debt they share).
    mapping(address => mapping(address => uint256)) public venusPrincipal;
    mapping(address => mapping(bytes32 => uint64)) public openedAt;
    mapping(address => mapping(bytes32 => uint64)) public vaultSince;
    mapping(address => bytes32[]) private _positions;
    mapping(address => mapping(bytes32 => uint256)) private _positionIndex;
    mapping(address => bytes32[]) private _held;
    mapping(address => mapping(bytes32 => uint256)) private _heldIndex;

    constructor(
        AtpRegistry registry_,
        address atpExecutor_,
        address executor_,
        address venusComptroller_,
        address moolah_
    ) {
        if (
            address(registry_).code.length == 0 || atpExecutor_.code.length == 0 || executor_ == address(0)
                || (venusComptroller_ == address(0) && moolah_ == address(0))
                || (venusComptroller_ != address(0) && venusComptroller_.code.length == 0)
                || (moolah_ != address(0) && moolah_.code.length == 0)
        ) revert InvalidConstructor();
        registry = registry_;
        atpExecutor = IGlobalPause(atpExecutor_);
        executor = executor_;
        venusComptroller = venusComptroller_;
        moolah = moolah_;
    }

    modifier onlyOwner() {
        if (msg.sender != registry.owner()) revert Unauthorized();
        _;
    }

    modifier onlyExecutor() {
        if (msg.sender != executor) revert Unauthorized();
        _;
    }

    // ---- ids ----

    function routeIdOf(R.Venue venue, address collateral_, address loan, bytes32 listaId)
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(uint8(venue), collateral_, loan, listaId));
    }

    function vaultIdOf(R.VaultKind kind, address token, address target) public pure returns (bytes32) {
        return keccak256(abi.encode(uint8(kind), token, target));
    }

    // ---- admin ----

    function setLoanToken(address token, bool allowed) external onlyOwner {
        if (allowed) {
            if (rewardTokenAllowed[token] || isReceipt[token]) revert BadParameter();
            uint8 decimals = IERC20Metadata(token).decimals();
            if (decimals > 18) revert BadParameter();
            _loanScale[token] = 10 ** (18 - decimals);
        }
        loanTokenAllowed[token] = allowed;
        emit LoanTokenSet(token, allowed);
    }

    /// @notice `Tier.NONE` closes new risk for the asset on every route; exits stay open.
    function setAssetTier(address asset, R.Tier tier) external onlyOwner {
        if (tier != R.Tier.NONE && rewardTokenAllowed[asset]) revert BadParameter();
        assetTier[asset] = tier;
        emit AssetTierSet(asset, tier);
    }

    function setVenusMarket(address underlying, address vToken) external onlyOwner {
        (bool listed,,) = IVenusComptroller(venusComptroller).markets(vToken);
        if (
            !listed || IVBorrowToken(vToken).underlying() != underlying
                || IVBorrowToken(vToken).comptroller() != venusComptroller
                || (venusMarket[underlying] != address(0) && venusMarket[underlying] != vToken)
        ) revert BadParameter();
        venusMarket[underlying] = vToken;
        venusUnderlying[vToken] = underlying;
        emit VenusMarketSet(underlying, vToken);
    }

    function setAdapter(R.VaultKind kind, address adapter) external onlyOwner {
        if (
            kind == R.VaultKind.NONE || adapterOf[kind] != address(0) || adapter.code.length == 0
                || IStrategyVaultAdapter(adapter).kind() != uint8(kind)
                || IAdapterExecutor(adapter).executor() != executor
        ) revert BadParameter();
        adapterOf[kind] = adapter;
        emit AdapterSet(kind, adapter);
    }

    function registerRoute(
        R.Venue venue,
        address collateral_,
        address loan,
        bytes32 listaId,
        uint256 borrowCap
    ) external onlyOwner returns (bytes32 id) {
        id = routeIdOf(venue, collateral_, loan, listaId);
        if (
            _routes[id].venue != R.Venue.NONE || !loanTokenAllowed[loan] || collateral_ == loan
                || rewardTokenAllowed[collateral_]
        ) revert BadRoute();
        isCollateral[collateral_] = true;
        R.Route memory r;
        r.venue = venue;
        r.collateral = collateral_;
        r.loan = loan;
        r.listaId = listaId;
        r.borrowCap = borrowCap;
        r.maxUtilizationBps = uint16(MAX_BORROW_UTILIZATION_BPS);
        r.enabled = true;
        if (venue == R.Venue.VENUS) {
            r.collateralVToken = venusMarket[collateral_];
            r.loanVToken = venusMarket[loan];
            if (r.collateralVToken == address(0) || r.loanVToken == address(0) || listaId != bytes32(0)) {
                revert BadRoute();
            }
            IVenusComptroller c = IVenusComptroller(venusComptroller);
            (, uint256 f,) = c.markets(r.collateralVToken);
            IVenusOracle oracle = IVenusOracle(c.oracle());
            if (
                f == 0 || f >= 1e18 || oracle.getUnderlyingPrice(r.collateralVToken) == 0
                    || oracle.getUnderlyingPrice(r.loanVToken) == 0
            ) revert BadRoute();
        } else if (venue == R.Venue.LISTA && moolah != address(0)) {
            MoolahParams memory p = IMoolahCore(moolah).idToMarketParams(listaId);
            if (
                p.loanToken != loan || p.collateralToken != collateral_ || p.lltv == 0 || p.lltv >= 1e18
                    || IListaOracle(p.oracle).peek(collateral_) == 0 || IListaOracle(p.oracle).peek(loan) == 0
            ) revert BadRoute();
        } else {
            revert BadRoute();
        }
        _routes[id] = r;
        routeIds.push(id);
        emit RouteRegistered(id, venue, collateral_, loan, listaId);
        emit RouteCapSet(id, borrowCap);
    }

    function setRoute(bytes32 id, bool enabled, bool retire) external onlyOwner {
        R.Route storage r = _routes[id];
        if (r.venue == R.Venue.NONE) revert UnknownRoute();
        if ((r.retired || retire) && enabled) revert BadRoute();
        if (retire) r.retired = true;
        r.enabled = enabled;
        emit RouteSet(id, enabled, r.retired);
    }

    function setRouteCap(bytes32 id, uint256 cap) external onlyOwner {
        if (_routes[id].venue == R.Venue.NONE) revert UnknownRoute();
        _routes[id].borrowCap = cap;
        emit RouteCapSet(id, cap);
    }

    /// @notice Borrow-market utilization above which the route takes no new borrowing (default 95%).
    function setRouteMaxUtilization(bytes32 id, uint16 bps) external onlyOwner {
        if (_routes[id].venue == R.Venue.NONE) revert UnknownRoute();
        if (bps == 0 || bps > 10_000) revert BadParameter();
        _routes[id].maxUtilizationBps = bps;
        emit RouteMaxUtilizationSet(id, bps);
    }

    function registerVault(R.VaultKind kind, address token, address target)
        external
        onlyOwner
        returns (bytes32 id)
    {
        id = vaultIdOf(kind, token, target);
        address adapter = adapterOf[kind];
        if (_vaults[id].kind != R.VaultKind.NONE || adapter == address(0) || !loanTokenAllowed[token]) {
            revert BadVault();
        }
        address receipt = IStrategyVaultAdapter(adapter).validate(target, token);
        if (receipt == token || rewardTokenAllowed[receipt] || loanTokenAllowed[receipt]) revert BadVault();
        _vaults[id] = R.Vault(kind, token, target, receipt, true, false);
        isReceipt[receipt] = true;
        vaultIds.push(id);
        emit VaultRegistered(id, kind, token, target, receipt);
    }

    function setVault(bytes32 id, bool enabled, bool retire) external onlyOwner {
        R.Vault storage v = _vaults[id];
        if (v.kind == R.VaultKind.NONE) revert UnknownVault();
        if ((v.retired || retire) && enabled) revert BadVault();
        if (retire) v.retired = true;
        v.enabled = enabled;
        emit VaultSet(id, enabled, v.retired);
    }

    function setPaused(bool paused_) external onlyOwner {
        paused = paused_;
        emit PausedSet(paused_);
    }

    function setLtvConfig(bytes32 id, uint256 target, uint256 deleverage) external onlyOwner {
        R.Route memory r = route(id);
        uint256 f = RouteReader.factor(r, _core(r));
        uint256 targetCap = Math.min(_tierCap(assetTier[r.collateral]), f / 2);
        uint256 deleverageCap = f * 2 / 3;
        uint256 t = target == 0 ? targetCap : target;
        uint256 d = deleverage == 0 ? deleverageCap : deleverage;
        if (t > targetCap || d > deleverageCap || t >= d) revert BadParameter();
        bytes32 key = _ltvKey(r, id);
        ltvConfig[key] = LtvConfig(uint128(target), uint128(deleverage));
        emit LtvConfigSet(key, t, d);
    }

    function setRateReporter(address reporter) external onlyOwner {
        rateReporter = reporter;
        emit RateReporterSet(reporter);
    }

    /// @notice A reward token can never be a loan token, a vault receipt or a collateral asset.
    function setRewardToken(address token, bool allowed) external onlyOwner {
        if (
            allowed
                && (loanTokenAllowed[token]
                    || isReceipt[token]
                    || _loanScale[token] != 0
                    || isCollateral[token]
                    || assetTier[token] != R.Tier.NONE
                    || venusUnderlying[token] != address(0))
        ) revert BadParameter();
        rewardTokenAllowed[token] = allowed;
        emit RewardTokenSet(token, allowed);
    }

    function setVenusBlocksPerYear(uint256 blocksPerYear) external onlyOwner {
        // Between 3 s and 0.1 s blocks.
        if (blocksPerYear < 10_512_000 || blocksPerYear > 315_360_000) revert BadParameter();
        venusBlocksPerYear = blocksPerYear;
        emit VenusBlocksPerYearSet(blocksPerYear);
    }

    function setRewardProofSuffix(bytes calldata suffix) external onlyOwner {
        if (suffix.length != 0 && (suffix.length < 16 || suffix.length > 64)) revert BadParameter();
        rewardProofSuffix = suffix;
        emit RewardProofSuffixSet(suffix);
    }

    // ---- rate reporter ----

    function reportRates(RouteReport[] calldata routes_, VaultReport[] calldata vaults_) external {
        if (msg.sender != rateReporter) revert Unauthorized();
        for (uint256 i; i < routes_.length; ++i) {
            RouteReport calldata x = routes_[i];
            if (_routes[x.routeId].venue == R.Venue.NONE) revert UnknownRoute();
            if (x.borrowIncentive > MAX_REPORTED_RATE || x.collateralIncentive > MAX_REPORTED_RATE) {
                revert BadParameter();
            }
            reports[x.routeId] =
                Report(uint64(block.timestamp), uint96(x.borrowIncentive), uint96(x.collateralIncentive));
            emit RouteRatesReported(x.routeId, x.borrowIncentive, x.collateralIncentive);
        }
        for (uint256 i; i < vaults_.length; ++i) {
            VaultReport calldata x = vaults_[i];
            if (_vaults[x.vaultId].kind == R.VaultKind.NONE) revert UnknownVault();
            if (x.baseRate > MAX_REPORTED_RATE || x.incentive > MAX_REPORTED_RATE) revert BadParameter();
            reports[x.vaultId] = Report(uint64(block.timestamp), uint96(x.baseRate), uint96(x.incentive));
            emit VaultRatesReported(x.vaultId, x.baseRate, x.incentive);
        }
    }

    // ---- account consent ----

    /// @notice Pinned to the strategy the account is enrolled in right now: enrolling into another strategy
    /// voids it until the account calls this again (which it can do in the same batch as the enrollment).
    /// A void or disabled policy only stops new risk; every exit keeps working.
    function setStrategyPolicy(uint256 maxDebt, address rewardRecipient, bool enabled) external {
        if (msg.sender.code.length == 0 || !registry.isEnrolled(msg.sender) || (enabled && maxDebt == 0)) {
            revert ConsentRequired();
        }
        _policies[msg.sender] =
            R.Policy(maxDebt, rewardRecipient, registry.enrollments(msg.sender).strategyId, enabled);
        emit StrategyPolicySet(msg.sender, maxDebt, rewardRecipient, enabled);
    }

    // ---- executor hooks ----

    /// @notice Admission for new risk on `routeId` (and a deposit into `vaultId` when `borrowAmount` > 0).
    function beforeOpen(address account, bytes32 routeId, bytes32 vaultId, uint256 borrowAmount)
        external
        view
        onlyExecutor
        returns (R.Route memory r, R.Vault memory v, address adapter)
    {
        r = route(routeId);
        if (!_routeOpen(r)) revert AdmissionClosed();
        R.Policy memory p = _policies[account];
        AtpRegistry.Enrollment memory e = registry.enrollments(account);
        if (!p.enabled || !registry.isEnrolled(account) || e.paused || p.strategyId != e.strategyId) {
            revert ConsentRequired();
        }
        // Venus debt is per account and loan token: debt this registry did not open (e.g. a v1 position on
        // the same account) would be taken for this route's. An account that owes the token without holding
        // a Venus position in it here cannot open. (Interest left after the principal is repaid still has its
        // position, see `_settle`.)
        if (
            r.venue == R.Venue.VENUS && IVBorrowToken(r.loanVToken).borrowBalanceStored(account) != 0
                && !_venusPosition(account, bytes32(0), r.loan)
        ) revert ForeignDebt();
        if (borrowAmount != 0) {
            (v, adapter) = vaultFor(vaultId);
            if (!_vaultOpen(v)) revert AdmissionClosed();
            uint256 used = totalPrincipal[routeId];
            uint256 available = r.borrowCap > used ? r.borrowCap - used : 0;
            if (borrowAmount > available) revert BorrowCapExceeded(borrowAmount, available);
            uint256 usd = accountPrincipalUsd[account] + borrowAmount * _loanScale[r.loan];
            if (usd > p.maxDebt) revert DebtAboveConsent(usd, p.maxDebt);
        }
    }

    /// @notice Admission for a vault-to-vault move (no new debt): not paused, target vault open, consent live.
    function beforeSwitch(address account, bytes32 toVaultId)
        external
        view
        onlyExecutor
        returns (R.Vault memory v, address adapter)
    {
        (v, adapter) = vaultFor(toVaultId);
        R.Policy memory p = _policies[account];
        AtpRegistry.Enrollment memory e = registry.enrollments(account);
        if (
            !_vaultOpen(v) || !p.enabled || !registry.isEnrolled(account) || e.paused
                || p.strategyId != e.strategyId
        ) {
            revert AdmissionClosed();
        }
    }

    function recordOpen(address account, bytes32 routeId, uint256 borrowed) external onlyExecutor {
        R.Route storage r = _routes[routeId];
        if (borrowed != 0) {
            if (principal[account][routeId] == 0) openedAt[account][routeId] = uint64(block.timestamp);
            principal[account][routeId] += borrowed;
            totalPrincipal[routeId] += borrowed;
            accountPrincipalUsd[account] += borrowed * _loanScale[r.loan];
            if (r.venue == R.Venue.VENUS) venusPrincipal[account][r.loan] += borrowed;
        }
        if (_positionIndex[account][routeId] == 0) {
            if (_positions[account].length == MAX_POSITIONS) revert TooManyPositions();
            _positions[account].push(routeId);
            _positionIndex[account][routeId] = _positions[account].length;
        }
    }

    /// @notice Repaid assets retire principal first; interest repaid beyond principal does not go negative.
    /// Venus debt is shared by every route of the loan token, so what a repayment exceeds this route's
    /// principal by retires the principal of the account's other Venus routes in that token.
    function recordReduce(address account, bytes32 routeId, uint256 repaid) external onlyExecutor {
        uint256 removed = Math.min(principal[account][routeId], repaid);
        _retire(account, routeId, removed);
        R.Route storage r = _routes[routeId];
        if (removed != repaid && r.venue == R.Venue.VENUS && venusPrincipal[account][r.loan] != 0) {
            address loan = r.loan;
            bytes32[] memory ids = _positions[account];
            for (uint256 i; i < ids.length && removed != repaid; ++i) {
                R.Route storage other = _routes[ids[i]];
                if (other.venue != R.Venue.VENUS || other.loan != loan) continue;
                uint256 more = Math.min(principal[account][ids[i]], repaid - removed);
                _retire(account, ids[i], more);
                removed += more;
            }
        }
        _settle(account, routeId);
    }

    /// @notice A Venus position that keeps its collateral and moves to another loan token (migrate between two
    /// Venus routes of one collateral): the new route takes the old one's place in the account's list.
    function recordSwap(address account, bytes32 fromRouteId, bytes32 toRouteId) external onlyExecutor {
        uint256 index = _positionIndex[account][fromRouteId];
        if (index == 0 || principal[account][fromRouteId] != 0 || _positionIndex[account][toRouteId] != 0) {
            return;
        }
        _positions[account][index - 1] = toRouteId;
        _positionIndex[account][toRouteId] = index;
        delete _positionIndex[account][fromRouteId];
    }

    /// @notice Track whether the account's box holds anything in `vaultId` (`since` restarts when it empties).
    function recordVault(address account, bytes32 vaultId, bool holds) external onlyExecutor {
        uint256 index = _heldIndex[account][vaultId];
        if (holds && index == 0) {
            if (_held[account].length == MAX_POSITIONS) revert TooManyPositions();
            _held[account].push(vaultId);
            _heldIndex[account][vaultId] = _held[account].length;
            vaultSince[account][vaultId] = uint64(block.timestamp);
        } else if (!holds && index != 0) {
            bytes32 last = _held[account][_held[account].length - 1];
            _held[account][index - 1] = last;
            _heldIndex[account][last] = index;
            _held[account].pop();
            delete _heldIndex[account][vaultId];
            delete vaultSince[account][vaultId];
        }
    }

    // ---- permissionless ----

    function reconcile(address account, bytes32 routeId) external {
        R.Route memory r = route(routeId);
        uint256 actual = RouteReader.debt(r, _core(r), account);
        uint256 tracked =
            r.venue == R.Venue.VENUS ? venusPrincipal[account][r.loan] : principal[account][routeId];
        if (tracked > actual) {
            uint256 removed = Math.min(principal[account][routeId], tracked - actual);
            _retire(account, routeId, removed);
            emit PrincipalReconciled(account, routeId, removed);
        }
        _settle(account, routeId);
    }

    // ---- reads ----

    function routeCount() external view returns (uint256) {
        return routeIds.length;
    }

    function vaultCount() external view returns (uint256) {
        return vaultIds.length;
    }

    function route(bytes32 id) public view returns (R.Route memory r) {
        r = _routes[id];
        if (r.venue == R.Venue.NONE) revert UnknownRoute();
    }

    function vault(bytes32 id) public view returns (R.Vault memory v) {
        v = _vaults[id];
        if (v.kind == R.VaultKind.NONE) revert UnknownVault();
    }

    function vaultFor(bytes32 id) public view returns (R.Vault memory v, address adapter) {
        v = vault(id);
        adapter = adapterOf[v.kind];
    }

    function policy(address account) external view returns (R.Policy memory) {
        return _policies[account];
    }

    function accountRoutes(address account) external view returns (bytes32[] memory) {
        return _positions[account];
    }

    function accountVaults(address account) external view returns (bytes32[] memory) {
        return _held[account];
    }

    /// @notice Is new risk on this route admitted (pauses, enable, retire, loan token, tier)?
    function routeOpen(bytes32 id) external view returns (bool) {
        return _routeOpen(route(id));
    }

    function vaultOpen(bytes32 id) external view returns (bool) {
        return _vaultOpen(vault(id));
    }

    /// @notice May `token` leave the account's box as a reward, and where to on an exit sweep. `fromAccount`:
    /// the sweep also takes the token from the account itself, which is refused for anything the account's
    /// strategy has ever traded (holdings are not rewards).
    function rewardRoute(address account, address token, bool fromAccount)
        external
        view
        returns (bool ok, address recipient)
    {
        recipient = _policies[account].rewardRecipient;
        if (recipient == address(0)) recipient = account;
        ok = rewardTokenAllowed[token]
            && !(fromAccount && registry.wasAssetAllowed(registry.enrollments(account).strategyId, token));
    }

    /// @notice A fresh report: (route: borrow incentive, collateral incentive) / (vault: base rate, incentive).
    function freshReport(bytes32 id) external view returns (bool fresh, uint256 a, uint256 b) {
        Report memory x = reports[id];
        if (x.time != 0 && block.timestamp - x.time <= REPORT_TTL) return (true, x.a, x.b);
    }

    // ---- internals ----

    function _core(R.Route memory r) private view returns (address) {
        return r.venue == R.Venue.VENUS ? venusComptroller : moolah;
    }

    function _routeOpen(R.Route memory r) private view returns (bool) {
        return !paused && !atpExecutor.globalPaused() && r.enabled && !r.retired && loanTokenAllowed[r.loan]
            && assetTier[r.collateral] != R.Tier.NONE;
    }

    function _vaultOpen(R.Vault memory v) private view returns (bool) {
        return !paused && !atpExecutor.globalPaused() && v.enabled && !v.retired && loanTokenAllowed[v.token];
    }

    function _tierCap(R.Tier tier) private pure returns (uint256) {
        if (tier == R.Tier.INDEX_LARGE_CAP) return INDEX_LARGE_CAP_LTV;
        if (tier == R.Tier.STOCK) return STOCK_LTV;
        if (tier == R.Tier.CRYPTO_LINKED) return CRYPTO_LINKED_LTV;
        return 0;
    }

    function _ltvKey(R.Route memory r, bytes32 id) private pure returns (bytes32) {
        return r.venue == R.Venue.VENUS ? bytes32(uint256(uint160(r.collateral))) : id;
    }

    function _retire(address account, bytes32 routeId, uint256 removed) private {
        if (removed == 0) return;
        R.Route storage r = _routes[routeId];
        principal[account][routeId] -= removed;
        totalPrincipal[routeId] -= removed;
        accountPrincipalUsd[account] -= removed * _loanScale[r.loan];
        if (r.venue == R.Venue.VENUS) venusPrincipal[account][r.loan] -= removed;
        if (principal[account][routeId] == 0) delete openedAt[account][routeId];
    }

    /// @dev Whether the account holds a Venus position in `loan` other than `except`.
    function _venusPosition(address account, bytes32 except, address loan) private view returns (bool) {
        bytes32[] storage ids = _positions[account];
        for (uint256 i; i < ids.length; ++i) {
            R.Route storage other = _routes[ids[i]];
            if (ids[i] != except && other.venue == R.Venue.VENUS && other.loan == loan) return true;
        }
        return false;
    }

    /// @dev Drop the position once nothing is left on the route: no principal, no collateral (or another
    /// Venus position standing for the same collateral), and no debt (or, on Venus, another position standing
    /// for the same loan token).
    function _settle(address account, bytes32 routeId) private {
        uint256 index = _positionIndex[account][routeId];
        if (index == 0 || principal[account][routeId] != 0) return;
        R.Route memory r = _routes[routeId];
        address core = _core(r);
        bytes32[] storage ids = _positions[account];
        if (RouteReader.collateral(r, core, account) != 0) {
            // Venus routes of one collateral share the same posted vTokens: keep a single position for them.
            if (r.venue != R.Venue.VENUS) return;
            bool shared;
            for (uint256 i; i < ids.length && !shared; ++i) {
                R.Route storage other = _routes[ids[i]];
                shared = ids[i] != routeId && other.venue == R.Venue.VENUS && other.collateral == r.collateral;
            }
            if (!shared) return;
        }
        // Debt keeps its position: Lista debt is this market's; Venus debt in the loan token needs one
        // position of that token, this one unless another already stands for it.
        if (
            RouteReader.debt(r, core, account) != 0
                && (r.venue == R.Venue.LISTA || !_venusPosition(account, routeId, r.loan))
        ) return;
        bytes32 last = _positions[account][_positions[account].length - 1];
        _positions[account][index - 1] = last;
        _positionIndex[account][last] = index;
        _positions[account].pop();
        delete _positionIndex[account][routeId];
    }
}
