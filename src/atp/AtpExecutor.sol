// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { UniversalRouterCommands as Cmd } from "./interfaces/IUniversalRouter.sol";
import { IUniversalRouter } from "./interfaces/IUniversalRouter.sol";
import { IOracleFloor } from "./interfaces/IOracleFloor.sol";
import { IPermit2 } from "./interfaces/IPermit2.sol";
import { AtpRegistry } from "./AtpRegistry.sol";

/// @title AtpExecutor
/// @notice The only contract that moves user funds for an ATP rebalance. One call per user operation:
/// the smart account approves this executor, the executor pulls `tokenIn`, swaps through the pinned
/// Universal Router, splits the fee off the output, and returns the net output to the account.
/// @dev Trust model (docs/atp-pivot-executor-spec.zh-TW.md §1-§2): the session key only ever triggers
/// "account -> executeRebalance", enforced in the Kernel layer, so this contract does not inspect session
/// keys. It trusts `msg.sender == account` and enforces the domain rules itself: enrolled/unpaused
/// strategy, version asset allowlist, command allowlist with the recipient pinned back here, deadline, and
/// the oracle floor. The agent chooses routes and fills `amountOutMin`, but the oracle-derived `minGross`
/// is the authority: the realised gross output must clear it, so `amountOutMin = 0` cannot weaken the floor.
/// @dev Buy limit (A10-1, cre8-contracts#10): a leaked session key could grind an account down by trading
/// back and forth, each step clearing the floor. Every round trip needs a buy, so buys (numeraire -> asset)
/// are capped per account at `maxBuyBps` of the account's current value per fixed 24-hour window. Sales to the
/// numeraire are never limited nor counted, so exits always go through.
contract AtpExecutor is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant BPS_DENOMINATOR = 10_000;
    /// @dev Canonical Uniswap Permit2, the same address on every chain it is deployed to, BSC mainnet (56)
    /// and testnet (97) included. Read only by the constructor; see the pin there for why it exists.
    address internal constant CANONICAL_PERMIT2 = 0x31c2F6fcFf4F8759b3Bd5Bf0e1084A055615c768;
    /// @notice Length of the fixed buy-limit window. It opens with an account's first buy and resets with the
    /// first buy at or after `start + BUY_WINDOW`.
    uint256 public constant BUY_WINDOW = 1 days;
    /// @notice Upper bound for `maxBuyBps` (2x the account value per window).
    uint16 public constant MAX_BUY_BPS_CEILING = 20_000;

    /// @notice Strategy/enrollment/fee record. Also the admin for `feeRecipient`.
    AtpRegistry public immutable registry;
    /// @notice PancakeSwap Universal Router, pinned per chain.
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

    /// @dev One slot per account. `bought` is the numeraire spent on buys since `start`.
    struct BuyWindow {
        uint64 start;
        uint192 bought;
    }

    /// @notice Buy-limit window per account; `start == 0` means never opened, and a window is stale (treated as
    /// empty) once `start + BUY_WINDOW` has passed.
    mapping(address => BuyWindow) public buyWindowOf;

    struct SwapStep {
        /// @notice Token sold, pulled from the account.
        address tokenIn;
        /// @notice Token bought, must land back on this executor.
        address tokenOut;
        /// @notice Exact input amount, in `tokenIn` units.
        uint256 amountIn;
        /// @notice The agent's own bound. Advisory only: the executor additionally requires it to be at
        /// least `minGross` and independently checks the realised output against `minGross`.
        uint256 amountOutMin;
        /// @notice Universal Router command bytes, allowlisted per step.
        bytes commands;
        /// @notice Universal Router input payloads, one per command.
        bytes[] inputs;
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
    error BelowFloor(uint256 realised, uint256 floor);
    /// @dev This batch would take the window's buys to `bought`, above `cap` (value x `maxBuyBps`).
    error BuyLimitExceeded(uint256 bought, uint256 cap);
    error BuyBpsTooHigh(uint16 bps);
    /// @dev Neither leg is the numeraire, so the step is neither a sale nor a countable buy. The oracle router
    /// rejects such a pair as well; this keeps the buy limit fail-closed on its own.
    error NotNumeraireRoute(address tokenIn, address tokenOut);

    constructor(
        AtpRegistry registry_,
        IUniversalRouter universalRouter_,
        IOracleFloor oracle_,
        address permit2_,
        address feeRecipient_,
        address numeraire_,
        uint16 maxBuyBps_
    ) {
        if (
            address(registry_).code.length == 0 || address(universalRouter_).code.length == 0
                || address(oracle_).code.length == 0 || permit2_.code.length == 0
                || feeRecipient_ == address(0) || numeraire_.code.length == 0
        ) revert InvalidConfig();
        if (maxBuyBps_ > MAX_BUY_BPS_CEILING) revert BuyBpsTooHigh(maxBuyBps_);

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

        registry = registry_;
        universalRouter = universalRouter_;
        oracle = oracle_;
        permit2 = IPermit2(permit2_);
        feeRecipient = feeRecipient_;
        numeraire = numeraire_;
        maxBuyBps = maxBuyBps_;
        emit MaxBuyBpsSet(maxBuyBps_);
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
        (bool hasBuy, uint256 cap, BuyWindow memory window) = _openBuyWindow(account, enrollment, steps);

        uint256 count = steps.length;
        for (uint256 i; i < count; ++i) {
            SwapStep calldata step = steps[i];
            uint256 floor = _checkStep(step, enrollment, feeBps);
            if (step.tokenOut != numeraire) {
                // A buy: counted against the window, before any token moves.
                if (step.tokenIn != numeraire) revert NotNumeraireRoute(step.tokenIn, step.tokenOut);
                uint256 bought = window.bought + step.amountIn;
                if (bought > cap) revert BuyLimitExceeded(bought, cap);
                window.bought = SafeCast.toUint192(bought);
            }
            uint256 gross = _swap(account, step, deadline);
            if (gross < floor) revert BelowFloor(gross, floor);
            uint256 fee = _splitFee(step.tokenOut, gross, feeBps, account);
            emit SwapExecuted(
                account, step.tokenIn, step.tokenOut, step.amountIn, gross, fee, gross - fee, floor
            );
        }
        if (hasBuy) buyWindowOf[account] = window;
    }

    // ---- buy limit ----

    /// @notice What `account` may still buy: `cap` is the current account value x `maxBuyBps`, `bought` what the
    /// open window already spent, `windowEndsAt` when it resets (0 = no open window: the next buy opens one).
    /// Remaining = `cap - bought` when positive. All zero for an account that is not enrolled.
    /// @dev Runs the same valuation as `executeRebalance`, so the value can move slightly between this read
    /// and the transaction; leave a margin.
    function buyAllowance(address account)
        external
        view
        returns (uint256 cap, uint256 bought, uint64 windowEndsAt)
    {
        if (!registry.isEnrolled(account)) return (0, 0, 0);
        BuyWindow memory window = buyWindowOf[account];
        if (window.start != 0 && block.timestamp < uint256(window.start) + BUY_WINDOW) {
            bought = window.bought;
            windowEndsAt = SafeCast.toUint64(uint256(window.start) + BUY_WINDOW);
        }
        cap = _buyCap(account, registry.enrollments(account));
    }

    /// @dev Only a batch with a buy pays for the valuation; a sales-only batch (an exit) reads nothing extra.
    /// An expired (or never opened) window starts afresh at this block.
    function _openBuyWindow(
        address account,
        AtpRegistry.Enrollment memory enrollment,
        SwapStep[] calldata steps
    ) internal view returns (bool hasBuy, uint256 cap, BuyWindow memory window) {
        uint256 count = steps.length;
        for (uint256 i; i < count; ++i) {
            if (steps[i].tokenOut != numeraire) {
                hasBuy = true;
                break;
            }
        }
        if (!hasBuy) return (false, 0, window);

        window = buyWindowOf[account];
        if (window.start == 0 || block.timestamp >= uint256(window.start) + BUY_WINDOW) {
            window.start = SafeCast.toUint64(block.timestamp);
            window.bought = 0;
        }
        cap = _buyCap(account, enrollment);
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

    /// @dev Account value in numeraire units: its numeraire balance plus, for every other asset of its pinned
    /// version it holds, the oracle quote (`quoted`, before slippage) for selling the whole balance. An asset
    /// the oracle cannot price (stale, cleared) counts as zero: that only lowers the cap, i.e. fails closed,
    /// instead of blocking the whole batch. Tokens outside the pinned version are not counted.
    function _accountValue(address account, AtpRegistry.Enrollment memory enrollment)
        internal
        view
        returns (uint256 value)
    {
        value = IERC20(numeraire).balanceOf(account);
        address[] memory assets = registry.version(enrollment.strategyId, enrollment.version).assets;
        for (uint256 i; i < assets.length; ++i) {
            address asset = assets[i];
            if (asset == numeraire) continue;
            uint256 balance = IERC20(asset).balanceOf(account);
            if (balance == 0) continue;
            try oracle.previewSwap(asset, numeraire, balance) returns (uint256 quoted, uint256) {
                value += quoted;
            } catch { }
        }
    }

    // ---- step checks ----

    /// @dev Returns the gross-output floor for this step: the oracle floor grossed back up over the fee.
    function _checkStep(SwapStep calldata step, AtpRegistry.Enrollment memory enrollment, uint16 feeBps)
        internal
        view
        returns (uint256 minGross)
    {
        if (step.amountIn == 0) revert ZeroAmount();
        if (step.tokenIn == step.tokenOut) revert SameToken();
        if (
            !registry.isAssetAllowed(enrollment.strategyId, enrollment.version, step.tokenIn)
                || !registry.isAssetAllowed(enrollment.strategyId, enrollment.version, step.tokenOut)
        ) revert AssetNotAllowed();

        _checkCommands(step.commands, step.inputs);

        (, uint256 minimum) = oracle.previewSwap(step.tokenIn, step.tokenOut, step.amountIn);
        if (minimum == 0) revert NoFloor();
        minGross = _minGross(minimum, feeBps);

        // amountOutMin is agent-supplied, so it is never the authority: require it to be at least the floor
        // (a lying agent is rejected up front) and then check the real gross output in `executeRebalance`.
        // TODO: also overwrite the router's own amountOutMin inside `inputs` with `minGross`; today the
        // router-level value stays whatever the agent encoded, and the post-swap check is what binds.
        if (step.amountOutMin < minGross) revert BelowFloor(step.amountOutMin, minGross);
    }

    /// @dev Command allowlist (fixed decision): V3_SWAP_EXACT_IN, V2_SWAP_EXACT_IN, SWEEP, TRANSFER only.
    /// Exact bytes, so flag bits such as FLAG_ALLOW_REVERT are rejected as well. Every admitted command must
    /// pay out to this executor, which is what makes the fee split and the residual sweep safe.
    function _checkCommands(bytes calldata commands, bytes[] calldata inputs) internal view {
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
    function _checkRecipient(bytes calldata input, uint256 wordIndex) internal view {
        uint256 offset = (wordIndex + 1) * 32;
        if (input.length < offset) revert BadCommands();
        address recipient;
        assembly {
            recipient := and(
                calldataload(add(input.offset, mul(wordIndex, 32))),
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

        uint256 inBaseline = tokenIn.balanceOf(address(this));
        // TODO(permit2): the account -> executor leg is still a plain ERC20 `safeTransferFrom`, so the
        // account must approve this executor per token. Move that leg to Permit2 (accounts signing a
        // Permit2 transfer) once the account layer supports it; the router leg below is already Permit2.
        tokenIn.safeTransferFrom(account, address(this), step.amountIn);

        // Permit2's allowance model is uint160: `permit2.approve` takes a uint160 amount, so the explicit
        // `uint160(step.amountIn)` cast below would silently keep only the low 160 bits of a larger value.
        // The router would then be allowed to pull far less than the executor approved to Permit2 (the
        // ERC20 leg is the full uint256), and the swap would fail inside Permit2 with an opaque allowance
        // error instead of failing here. Every real token supply is orders of magnitude below 2**160 units,
        // so this only rejects unrepresentable input: reject it, never truncate it.
        if (step.amountIn > type(uint160).max) revert AmountTooLarge();

        // The Universal Router does not `transferFrom` the caller: its V3 path asks Permit2 to move the
        // input token, and Permit2 only does so against an allowance granted inside Permit2. Both legs are
        // needed: ERC20 approve to Permit2, then Permit2 approve for the router with the batch deadline.
        tokenIn.forceApprove(address(permit2), step.amountIn);
        permit2.approve(step.tokenIn, address(universalRouter), uint160(step.amountIn), uint48(deadline));

        uint256 before = tokenOut.balanceOf(address(this));
        universalRouter.execute(step.commands, step.inputs, deadline);
        gross = tokenOut.balanceOf(address(this)) - before;
        // Permit2's own allowance expires at `deadline`, but the ERC20 allowance to Permit2 does not: it is
        // an unbounded-lifetime approval, so it is reset to zero here.
        //
        // Deliberate approve churn: a batch that swaps the same input token twice pays
        // approve -> swap -> approve(0) twice, i.e. two extra ERC20 approvals and the gas of two extra
        // non-zero allowance writes. Batching the approvals and zeroing each token once after the whole
        // batch would be cheaper, but that keeps every input token approved to Permit2 for the entire
        // batch. The cost is deliberately paid to keep the authorization window as short as possible:
        // security first, gas second. The call sequence is intentionally unchanged.
        tokenIn.forceApprove(address(permit2), 0);

        // Router may consume less than the pulled amount; never strand it here.
        uint256 residual = tokenIn.balanceOf(address(this)) - inBaseline;
        if (residual > 0) tokenIn.safeTransfer(account, residual);
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
