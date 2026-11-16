// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title AtpRegistry
/// @notice Versioned strategy settings with an immutable 24-hour notice period and explicit account consent.
/// @dev Enrolled accounts follow the latest effective version for swaps. Enrollment.version records the
/// version personally accepted by the account (also retained for the separate yield-policy consent).
contract AtpRegistry {
    // ---- types ----
    struct Version {
        /// @notice Admission list of tokens (bStock) this version may trade.
        address[] assets;
        /// @notice Portfolio weights per asset, same order and length as `assets`, summing to 10000.
        uint16[] weightsBps;
        /// @notice Off-chain encoding (interval | cron) of the rebalance schedule.
        bytes32 scheduleHash;
        /// @notice Unix timestamp from which this version may be executed.
        uint64 activeAt;
        /// @notice Commitment to per-asset strategy parameters and fund rules, encoded off chain.
        bytes32 settingsHash;
        /// @notice Creator performance fee; consumed by the separate performance-fee ledger.
        uint16 performanceFeeBps;
        /// @notice keccak256(abi.encode(assets, weightsBps, scheduleHash, settingsHash, performanceFeeBps)).
        bytes32 configHash;
    }

    struct StrategyMeta {
        address provider;
        string name;
        string description;
        bool isPublic;
    }

    struct Enrollment {
        uint256 strategyId;
        /// @notice Version index personally accepted at enrollment time (1-based; 0 means "never enrolled").
        uint16 version;
        bool paused;
    }

    // ---- constants ----
    uint64 public constant VERSION_DELAY = 1 days;
    uint64 public constant PUBLICATION_INTERVAL = 7 days;
    uint16 public constant MIN_PERFORMANCE_FEE_BPS = 500;
    uint16 public constant MAX_PERFORMANCE_FEE_BPS = 2_000;
    /// @notice Maximum distinct assets across a strategy's effective history and any new version.
    /// Includes the numeraire when listed; cancelled versions do not consume capacity.
    uint256 public constant MAX_STRATEGY_ASSETS = 128;
    bytes32 public constant FOLLOW_VERSIONS_TERMS = keccak256(
        "I agree to follow future strategy versions; changes require at least 24 hours notice during which I can exit. Fee-only decreases may take effect immediately."
    );
    /// @notice Hard ceiling for both the default and the per-strategy swap fee (0-3%).
    uint16 public constant MAX_SWAP_FEE_BPS = 300;
    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint16 public constant TOTAL_WEIGHT_BPS = 10_000;
    /// @notice `pauseFlags` bits: who holds an account paused. Each source clears only what it may (see
    /// `setPaused`); the account is paused while any bit is set.
    uint8 public constant PAUSED_BY_OWNER = 1;
    uint8 public constant PAUSED_BY_OPERATOR = 2;
    uint8 public constant PAUSED_BY_ACCOUNT = 4;

    // ---- admin / fee ----
    /// @notice Admin (a Safe on mainnet). Also the only address that may move `feeRecipient`.
    address public owner;
    /// @notice Proposed next owner; becomes `owner` only when it calls `acceptOwnership`.
    address public pendingOwner;
    /// @notice Relayer key allowed to consume approved first enrollments and `setPaused`; zero means no operator.
    address public operator;
    /// @notice Default swap fee for strategies without an override.
    uint16 public defaultSwapFeeBps;
    /// @notice Per-strategy swap fee override; 0 means "use `defaultSwapFeeBps`".
    mapping(uint256 => uint16) public feeBps;
    /// @notice The executor's numeraire (USDT), set once by the owner: the only asset a version may list at
    /// weight 0. Zero (unset) means no asset may have weight 0.
    address public numeraire;

    // ---- strategy / version ----
    mapping(uint256 => StrategyMeta) public strategies;
    /// @dev 1-based version history: index 0 is an empty sentinel so that version 0 can mean "active".
    mapping(uint256 => Version[]) internal _versions;
    mapping(uint256 => uint16) private _effectiveVersion;
    mapping(uint256 => uint16) private _pendingVersion;
    mapping(uint256 => mapping(uint16 => bool)) public cancelledVersion;
    mapping(uint256 => uint64) public lastPublishedAt;
    mapping(uint256 => address[]) private _historicalAssets;
    mapping(uint256 => mapping(address => bool)) private _historicalAsset;
    /// @notice One-use approval for the operator's FIRST enrollment, granted only by the account itself.
    mapping(address => bytes32) public enrollmentApproval;
    /// @notice Next strategy id to be handed out; ids start at 1.
    uint256 public nextStrategyId;

    // ---- enrollment ----
    mapping(address => Enrollment) internal _enrollments;
    mapping(address => bool) public isEnrolled;
    /// @notice OR of the `PAUSED_BY_*` bits holding `account` paused. `enrollments(account).paused` always
    /// equals `pauseFlags[account] != 0`; it is kept as a separate field so the executor and the backend read
    /// the same `Enrollment` layout as before.
    mapping(address => uint8) public pauseFlags;

    // ---- events ----
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OperatorUpdated(address indexed previousOperator, address indexed newOperator);
    event DefaultFeeBpsUpdated(uint16 bps);
    event FeeBpsUpdated(uint256 indexed id, uint16 bps);
    event NumeraireSet(address indexed numeraire);
    event StrategyRegistered(uint256 indexed id, address indexed provider, string name);
    event VersionPublished(uint256 indexed id, uint16 version, bytes32 scheduleHash);
    event VersionScheduled(uint256 indexed id, uint16 indexed version, uint64 activeAt, bytes32 configHash);
    event VersionCancelled(uint256 indexed id, uint16 indexed version);
    event EnrollmentApproved(address indexed account, uint256 indexed id, uint16 version, bytes32 terms);
    event Enrolled(address indexed account, uint256 id, uint16 version);
    event EnrollmentPausedSet(address indexed account, bool paused);
    event PauseFlagsSet(address indexed account, uint8 flags);

    // ---- errors ----
    error NotOwner();
    error NotPendingOwner();
    error ZeroAddress();
    error FeeTooHigh(uint16 bps);
    error UnknownStrategy(uint256 id);
    error UnknownVersion(uint256 id, uint16 version);
    error NotStrategyProvider(uint256 id);
    error EmptyAssets();
    error LengthMismatch();
    error DuplicateAsset(address asset);
    error WeightsMismatch(uint256 sum);
    error Unauthorized();
    error VersionNotPublished(uint256 id);
    /// @dev The operator may only make an account's first enrollment; changing an enrolled account's
    /// strategy or version is the account's own call.
    error AlreadyEnrolled(address account);
    /// @dev A version asset (or the numeraire) with no code: every buy would revert valuing it.
    error NotContract(address asset);
    /// @dev Weight 0 for an asset other than the numeraire.
    error ZeroWeight(address asset);
    error NumeraireAlreadySet();
    error PendingVersionExists(uint256 id);
    error NoPendingVersion(uint256 id);
    error PublicationTooSoon(uint256 earliest);
    error ActivationTooSoon(uint256 earliest);
    error PerformanceFeeOutOfRange(uint16 bps);
    error VersionLimit();
    error StrategyAssetLimitExceeded(uint256 count);
    error UnexpectedVersion(uint16 expected, uint16 actual);
    error ConsentRequired();

    constructor() {
        owner = msg.sender;
        emit OwnershipTransferred(address(0), msg.sender);
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    // ---- admin ----

    /// @notice Propose `next` as the new owner. Nothing changes until `next` calls `acceptOwnership`, so a
    /// mistyped address can never take the role. Proposing `address(0)` cancels a pending handover.
    function transferOwnership(address next) external onlyOwner {
        pendingOwner = next;
        emit OwnershipTransferStarted(owner, next);
    }

    /// @notice Complete a handover started by `transferOwnership`; callable only by the proposed owner.
    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        emit OwnershipTransferred(owner, msg.sender);
        owner = msg.sender;
        pendingOwner = address(0);
    }

    /// @notice Set (or with `address(0)` revoke) the relayer key allowed to enroll and pause accounts.
    function setOperator(address next) external onlyOwner {
        emit OperatorUpdated(operator, next);
        operator = next;
    }

    /// @notice Set the swap fee used by every strategy without an override.
    function setDefaultFeeBps(uint16 bps) external onlyOwner {
        _checkFee(bps);
        defaultSwapFeeBps = bps;
        emit DefaultFeeBpsUpdated(bps);
    }

    /// @notice Set (or with `bps == 0` clear) a strategy's swap fee override.
    function setStrategyFeeBps(uint256 id, uint16 bps) external onlyOwner {
        if (strategies[id].provider == address(0)) revert UnknownStrategy(id);
        _checkFee(bps);
        feeBps[id] = bps;
        emit FeeBpsUpdated(id, bps);
    }

    /// @notice Name the numeraire (the executor's USDT), once: from then on it is the only asset a version may
    /// list at weight 0. Before it is set no asset may have weight 0.
    function setNumeraire(address numeraire_) external onlyOwner {
        if (numeraire != address(0)) revert NumeraireAlreadySet();
        if (numeraire_.code.length == 0) revert NotContract(numeraire_);
        numeraire = numeraire_;
        emit NumeraireSet(numeraire_);
    }

    // ---- strategy / version ----

    /// @notice Register a new strategy owned by `msg.sender`. Provider admission (allowlisting who may
    /// register) is deliberately not enforced on-chain yet.
    function registerStrategy(string calldata name, string calldata description, bool isPublic)
        external
        returns (uint256 id)
    {
        id = ++nextStrategyId;
        strategies[id] =
            StrategyMeta({ provider: msg.sender, name: name, description: description, isPublic: isPublic });
        emit StrategyRegistered(id, msg.sender, name);
    }

    /// @notice Publish with default 5% performance fee and no additional off-chain rules.
    /// `activeAt == 0` selects the earliest permitted activation; a nonzero time cannot shorten notice.
    function publishVersion(
        uint256 id,
        address[] calldata assets,
        uint16[] calldata weightsBps,
        bytes32 scheduleHash,
        uint64 activeAt
    ) external returns (uint16) {
        return _publishVersion(
            id, assets, weightsBps, scheduleHash, bytes32(0), MIN_PERFORMANCE_FEE_BPS, activeAt
        );
    }

    /// @notice Publish the complete settings commitment. Only a provable fee-only decrease can be immediate.
    function publishSettingsVersion(
        uint256 id,
        address[] calldata assets,
        uint16[] calldata weightsBps,
        bytes32 scheduleHash,
        bytes32 settingsHash,
        uint16 performanceFeeBps,
        uint64 activeAt
    ) external returns (uint16) {
        return _publishVersion(
            id, assets, weightsBps, scheduleHash, settingsHash, performanceFeeBps, activeAt
        );
    }

    function _publishVersion(
        uint256 id,
        address[] calldata assets,
        uint16[] calldata weightsBps,
        bytes32 scheduleHash,
        bytes32 settingsHash,
        uint16 performanceFeeBps,
        uint64 activeAt
    ) private returns (uint16 versionNumber) {
        _providerOrOwner(id);
        _validateVersion(assets, weightsBps);
        if (performanceFeeBps < MIN_PERFORMANCE_FEE_BPS || performanceFeeBps > MAX_PERFORMANCE_FEE_BPS) {
            revert PerformanceFeeOutOfRange(performanceFeeBps);
        }
        _activate(id);
        if (_pendingVersion[id] != 0) revert PendingVersionExists(id);
        Version[] storage history = _versions[id];
        if (history.length != 0 && block.timestamp < uint256(lastPublishedAt[id]) + PUBLICATION_INTERVAL) {
            revert PublicationTooSoon(uint256(lastPublishedAt[id]) + PUBLICATION_INTERVAL);
        }
        // _activate has materialized every previously effective asset, including a just-matured pending.
        // The new list is duplicate-free, so each asset absent from that history adds exactly one slot.
        uint256 assetCount = _historicalAssets[id].length;
        for (uint256 i; i < assets.length; ++i) {
            if (!_historicalAsset[id][assets[i]]) ++assetCount;
        }
        if (assetCount > MAX_STRATEGY_ASSETS) revert StrategyAssetLimitExceeded(assetCount);
        bool feeOnlyDecrease;
        uint16 current = _effectiveVersion[id];
        if (current != 0) {
            Version storage prior = history[current];
            feeOnlyDecrease = performanceFeeBps < prior.performanceFeeBps
                && keccak256(abi.encode(assets, weightsBps, scheduleHash, settingsHash))
                    == keccak256(
                        abi.encode(prior.assets, prior.weightsBps, prior.scheduleHash, prior.settingsHash)
                    );
        }
        uint256 earliest = block.timestamp + (feeOnlyDecrease ? 0 : VERSION_DELAY);
        if (earliest > type(uint64).max) revert ActivationTooSoon(earliest);
        if (activeAt == 0) activeAt = uint64(earliest);
        if (activeAt < earliest) revert ActivationTooSoon(earliest);
        if (history.length == 0) history.push();
        if (history.length > type(uint16).max) revert VersionLimit();
        history.push(
            Version({
                assets: assets,
                weightsBps: weightsBps,
                scheduleHash: scheduleHash,
                activeAt: activeAt,
                settingsHash: settingsHash,
                performanceFeeBps: performanceFeeBps,
                configHash: keccak256(
                    abi.encode(assets, weightsBps, scheduleHash, settingsHash, performanceFeeBps)
                )
            })
        );
        versionNumber = uint16(history.length - 1);
        lastPublishedAt[id] = uint64(block.timestamp);
        _pendingVersion[id] = versionNumber;
        emit VersionPublished(id, versionNumber, scheduleHash);
        emit VersionScheduled(id, versionNumber, activeAt, history[versionNumber].configHash);
        _activate(id);
    }

    /// @notice Cancel only before activation. Cancellation never reuses a version or resets the 7-day clock.
    function cancelVersion(uint256 id) external {
        _providerOrOwner(id);
        uint16 pending = pendingVersion(id);
        if (pending == 0) revert NoPendingVersion(id);
        cancelledVersion[id][pending] = true;
        _pendingVersion[id] = 0;
        emit VersionCancelled(id, pending);
    }

    function _providerOrOwner(uint256 id) private view {
        address provider = strategies[id].provider;
        if (provider == address(0)) revert UnknownStrategy(id);
        if (msg.sender != provider && msg.sender != owner) revert NotStrategyProvider(id);
    }

    /// @notice Latest version effective at this block, without a keeper activation transaction.
    function activeVersion(uint256 id) public view returns (uint16) {
        uint16 pending = _pendingVersion[id];
        return
            pending != 0 && _versions[id][pending].activeAt <= block.timestamp
                ? pending
                : _effectiveVersion[id];
    }

    function pendingVersion(uint256 id) public view returns (uint16) {
        uint16 pending = _pendingVersion[id];
        return pending != 0 && _versions[id][pending].activeAt > block.timestamp ? pending : 0;
    }

    function _activate(uint256 id) private {
        uint16 pending = _pendingVersion[id];
        if (pending == 0 || _versions[id][pending].activeAt > block.timestamp) return;
        _effectiveVersion[id] = pending;
        _pendingVersion[id] = 0;
        address[] storage assets = _versions[id][pending].assets;
        for (uint256 i; i < assets.length; ++i) {
            address asset = assets[i];
            if (!_historicalAsset[id][asset]) {
                _historicalAsset[id][asset] = true;
                _historicalAssets[id].push(asset);
            }
        }
    }

    // ---- enrollment ----

    /// @notice Account's sudo call consents to FOLLOW_VERSIONS_TERMS and authorizes ONE first enrollment.
    /// The operator cannot manufacture consent, choose another strategy/version, or reuse it after enrollment.
    function approveEnrollment(uint256 id, uint16 expectedVersion) external {
        if (isEnrolled[msg.sender]) revert AlreadyEnrolled(msg.sender);
        _checkExpectedVersion(id, expectedVersion);
        enrollmentApproval[msg.sender] = _approval(id, expectedVersion);
        emit EnrollmentApproved(msg.sender, id, expectedVersion, FOLLOW_VERSIONS_TERMS);
    }

    function revokeEnrollmentApproval() external {
        delete enrollmentApproval[msg.sender];
        emit EnrollmentApproved(msg.sender, 0, 0, FOLLOW_VERSIONS_TERMS);
    }

    /// @notice Account's own sudo call is consent to FOLLOW_VERSIONS_TERMS; operator needs prior approval.
    /// expectedVersion must equal the latest EFFECTIVE version, never zero. No two-argument entry point exists.
    function enroll(address account, uint256 id, uint16 expectedVersion) external {
        if (msg.sender != account) {
            if (msg.sender != operator) revert Unauthorized();
            if (isEnrolled[account]) revert AlreadyEnrolled(account);
        }
        if (account == address(0)) revert ZeroAddress();
        _checkExpectedVersion(id, expectedVersion);
        if (msg.sender != account && enrollmentApproval[account] != _approval(id, expectedVersion)) {
            revert ConsentRequired();
        }
        delete enrollmentApproval[account];
        _enrollments[account] = Enrollment({ strategyId: id, version: expectedVersion, paused: false });
        isEnrolled[account] = true;
        if (pauseFlags[account] != 0) {
            pauseFlags[account] = 0;
            emit PauseFlagsSet(account, 0);
        }
        emit Enrolled(account, id, expectedVersion);
    }

    function _checkExpectedVersion(uint256 id, uint16 expectedVersion) private view {
        if (strategies[id].provider == address(0)) revert UnknownStrategy(id);
        uint16 actual = activeVersion(id);
        if (actual == 0) revert VersionNotPublished(id);
        if (expectedVersion == 0 || expectedVersion != actual) {
            revert UnexpectedVersion(expectedVersion, actual);
        }
    }

    function _approval(uint256 id, uint16 versionNumber) private view returns (bytes32) {
        return keccak256(
            abi.encode(id, versionNumber, _versions[id][versionNumber].configHash, FOLLOW_VERSIONS_TERMS)
        );
    }

    /// @notice Pause or resume an enrolled account. A paused account fails every `executeRebalance`.
    /// @dev Each caller sets its own `PAUSED_BY_*` bit and clears only what it outranks:
    /// - the account itself: pause sets ACCOUNT; resume clears every bit (the account is the owner's own);
    /// - the owner (Safe): pause sets OWNER; resume clears OWNER and OPERATOR, never the account's own;
    /// - the operator: pause sets OPERATOR; resume clears OPERATOR only.
    /// A resume that leaves another source's bit set succeeds but the account stays paused; read
    /// `pauseFlags` (or the `PauseFlagsSet` event) for the result.
    function setPaused(address account, bool paused) external {
        uint8 flags = pauseFlags[account];
        if (msg.sender == account) {
            flags = paused ? flags | PAUSED_BY_ACCOUNT : 0;
        } else if (msg.sender == owner) {
            flags = paused ? flags | PAUSED_BY_OWNER : flags & ~(PAUSED_BY_OWNER | PAUSED_BY_OPERATOR);
        } else if (msg.sender == operator) {
            flags = paused ? flags | PAUSED_BY_OPERATOR : flags & ~PAUSED_BY_OPERATOR;
        } else {
            revert Unauthorized();
        }
        if (!isEnrolled[account]) revert Unauthorized();

        bool nowPaused = flags != 0;
        pauseFlags[account] = flags;
        _enrollments[account].paused = nowPaused;
        emit PauseFlagsSet(account, flags);
        emit EnrollmentPausedSet(account, nowPaused);
    }

    // ---- views ----

    /// @notice Enrollment record for `account` (all-zero when never enrolled).
    function enrollments(address account) external view returns (Enrollment memory) {
        return _enrollments[account];
    }

    /// @notice Fee in bps actually charged for `id`: its override, else the default.
    function effectiveFeeBps(uint256 id) public view returns (uint16) {
        uint16 strategyFee = feeBps[id];
        return strategyFee == 0 ? defaultSwapFeeBps : strategyFee;
    }

    /// @notice Version record; `versionNumber == 0` resolves to the active version.
    function version(uint256 id, uint16 versionNumber) public view returns (Version memory) {
        if (versionNumber == 0) versionNumber = activeVersion(id);
        if (versionNumber == 0 || versionNumber >= _versions[id].length) {
            revert UnknownVersion(id, versionNumber);
        }
        return _versions[id][versionNumber];
    }

    /// @notice Number of published versions (0 when the strategy has none).
    function versionCount(uint256 id) public view returns (uint256) {
        uint256 stored = _versions[id].length;
        return stored == 0 ? 0 : stored - 1;
    }

    /// @notice Whether `asset` is tradable in `id` at `versionNumber` (0 = active).
    /// @dev Returns false rather than reverting for an unknown strategy/version so the executor can fail one
    /// step with its own error; an empty asset list can therefore never be "allowed". The scan is linear in the
    /// version's asset count and runs twice per swap step.
    function isAssetAllowed(uint256 id, uint16 versionNumber, address asset) public view returns (bool) {
        if (versionNumber == 0) versionNumber = activeVersion(id);
        if (versionNumber == 0 || versionNumber >= _versions[id].length) return false;
        if (cancelledVersion[id][versionNumber] || _versions[id][versionNumber].activeAt > block.timestamp) {
            return false;
        }
        address[] storage assets = _versions[id][versionNumber].assets;
        for (uint256 i; i < assets.length; ++i) {
            if (assets[i] == asset) return true;
        }
        return false;
    }

    /// @notice Ever effective (not pending or cancelled): admitted only for sales back to numeraire.
    function wasAssetAllowed(uint256 id, address asset) external view returns (bool) {
        return _historicalAsset[id][asset] || isAssetAllowed(id, 0, asset);
    }

    /// @notice Deduplicated union of all effective versions, including a matured but unmaterialized pending.
    function historicalAssets(uint256 id) external view returns (address[] memory assets) {
        address[] storage past = _historicalAssets[id];
        uint16 current = activeVersion(id);
        address[] memory latest = current == 0 ? new address[](0) : _versions[id][current].assets;
        assets = new address[](past.length + latest.length);
        uint256 count;
        for (uint256 i; i < past.length; ++i) {
            assets[count++] = past[i];
        }
        for (uint256 i; i < latest.length; ++i) {
            if (!_historicalAsset[id][latest[i]]) assets[count++] = latest[i];
        }
        assembly { mstore(assets, count) }
    }

    // ---- internals ----

    function _checkFee(uint16 bps) internal pure {
        if (bps > MAX_SWAP_FEE_BPS) revert FeeTooHigh(bps);
    }

    /// @dev Duplicate-free, positive-length asset list with weights summing to exactly 10000. The complete
    /// effective history plus this list must fit MAX_STRATEGY_ASSETS; reject an oversized list before the
    /// quadratic duplicate check. Every asset must be a contract and have a positive weight, except the
    /// numeraire, which may have weight 0 (cre8-contracts#47). Providers must publish oracle-supported assets;
    /// the registry does not validate oracle coverage.
    function _validateVersion(address[] calldata assets, uint16[] calldata weightsBps) internal view {
        uint256 count = assets.length;
        if (count == 0) revert EmptyAssets();
        if (count != weightsBps.length) revert LengthMismatch();
        if (count > MAX_STRATEGY_ASSETS) revert StrategyAssetLimitExceeded(count);
        address numeraire_ = numeraire;
        uint256 sum;
        for (uint256 i; i < count; ++i) {
            address asset = assets[i];
            if (asset == address(0)) revert ZeroAddress();
            if (asset.code.length == 0) revert NotContract(asset);
            // `asset` is never zero, so an unset numeraire matches no asset.
            if (weightsBps[i] == 0 && asset != numeraire_) revert ZeroWeight(asset);
            for (uint256 j; j < i; ++j) {
                if (assets[j] == asset) revert DuplicateAsset(asset);
            }
            sum += weightsBps[i];
        }
        if (sum != TOTAL_WEIGHT_BPS) revert WeightsMismatch(sum);
    }
}
