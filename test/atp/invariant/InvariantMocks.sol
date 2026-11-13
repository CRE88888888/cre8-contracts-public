// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { AtpExecutor } from "../../../src/atp/AtpExecutor.sol";
import { AtpRegistry } from "../../../src/atp/AtpRegistry.sol";
import { IOracleFloor } from "../../../src/atp/interfaces/IOracleFloor.sol";
import { BurnableToken } from "../AtpExecutorBuyLimit.t.sol";
import { FunctionalPermit2 } from "../AtpExecutorVenues.t.sol";

/// @dev Fixed-price oracle with a slippage discount: `quoted` = amount at `price` (numeraire units per 1e18
/// asset units), `minimum` = quoted x (1 - slippage), rounded up. A zero price reverts (stale / unpriced).
contract SlippageOracle is IOracleFloor {
    address public immutable numeraire;
    uint16 public immutable slippageBps;
    mapping(address => uint256) public price;

    constructor(address numeraire_, uint16 slippageBps_) {
        numeraire = numeraire_;
        slippageBps = slippageBps_;
    }

    function setPrice(address asset, uint256 price_) external {
        price[asset] = price_;
    }

    function previewSwap(address tokenIn, address tokenOut, uint256 amountIn)
        external
        view
        returns (uint256 quoted, uint256 minimum)
    {
        require(amountIn != 0 && tokenIn != tokenOut, "args");
        if (tokenOut == numeraire) {
            require(price[tokenIn] != 0, "unpriced");
            quoted = amountIn * price[tokenIn] / 1e18;
        } else if (tokenIn == numeraire) {
            require(price[tokenOut] != 0, "unpriced");
            quoted = amountIn * 1e18 / price[tokenOut];
        } else {
            revert("route");
        }
        require(quoted != 0, "zero quote");
        minimum = (quoted * (10_000 - slippageBps) + 9_999) / 10_000;
    }
}

/// @dev A smart account stand-in: the executor requires `msg.sender == account` and code at the account.
contract TestAccount {
    function exec(AtpExecutor executor, AtpExecutor.SwapStep[] calldata steps, uint256 deadline) external {
        executor.executeRebalance(address(this), steps, deadline);
    }

    function approve(BurnableToken token, address spender) external {
        token.approve(spender, type(uint256).max);
    }

    function enroll(AtpRegistry registry, uint256 id) external {
        registry.enroll(address(this), id);
    }

    function setPaused(AtpRegistry registry, bool paused) external {
        registry.setPaused(address(this), paused);
    }
}

/// @dev A venue that behaves honestly or maliciously per call. `swap` is called by the executor with this
/// step's raw `data`; `msg.sender` is the executor. Pays through a FunctionalPermit2 when `permit2` is set.
contract RandomVenue {
    enum Mode {
        Pay, // pull amountIn, pay `amountOut` (which may be above or below the floor) to the executor
        PayNothing, // pull amountIn, pay nothing
        PayElsewhere, // pull amountIn, pay `amountOut` to a third party
        PullMore, // try to pull amountIn + 1
        PullFromAccount, // try to pull from the account (which never approved a venue)
        PullStray, // try to pull a donated token from the executor (never approved)
        Reenter, // call back into executeRebalance
        PullHalf, // pull half, pay `amountOut`
        CallAdmin, // try an executor admin function mid-swap
        DonateStray // pull amountIn, pay `amountOut`, and also send a stray token to the executor
    }

    FunctionalPermit2 public immutable permit2; // zero for an ERC20-approve venue
    BurnableToken public immutable stray;

    constructor(FunctionalPermit2 permit2_, BurnableToken stray_) {
        permit2 = permit2_;
        stray = stray_;
    }

    function _pull(address token, address from, uint256 amount) internal {
        if (address(permit2) != address(0)) {
            permit2.transferFrom(from, address(this), uint160(amount), token);
        } else {
            BurnableToken(token).transferFrom(from, address(this), amount);
        }
    }

    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        Mode mode,
        address account
    ) external {
        if (mode == Mode.Pay || mode == Mode.DonateStray) {
            _pull(tokenIn, msg.sender, amountIn);
            BurnableToken(tokenOut).mint(msg.sender, amountOut);
            if (mode == Mode.DonateStray) stray.mint(msg.sender, 1e18);
        } else if (mode == Mode.PayNothing) {
            _pull(tokenIn, msg.sender, amountIn);
        } else if (mode == Mode.PayElsewhere) {
            _pull(tokenIn, msg.sender, amountIn);
            BurnableToken(tokenOut).mint(address(0xBAD), amountOut);
        } else if (mode == Mode.PullMore) {
            _pull(tokenIn, msg.sender, amountIn + 1);
        } else if (mode == Mode.PullFromAccount) {
            _pull(tokenIn, account, 1);
        } else if (mode == Mode.PullStray) {
            stray.transferFrom(msg.sender, address(this), 1);
        } else if (mode == Mode.Reenter) {
            AtpExecutor.SwapStep[] memory none;
            AtpExecutor(msg.sender).executeRebalance(account, none, block.timestamp + 300);
        } else if (mode == Mode.PullHalf) {
            _pull(tokenIn, msg.sender, amountIn / 2);
            BurnableToken(tokenOut).mint(msg.sender, amountOut);
        } else if (mode == Mode.CallAdmin) {
            AtpExecutor(msg.sender).setMaxBuyBps(20_000);
        }
    }
}
