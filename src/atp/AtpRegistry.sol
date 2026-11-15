// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title AtpRegistry
/// @notice On-chain record of ATP strategies: versioned asset/weight sets, the admin-controlled swap fee,
/// and which strategy version an account is enrolled in.
/// @dev Weights are data, not logic: the keeper reads them, the executor only uses the asset set of the
/// enrolled version as an allowlist. A published version is immutable; a provider changes weights by
/// publishing the next version, and existing enrollments keep the version they pinned until they re-enroll.
/// @dev Roles: `owner` (a Safe on mainnet) holds every admin power and hands it over in two steps
/// (`transferOwnership` → `acceptOwnership`). `operator` is the backend relayer key, set and revoked by the
/// owner: it may only make an account's first enrollment and pause/resume what it paused itself, so a leaked
/// relayer key cannot touch fees, ownership, an enrolled account's strategy or version, or a pause set by the
/// owner or the account (A10-2). Changing an enrolled account's strategy or version is the account's own call
/// (its owner's sudo UserOp). The first enrollment still has no two-phase user signature - see
/// docs/atp-pivot-executor-spec.zh-TW.md §6.
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
    }

    struct StrategyMeta {
        address provider;
        string name;
        string description;
        bool isPublic;
    }

    struct Enrollment {
        uint256 strategyId;
        /// @notice Version index pinned at enrollment time (1-based; 0 means "never enrolled").
        uint16 version;
        bool paused;
    }

    // ---- constants ----
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
    /// @notice Relayer key allowed to `enroll` accounts and `setPaused`; zero means no operator.
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
    /// @notice Currently active version index for a strategy (0 = none published).
    mapping(uint256 => uint16) public activeVersion;
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

    /// @notice Publish the next version of `id` and make it active for new enrollments.
    /// @dev Append-only: a version index can never be reused or overwritten, so the history of a strategy
    /// only grows. Only the strategy provider or the registry owner may publish.
    function publishVersion(
        uint256 id,
        address[] calldata assets,
        uint16[] calldata weightsBps,
        bytes32 scheduleHash,
        uint64 activeAt
    ) external returns (uint16 versionNumber) {
        StrategyMeta memory meta = strategies[id];
        if (meta.provider == address(0)) revert UnknownStrategy(id);
        if (msg.sender != meta.provider && msg.sender != owner) revert NotStrategyProvider(id);
        _validateVersion(assets, weightsBps);

        Version[] storage history = _versions[id];
        // 1-based: seed the sentinel on first publish so version 0 stays reserved for "active".
        if (history.length == 0) history.push();
        Version storage published = history.push();
        published.assets = assets;
        published.weightsBps = weightsBps;
        published.scheduleHash = scheduleHash;
        published.activeAt = activeAt;

        versionNumber = uint16(history.length - 1);
        activeVersion[id] = versionNumber;
        emit VersionPublished(id, versionNumber, scheduleHash);
    }

    // ---- enrollment ----

    /// @notice Enroll `account` into `id`, pinning the currently active version.
    /// @dev The account itself may always (re-)enroll: that is how its owner moves to another strategy or a
    /// newer version, and it clears every pause, since the account is the owner's own. The operator (backend
    /// relayer) may only make the first enrollment of an account that is not enrolled yet, so it can neither
    /// move a funded account onto a strategy or version its owner never chose, nor clear a pause by
    /// re-enrolling. The owner cannot enroll: it is a Safe and has no reason to.
    /// TODO: the operator's first enrollment still carries no two-phase user signature.
    function enroll(address account, uint256 id) external {
        if (msg.sender != account) {
            if (msg.sender != operator) revert Unauthorized();
            if (isEnrolled[account]) revert AlreadyEnrolled(account);
        }
        if (account == address(0)) revert ZeroAddress();
        if (strategies[id].provider == address(0)) revert UnknownStrategy(id);
        uint16 version = activeVersion[id];
        if (version == 0) revert VersionNotPublished(id);

        _enrollments[account] = Enrollment({ strategyId: id, version: version, paused: false });
        isEnrolled[account] = true;
        if (pauseFlags[account] != 0) {
            pauseFlags[account] = 0;
            emit PauseFlagsSet(account, 0);
        }
        emit Enrolled(account, id, version);
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
        if (versionNumber == 0) versionNumber = activeVersion[id];
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
        if (versionNumber == 0) versionNumber = activeVersion[id];
        if (versionNumber == 0 || versionNumber >= _versions[id].length) return false;
        address[] storage assets = _versions[id][versionNumber].assets;
        for (uint256 i; i < assets.length; ++i) {
            if (assets[i] == asset) return true;
        }
        return false;
    }

    // ---- internals ----

    function _checkFee(uint16 bps) internal pure {
        if (bps > MAX_SWAP_FEE_BPS) revert FeeTooHigh(bps);
    }

    /// @dev Duplicate-free, positive-length asset list with weights summing to exactly 10000. There is no
    /// asset-count ceiling (cre8-contracts#45). Swaps are per step, so a large rebalance or exit is split over
    /// several `executeRebalance` batches; only this publish and the executor's account valuation (once per
    /// batch with a buy) walk the whole list in one transaction. docs/testnet-97.zh-TW.md has the gas per
    /// flow measured for a 93-asset version. Every asset must be a contract and have a positive weight, except
    /// the numeraire, which may have weight 0 (cre8-contracts#47).
    function _validateVersion(address[] calldata assets, uint16[] calldata weightsBps) internal view {
        uint256 count = assets.length;
        if (count == 0) revert EmptyAssets();
        if (count != weightsBps.length) revert LengthMismatch();
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
