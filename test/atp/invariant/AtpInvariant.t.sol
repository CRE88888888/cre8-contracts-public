// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test, console } from "forge-std/Test.sol";
import { AtpExecutor } from "../../../src/atp/AtpExecutor.sol";
import { AtpRegistry } from "../../../src/atp/AtpRegistry.sol";
import { BurnableToken } from "../AtpExecutorBuyLimit.t.sol";
import { AtpHandler } from "./AtpHandler.sol";
import { TestAccount } from "./InvariantMocks.sol";

/// @notice The seven pre-launch invariants of cre8-contracts#21, checked after every call of a random
/// sequence driven by `AtpHandler` (rebalances through honest and malicious venues, price moves, time, Safe
/// admin changes, non-Safe admin attempts, enrollments and pauses from every caller, third-party donations).
/// @dev Run deeper locally: `FOUNDRY_INVARIANT_RUNS=2000 FOUNDRY_INVARIANT_DEPTH=200 forge test --match-path
/// 'test/atp/invariant/*'`.
contract AtpInvariantTest is Test {
    AtpHandler internal handler;

    function setUp() public {
        handler = new AtpHandler();
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](10);
        selectors[0] = AtpHandler.rebalance.selector;
        selectors[1] = AtpHandler.rebalance.selector; // weighted: rebalances are the point
        selectors[2] = AtpHandler.movePrice.selector;
        selectors[3] = AtpHandler.warp.selector;
        selectors[4] = AtpHandler.deposit.selector;
        selectors[5] = AtpHandler.donate.selector;
        selectors[6] = AtpHandler.safeAdmin.selector;
        selectors[7] = AtpHandler.unauthorizedAdmin.selector;
        selectors[8] = AtpHandler.enroll.selector;
        selectors[9] = AtpHandler.setPaused.selector;
        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
    }

    /// (1) Between calls the executor holds nothing of anyone's: each token balance equals exactly what third
    /// parties sent it unasked, and it has no ERC20 allowance left to any venue, spender or Permit2.
    function invariant_1_executorHoldsNothingAndApprovesNothing() public view {
        AtpExecutor executor = handler.executor();
        BurnableToken[5] memory tokens = handler.tokens();
        address[4] memory spenders = [
            address(handler.erc20Venue()),
            address(handler.permit2Venue()),
            address(handler.ur()),
            address(handler.permit2())
        ];
        for (uint256 t; t < tokens.length; ++t) {
            assertEq(
                tokens[t].balanceOf(address(executor)),
                handler.ghostDonated(address(tokens[t])),
                "executor balance"
            );
            for (uint256 s; s < spenders.length; ++s) {
                assertEq(tokens[t].allowance(address(executor), spenders[s]), 0, "executor allowance");
            }
        }
    }

    /// (2) Accounts trade only allowlisted assets through allowlisted venues; at most `amountIn` leaves; the fee
    /// is exactly floor(gross x feeBps) and goes only to `feeRecipient`; nobody else's balance moves.
    function invariant_2_onlyAllowedSwapsAndFeeOnlyToRecipient() public view {
        assertEq(handler.ghostNotAllowedExecuted(), 0, "asset outside the pinned version traded");
        assertEq(handler.ghostUnlistedVenueExecuted(), 0, "venue off the allowlist used");
        assertEq(handler.ghostInOverspend(), 0, "more than amountIn left the account");
        assertEq(handler.ghostFeeViolations(), 0, "fee wrong or elsewhere");
        assertEq(handler.ghostLeaks(), 0, "another account's balance moved");
    }

    /// (3) No caller but the Safe changes venues, oracles, secondaries, fees, the operator, maxBuyBps, the global
    /// pause, strategy versions or ownership.
    function invariant_3_onlyTheSafeAdministers() public view {
        assertEq(handler.ghostUnauthorizedAdmin(), 0, "non-Safe admin call succeeded");
        assertEq(handler.registry().owner(), address(handler), "registry owner");
        assertEq(handler.router().owner(), address(handler), "router owner");
        assertEq(handler.executor().feeRecipient(), address(0xFEE), "fee recipient");
    }

    /// (4) The operator only makes first enrollments and only lifts its own pause; the account lifts every pause;
    /// the registry's pause flags always match the model, and `paused` mirrors them.
    function invariant_4_operatorBoundsAndPauseSources() public view {
        assertEq(handler.ghostEnrollViolations(), 0, "enroll outcome");
        assertEq(handler.ghostPauseViolations(), 0, "setPaused outcome");
        AtpRegistry registry = handler.registry();
        for (uint256 i; i < 2; ++i) {
            address account = address(handler.accounts(i));
            assertEq(registry.pauseFlags(account), handler.modelFlags(account), "pause flags");
            assertEq(registry.enrollments(account).paused, handler.modelFlags(account) != 0, "paused mirror");
            assertEq(registry.isEnrolled(account), handler.modelEnrolled(account), "enrolled");
            if (handler.modelEnrolled(account)) {
                assertEq(registry.enrollments(account).strategyId, handler.modelStrategy(account), "strategy");
            }
        }
    }

    /// (5) Within a window, buys never take an account past the cap computed at the start of the batch; sales
    /// are never stopped by the buy limit.
    function invariant_5_buyLimitHoldsAndSalesAreFree() public view {
        assertEq(handler.ghostBuyLimitViolations(), 0, "bought past the cap");
        assertEq(handler.ghostSaleBlockedByBuyLimit(), 0, "a sale hit the buy limit");
    }

    /// (6) With the global pause on, or the account paused by any source, nothing executes.
    function invariant_6_pausedNeverExecutes() public view {
        assertEq(handler.ghostPausedButExecuted(), 0, "executed while paused");
    }

    /// (7) Whatever a venue does (steal, underpay, pay elsewhere, pull more, re-enter, call admin, donate...),
    /// every executed step pays the account at least the oracle floor, and its gross output clears the step's
    /// own amountOutMin (cre8-contracts#24): the loss is bounded by amountIn's value - max(floor, amountOutMin).
    function invariant_7_venueLossBoundedByTheFloor() public view {
        assertEq(handler.ghostFloorViolations(), 0, "account received less than the floor");
        assertEq(handler.ghostMinOutViolations(), 0, "gross output below amountOutMin");
    }

    /// @dev Coverage guard: the handler really settles swaps through every venue kind and through the two
    /// malicious behaviours that can settle (pull half, donate a stray token), and really reverts the others,
    /// so the invariants above are checked against executed trades rather than an all-revert sequence.
    function test_handlerSettlesEveryVenueKindAndRejectsTheRest() public {
        AtpHandler h = new AtpHandler();
        for (uint256 venue; venue < 7; ++venue) {
            h.rebalance(0, true, 0, 100e18, venue, 15, 10_000, 0); // honest buy of A
            h.rebalance(0, false, 0, 10e18, venue, 15, 10_000, 0); // honest sale of A
        }
        assertEq(h.callsSwapOk(), 14, "UR, ERC20 and Permit2 venues settle both ways");
        h.rebalance(0, true, 0, 100e18, 7, 15, 10_000, 0); // venue off the allowlist
        assertEq(h.callsSwapReverted(), 1);

        h.rebalance(0, true, 0, 100e18, 2, 7, 10_000, 0); // PullHalf on the ERC20 venue
        h.rebalance(0, true, 0, 100e18, 2, 9, 10_000, 0); // DonateStray on the ERC20 venue
        assertEq(h.callsMaliciousOk(), 2, "the settleable malicious behaviours settle");
        for (uint256 mode = 1; mode <= 8; ++mode) {
            if (mode == 7) continue;
            h.rebalance(0, true, 0, 100e18, 2, mode, 10_000, 0); // every other behaviour must revert
        }
        assertEq(h.callsSwapOk(), 16, "no other malicious behaviour settles");
        h.rebalance(0, true, 0, 100e18, 2, 15, 9_400, 0); // pays 94% of the quote: below the 97% floor
        assertEq(h.callsSwapOk(), 16, "underpayment reverts");
        for (uint256 venue; venue < 7; ++venue) {
            // pays 99% of the quote, above the floor but below an amountOutMin of 100%: every venue kind reverts
            h.rebalance(0, true, 0, 100e18, venue, 15, 9_900, 10_000);
        }
        assertEq(h.callsSwapOk(), 16, "a payout between the floor and amountOutMin reverts");
        h.rebalance(0, true, 0, 100e18, 2, 15, 10_000, 10_000); // pays exactly amountOutMin
        assertEq(h.callsSwapOk(), 17, "a payout equal to amountOutMin settles");
        assertEq(
            h.ghostFloorViolations() + h.ghostMinOutViolations() + h.ghostFeeViolations() + h.ghostLeaks(), 0
        );
    }

    function afterInvariant() public view {
        console.log("swaps ok / reverted:", handler.callsSwapOk(), handler.callsSwapReverted());
        console.log("  buys ok / sales ok:", handler.callsBuyOk(), handler.callsSellOk());
        console.log("  malicious-mode swaps that still settled:", handler.callsMaliciousOk());
        console.log(
            "admin attempts / enroll / pause calls:",
            handler.callsAdminAttempts(),
            handler.callsEnroll(),
            handler.callsPause()
        );
    }
}
