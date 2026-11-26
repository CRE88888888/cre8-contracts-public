// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { UniversalRouterCommands as Cmd } from "./interfaces/IUniversalRouter.sol";
import { IUniversalRouter } from "./interfaces/IUniversalRouter.sol";
import { IOracleFloor } from "./interfaces/IOracleFloor.sol";
import { IPermit2 } from "./interfaces/IPermit2.sol";
import { AtpRegistry } from "./AtpRegistry.sol";
import { AtpYieldRegistry } from "./yield/AtpYieldRegistry.sol";
import { YieldTypes as Y } from "./yield/YieldTypes.sol";
import { YieldActions } from "./yield/YieldActions.sol";

/// @title AtpExecutor
/// @notice The only contract that moves user funds for an ATP rebalance. One call per user operation:
/// the smart account approves this executor, the executor pulls `tokenIn`, swaps through the pinned
/// Universal Router, splits the fee off the output, and returns the net output to the account.
/// @dev Trust model (docs/atp-pivot-executor-spec.zh-TW.md §1-§2): the session key only ever triggers
/// "account -> executeRebalance", enforced in the Kernel layer, so this contract does not inspect session
/// keys. It trusts `msg.sender == account` and enforces the domain rules itself: enrolled/unpaused
/// strategy, version asset allowlist, command allowlist with the recipient pinned back here, deadline, and
/// the oracle floor. The agent chooses routes and fills `amountOutMin`, which must be at least the oracle-derived
/// `minGross`; the realised gross output must then clear `amountOutMin` itself (cre8-contracts#24), so a tighter
/// agent bound binds on chain even when a venue's own calldata is opaque, and no bound can go below the floor.
/// @dev Buy limit (A10-1, cre8-contracts#10): a leaked session key could grind an account down by trading
/// back and forth, each step clearing the floor. Every round trip needs a buy, so buys (numeraire -> asset)
/// are capped per account at `maxBuyBps` of the account's current value per fixed 24-hour window. Sales to the
/// numeraire are never limited, so exits always go through.
/// @dev Sale credit (cre8-contracts#76): a sale's numeraire output is credited back against the window's buys, so an
/// account that sells everything can buy again the same day (a re-buy, a DCA period, a top-up) instead of waiting
/// for the window to end. The credit alone would let a leaked key round-trip without end, so every buy is also
/// counted, never credited, against a gross cap of `GROSS_BUY_MULTIPLE` x the highest cap (value x `maxBuyBps`) any
/// buy of the window has seen. The key cannot add money to the account, so that peak is what the account held; a
/// churning key is stopped after buying `GROSS_BUY_MULTIPLE` x `maxBuyBps` of it in a window.
/// @dev Venues (cre8-contracts#15): every step names a venue from a Safe-managed allowlist - the Pancake
/// Universal Router (commands allowlisted, recipient pinned here, as before) or an aggregator / DEX router
/// whose calldata is passed through undecoded. What bounds a malicious or compromised venue is not decoding but
/// four invariants: accounts approve only this executor; this executor holds no balance between calls; the
/// venue is approved exactly this step's `amountIn` of `tokenIn` and the approval is zeroed right after the
/// call; and the `tokenOut` that actually landed here must clear the step's `amountOutMin` (never below the
/// oracle floor) or the whole batch reverts. A venue can therefore take at most (step amount - amountOutMin)
/// per step, and never more than (step amount - floor), the same bound as a sandwich today.
/// @dev Minimum batch fee (cre8-contracts#33, docs P12): a batch with at least one swap pays
/// `max(notional x feeBps, min(minBatchFee, notional x MIN_FEE_MAX_BPS))`, where `notional` is the batch's
/// numeraire volume (a buy's `amountIn` plus a sale's gross output). The proportional part is still split off
/// each step's output exactly as before, so every step's floor check is unchanged; only the difference up to
/// the minimum (the top-up) is pulled in numeraire from the account after the last step. Because the top-up
/// never comes out of a swap's output, it neither enters nor loosens any floor. Two bounds keep it from
/// becoming a lever: it is at most `MIN_FEE_MAX_BPS` of the batch notional (a leaked session key cannot grind
/// an account down with dust batches, and a dust exit pays at most that share), and it is capped at what the
/// account holds and has approved in numeraire, so it never blocks a batch - least of all an exit.
/// @dev One minimum per account per window (cre8-contracts#47): the backend splits one purchase over several
/// batches (at most 16 steps each), and a per-batch minimum charged it several times. So the minimum is
/// accounted per account over a fixed `MIN_FEE_WINDOW`, opened by its first batch with a swap: the window is
/// treated as one batch of its cumulative notional `c`, and a batch pays only what the window still owes,
/// `max(0, T(c) - paid)`, where `T(c) = max(0, min(minBatchFee, c x MIN_FEE_MAX_BPS) - c x feeBps)` is the
/// one-batch top-up and `paid` the top-ups pulled so far in the window. Consequences: a window never pays less
/// than one batch of its cumulative notional would (a dust batch first cannot use the minimum up), never more
/// than one `minBatchFee` on top of the proportional fee, and no batch more than it would have paid alone
/// (T is subadditive) - except a shortfall an earlier batch of the window could not pay, which stays owed.
contract AtpExecutor is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant BPS_DENOMINATOR = 10_000;
    /// @notice Fixed execution-quote tolerance for signed yield minima; no administrative override.
    uint256 public constant YIELD_QUOTE_TOLERANCE_BPS = 10;
    /// @dev Canonical Uniswap Permit2, the same address on every chain it is deployed to, BSC mainnet (56)
    /// and testnet (97) included. Read only by the constructor; see the pin there for why it exists.
    address internal constant CANONICAL_PERMIT2 = 0x31c2F6fcFf4F8759b3Bd5Bf0e1084A055615c768;
    /// @notice Length of the fixed buy-limit window. It opens with an account's first buy and resets with the
    /// first buy at or after `start + BUY_WINDOW`.
    uint256 public constant BUY_WINDOW = 1 days;
    /// @notice Upper bound for `maxBuyBps` (2x the account value per window).
    uint16 public constant MAX_BUY_BPS_CEILING = 20_000;
    /// @notice A window's buys, sale credits ignored, never exceed this multiple of the highest cap a buy of the
    /// window has seen (cre8-contracts#76).
    uint256 public constant GROSS_BUY_MULTIPLE = 2;
    /// @notice The minimum-fee top-up never exceeds this share of the batch notional (1%).
    uint16 public constant MIN_FEE_MAX_BPS = 100;
    /// @notice Length of the fixed minimum-fee window: it opens with an account's first batch with a swap and
    /// resets with the first such batch at or after `start + MIN_FEE_WINDOW`.
    uint256 public constant MIN_FEE_WINDOW = 1 hours;
    /// @notice Gas cap for each `balanceOf` read while valuing an account (cre8-contracts#47); a token needing
    /// more counts as zero. ERC20 and bStock proxy reads take a few thousand to ~30k gas.
    uint256 public constant BALANCE_OF_GAS = 100_000;
    /// @notice Upper bound for `minBatchFee`: 5 whole numeraire units (5 USDT), read from its decimals.
    uint256 public immutable minBatchFeeCeiling;

    /// @notice Strategy/enrollment/fee record. Also the admin for `feeRecipient`.
    AtpRegistry public immutable registry;
    /// @notice PancakeSwap Universal Router, pinned per chain; registered as the first `PANCAKE_UR` venue at
    /// construction.
    IUniversalRouter public immutable universalRouter;
    /// @notice Oracle floor adapter; see IOracleFloor for the previewSwap/_saleFloor semantics.
    IOracleFloor public immutable oracle;
    /// @notice Canonical Permit2, pinned per chain. The Universal Router pays every ERC20 leg through it,
    /// so the input token has to be approved to Permit2 (and Permit2 told which spender may use it) before
    /// the router runs. Supplied by the deployer; on BSC mainnet (56) and testnet (97) the constructor
    /// additionally requires it to equal `CANONICAL_PERMIT2`.
    IPermit2 public immutable permit2;
    /// @notice The token every step trades against (USDT on BSC): a step paying it out is a sale, a step paying
    /// it in is a buy. Must equal the oracle router's numeraire; `DeployAtpMainnet` verifies it.
    address public immutable numeraire;
    /// @notice Receives the swap fee (admin-settable, registry owner only).
    address public feeRecipient;
    /// @notice Kill switch (registry owner only): while set, every `executeRebalance` reverts, sales to the
    /// numeraire included. For an oracle or executor incident, where even a sale would trade against a wrong
    /// floor. Owners can still move funds out of their own accounts; that path never touches this contract.
    bool public globalPaused;
    /// @notice Per-window buy cap in bps of the account's current value (registry owner only; 0 = sales only).
    uint16 public maxBuyBps;
    /// @notice Minimum fee per swap batch in numeraire units (registry owner only; 0 = proportional fee only).
    uint256 public minBatchFee;

    /// @dev One slot per account. `bought` is the numeraire spent on buys since `start`, less what sales have
    /// credited back since (never below zero).
    struct BuyWindow {
        uint64 start;
        uint192 bought;
    }

    /// @notice Buy-limit window per account; `start == 0` means never opened, and a window is stale (treated as
    /// empty) once `start + BUY_WINDOW` has passed.
    mapping(address => BuyWindow) public buyWindowOf;

    /// @dev Second slot of the same window (cre8-contracts#76), valid only while `buyWindowOf` is: `gross` is every
    /// buy since `start` with no sale credit, `peakCap` the highest cap (value x `maxBuyBps`) a buy of it has seen.
    struct BuyChurn {
        uint128 gross;
        uint128 peakCap;
    }

    /// @notice Gross side of the buy window, read together with `buyWindowOf` (stale when that one is).
    mapping(address => BuyChurn) public buyChurnOf;

    /// @dev The buy window as a batch works on it.
    struct BuyState {
        bool hasBuy;
        bool live;
        uint64 start;
        uint256 bought;
        uint256 gross;
        uint256 cap;
        uint256 peakCap;
        uint256 grossCap;
    }

    /// @dev `notional` is the numeraire volume of the window's batches, `paid` the minimum-fee top-ups pulled.
    struct MinFeeWindow {
        uint64 start;
        uint192 notional;
        uint256 paid;
    }

    /// @notice Minimum-fee window per account; `start == 0` means never opened, and a window is stale (treated
    /// as empty) once `start + MIN_FEE_WINDOW` has passed.
    mapping(address => MinFeeWindow) public minFeeWindowOf;

    /// @notice How a venue is paid and called.
    /// - `PANCAKE_UR`: Universal Router. `data` = `abi.encode(bytes commands, bytes[] inputs)`; commands are
    ///   allowlisted with every recipient pinned to this executor; paid through Permit2 (spender = the venue).
    /// - `ERC20_APPROVE`: aggregator / router pulling `tokenIn` with a plain ERC20 allowance granted to `spender`.
    /// - `PERMIT2`: router pulling `tokenIn` through Permit2, with the Permit2 allowance granted to `spender`.
    /// For the last two `data` is the raw calldata for the venue, never decoded here.
    enum VenueKind {
        NONE,
        PANCAKE_UR,
        ERC20_APPROVE,
        PERMIT2
    }

    struct Venue {
        VenueKind kind;
        /// @notice Who gets this step's allowance (the venue itself for `PANCAKE_UR`).
        address spender;
    }

    /// @notice Venue allowlist, keyed by call target. Registry owner (Safe) only; `NONE` = not allowed.
    mapping(address => Venue) public venues;

    struct SwapStep {
        /// @notice Token sold, pulled from the account.
        address tokenIn;
        /// @notice Token bought, must land back on this executor.
        address tokenOut;
        /// @notice Exact input amount, in `tokenIn` units.
        uint256 amountIn;
        /// @notice The agent's own bound on the gross output. Must be at least `minGross` (the oracle floor
        /// grossed up over the fee), and the realised output measured here must clear it (cre8-contracts#24).
        uint256 amountOutMin;
        /// @notice Call target, must be an allowlisted venue.
        address venue;
        /// @notice `PANCAKE_UR`: `abi.encode(commands, inputs)`; otherwise the venue's raw calldata.
        bytes data;
    }

    event SwapExecuted(
        address indexed account,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 gross,
        uint256 fee,
        uint256 net,
        uint256 oracleFloor
    );
    event FeeRecipientUpdated(address indexed previousRecipient, address indexed newRecipient);
    event GlobalPausedSet(bool paused);
    event MaxBuyBpsSet(uint16 bps);
    event MinBatchFeeSet(uint256 amount);
    /// @dev `due` is the top-up the batch owed over its proportional fee; `charged` is what was pulled (less only
    /// when the account held or had approved less numeraire).
    event MinFeeCharged(address indexed account, uint256 notional, uint256 due, uint256 charged);
    event VenueSet(address indexed target, VenueKind kind, address spender);
    event VenueRemoved(address indexed target);

    error InvalidConfig();
    error NotOwner();
    error ZeroAddress();
    error NotAccount();
    error NotContract();
    error NotEnrolled();
    error Paused();
    /// @dev The registry owner stopped every rebalance (`globalPaused`). Distinct from `Paused`, which is one
    /// account's enrollment.
    error ExecutorPaused();
    error DeadlineExpired();
    error ZeroAmount();
    /// @dev `amountIn` does not fit Permit2's uint160 allowance model, so the Permit2 leg would truncate it.
    error AmountTooLarge();
    error SameToken();
    error AssetNotAllowed();
    error BadCommands();
    error CommandNotAllowed(bytes1 command);
    error BadRecipient(address recipient);
    error NoFloor();
    error FeeTooHigh(uint256 bps);
    /// @dev `floor` is the bound that failed: `minGross` when `amountOutMin` is below it (checked before any token
    /// moves), otherwise the step's `amountOutMin` (checked against the realised output after the swap).
    error BelowFloor(uint256 realised, uint256 floor);
    /// @dev This batch would take the window's buys to `bought`, above `cap` (value x `maxBuyBps`); or its gross buys
    /// to `bought`, above `cap` = `GROSS_BUY_MULTIPLE` x the window's peak cap.
    error BuyLimitExceeded(uint256 bought, uint256 cap);
    error BuyBpsTooHigh(uint16 bps);
    error MinBatchFeeTooHigh(uint256 amount);
    /// @dev Neither leg is the numeraire, so the step is neither a sale nor a countable buy. The oracle router
    /// rejects such a pair as well; this keeps the buy limit fail-closed on its own.
    error NotNumeraireRoute(address tokenIn, address tokenOut);
    error VenueNotAllowed(address venue);
    /// @dev A venue (or its spender) that would be one of this step's tokens, the account, or a protocol contract.
    error BadVenue(address target);

    constructor(
        AtpRegistry registry_,
        IUniversalRouter universalRouter_,
        IOracleFloor oracle_,
        address permit2_,
        address feeRecipient_,
        address numeraire_,
        uint16 maxBuyBps_,
        uint256 minBatchFee_
    ) {
        if (
            address(registry_).code.length == 0 || address(universalRouter_).code.length == 0
                || address(oracle_).code.length == 0 || permit2_.code.length == 0
                || feeRecipient_ == address(0) || numeraire_.code.length == 0
        ) revert InvalidConfig();
        if (maxBuyBps_ > MAX_BUY_BPS_CEILING) revert BuyBpsTooHigh(maxBuyBps_);
        uint256 ceiling = 5 * 10 ** IERC20Metadata(numeraire_).decimals();
        if (minBatchFee_ > ceiling) revert MinBatchFeeTooHigh(minBatchFee_);

        // v1 hardening: on the chains this protocol actually serves, pin Permit2 to the canonical Uniswap
        // deployment. The code-length check above accepts any contract, so a mis-wired `permit2_` on BSC
        // would pass it while every input token got approved to an address the router never pays through -
        // or to a contract an attacker controls, which could pull the approved amount once the ERC20 leg is
        // granted. Pinning makes that deployment impossible instead of merely detectable after the fact.
        // The other chains keep the code-length check alone, because the canonical deployment is a per-chain
        // fact this contract should not have to know. This is a v1 guard: once more chains are supported,
        // move the per-chain pin into the deploy script so this constructor stays chain-agnostic.
        uint256 chainId = uint256(block.chainid);
        if (chainId == 56 || chainId == 97) {
            if (permit2_ != CANONICAL_PERMIT2) revert InvalidConfig();
        }

        yieldRegistry = new AtpYieldRegistry(registry_, address(this));
        emit YieldRegistrySet(address(yieldRegistry));
        registry = registry_;
        universalRouter = universalRouter_;
        oracle = oracle_;
        permit2 = IPermit2(permit2_);
        feeRecipient = feeRecipient_;
        numeraire = numeraire_;
        maxBuyBps = maxBuyBps_;
        emit MaxBuyBpsSet(maxBuyBps_);
        minBatchFeeCeiling = ceiling;
        minBatchFee = minBatchFee_;
        emit MinBatchFeeSet(minBatchFee_);
        _setVenue(address(universalRouter_), VenueKind.PANCAKE_UR, address(0));
    }

    // ---- admin ----

    /// @notice Replace the swap-fee recipient. Admin is the registry owner, so there is one admin key.
    function setFeeRecipient(address next) external {
        if (msg.sender != registry.owner()) revert NotOwner();
        if (next == address(0)) revert ZeroAddress();
        emit FeeRecipientUpdated(feeRecipient, next);
        feeRecipient = next;
    }

    /// @notice Stop (`true`) or resume (`false`) every rebalance in one transaction. Registry owner only, the
    /// same single admin key as `setFeeRecipient`; the operator has no access.
    function setGlobalPaused(bool paused) external {
        if (msg.sender != registry.owner()) revert NotOwner();
        globalPaused = paused;
        emit GlobalPausedSet(paused);
    }

    /// @notice Set the per-window buy cap in bps of the account value, at most `MAX_BUY_BPS_CEILING`. `0` stops
    /// every buy while sales go on ("sales only"). Registry owner only; the operator has no access.
    function setMaxBuyBps(uint16 bps) external {
        if (msg.sender != registry.owner()) revert NotOwner();
        if (bps > MAX_BUY_BPS_CEILING) revert BuyBpsTooHigh(bps);
        maxBuyBps = bps;
        emit MaxBuyBpsSet(bps);
    }

    /// @notice Set the minimum fee per swap batch, at most `minBatchFeeCeiling`. `0` leaves only the proportional
    /// fee. Registry owner only; the operator has no access.
    function setMinBatchFee(uint256 amount) external {
        if (msg.sender != registry.owner()) revert NotOwner();
        if (amount > minBatchFeeCeiling) revert MinBatchFeeTooHigh(amount);
        minBatchFee = amount;
        emit MinBatchFeeSet(amount);
    }

    /// @notice Allow (or reconfigure) `target` as a venue. Registry owner only; the operator has no access.
    /// `spender` is ignored for `PANCAKE_UR` (the venue itself is the Permit2 spender).
    function setVenue(address target, VenueKind kind, address spender) external {
        if (msg.sender != registry.owner()) revert NotOwner();
        _setVenue(target, kind, spender);
    }

    /// @notice Stop using `target` immediately. Registry owner only.
    function removeVenue(address target) external {
        if (msg.sender != registry.owner()) revert NotOwner();
        delete venues[target];
        emit VenueRemoved(target);
    }

    /// @dev Neither the target nor the spender may be a contract this executor trusts or holds allowances on:
    /// approving or calling the registry, the oracle, Permit2, the numeraire or this executor would turn the
    /// pass-through call into something other than a swap.
    function _setVenue(address target, VenueKind kind, address spender) internal {
        if (kind == VenueKind.NONE || target.code.length == 0) revert InvalidConfig();
        if (kind == VenueKind.PANCAKE_UR) spender = target;
        if (spender.code.length == 0) revert InvalidConfig();
        _requireNotProtocol(target);
        _requireNotProtocol(spender);
        venues[target] = Venue({ kind: kind, spender: spender });
        emit VenueSet(target, kind, spender);
    }

    function _requireNotProtocol(address target) internal view {
        if (target == address(yieldRegistry) || yieldRegistry.isYieldProtocol(target)) {
            revert BadVenue(target);
        }
        if (
            target == address(this) || target == address(registry) || target == address(oracle)
                || target == address(permit2) || target == numeraire
        ) revert BadVenue(target);
    }

    AtpYieldRegistry public immutable yieldRegistry;
    error YieldMinimum(uint256 supplied, uint256 required);
    event YieldRegistrySet(address indexed yieldRegistry);
    event SupplyExecuted(
        address indexed account,
        bytes32 indexed marketId,
        uint256 assets,
        uint256 shares,
        uint256 remainingReceipts
    );
    event WithdrawExecuted(
        address indexed account,
        bytes32 indexed marketId,
        uint256 shares,
        uint256 assets,
        uint256 remainingReceipts
    );

    function executeSupply(
        address account,
        bytes32 marketId,
        uint256 assets,
        uint256 minShares,
        uint256 deadline
    ) external nonReentrant {
        _yieldCaller(account, deadline);
        if (globalPaused) revert ExecutorPaused();
        if (assets == 0 || minShares == 0) revert ZeroAmount();
        Y.Market memory m = yieldRegistry.beforeSupply(account, marketId, assets);
        uint256 value = assets;
        if (m.asset != numeraire) (, value) = oracle.previewSwap(m.asset, numeraire, assets);
        uint256 minimum = 50 * 10 ** IERC20Metadata(numeraire).decimals();
        if (value < minimum) revert YieldMinimum(value, minimum);
        uint256 quote = yieldRegistry.quoteSupply(marketId, account, assets);
        uint256 floor = Math.mulDiv(quote, BPS_DENOMINATOR - YIELD_QUOTE_TOLERANCE_BPS, BPS_DENOMINATOR);
        if (quote == 0 || minShares < floor) revert YieldMinimum(minShares, floor);
        uint256 beforeUnits = yieldRegistry.units(marketId, account);
        uint256 received = YieldActions.supply(m, account, assets, minShares);
        yieldRegistry.recordSupply(account, marketId, beforeUnits);
        emit SupplyExecuted(account, marketId, assets, received, IERC20(m.receipt).balanceOf(account));
    }

    /// @notice Pure redemption ignores enrollment, retirement, supply cooldown, budgets and swap quotas.
    function executeWithdraw(
        address account,
        bytes32 marketId,
        uint256 shares,
        uint256 minAssets,
        uint256 deadline
    ) external nonReentrant {
        _yieldCaller(account, deadline);
        if (globalPaused) revert ExecutorPaused();
        if (shares == 0 || minAssets == 0) revert ZeroAmount();
        Y.Market memory m = yieldRegistry.market(marketId);
        uint256 quote = yieldRegistry.quoteWithdraw(marketId, shares);
        uint256 floor = Math.mulDiv(quote, BPS_DENOMINATOR - YIELD_QUOTE_TOLERANCE_BPS, BPS_DENOMINATOR);
        if (quote == 0 || minAssets < floor) revert YieldMinimum(minAssets, floor);
        uint256 beforeUnits = yieldRegistry.units(marketId, account);
        uint256 trackedBefore = yieldRegistry.accountUnits(account, marketId);
        uint256 received = YieldActions.withdraw(m, account, shares, minAssets);
        yieldRegistry.recordWithdraw(account, marketId, beforeUnits, trackedBefore);
        emit WithdrawExecuted(account, marketId, shares, received, IERC20(m.receipt).balanceOf(account));
    }

    function _yieldCaller(address account, uint256 deadline) private view {
        if (msg.sender != account) revert NotAccount();
        if (account.code.length == 0) revert NotContract();
        if (block.timestamp > deadline) revert DeadlineExpired();
    }

    /// @notice Use eth_call: accrue and validate every held receipt before returning the canonical NAV.
    /// A failed risk/identity/rate read reverts; no "zero receipt value" fallback exists.
    function previewAccountValue(address account) external nonReentrant returns (uint256) {
        if (!registry.isEnrolled(account)) revert NotEnrolled();
        yieldRegistry.syncAccount(account);
        return _accountValue(account, registry.enrollments(account));
    }

    /// @notice Same fresh snapshot as executeRebalance, including receipt claims, without broadcasting.
    function previewBuyAllowance(address account)
        external
        nonReentrant
        returns (uint256 cap, uint256 bought, uint64 windowEndsAt)
    {
        yieldRegistry.syncAccount(account);
        return this.buyAllowance(account);
    }

    // ---- execution ----

    /// @notice Execute one rebalance batch for `account`.
    /// @dev `msg.sender` must be the account itself: a session key reaches here only through the account's
    /// own `execute()`, which is where its permission is validated. `deadline` bounds the whole batch and is
    /// also forwarded to the router.
    function executeRebalance(address account, SwapStep[] calldata steps, uint256 deadline)
        external
        nonReentrant
    {
        if (globalPaused) revert ExecutorPaused();
        if (msg.sender != account) revert NotAccount();
        if (account.code.length == 0) revert NotContract();
        if (block.timestamp > deadline) revert DeadlineExpired();

        AtpRegistry.Enrollment memory enrollment = registry.enrollments(account);
        if (!registry.isEnrolled(account)) revert NotEnrolled();
        if (enrollment.paused) revert Paused();
        uint16 feeBps = registry.effectiveFeeBps(enrollment.strategyId);
        {
            for (uint256 i; i < steps.length; ++i) {
                if (steps[i].tokenOut != numeraire) {
                    yieldRegistry.syncAccount(account);
                    break;
                }
            }
        }
        BuyState memory buys = _openBuyWindow(account, enrollment, steps);
        bool credited;

        uint256 count = steps.length;
        // Numeraire volume of the batch: a buy's input plus a sale's gross output (every step has exactly one
        // numeraire leg, see NotNumeraireRoute).
        uint256 notional;
        for (uint256 i; i < count; ++i) {
            SwapStep calldata step = steps[i];
            uint256 floor = _checkStep(account, step, enrollment, feeBps);
            bool isBuy = step.tokenOut != numeraire;
            if (isBuy) {
                // A buy: counted against the window, before any token moves - net of sale credits against the
                // current cap, and gross against the window's churn cap.
                if (step.tokenIn != numeraire) revert NotNumeraireRoute(step.tokenIn, step.tokenOut);
                buys.bought += step.amountIn;
                if (buys.bought > buys.cap) revert BuyLimitExceeded(buys.bought, buys.cap);
                buys.gross += step.amountIn;
                if (buys.gross > buys.grossCap) revert BuyLimitExceeded(buys.gross, buys.grossCap);
            }
            uint256 gross = _swap(account, step, deadline);
            // `_checkStep` already required amountOutMin >= floor, so this bound also covers the oracle floor.
            if (gross < step.amountOutMin) revert BelowFloor(gross, step.amountOutMin);
            if (!isBuy && buys.live && buys.bought != 0) {
                // A sale credits its numeraire output back to an open window (never below zero, never past it).
                buys.bought -= Math.min(buys.bought, gross);
                credited = true;
            }
            notional += isBuy ? step.amountIn : gross;
            uint256 fee = _splitFee(step.tokenOut, gross, feeBps, account);
            emit SwapExecuted(
                account, step.tokenIn, step.tokenOut, step.amountIn, gross, fee, gross - fee, floor
            );
        }
        if (buys.hasBuy || credited) {
            buyWindowOf[account] = BuyWindow({ start: buys.start, bought: SafeCast.toUint192(buys.bought) });
        }
        if (buys.hasBuy) {
            buyChurnOf[account] = BuyChurn({
                gross: SafeCast.toUint128(buys.gross), peakCap: SafeCast.toUint128(buys.peakCap)
            });
        }
        _chargeMinFee(account, notional, feeBps);
    }

    // ---- minimum batch fee ----

    /// @notice The minimum-fee top-up a batch of `notional` numeraire volume owes under strategy `strategyId`'s
    /// fee, on top of the proportional fee split off its steps, when it is the first batch of its account's
    /// window (`minFeeDue` gives the account-aware figure). 0 for an empty batch or once the proportional fee
    /// reaches the minimum. The executor pulls at most the account's numeraire balance and allowance.
    function minFeeTopUp(uint256 strategyId, uint256 notional) external view returns (uint256) {
        return _minFeeTopUp(notional, registry.effectiveFeeBps(strategyId));
    }

    /// @dev topUp = max(0, min(minBatchFee, notional x MIN_FEE_MAX_BPS) - notional x feeBps), both rounded
    /// down; so proportional + topUp = max(proportional, minimum). The proportional part is credited at the
    /// notional value, which is what each step's fee (taken in its output token) is worth at execution.
    function _minFeeTopUp(uint256 notional, uint16 feeBps) internal view returns (uint256) {
        uint256 minimum = Math.min(minBatchFee, Math.mulDiv(notional, MIN_FEE_MAX_BPS, BPS_DENOMINATOR));
        uint256 proportional = Math.mulDiv(notional, feeBps, BPS_DENOMINATOR);
        return minimum > proportional ? minimum - proportional : 0;
    }

    /// @notice The minimum-fee top-up `account`'s next batch of `notional` numeraire volume would owe now, under
    /// its enrolled strategy's fee and its open window (see the contract notes). Before the balance and
    /// allowance cap; 0 for `notional == 0`.
    function minFeeDue(address account, uint256 notional) external view returns (uint256) {
        if (notional == 0) return 0;
        MinFeeWindow memory window = _currentMinFeeWindow(account);
        uint16 feeBps = registry.effectiveFeeBps(registry.enrollments(account).strategyId);
        return _minFeeDue(uint256(window.notional) + notional, window.paid, feeBps);
    }

    /// @dev Pulled after every step has cleared its floor, from the account's own numeraire, never from a swap
    /// output. Capped at the balance and allowance the account has, so the fee can be short but can never
    /// make a batch revert (an exit whose proceeds are below the minimum still goes through); what is short
    /// stays owed for the rest of the window.
    function _chargeMinFee(address account, uint256 notional, uint16 feeBps) internal {
        if (notional == 0) return;
        MinFeeWindow memory window = _currentMinFeeWindow(account);
        uint256 cumulative = uint256(window.notional) + notional;
        uint256 due = _minFeeDue(cumulative, window.paid, feeBps);
        IERC20 token = IERC20(numeraire);
        uint256 charged;
        if (due != 0) {
            charged =
                Math.min(due, Math.min(token.balanceOf(account), token.allowance(account, address(this))));
        }
        minFeeWindowOf[account] = MinFeeWindow({
            start: window.start, notional: SafeCast.toUint192(cumulative), paid: window.paid + charged
        });
        if (due == 0) return;
        if (charged > 0) token.safeTransferFrom(account, feeRecipient, charged);
        emit MinFeeCharged(account, notional, due, charged);
    }

    /// @dev The account's window as of now; an expired (or never opened) one starts afresh at this block.
    function _currentMinFeeWindow(address account) internal view returns (MinFeeWindow memory window) {
        window = minFeeWindowOf[account];
        if (window.start == 0 || block.timestamp >= uint256(window.start) + MIN_FEE_WINDOW) {
            window.start = SafeCast.toUint64(block.timestamp);
            window.notional = 0;
            window.paid = 0;
        }
    }

    /// @dev What the window still owes once its cumulative notional is `cumulative`: T(cumulative) - paid.
    function _minFeeDue(uint256 cumulative, uint256 paid, uint16 feeBps) internal view returns (uint256) {
        uint256 owed = _minFeeTopUp(cumulative, feeBps);
        return owed > paid ? owed - paid : 0;
    }

    // ---- buy limit ----

    /// @notice What `account` may still buy: `cap` is the current account value x `maxBuyBps`, `bought` what the
    /// open window has used of it, `windowEndsAt` when it resets (0 = no open window: the next buy opens one).
    /// Remaining = `cap - bought` when positive. All zero for an account that is not enrolled.
    /// @dev `bought` is the larger of the window's buys net of sale credits and `cap - (gross cap - gross buys)`, so
    /// `cap - bought` is what both bounds still allow (cre8-contracts#76). Runs the same valuation as
    /// `executeRebalance`, so the value can move slightly between this read and the transaction; leave a margin.
    function buyAllowance(address account)
        external
        view
        returns (uint256 cap, uint256 bought, uint64 windowEndsAt)
    {
        if (!registry.isEnrolled(account)) return (0, 0, 0);
        cap = _buyCap(account, registry.enrollments(account));
        BuyWindow memory window = buyWindowOf[account];
        if (window.start != 0 && block.timestamp < uint256(window.start) + BUY_WINDOW) {
            BuyChurn memory churn = buyChurnOf[account];
            uint256 grossCap = Math.max(churn.peakCap, cap) * GROSS_BUY_MULTIPLE;
            uint256 grossUsed = uint256(churn.gross) + cap;
            bought = window.bought;
            if (grossUsed > grossCap && grossUsed - grossCap > bought) bought = grossUsed - grossCap;
            windowEndsAt = SafeCast.toUint64(uint256(window.start) + BUY_WINDOW);
        }
    }

    /// @dev Only a batch with a buy pays for the valuation; a sales-only batch (an exit) reads only the window, to
    /// credit an open one. An expired (or never opened) window starts afresh at a buy's block.
    function _openBuyWindow(
        address account,
        AtpRegistry.Enrollment memory enrollment,
        SwapStep[] calldata steps
    ) internal view returns (BuyState memory buys) {
        uint256 count = steps.length;
        for (uint256 i; i < count; ++i) {
            if (steps[i].tokenOut != numeraire) {
                buys.hasBuy = true;
                break;
            }
        }
        BuyWindow memory window = buyWindowOf[account];
        if (window.start != 0 && block.timestamp < uint256(window.start) + BUY_WINDOW) {
            BuyChurn memory churn = buyChurnOf[account];
            buys.live = true;
            buys.start = window.start;
            buys.bought = window.bought;
            buys.gross = churn.gross;
            buys.peakCap = churn.peakCap;
        }
        if (!buys.hasBuy) return buys;
        if (!buys.live) {
            buys.live = true;
            buys.start = SafeCast.toUint64(block.timestamp);
        }
        buys.cap = _buyCap(account, enrollment);
        if (buys.cap > buys.peakCap) buys.peakCap = buys.cap;
        buys.grossCap = buys.peakCap * GROSS_BUY_MULTIPLE;
    }

    function _buyCap(address account, AtpRegistry.Enrollment memory enrollment)
        internal
        view
        returns (uint256)
    {
        uint16 bps = maxBuyBps;
        if (bps == 0) return 0;
        return Math.mulDiv(_accountValue(account, enrollment), bps, BPS_DENOMINATOR);
    }

    /// @dev Account value in numeraire units: its numeraire balance plus, for every other historically effective
    /// version asset it holds, the oracle quote (`quoted`, before slippage) for selling the whole balance. An asset
    /// the oracle cannot price (stale, cleared) counts as zero: that only lowers the cap, i.e. fails closed,
    /// instead of blocking the whole batch. Tokens outside effective version history are not counted. Likewise an asset
    /// whose `balanceOf` reverts, answers with less than one word or needs more than `BALANCE_OF_GAS` counts as zero (cre8-contracts#47): a
    /// provider must not be able to brick every buy of a version with such a token.
    function _accountValue(address account, AtpRegistry.Enrollment memory enrollment)
        internal
        view
        returns (uint256 value)
    {
        value = IERC20(numeraire).balanceOf(account);
        address[] memory assets = registry.historicalAssets(enrollment.strategyId);
        for (uint256 i; i < assets.length; ++i) {
            address asset = assets[i];
            if (asset == numeraire) continue;
            if (yieldRegistry.receiptMarket(asset) != bytes32(0)) {
                continue;
            }
            uint256 balance = _balanceOrZero(asset, account);
            if (balance == 0) continue;
            try oracle.previewSwap(asset, numeraire, balance) returns (uint256 quoted, uint256) {
                value += quoted;
            } catch { }
        }
        {
            bytes32[] memory positions = yieldRegistry.accountMarkets(account);
            for (uint256 i; i < positions.length; ++i) {
                bytes32 id = positions[i];
                Y.Market memory m = yieldRegistry.market(id);
                uint256 held = IERC20(m.receipt).balanceOf(account);
                if (held == 0) continue;
                uint256 underlying = yieldRegistry.receiptAssets(id, account);
                if (underlying == 0) revert NoFloor();
                if (m.asset == numeraire) {
                    value += underlying;
                } else {
                    (uint256 quoted,) = oracle.previewSwap(m.asset, numeraire, underlying);
                    if (quoted == 0) revert NoFloor();
                    value += quoted;
                }
            }
        }
    }

    /// @dev `asset.balanceOf(account)`, or 0 when the call reverts, returns less than one word, or needs more
    /// than `BALANCE_OF_GAS`. Low-level, not `try`: a call that succeeds with short return data would make a
    /// `try`'s decoding revert in this frame, which no `catch` clause catches. The gas cap and copying only the
    /// first return word keep a hostile token from burning the batch's gas (a loop, or a huge return payload).
    function _balanceOrZero(address asset, address account) internal view returns (uint256 amount) {
        bytes memory data = abi.encodeCall(IERC20.balanceOf, (account));
        bool ok;
        assembly {
            ok := staticcall(BALANCE_OF_GAS, asset, add(data, 32), mload(data), 0, 32)
            if lt(returndatasize(), 32) { ok := 0 }
            amount := mload(0)
        }
        if (!ok) amount = 0;
    }

    // ---- step checks ----

    /// @dev Returns the gross-output floor for this step: the oracle floor grossed back up over the fee.
    function _checkStep(
        address account,
        SwapStep calldata step,
        AtpRegistry.Enrollment memory enrollment,
        uint16 feeBps
    ) internal view returns (uint256 minGross) {
        if (step.amountIn == 0) revert ZeroAmount();
        if (
            yieldRegistry.receiptMarket(step.tokenIn) != bytes32(0)
                || yieldRegistry.receiptMarket(step.tokenOut) != bytes32(0)
        ) revert AssetNotAllowed();
        if (step.tokenIn == step.tokenOut) revert SameToken();
        if (step.tokenOut == numeraire
                ? !registry.wasAssetAllowed(enrollment.strategyId, step.tokenIn)
                : (!registry.isAssetAllowed(enrollment.strategyId, 0, step.tokenOut)
                        || !registry.isAssetAllowed(enrollment.strategyId, 0, step.tokenIn))) revert AssetNotAllowed();

        Venue memory venue = venues[step.venue];
        if (venue.kind == VenueKind.NONE) revert VenueNotAllowed(step.venue);
        // Re-check dynamically: a market may have been registered after this venue was configured.
        _requireNotProtocol(step.venue);
        _requireNotProtocol(venue.spender);
        // Never call or approve one of this step's own tokens or the account: the allowance this step grants
        // must only ever be spendable by a swap venue.
        if (
            step.venue == step.tokenIn || step.venue == step.tokenOut || step.venue == account
                || venue.spender == step.tokenIn || venue.spender == step.tokenOut || venue.spender == account
        ) revert BadVenue(step.venue);
        if (venue.kind == VenueKind.PANCAKE_UR) {
            (bytes memory commands, bytes[] memory inputs) = abi.decode(step.data, (bytes, bytes[]));
            _checkCommands(commands, inputs);
        }

        (, uint256 minimum) = oracle.previewSwap(step.tokenIn, step.tokenOut, step.amountIn);
        if (minimum == 0) revert NoFloor();
        minGross = _minGross(minimum, feeBps);

        // amountOutMin is agent-supplied, so it may only tighten the floor: require it to be at least the floor
        // (a lying agent is rejected up front); `executeRebalance` then checks the real gross output against it.
        // The router-level bound inside the venue calldata stays whatever the agent encoded and is not relied on.
        if (step.amountOutMin < minGross) revert BelowFloor(step.amountOutMin, minGross);
    }

    /// @dev Command allowlist (fixed decision): V3_SWAP_EXACT_IN, V2_SWAP_EXACT_IN, SWEEP, TRANSFER only.
    /// Exact bytes, so flag bits such as FLAG_ALLOW_REVERT are rejected as well. Every admitted command must
    /// pay out to this executor, which is what makes the fee split and the residual sweep safe.
    function _checkCommands(bytes memory commands, bytes[] memory inputs) internal view {
        uint256 count = commands.length;
        if (count == 0 || count != inputs.length) revert BadCommands();
        for (uint256 i; i < count; ++i) {
            bytes1 command = commands[i];
            if (command == Cmd.V3_SWAP_EXACT_IN || command == Cmd.V2_SWAP_EXACT_IN) {
                // (recipient, amountIn, amountOutMin, path, payerIsUser)
                _checkRecipient(inputs[i], 0);
            } else if (command == Cmd.SWEEP || command == Cmd.TRANSFER) {
                // (token, recipient, amount...)
                _checkRecipient(inputs[i], 1);
            } else {
                revert CommandNotAllowed(command);
            }
        }
    }

    /// @dev Reads the `recipient` head word of a Universal Router command input and pins it to this
    /// executor. Fails closed on a malformed payload.
    /// @dev ABI encoding right-aligns an `address` in its 32-byte word (the top 12 bytes are zero), so the
    /// address is the LOW 20 bytes of that word. The mask is load-bearing: shifting the word right by 96
    /// bits keeps the address's top 8 bytes instead and rejects every well-formed swap as BadRecipient.
    function _checkRecipient(bytes memory input, uint256 wordIndex) internal view {
        uint256 offset = (wordIndex + 1) * 32;
        if (input.length < offset) revert BadCommands();
        address recipient;
        assembly {
            recipient := and(
                mload(add(add(input, 32), mul(wordIndex, 32))),
                0xffffffffffffffffffffffffffffffffffffffff
            )
        }
        if (recipient != address(this)) revert BadRecipient(recipient);
    }

    // ---- swap / fee ----

    function _swap(address account, SwapStep calldata step, uint256 deadline)
        internal
        returns (uint256 gross)
    {
        IERC20 tokenIn = IERC20(step.tokenIn);
        IERC20 tokenOut = IERC20(step.tokenOut);
        Venue memory venue = venues[step.venue];

        uint256 inBaseline = tokenIn.balanceOf(address(this));
        // TODO(permit2): the account -> executor leg is still a plain ERC20 `safeTransferFrom`, so the
        // account must approve this executor per token. Move that leg to Permit2 (accounts signing a
        // Permit2 transfer) once the account layer supports it; the router leg below is already Permit2.
        tokenIn.safeTransferFrom(account, address(this), step.amountIn);
        uint256 before = tokenOut.balanceOf(address(this));

        if (venue.kind == VenueKind.ERC20_APPROVE) {
            // Exactly this step's amount, to exactly this venue's spender, zeroed straight after the call.
            tokenIn.forceApprove(venue.spender, step.amountIn);
            _callVenue(step.venue, step.data);
            tokenIn.forceApprove(venue.spender, 0);
        } else {
            // Permit2's allowance model is uint160: `permit2.approve` takes a uint160 amount, so the explicit
            // `uint160(step.amountIn)` cast below would silently keep only the low 160 bits of a larger value.
            // The router would then be allowed to pull far less than the executor approved to Permit2 (the
            // ERC20 leg is the full uint256), and the swap would fail inside Permit2 with an opaque allowance
            // error instead of failing here. Every real token supply is orders of magnitude below 2**160
            // units, so this only rejects unrepresentable input: reject it, never truncate it.
            if (step.amountIn > type(uint160).max) revert AmountTooLarge();

            // A Permit2 venue does not `transferFrom` the caller: it asks Permit2 to move the input token, and
            // Permit2 only does so against an allowance granted inside Permit2. Both legs are needed: ERC20
            // approve to Permit2, then Permit2 approve for the venue's spender with the batch deadline.
            tokenIn.forceApprove(address(permit2), step.amountIn);
            permit2.approve(step.tokenIn, venue.spender, uint160(step.amountIn), uint48(deadline));
            if (venue.kind == VenueKind.PANCAKE_UR) {
                (bytes memory commands, bytes[] memory inputs) = abi.decode(step.data, (bytes, bytes[]));
                IUniversalRouter(step.venue).execute(commands, inputs, deadline);
            } else {
                _callVenue(step.venue, step.data);
            }
            // Permit2's own allowance expires at `deadline`, but the ERC20 allowance to Permit2 does not: it
            // is an unbounded-lifetime approval, so it is reset to zero here.
            //
            // Deliberate approve churn: a batch that swaps the same input token twice pays
            // approve -> swap -> approve(0) twice. Batching the approvals and zeroing each token once after the
            // whole batch would be cheaper, but that keeps every input token approved for the entire batch.
            // The cost is deliberately paid to keep the authorization window as short as possible.
            tokenIn.forceApprove(address(permit2), 0);
        }
        gross = tokenOut.balanceOf(address(this)) - before;

        // The venue may consume less than the pulled amount; never strand it here. Underflows (reverts) if the
        // venue somehow left this executor with less `tokenIn` than it held before the step.
        uint256 residual = tokenIn.balanceOf(address(this)) - inBaseline;
        if (residual > 0) tokenIn.safeTransfer(account, residual);
    }

    /// @dev Pass-through call with no value; a venue revert is bubbled up verbatim.
    function _callVenue(address target, bytes calldata data) internal {
        (bool ok, bytes memory ret) = target.call(data);
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
    }

    /// @dev fee = floor(gross * feeBps / 10000); the account gets the rest. Fee is taken from the output
    /// side only - the pool fee was already deducted by the swap itself.
    function _splitFee(address tokenOut, uint256 gross, uint16 feeBps, address account)
        internal
        returns (uint256 fee)
    {
        fee = Math.mulDiv(gross, feeBps, BPS_DENOMINATOR);
        if (fee > 0) IERC20(tokenOut).safeTransfer(feeRecipient, fee);
        IERC20(tokenOut).safeTransfer(account, gross - fee);
    }

    /// @dev minGross = ceil(oracleFloor / (1 - feeBps/10000)), so the account still clears the floor after
    /// the fee is taken. See docs/atp-pivot-executor-spec.zh-TW.md §5.
    function _minGross(uint256 oracleFloor, uint16 feeBps) internal pure returns (uint256) {
        if (feeBps >= BPS_DENOMINATOR) revert FeeTooHigh(feeBps);
        return Math.mulDiv(oracleFloor, BPS_DENOMINATOR, BPS_DENOMINATOR - feeBps, Math.Rounding.Ceil);
    }
}
