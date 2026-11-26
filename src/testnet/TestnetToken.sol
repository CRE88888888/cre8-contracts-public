// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title TestnetToken
/// @notice TESTNET ONLY (BSC testnet, chain 97; cre8-contracts#30). A freely minted stand-in for one of the 38
/// launch assets: same symbol and decimals as the mainnet token, no value, no relation to its issuer. Pools,
/// oracles and the executor treat it exactly like the real token.
/// @dev `owner` (the testnet deployer) appoints minters. Minters mint without limit: the testnet keeper uses it
/// to seed liquidity and move pool prices, which is the point of a mock market. Nothing here is ever deployed on
/// mainnet: `script/DeployTestnet.s.sol` only runs on chain 97.
contract TestnetToken is ERC20 {
    uint8 private immutable _decimals;

    address public owner;
    mapping(address => bool) public isMinter;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event MinterSet(address indexed minter, bool allowed);

    error NotOwner();
    error NotMinter();
    error ZeroAddress();

    constructor(string memory name_, string memory symbol_, uint8 decimals_, address owner_)
        ERC20(name_, symbol_)
    {
        if (owner_ == address(0)) revert ZeroAddress();
        _decimals = decimals_;
        owner = owner_;
        isMinter[owner_] = true;
        emit OwnershipTransferred(address(0), owner_);
        emit MinterSet(owner_, true);
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function transferOwnership(address next) external onlyOwner {
        if (next == address(0)) revert ZeroAddress();
        emit OwnershipTransferred(owner, next);
        owner = next;
    }

    function setMinter(address minter, bool allowed) external onlyOwner {
        if (minter == address(0)) revert ZeroAddress();
        isMinter[minter] = allowed;
        emit MinterSet(minter, allowed);
    }

    function mint(address to, uint256 amount) external {
        if (!isMinter[msg.sender]) revert NotMinter();
        _mint(to, amount);
    }
}

/// @title TestnetBStock
/// @notice A `TestnetToken` that also mimics the bStock (BEP-677 / ERC-8056) display multiplier: the raw balance
/// is what pools, oracles and the executor use; `uiMultiplier` only converts it to the share count a UI shows.
/// Prices are always raw prices, so the multiplier must never be applied to a pool or oracle price again.
/// @dev Same read ABI as the mainnet bStocks (`uiMultiplier`, `toUIAmount`, `fromUIAmount`, `balanceOfUI`,
/// 1e18 = 1x, rounding down), so the app's display code can run unchanged against the mock.
contract TestnetBStock is TestnetToken {
    uint256 public uiMultiplier;

    event UiMultiplierSet(uint256 multiplier);

    error InvalidMultiplier();

    constructor(
        string memory name_,
        string memory symbol_,
        uint8 decimals_,
        address owner_,
        uint256 uiMultiplier_
    ) TestnetToken(name_, symbol_, decimals_, owner_) {
        if (uiMultiplier_ == 0) revert InvalidMultiplier();
        uiMultiplier = uiMultiplier_;
        emit UiMultiplierSet(uiMultiplier_);
    }

    /// @notice Simulates a corporate action (split, dividend reinvestment) for the display layer.
    function setUiMultiplier(uint256 multiplier) external onlyOwner {
        if (multiplier == 0) revert InvalidMultiplier();
        uiMultiplier = multiplier;
        emit UiMultiplierSet(multiplier);
    }

    function toUIAmount(uint256 rawAmount) public view returns (uint256) {
        return rawAmount * uiMultiplier / 1e18;
    }

    function fromUIAmount(uint256 uiAmount) external view returns (uint256) {
        return uiAmount * 1e18 / uiMultiplier;
    }

    function balanceOfUI(address account) external view returns (uint256) {
        return toUIAmount(balanceOf(account));
    }
}

/// @title TestnetUSDT
/// @notice The testnet numeraire (18 decimals, like BSC USDT) with a capped faucet run by the backend. Only a
/// faucet address (the backend operator, appointed by the owner) can hand out test money, and only in two capped
/// ways: `claimFor` up to `dailyLimit` per recipient per fixed 24-hour window (it opens with the recipient's first
/// claim, like the executor's buy window), and `welcomeFor`, the one-off welcome grant of `WELCOME_AMOUNT` per
/// recipient. There is no self-service claim (cre8-contracts#47): the parameter table's per-user and site-wide
/// limits live in the backend's claim API (login, quotas), which a public `claim` let any address bypass.
/// @dev Faucet and minter are separate roles (cre8-contracts#47): a faucet cannot `mint`, so a leaked operator key
/// can only grant capped amounts per address. Uncapped `mint` stays with minters (the deployer while it seeds the
/// pools; after the hand-over only whom the owner appoints).
contract TestnetUSDT is TestnetToken {
    uint256 public constant CLAIM_WINDOW = 1 days;
    /// @notice One-off welcome grant per recipient (parameter table: 10,000 test USDT per new user).
    uint256 public constant WELCOME_AMOUNT = 10_000e18;

    struct ClaimWindow {
        uint64 start;
        uint192 claimed;
    }

    uint256 public dailyLimit;
    mapping(address => ClaimWindow) public claimWindowOf;
    mapping(address => bool) public isFaucet;
    mapping(address => bool) public welcomed;

    event DailyLimitSet(uint256 limit);
    event FaucetSet(address indexed faucet, bool allowed);
    event Claimed(address indexed to, uint256 amount, address indexed by);
    event Welcomed(address indexed to, uint256 amount, address indexed by);

    error NotFaucet();
    error ClaimLimitExceeded(uint256 requested, uint256 remaining);
    error AlreadyWelcomed(address to);
    error ZeroAmount();

    constructor(address owner_, uint256 dailyLimit_) TestnetToken("Testnet USDT", "USDT", 18, owner_) {
        dailyLimit = dailyLimit_;
        emit DailyLimitSet(dailyLimit_);
    }

    modifier onlyFaucet() {
        if (!isFaucet[msg.sender]) revert NotFaucet();
        _;
    }

    function setDailyLimit(uint256 limit) external onlyOwner {
        dailyLimit = limit;
        emit DailyLimitSet(limit);
    }

    function setFaucet(address faucet, bool allowed) external onlyOwner {
        if (faucet == address(0)) revert ZeroAddress();
        isFaucet[faucet] = allowed;
        emit FaucetSet(faucet, allowed);
    }

    /// @notice What `account` may still claim now, and when its current window resets (0 = no open window).
    function claimable(address account) public view returns (uint256 remaining, uint256 windowEndsAt) {
        ClaimWindow memory w = claimWindowOf[account];
        if (w.start == 0 || block.timestamp >= w.start + CLAIM_WINDOW) return (dailyLimit, 0);
        remaining = w.claimed >= dailyLimit ? 0 : dailyLimit - w.claimed;
        windowEndsAt = w.start + CLAIM_WINDOW;
    }

    /// @notice Daily faucet: grant `to` up to its remaining `dailyLimit` in the current window. Faucet only.
    function claimFor(address to, uint256 amount) external onlyFaucet {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        (uint256 remaining, uint256 windowEndsAt) = claimable(to);
        if (amount > remaining) revert ClaimLimitExceeded(amount, remaining);
        ClaimWindow storage w = claimWindowOf[to];
        if (windowEndsAt == 0) {
            w.start = uint64(block.timestamp);
            w.claimed = uint192(amount);
        } else {
            w.claimed += uint192(amount);
        }
        _mint(to, amount);
        emit Claimed(to, amount, msg.sender);
    }

    /// @notice One-off welcome grant of `WELCOME_AMOUNT` to `to`; a second grant to the same address reverts.
    /// Faucet only; independent of the daily claim window.
    function welcomeFor(address to) external onlyFaucet {
        if (to == address(0)) revert ZeroAddress();
        if (welcomed[to]) revert AlreadyWelcomed(to);
        welcomed[to] = true;
        _mint(to, WELCOME_AMOUNT);
        emit Welcomed(to, WELCOME_AMOUNT, msg.sender);
    }
}
