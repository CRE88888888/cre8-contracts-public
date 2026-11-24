// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { AtpRegistry } from "../../AtpRegistry.sol";
import { RoutingTypes as R } from "./RoutingTypes.sol";
import { IAtpBorrowExecutorV2 } from "./IAtpBorrowExecutorV2.sol";
import { IAtpBorrowLensV2 } from "./IAtpBorrowLensV2.sol";
import { AtpBorrowRegistryV2 } from "./AtpBorrowRegistryV2.sol";
import { IAtpBorrowCashSwapper } from "./IAtpBorrowCashSwapper.sol";

interface ISwapPool {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amount,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1);
}

/// @title AtpBorrowCashSwapper
/// @notice Routing v2 borrows USDT / USDC / USD1 / U, and the core only trades strategy assets against USDT.
/// A position in USDC / USD1 / U whose vault grew slower than its debt (negative base carry, a deleverage)
/// therefore cannot be closed: nothing turns the account's USDT into the token it owes. This contract does
/// that one swap, and the reverse for the loan token a closed position leaves in the account.
/// It is a separate add-on: the routing executor, extension, registry and lens are not changed and do not
/// know it. `topUp` only puts loan token into the account's strategy box, which the executor already uses
/// first for every repayment (the account's own and a third-party deleverage).
/// @dev Where the money can go: USDT from the caller -> pool, loan token pool -> the caller's box (`topUp`);
/// loan token from the caller -> pool, USDT pool -> the caller (`cashOut`). No account or receiver argument.
/// This contract never holds a token: the pool pays the destination itself and the callback moves the input
/// from the caller straight to the pool. No oracle: a swap must clear a fixed peg bound (pay at most what it
/// received x (1 + maxPegBps), both tokens at 1:1), measured on real balances, or it reverts. A top-up is
/// capped at what the box is short of the debt, plus a small buffer. Neither action adds risk, so neither
/// follows a pause (like every exit of routing v2); the owner switches a token off with `setPool(token, 0)`.
contract AtpBorrowCashSwapper is IAtpBorrowCashSwapper, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint16 public constant MAX_PEG_BPS = 100;
    uint16 public constant MAX_BUFFER_BPS = 500;
    uint256 private constant MAX = type(uint256).max;
    /// @dev The pool's own price limits (+/- 1): the peg bound below is the price check, not these.
    uint160 private constant MIN_SQRT_LIMIT = 4_295_128_740;
    uint160 private constant MAX_SQRT_LIMIT =
        1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_341;
    /// @dev Raw units a pool rounds against the trader (two on the input, one on the output).
    uint256 private constant ROUNDING = 3;

    address public immutable executor;
    address public immutable borrowRegistry;
    address public immutable lens;
    address public immutable registry;
    address public immutable usdt;
    /// @dev 10 ** (18 - decimals) of USDT.
    uint256 private immutable _usdtScale;

    struct Pool {
        address pool;
        bool usdtIsToken0;
        /// @dev 10 ** (18 - decimals) of the loan token.
        uint88 scale;
    }

    mapping(address => Pool) private _pools;
    uint16 public maxPegBps = 50;
    uint16 public bufferBps = 100;
    /// @dev keccak256(pool, payer, input token) of the one swap in flight; the callback pays for nothing else.
    bytes32 private _inFlight;

    constructor(address executor_) {
        if (executor_.code.length == 0) revert BadParameter();
        executor = executor_;
        borrowRegistry = IAtpBorrowExecutorV2(executor_).borrowRegistry();
        lens = IAtpBorrowExecutorV2(executor_).lens();
        if (AtpBorrowRegistryV2(borrowRegistry).executor() != executor_) revert BadParameter();
        registry = address(AtpBorrowRegistryV2(borrowRegistry).registry());
        usdt = AtpRegistry(registry).numeraire();
        if (usdt == address(0)) revert BadParameter();
        _usdtScale = _scale(usdt);
    }

    modifier onlyOwner() {
        if (msg.sender != AtpRegistry(registry).owner()) revert Unauthorized();
        _;
    }

    // ---- owner ----

    function setPool(address token, address pool) external onlyOwner {
        if (pool == address(0)) {
            delete _pools[token];
        } else {
            if (token == usdt || !AtpBorrowRegistryV2(borrowRegistry).loanTokenAllowed(token)) {
                revert BadParameter();
            }
            if (pool.code.length == 0) revert BadPool();
            (address token0, address token1) = (ISwapPool(pool).token0(), ISwapPool(pool).token1());
            bool usdtIsToken0 = token0 == usdt;
            if (!(usdtIsToken0 && token1 == token) && !(token0 == token && token1 == usdt)) revert BadPool();
            _pools[token] = Pool(pool, usdtIsToken0, uint88(_scale(token)));
        }
        emit PoolSet(token, pool);
    }

    function setLimits(uint16 maxPegBps_, uint16 bufferBps_) external onlyOwner {
        if (maxPegBps_ > MAX_PEG_BPS || bufferBps_ > MAX_BUFFER_BPS) revert BadParameter();
        (maxPegBps, bufferBps) = (maxPegBps_, bufferBps_);
        emit LimitsSet(maxPegBps_, bufferBps_);
    }

    function poolOf(address token) external view returns (address) {
        return _pools[token].pool;
    }

    // ---- the account ----

    function shortfall(address account, address token) external returns (uint256 gap, uint256 cap) {
        (uint256 owed, uint256 held) = _position(account, token);
        if (owed > held) (gap, cap) = (owed - held, _cap(owed - held));
    }

    function topUp(address token, uint256 amountOut, uint256 maxUsdtIn, uint256 deadline)
        external
        nonReentrant
        returns (uint256 usdtIn, uint256 tokenOut)
    {
        Pool memory p = _pool(token, deadline);
        address box = IAtpBorrowExecutorV2(executor).boxOf(msg.sender);
        if (box.code.length == 0) revert NoBox();
        (uint256 owed, uint256 held) = _position(msg.sender, token);
        if (owed <= held) revert NoShortfall(owed, held);
        uint256 cap = _cap(owed - held);
        if (amountOut == MAX) amountOut = cap;
        if (amountOut == 0) revert ZeroAmount();
        if (amountOut > cap) revert AboveShortfall(amountOut, cap);
        (usdtIn, tokenOut) = _swap(p, usdt, _usdtScale, token, p.scale, box, -int256(amountOut));
        if (tokenOut != amountOut) revert InexactOutput(tokenOut, amountOut);
        if (usdtIn > maxUsdtIn) revert Slippage(usdtIn, maxUsdtIn);
        emit ToppedUp(msg.sender, token, usdtIn, tokenOut, owed - held);
    }

    function cashOut(address token, uint256 amountIn, uint256 minUsdtOut, uint256 deadline)
        external
        nonReentrant
        returns (uint256 tokenIn, uint256 usdtOut)
    {
        Pool memory p = _pool(token, deadline);
        AtpRegistry core = AtpRegistry(registry);
        if (core.wasAssetAllowed(core.enrollments(msg.sender).strategyId, token)) {
            revert StrategyAsset(token);
        }
        if (amountIn == MAX) amountIn = IERC20(token).balanceOf(msg.sender);
        if (amountIn == 0) revert ZeroAmount();
        (tokenIn, usdtOut) = _swap(p, token, p.scale, usdt, _usdtScale, msg.sender, int256(amountIn));
        if (tokenIn > amountIn) revert Overcharged(tokenIn, amountIn);
        if (usdtOut < minUsdtOut) revert Slippage(usdtOut, minUsdtOut);
        emit CashedOut(msg.sender, token, tokenIn, usdtOut);
    }

    /// @notice PancakeSwap V3 swap callback: pays the pool of the swap in flight from the caller of that
    /// swap, in its input token, and nothing else.
    function pancakeV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external {
        (address payer, address tokenIn) = abi.decode(data, (address, address));
        if (keccak256(abi.encode(msg.sender, payer, tokenIn)) != _inFlight) revert BadCallback();
        int256 owed = amount0Delta > 0 ? amount0Delta : amount1Delta;
        if (owed <= 0) revert BadCallback();
        IERC20(tokenIn).safeTransferFrom(payer, msg.sender, uint256(owed));
    }

    // ---- internals ----

    /// @dev After accrual: the account's debt in `token`, and what its box holds against it (idle loan token
    /// plus its deposits in every vault of that token).
    function _position(address account, address token) private returns (uint256 owed, uint256 held) {
        IAtpBorrowLensV2 l = IAtpBorrowLensV2(lens);
        l.syncToken(account, token);
        owed = l.tokenDebt(account, token);
        held = l.idleOf(account, token);
        bytes32[] memory ids = AtpBorrowRegistryV2(borrowRegistry).accountVaults(account);
        for (uint256 i; i < ids.length; ++i) {
            if (AtpBorrowRegistryV2(borrowRegistry).vault(ids[i]).token != token) continue;
            // A vault that cannot even be read counts as empty: its money cannot repay anything now, and
            // the cap can only grow up to the debt itself.
            try l.vaultStatus(ids[i], account) returns (R.VaultStatus memory s) {
                held += s.assets;
            } catch { }
        }
    }

    function _cap(uint256 gap) private view returns (uint256) {
        return gap + Math.mulDiv(gap, bufferBps, 10_000, Math.Rounding.Ceil);
    }

    function _pool(address token, uint256 deadline) private view returns (Pool memory p) {
        if (block.timestamp > deadline) revert DeadlineExpired();
        p = _pools[token];
        if (p.pool == address(0)) revert PoolNotSet(token);
    }

    /// @dev One swap on the token's pool, paid by the caller, delivered by the pool to `to`. `amount` > 0:
    /// exact input; < 0: exact output. What was paid and received is measured on the caller's and on `to`'s
    /// balances, and must clear the peg bound whatever the pool reported.
    function _swap(
        Pool memory p,
        address tokenIn,
        uint256 scaleIn,
        address tokenOut,
        uint256 scaleOut,
        address to,
        int256 amount
    ) private returns (uint256 paid, uint256 received) {
        bool zeroForOne = (tokenIn == usdt) == p.usdtIsToken0;
        uint256 inBefore = IERC20(tokenIn).balanceOf(msg.sender);
        uint256 outBefore = IERC20(tokenOut).balanceOf(to);
        _inFlight = keccak256(abi.encode(p.pool, msg.sender, tokenIn));
        ISwapPool(p.pool)
            .swap(
                to,
                zeroForOne,
                amount,
                zeroForOne ? MIN_SQRT_LIMIT : MAX_SQRT_LIMIT,
                abi.encode(msg.sender, tokenIn)
            );
        delete _inFlight;
        paid = inBefore - IERC20(tokenIn).balanceOf(msg.sender);
        received = IERC20(tokenOut).balanceOf(to) - outBefore;
        (uint256 paid18, uint256 received18) = (paid * scaleIn, received * scaleOut);
        if (paid18 > received18 + received18 * maxPegBps / 10_000 + ROUNDING * Math.max(scaleIn, scaleOut)) {
            revert PegExceeded(paid18, received18);
        }
    }

    function _scale(address token) private view returns (uint256) {
        uint8 decimals = IERC20Metadata(token).decimals();
        if (decimals > 18) revert BadParameter();
        return 10 ** (18 - decimals);
    }
}
