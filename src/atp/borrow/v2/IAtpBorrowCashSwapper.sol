// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Add-on of Strategy Earn routing v2 (docs/borrow-routing-v2.zh-TW.md §17): the only way a portfolio
/// account turns USDT into a loan token it owes (USDC / USD1 / U) and back. The caller is the account itself
/// (`msg.sender`; a session key gets here through the account's own `execute()`); no function takes an account
/// or a receiver. Amounts are raw token units; `type(uint256).max` means "all" for `cashOut` only (`topUp`
/// takes an explicit amount: the backend buys what `shortfall` reports, not the most it may).
interface IAtpBorrowCashSwapper {
    event PoolSet(address indexed token, address pool);
    event LimitsSet(uint16 maxPegBps, uint16 bufferBps);
    /// @param need The account's debt in `token` less the loan token idle in its box, before the swap
    /// (vault deposits are not counted).
    event ToppedUp(
        address indexed account, address indexed token, uint256 usdtIn, uint256 tokenOut, uint256 need
    );
    event CashedOut(address indexed account, address indexed token, uint256 tokenIn, uint256 usdtOut);

    error Unauthorized();
    error BadParameter();
    error BadPool();
    error DeadlineExpired();
    error ZeroAmount();
    error PoolNotSet(address token);
    /// @dev The account has no strategy box yet (it never deposited through routing v2).
    error NoBox();
    /// @dev The loan token idle in the box already covers the debt: `idle` >= `debt`.
    error NoShortfall(uint256 debt, uint256 idle);
    /// @dev One top-up buys at most `cap` = (debt - idle in the box) x (1 + bufferBps).
    error AboveShortfall(uint256 amount, uint256 cap);
    /// @dev This top-up would take the window's purchases to `bought`, above `cap` (the highest debt a
    /// top-up of the window saw x (1 + bufferBps)). The window resets `TOP_UP_WINDOW` after it opened.
    error WindowExceeded(uint256 bought, uint256 cap);
    /// @dev The pool did not deliver exactly the output asked for (a partial fill, or more than asked).
    error InexactOutput(uint256 received, uint256 wanted);
    /// @dev The pool took more of the caller's token than the caller offered to sell.
    error Overcharged(uint256 paid, uint256 offered);
    /// @dev The caller's own bound: paid more than `maxUsdtIn`, or got less than `minUsdtOut`.
    error Slippage(uint256 amount, uint256 bound);
    /// @dev Paid more than received x (1 + maxPegBps); both as 18-decimal amounts at 1:1.
    error PegExceeded(uint256 paid, uint256 received);
    /// @dev `token` is an asset the account's strategy trades: it is a holding, not leftover loan token.
    error StrategyAsset(address token);
    error BadCallback();

    /// @notice Hard ceilings of the two owner-set limits, in bps.
    function MAX_PEG_BPS() external view returns (uint16);
    function MAX_BUFFER_BPS() external view returns (uint16);
    /// @notice Length of the fixed top-up window (24 hours): it opens with an account's first top-up of a
    /// token and resets with the first top-up at or after `start + TOP_UP_WINDOW`.
    function TOP_UP_WINDOW() external view returns (uint256);

    /// @notice The routing v2 executor this contract is bound to, and what it reads from it.
    function executor() external view returns (address);
    function borrowRegistry() external view returns (address);
    function lens() external view returns (address);
    /// @notice The core `AtpRegistry`: its `owner()` owns this contract, its `numeraire()` is `usdt`.
    function registry() external view returns (address);
    function usdt() external view returns (address);

    /// @notice A swap may pay at most received x (1 + maxPegBps / 10000), counting both tokens at 1:1.
    function maxPegBps() external view returns (uint16);
    /// @notice A top-up may exceed the debt it covers by this share of it (interest of the next blocks,
    /// rounding); the window's allowance carries the same share.
    function bufferBps() external view returns (uint16);
    /// @notice The top-up window of `account` in `token`: when it opened (0 = never; stale once
    /// `start + TOP_UP_WINDOW` has passed), the loan token bought since, and the highest debt in the token a
    /// top-up found since. Use `topUpCap` / `shortfall` for what may be bought now.
    function topUpWindowOf(address account, address token)
        external
        view
        returns (uint64 start, uint192 bought, uint256 peakDebt);
    /// @notice The one allowlisted USDT pool of a loan token (zero = swaps of that token are off).
    function poolOf(address token) external view returns (address);

    // ---- owner (AtpRegistry.owner()) ----

    /// @notice Allowlist the PancakeSwap V3 pool of USDT and `token` (a loan token of the routing registry
    /// other than USDT, with 6 to 18 decimals). `pool` = zero switches both actions off for the token.
    function setPool(address token, address pool) external;
    /// @notice `maxPegBps` <= MAX_PEG_BPS (default 25), `bufferBps` <= MAX_BUFFER_BPS (default 100).
    function setLimits(uint16 maxPegBps, uint16 bufferBps) external;

    // ---- the account ----

    /// @notice Use eth_call (it accrues): the most a `topUp` of `token` may buy for `account` now, the
    /// smaller of (debt - idle in the box) x (1 + bufferBps) and what the window has left (0 = nothing to
    /// cover, or the window is used up). It reads no vault, so it answers whatever state the vaults are in.
    function topUpCap(address account, address token) external returns (uint256 cap);

    /// @notice Use eth_call (it accrues). `gap`: what the backend normally buys before a repayment, the
    /// debt in `token` less the loan token idle in the account's box less the box's deposits in every vault
    /// of that token (0 = covered). It is information only, nothing on chain uses it: a vault that reads
    /// full but cannot pay still counts, so a repayment can need more than `gap` (up to `cap`); and the call
    /// reverts when a vault of the token cannot be read (use `topUpCap` then). `cap`: as `topUpCap`.
    /// `gap` > `cap` means the window is used up until it resets.
    function shortfall(address account, address token) external returns (uint256 gap, uint256 cap);

    /// @notice Buy exactly `amountOut` of `token` with the caller's USDT and put it into the caller's strategy
    /// box, where the next `executeReduce` / `executeDeleverage` uses it first. Two limits, neither reads a
    /// vault: `amountOut` <= (debt - idle in the box) x (1 + bufferBps) (`AboveShortfall`; `NoShortfall`
    /// when the idle loan token already covers the debt), and the window's purchases including this one <=
    /// the highest debt a top-up of the window saw x (1 + bufferBps) (`WindowExceeded`). Never paused.
    function topUp(address token, uint256 amountOut, uint256 maxUsdtIn, uint256 deadline)
        external
        returns (uint256 usdtIn, uint256 tokenOut);

    /// @notice Sell `amountIn` (`max` = all) of the caller's own `token` for USDT, paid to the caller.
    /// Refused for a token the caller's strategy trades. Never paused, not limited by the window.
    function cashOut(address token, uint256 amountIn, uint256 minUsdtOut, uint256 deadline)
        external
        returns (uint256 tokenIn, uint256 usdtOut);
}
