// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { AtpRegistry } from "../AtpRegistry.sol";
import { YieldTypes as Y } from "./YieldTypes.sol";
import { YieldReader } from "./YieldReader.sol";
import { YieldView } from "./YieldView.sol";

/// @notice Append-only yield admission and shared, interest-bearing exposure ledger (#40).
/// The registry owner can stop supply or retire a market; neither removes its receipt or exit route.
/// Capacity is checked before and after each atomic supply; no persistent reservation API exists.
contract AtpYieldRegistry is ReentrancyGuard {
    uint256 internal constant MAX_MARKETS = 64;
    // Executor constructs its own empty module and binds it permanently. Neither pointer can change.
    AtpRegistry public immutable registry;
    address public immutable executor;
    bool public supplyPaused;
    mapping(address => bool) public isYieldProtocol;
    bytes32[] public marketIds;
    mapping(bytes32 => Y.Market) private _markets;
    mapping(address => bytes32) public receiptMarket;
    mapping(bytes32 => uint256) private _preSupplyLimit;
    mapping(bytes32 => uint256) public totalUnits;
    mapping(bytes32 => bytes32) public marketIdentity;
    mapping(address => bytes32[]) private _positions;
    mapping(address => mapping(bytes32 => uint256)) private _positionIndex;
    event ExposureReconciled(address indexed account, bytes32 indexed marketId, uint256 removed);
    event MarketIdentityAcknowledged(bytes32 indexed marketId, bytes32 previousIdentity, bytes32 identity);
    event MaxRateWidened(bytes32 indexed marketId, uint256 previousMaxRate, uint256 maxRate);

    enum RateCheck {
        LENIENT,
        SUPPLY,
        RISK_EXIT
    }

    struct RateCheckpoint {
        uint256 rate;
        uint256 observedAt;
    }
    mapping(bytes32 => RateCheckpoint) public rateCheckpoint;
    event MarketRateAcknowledged(bytes32 indexed marketId, uint256 previousRate, uint256 rate);
    error UnacknowledgedRate();
    error SupplyCapExceeded(uint256 requested, uint256 available);
    event MarketConfigurationAcknowledged(
        bytes32 indexed marketId, bytes32 previousConfiguration, bytes32 configuration
    );
    mapping(address => mapping(bytes32 => uint256)) public accountUnits;
    mapping(address => mapping(bytes32 => bool)) public exiting;
    mapping(address => mapping(address => uint256)) public lastSupply;

    struct Policy {
        uint256 dailyAssets;
        uint256 strategyId;
        uint16 version;
        bool enabled;
    }
    mapping(address => mapping(bytes32 => Policy)) public policies;

    event MarketRegistered(
        bytes32 indexed marketId,
        Y.Kind kind,
        address indexed asset,
        address indexed receipt,
        address target,
        address riskSource
    );
    event MarketSupplySet(bytes32 indexed marketId, bool enabled, bool retired);
    event SupplyPausedSet(bool paused);
    event YieldPolicySet(
        address indexed account,
        bytes32 indexed marketId,
        uint256 dailyAssets,
        uint256 strategyId,
        uint16 version,
        bool enabled
    );
    event YieldExitRequested(address indexed account, bytes32 indexed marketId);

    error Unauthorized();
    error UnknownMarket();
    error AdmissionClosed();
    error ConsentRequired();
    error CapacityExceeded(uint256 exposure, uint256 limit);
    error ReceiptMismatch();
    error SupplyCooldown();
    error BadMarket();
    error InvalidConstructor();

    constructor(AtpRegistry registry_, address executor_) {
        if (
            address(registry_).code.length == 0 || address(YieldView).code.length == 0
                || (executor_.code.length == 0 && msg.sender != executor_)
        ) {
            revert InvalidConstructor();
        }
        registry = registry_;
        executor = executor_;
        isYieldProtocol[address(YieldView)] = true;
    }
    modifier onlyOwner() {
        if (msg.sender != registry.owner()) revert Unauthorized();
        _;
    }
    modifier onlyExecutor() {
        if (msg.sender != executor) revert Unauthorized();
        _;
    }

    /// @notice Linked read library, fixed in bytecode and never replaceable.
    function reader() external pure returns (address) {
        return address(YieldView);
    }

    function marketCount() external view returns (uint256) {
        return marketIds.length;
    }

    function market(bytes32 id) public view returns (Y.Market memory m) {
        m = _markets[id];
        if (m.kind == Y.Kind.NONE) revert UnknownMarket();
        if (m.chainId != block.chainid) revert BadMarket();
    }

    function registerMarket(bytes32 id, Y.Market calldata m) external onlyOwner {
        if (
            id == bytes32(0) || _markets[id].kind != Y.Kind.NONE || receiptMarket[m.receipt] != bytes32(0)
                || marketIds.length == MAX_MARKETS || m.retired || m.configuration == bytes32(0)
        ) revert BadMarket();
        if (receiptMarket[m.asset] != bytes32(0)) revert BadMarket();
        for (uint256 i; i < marketIds.length; ++i) {
            if (_markets[marketIds[i]].asset == m.receipt) revert BadMarket();
        }
        YieldView.validate(m);
        marketIdentity[id] = YieldView.identity(m);
        rateCheckpoint[id] = RateCheckpoint(YieldView.rate(m), block.timestamp);
        _markets[id] = m;
        _observeRate(id, m, RateCheck.SUPPLY);
        marketIds.push(id);
        receiptMarket[m.receipt] = id;
        isYieldProtocol[m.target] = true;
        isYieldProtocol[m.receipt] = true;
        isYieldProtocol[m.riskSource] = true;
        emit MarketRegistered(id, m.kind, m.asset, m.receipt, m.target, m.riskSource);
    }

    function setMarketSupply(bytes32 id, bool enabled, bool retire) external onlyOwner {
        market(id);
        Y.Market storage m = _markets[id];
        if ((m.retired || retire) && enabled) revert BadMarket();
        if (retire) m.retired = true;
        m.supplyEnabled = enabled;
        emit MarketSupplySet(id, enabled, m.retired);
    }

    function setSupplyPaused(bool paused) external onlyOwner {
        supplyPaused = paused;
        emit SupplyPausedSet(paused);
    }

    /// @notice Account-owner action; new session policies must allow only executor supply/withdraw selectors.
    /// Consent pins the enrolled version. Re-enrollment requires fresh consent before any new deposit.
    function setYieldPolicy(bytes32 id, uint256 dailyAssets, bool enabled) external {
        Y.Market memory m = market(id);
        AtpRegistry.Enrollment memory e = registry.enrollments(msg.sender);
        if (
            msg.sender.code.length == 0 || !registry.isEnrolled(msg.sender)
                || !registry.isAssetAllowed(e.strategyId, e.version, m.asset) || (enabled && dailyAssets == 0)
        ) revert ConsentRequired();
        // Renewed consent with no tracked risk may clear an exit. A successful
        // receipt read is still required; externally donated units do not create tracked risk.
        if (enabled && accountUnits[msg.sender][id] == 0) {
            YieldView.units(m, msg.sender);
            exiting[msg.sender][id] = false;
        }
        policies[msg.sender][id] = Policy(dailyAssets, e.strategyId, e.version, enabled);
        emit YieldPolicySet(msg.sender, id, dailyAssets, e.strategyId, e.version, enabled);
    }

    function requestExit(bytes32 id) external {
        market(id);
        bool pending = accountUnits[msg.sender][id] != 0;
        if (!pending) {
            try this.units(id, msg.sender) returns (uint256) { }
            catch {
                pending = true; // Stopping consent must remain possible even when receipt reads fail.
            }
        }
        exiting[msg.sender][id] = pending;
        policies[msg.sender][id].enabled = false;
        emit YieldExitRequested(msg.sender, id);
    }

    /// @notice Only positions created through this executor are enumerated for NAV. Untracked external
    /// gifts never increase exposure or buy capacity. Reconciliation never adds untracked units.
    function accountMarkets(address account) external view returns (bytes32[] memory) {
        return _positions[account];
    }

    function reconcile(address account, bytes32 id) external nonReentrant {
        _reconcile(account, id, YieldView.units(market(id), account));
    }

    function _reconcile(address account, bytes32 id, uint256 actual) private {
        uint256 tracked = accountUnits[account][id];
        if (tracked > actual) {
            totalUnits[id] -= tracked - actual;
            accountUnits[account][id] = actual;
            emit ExposureReconciled(account, id, tracked - actual);
        }
        if (tracked == 0 || actual == 0) {
            exiting[account][id] = false;
            uint256 index = _positionIndex[account][id];
            if (index != 0) {
                bytes32 last = _positions[account][_positions[account].length - 1];
                _positions[account][index - 1] = last;
                _positionIndex[account][last] = index;
                _positions[account].pop();
                delete _positionIndex[account][id];
            }
        }
    }

    function beforeSupply(address account, bytes32 id, uint256 amount)
        external
        onlyExecutor
        nonReentrant
        returns (Y.Market memory m)
    {
        m = market(id);
        _consent(account, id, m, amount);
        uint256 last = lastSupply[account][m.asset];
        if (last != 0 && block.timestamp < last + 1 days) revert SupplyCooldown();
        _reconcile(account, id, YieldView.units(m, account));
        _syncGroup(m, RateCheck.SUPPLY);
        _checkSupplyCapacity(account, m, amount);
        _preSupplyLimit[id] = _capacity(id, amount);
        lastSupply[account][m.asset] = block.timestamp;
    }

    function recordSupply(address account, bytes32 id, uint256 beforeUnits) external onlyExecutor {
        Y.Market memory m = market(id);
        _checkIdentity(id, m);
        uint256 afterUnits = YieldView.units(m, account);
        if (afterUnits <= beforeUnits) revert ReceiptMismatch();
        uint256 added = afterUnits - beforeUnits;
        totalUnits[id] += added;
        accountUnits[account][id] += added;
        if (_positionIndex[account][id] == 0) {
            _positions[account].push(id);
            _positionIndex[account][id] = _positions[account].length;
        }
        uint256 limit = _preSupplyLimit[id];
        delete _preSupplyLimit[id];
        (, uint256 exposure) = _groupState(m, false);
        if (exposure > limit) revert CapacityExceeded(exposure, limit);
    }

    function recordWithdraw(address account, bytes32 id, uint256 beforeUnits, uint256 trackedBefore)
        external
        onlyExecutor
    {
        uint256 afterUnits = YieldView.units(market(id), account);
        if (afterUnits >= beforeUnits) revert ReceiptMismatch();
        uint256 tracked = accountUnits[account][id];
        uint256 removed = Math.min(trackedBefore, beforeUnits - afterUnits);
        // Permissionless reconciliation may already have released part of this withdrawal during a
        // protocol callback. Bound by the pre-action ledger instead of debiting the same units twice.
        uint256 remaining = Math.min(tracked, trackedBefore - removed);
        totalUnits[id] -= tracked - remaining;
        accountUnits[account][id] = remaining;
        _reconcile(account, id, afterUnits);
    }

    function quoteSupply(bytes32 id, address account, uint256 amount)
        external
        nonReentrant
        returns (uint256)
    {
        Y.Market memory m = market(id);
        YieldReader.sync(m);
        _observeRate(id, m, RateCheck.SUPPLY);
        return YieldView.quoteSupply(m, account, amount);
    }

    function quoteWithdraw(bytes32 id, uint256 shares) external nonReentrant returns (uint256) {
        Y.Market memory m = market(id);
        YieldView.validate(m);
        YieldReader.sync(m);
        _observeRate(id, m, RateCheck.LENIENT);
        return YieldView.quoteWithdraw(m, shares);
    }

    function units(bytes32 id, address account) external view returns (uint256) {
        return YieldView.units(market(id), account);
    }

    function receiptAssets(bytes32 id, address account) external view returns (uint256) {
        Y.Market memory m = market(id);
        _checkIdentity(id, m);
        uint256 current = YieldView.rate(m);
        uint256 conservative =
            _rateAcceptable(id, m, current) ? current : Math.min(current, rateCheckpoint[id].rate);
        uint256 held = Math.min(YieldView.units(m, account), accountUnits[account][id]);
        return Math.min(YieldView.assets(m, held, false), Math.mulDiv(held, conservative, 1e18));
    }

    function health(bytes32 id) external view returns (Y.Health memory) {
        Y.Market memory m = market(id);
        _checkIdentity(id, m);
        return YieldView.health(m);
    }

    function syncAccount(address account) external onlyExecutor {
        bytes32[] memory positions = _positions[account];
        for (uint256 i; i < positions.length; ++i) {
            bytes32 id = positions[i];
            Y.Market memory m = market(id);
            uint256 actual = YieldView.units(m, account);
            _reconcile(account, id, actual);
            if (accountUnits[account][id] == 0) continue;
            _checkIdentity(id, m);
            YieldReader.sync(m);
            _observeRate(id, m, RateCheck.LENIENT);
        }
    }

    /// @notice Permissionless risk observation. A failed read freezes new risk; it never moves assets.
    /// Rate drops/read failures/staleness or U >= 90% count as risk; upward rates/configuration alone do not.
    /// A marked exit persists until tracked/actual units reconcile to zero, even if the market recovers.
    function markRiskExit(address account, bytes32 id) external nonReentrant {
        market(id);
        if (accountUnits[account][id] == 0) revert AdmissionClosed();
        bool unsafe;
        try this.assessRiskExit(id) returns (Y.Health memory h) {
            unsafe = h.utilizationBps >= 9_000;
        } catch {
            unsafe = true;
        }
        if (!unsafe) revert AdmissionClosed();
        exiting[account][id] = true;
        emit YieldExitRequested(account, id);
    }

    function assessRiskExit(bytes32 id) external returns (Y.Health memory) {
        if (msg.sender != address(this)) revert Unauthorized();
        Y.Market memory m = market(id);
        _syncGroup(m, RateCheck.RISK_EXIT);
        _checkIdentity(id, m);
        return YieldView.health(m);
    }

    /// @notice Call with eth_call to get a current, accrued risk snapshot without a public transaction.
    function refreshHealth(bytes32 id) external nonReentrant returns (Y.Health memory) {
        Y.Market memory m = market(id);
        _syncGroup(m, RateCheck.SUPPLY);
        _checkIdentity(id, m);
        return YieldView.health(m);
    }

    function _consent(address account, bytes32 id, Y.Market memory m, uint256 amount) private view {
        if (supplyPaused || !m.supplyEnabled || m.retired || exiting[account][id]) revert AdmissionClosed();
        Policy memory p = policies[account][id];
        AtpRegistry.Enrollment memory e = registry.enrollments(account);
        if (
            !p.enabled || amount == 0 || amount > p.dailyAssets || !registry.isEnrolled(account) || e.paused
                || p.strategyId != e.strategyId || p.version != e.version
        ) revert ConsentRequired();
    }

    function _sameGroup(Y.Market memory a, Y.Market memory b) private pure returns (bool) {
        return a.kind == b.kind && a.asset == b.asset && a.riskSource == b.riskSource;
    }

    function _syncGroup(Y.Market memory m, RateCheck check) private {
        for (uint256 i; i < marketIds.length; ++i) {
            Y.Market memory other = market(marketIds[i]);
            if (_sameGroup(m, other)) {
                YieldReader.sync(other);
                _observeRate(marketIds[i], other, check);
            }
        }
    }

    /// @dev Share the same group traversal for admission and the post-supply exposure check.
    function _groupState(Y.Market memory m, bool checkHealth)
        private
        view
        returns (uint256 limit, uint256 exposure)
    {
        limit = type(uint256).max;
        for (uint256 i; i < marketIds.length; ++i) {
            bytes32 id = marketIds[i];
            Y.Market memory other = market(id);
            if (!_sameGroup(m, other)) continue;
            if (checkHealth) {
                _checkIdentity(id, other);
                Y.Health memory h = YieldView.health(other);
                if (h.configuration != other.configuration || h.utilizationBps > 8_000) {
                    revert AdmissionClosed();
                }
                limit = Math.min(limit, Math.min(h.supply / 100, h.liquidity / 10));
            }
            exposure += YieldView.assets(other, totalUnits[id], true);
        }
    }

    /// @notice Re-admit a reviewed queue/fee configuration. Asset/receipt/target/implementation identity
    /// stays pinned; exposure and user consent remain unchanged.
    function acknowledgeConfiguration(bytes32 id, bytes32 expected) external onlyOwner nonReentrant {
        Y.Market memory m = market(id);
        _checkIdentity(id, m);
        YieldReader.sync(m);
        Y.Health memory h = YieldView.health(m);
        if (expected == bytes32(0) || h.configuration != expected) {
            revert AdmissionClosed();
        }
        emit MarketConfigurationAcknowledged(id, m.configuration, expected);
        _markets[id].configuration = expected;
    }

    /// @notice Explicitly acknowledge a new conservative rate after an alerted loss/jump. Owner only;
    /// this never changes identity, rate bounds, queue configuration, consent or supply flags.
    function acknowledgeRate(bytes32 id) external onlyOwner nonReentrant {
        Y.Market memory m = market(id);
        _checkIdentity(id, m);
        YieldReader.sync(m);
        uint256 current = YieldView.rate(m);
        emit MarketRateAcknowledged(id, rateCheckpoint[id].rate, current);
        rateCheckpoint[id] = RateCheckpoint(current, block.timestamp);
    }

    function acknowledgeIdentity(bytes32 id, bytes32 expected) external onlyOwner nonReentrant {
        Y.Market memory m = market(id);
        YieldView.validate(m);
        if (expected == bytes32(0) || YieldView.identity(m) != expected) revert AdmissionClosed();
        emit MarketIdentityAcknowledged(id, marketIdentity[id], expected);
        marketIdentity[id] = expected;
    }

    function widenMaxRate(bytes32 id, uint256 next) external onlyOwner {
        Y.Market memory m = market(id);
        if (next <= m.maxRate) revert BadMarket();
        _markets[id].maxRate = next;
        emit MaxRateWidened(id, m.maxRate, next);
    }

    // Supply rejects losses and jumps. Risk exit rejects only losses; upward donations cannot force exit.
    // Lenient observations used by NAV/withdraw never checkpoint a loss or anomalous jump.
    function _observeRate(bytes32 id, Y.Market memory m, RateCheck check) private {
        uint256 current = YieldView.rate(m);
        if (check == RateCheck.RISK_EXIT && current < rateCheckpoint[id].rate) revert UnacknowledgedRate();
        bool accepted = _rateAcceptable(id, m, current);
        if (check == RateCheck.SUPPLY && !accepted) {
            if (current < m.minRate || current > m.maxRate) revert YieldReader.BadRate();
            revert UnacknowledgedRate();
        }
        if (accepted) rateCheckpoint[id] = RateCheckpoint(current, block.timestamp);
    }

    function _rateAcceptable(bytes32 id, Y.Market memory m, uint256 current) private view returns (bool) {
        RateCheckpoint memory previous = rateCheckpoint[id];
        return YieldView.rateAcceptable(m, current, previous.rate, previous.observedAt);
    }

    function _checkIdentity(bytes32 id, Y.Market memory m) private view {
        if (YieldView.identity(m) != marketIdentity[id]) revert AdmissionClosed();
    }

    function _checkSupplyCapacity(address account, Y.Market memory m, uint256 incoming) private view {
        uint256 available = YieldView.supplyCapacity(m, account);
        uint256 requested = incoming;
        if (requested > available) revert SupplyCapExceeded(requested, available);
    }

    function _capacity(bytes32 id, uint256 incoming) private view returns (uint256 limit) {
        uint256 exposure;
        (limit, exposure) = _groupState(market(id), true);
        exposure += incoming;
        if (exposure > limit) revert CapacityExceeded(exposure, limit);
    }
}
