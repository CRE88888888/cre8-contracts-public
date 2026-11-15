// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test, Vm } from "forge-std/Test.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { AtpExecutor } from "../../src/atp/AtpExecutor.sol";
import { AtpRegistry } from "../../src/atp/AtpRegistry.sol";
import { MockPermit2, MockUniversalRouter } from "./AtpExecutor.t.sol";
import { BurnableToken, PricedOracle, PricedRouter } from "./AtpExecutorBuyLimit.t.sol";

/// @dev A second enrolled account (the executor requires `msg.sender == account` and code there).
contract MinFeeAccount {
    AtpExecutor internal immutable executor;

    constructor(AtpExecutor executor_) {
        executor = executor_;
    }

    function approve(address token) external {
        BurnableToken(token).approve(address(executor), type(uint256).max);
    }

    function run(AtpExecutor.SwapStep[] calldata steps, uint256 deadline) external {
        executor.executeRebalance(address(this), steps, deadline);
    }
}

/// @notice Pins the minimum batch fee (cre8-contracts#33, docs P12): a batch with at least one swap pays
/// `max(notional x feeBps, min(minBatchFee, notional x 1%))` in total. The proportional part is split off each
/// step's output as before (so every floor check is unchanged); the top-up is pulled in USDT from the account
/// after the last step, capped at its USDT balance and allowance, so it never blocks a batch.
/// @dev This contract is the registry owner and the enrolled account. A is priced at 2 USDT with no slippage,
/// the proportional fee is 10 bps and the minimum 0.30 USDT, the production values. `PricedRouter` pays exactly
/// a step's `amountOutMin`, which the fixtures set to `minGross` (the floor grossed up over the 10 bps), so every
/// step settles at the lowest output the executor accepts.
contract AtpExecutorMinFeeTest is Test {
    address internal constant OPERATOR = address(0x0FE7);
    address internal constant OUTSIDER = address(0xCAFE);
    address internal constant FEE_RECIPIENT = address(0xFEE);
    uint16 internal constant FEE_BPS = 10;
    uint256 internal constant MIN_FEE = 0.3e18;
    uint256 internal constant BPS = 10_000;

    AtpRegistry internal registry;
    AtpExecutor internal executor;
    PricedOracle internal oracle;
    PricedRouter internal router;
    BurnableToken internal usdt;
    BurnableToken internal tokenA;
    uint256 internal strategyId;

    function setUp() public {
        usdt = new BurnableToken();
        tokenA = new BurnableToken();
        oracle = new PricedOracle(address(usdt));
        oracle.setPrice(address(tokenA), 2e18);
        router = new PricedRouter();

        registry = new AtpRegistry();
        registry.setOperator(OPERATOR);
        registry.setDefaultFeeBps(FEE_BPS);
        executor = new AtpExecutor(
            registry,
            router,
            oracle,
            address(new MockPermit2()),
            FEE_RECIPIENT,
            address(usdt),
            20_000,
            MIN_FEE
        );

        address[] memory assets = new address[](2);
        assets[0] = address(usdt);
        assets[1] = address(tokenA);
        uint16[] memory weights = new uint16[](2);
        weights[0] = 5_000;
        weights[1] = 5_000;
        strategyId = registry.registerStrategy("index", "min fee", true);
        registry.publishVersion(strategyId, assets, weights, keccak256("schedule"), 0);
        registry.enroll(address(this), strategyId);

        usdt.approve(address(executor), type(uint256).max);
        tokenA.approve(address(executor), type(uint256).max);
    }

    // ---- fixtures ----

    /// @dev One exact-input hop at the lowest output the executor accepts: amountOutMin = minGross.
    function _step(address tokenIn, address tokenOut, uint256 amountIn)
        internal
        view
        returns (AtpExecutor.SwapStep memory step)
    {
        (, uint256 minimum) = oracle.previewSwap(tokenIn, tokenOut, amountIn);
        uint16 feeBps = registry.effectiveFeeBps(strategyId);
        uint256 minGross = Math.mulDiv(minimum, BPS, BPS - feeBps, Math.Rounding.Ceil);
        step.tokenIn = tokenIn;
        step.tokenOut = tokenOut;
        step.amountIn = amountIn;
        step.amountOutMin = minGross;
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(
            address(executor), amountIn, minGross, abi.encodePacked(tokenIn, uint24(500), tokenOut), true
        );
        step.venue = address(router);
        step.data = abi.encode(hex"00", inputs);
    }

    function _buy(uint256 usdtIn) internal view returns (AtpExecutor.SwapStep memory) {
        return _step(address(usdt), address(tokenA), usdtIn);
    }

    function _sell(uint256 aIn) internal view returns (AtpExecutor.SwapStep memory) {
        return _step(address(tokenA), address(usdt), aIn);
    }

    function _one(AtpExecutor.SwapStep memory a) internal pure returns (AtpExecutor.SwapStep[] memory steps) {
        steps = new AtpExecutor.SwapStep[](1);
        steps[0] = a;
    }

    function _two(AtpExecutor.SwapStep memory a, AtpExecutor.SwapStep memory b)
        internal
        pure
        returns (AtpExecutor.SwapStep[] memory steps)
    {
        steps = new AtpExecutor.SwapStep[](2);
        steps[0] = a;
        steps[1] = b;
    }

    function _exec(AtpExecutor.SwapStep[] memory steps) internal {
        executor.executeRebalance(address(this), steps, block.timestamp + 300);
    }

    /// @dev A sale that settles at exactly `gross` USDT: with A at 2 and 10 bps, gross = ceil(2a x 10000 / 9990),
    /// so a = gross x 9990 / 20000 hits it exactly whenever that division is exact (all the values used here).
    function _aForGross(uint256 gross) internal pure returns (uint256 a) {
        a = gross * (BPS - FEE_BPS) / 20_000;
        require(a * 20_000 == gross * (BPS - FEE_BPS), "inexact");
    }

    function _usdt(address who) internal view returns (uint256) {
        return usdt.balanceOf(who);
    }

    function _minFeeEvents() internal returns (Vm.Log[] memory found, uint256 count) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        found = new Vm.Log[](logs.length);
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(executor)
                    && logs[i].topics[0] == AtpExecutor.MinFeeCharged.selector
            ) {
                found[count++] = logs[i];
            }
        }
    }

    // ---- configuration ----

    function test_constructor_storesMinFeeAndCeiling() public view {
        assertEq(executor.minBatchFee(), MIN_FEE);
        assertEq(executor.minBatchFeeCeiling(), 5e18, "5 USDT at 18 decimals");
        assertEq(executor.MIN_FEE_MAX_BPS(), 100);
    }

    function test_constructor_acceptsTheCeilingAndRejectsAbove() public {
        MockPermit2 permit2 = new MockPermit2();
        AtpExecutor atCeiling = new AtpExecutor(
            registry, router, oracle, address(permit2), FEE_RECIPIENT, address(usdt), 0, 5e18
        );
        assertEq(atCeiling.minBatchFee(), 5e18);

        vm.expectRevert(abi.encodeWithSelector(AtpExecutor.MinBatchFeeTooHigh.selector, 5e18 + 1));
        new AtpExecutor(registry, router, oracle, address(permit2), FEE_RECIPIENT, address(usdt), 0, 5e18 + 1);
    }

    function test_constructor_rejectsNumeraireWithoutDecimals() public {
        // A contract that is not an ERC20: the ceiling cannot be derived, so construction fails.
        address notAToken = address(new MockUniversalRouter());
        MockPermit2 permit2 = new MockPermit2();
        vm.expectRevert();
        new AtpExecutor(registry, router, oracle, address(permit2), FEE_RECIPIENT, notAToken, 0, 0);
    }

    function test_setMinBatchFee_onlyRegistryOwnerAndBounded() public {
        vm.prank(OUTSIDER);
        vm.expectRevert(AtpExecutor.NotOwner.selector);
        executor.setMinBatchFee(0);

        // The operator can neither raise nor waive it.
        vm.prank(OPERATOR);
        vm.expectRevert(AtpExecutor.NotOwner.selector);
        executor.setMinBatchFee(0);

        vm.expectRevert(abi.encodeWithSelector(AtpExecutor.MinBatchFeeTooHigh.selector, 5e18 + 1));
        executor.setMinBatchFee(5e18 + 1);

        vm.expectEmit(false, false, false, true, address(executor));
        emit AtpExecutor.MinBatchFeeSet(5e18);
        executor.setMinBatchFee(5e18);
        assertEq(executor.minBatchFee(), 5e18);

        executor.setMinBatchFee(0);
        assertEq(executor.minBatchFee(), 0);
    }

    // ---- notional 0 ----

    function test_emptyBatch_chargesNothing() public {
        usdt.mint(address(this), 100e18);
        vm.recordLogs();
        _exec(new AtpExecutor.SwapStep[](0));
        (, uint256 count) = _minFeeEvents();
        assertEq(count, 0, "no event");
        assertEq(_usdt(address(this)), 100e18, "no swap, no fee");
        assertEq(_usdt(FEE_RECIPIENT), 0);
        assertEq(executor.minFeeTopUp(strategyId, 0), 0);
    }

    // ---- the 300 USDT crossover, pure buys ----

    function _checkBuy(uint256 usdtIn, uint256 expectedTopUp) internal {
        usdt.mint(address(this), usdtIn + 1e18);
        assertEq(executor.minFeeTopUp(strategyId, usdtIn), expectedTopUp, "view");
        _exec(_one(_buy(usdtIn)));
        assertEq(_usdt(address(this)), 1e18 - expectedTopUp, "account paid amountIn + top-up");
        assertEq(_usdt(FEE_RECIPIENT), expectedTopUp, "top-up in USDT");
        // The proportional fee is still taken in A from the step's output, exactly as before.
        uint256 gross = tokenA.balanceOf(address(this)) + tokenA.balanceOf(FEE_RECIPIENT);
        assertEq(tokenA.balanceOf(FEE_RECIPIENT), gross * FEE_BPS / BPS, "proportional fee in A");
    }

    function test_buy299_paysTheTopUp() public {
        _checkBuy(299e18, 0.001e18); // 0.30 - 0.299
    }

    function test_buy300_proportionalEqualsTheMinimum() public {
        _checkBuy(300e18, 0);
    }

    function test_buy301_proportionalOnly() public {
        _checkBuy(301e18, 0);
    }

    // ---- the 300 USDT crossover, pure sales ----

    function _checkSale(uint256 gross, uint256 expectedTotalFee) internal {
        tokenA.mint(address(this), _aForGross(gross));
        vm.recordLogs();
        _exec(_one(_sell(_aForGross(gross))));
        assertEq(_usdt(FEE_RECIPIENT), expectedTotalFee, "total fee = max(0.1%, 0.30)");
        assertEq(_usdt(address(this)) + _usdt(FEE_RECIPIENT), gross, "nothing else moved");
        (Vm.Log[] memory found, uint256 count) = _minFeeEvents();
        uint256 topUp = expectedTotalFee - gross * FEE_BPS / BPS;
        if (topUp == 0) {
            assertEq(count, 0, "no top-up, no event");
        } else {
            assertEq(count, 1);
            assertEq(found[0].topics[1], bytes32(uint256(uint160(address(this)))), "account");
            assertEq(found[0].data, abi.encode(gross, topUp, topUp), "notional, due, charged");
        }
    }

    function test_sale299_paysTheMinimum() public {
        _checkSale(299e18, MIN_FEE);
    }

    function test_sale300_proportionalEqualsTheMinimum() public {
        _checkSale(300e18, MIN_FEE);
    }

    function test_sale301_proportionalOnly() public {
        _checkSale(301e18, 0.301e18);
    }

    // ---- per batch, not per step ----

    function test_mixedBatch_minimumAppliesToTheBatchNotEachStep() public {
        // Sale of ~200 USDT + buy of 110 USDT: each step alone is under 300, the batch is above it.
        uint256 saleGross = 200e18;
        tokenA.mint(address(this), _aForGross(saleGross));
        usdt.mint(address(this), 110e18);
        _exec(_two(_sell(_aForGross(saleGross)), _buy(110e18)));
        assertEq(_usdt(FEE_RECIPIENT), saleGross * FEE_BPS / BPS, "only the sale's proportional fee in USDT");
        assertEq(_usdt(address(this)), saleGross - saleGross * FEE_BPS / BPS, "no top-up");
    }

    function test_mixedBatch_belowTheCrossoverPaysOneTopUp() public {
        // Two buys of 50 and a sale of 100: notional 200, proportional 0.20 (0.10 in A, 0.10 in USDT), top-up 0.10.
        uint256 saleGross = 100e18;
        tokenA.mint(address(this), _aForGross(saleGross));
        usdt.mint(address(this), 100e18);
        AtpExecutor.SwapStep[] memory steps = new AtpExecutor.SwapStep[](3);
        steps[0] = _buy(50e18);
        steps[1] = _sell(_aForGross(saleGross));
        steps[2] = _buy(50e18);
        assertEq(executor.minFeeTopUp(strategyId, 200e18), 0.1e18);
        _exec(steps);
        assertEq(_usdt(FEE_RECIPIENT), 0.1e18 + 0.1e18, "sale's proportional fee + one top-up");
        assertEq(_usdt(address(this)), 100e18 - 0.1e18 - 0.1e18, "100 in, 100 out, 0.20 to the fee recipient");
    }

    // ---- exits ----

    function test_fullExit_paysTheMinimumOutOfTheProceeds() public {
        // Everything in A, no USDT: sell it all; the top-up comes out of the sale's proceeds.
        uint256 gross = 100e18;
        tokenA.mint(address(this), _aForGross(gross));
        _exec(_one(_sell(tokenA.balanceOf(address(this)))));
        assertEq(tokenA.balanceOf(address(this)), 0, "exited");
        assertEq(_usdt(FEE_RECIPIENT), MIN_FEE, "max(0.10, 0.30)");
        assertEq(_usdt(address(this)), gross - MIN_FEE, "proceeds less the minimum");
    }

    function test_dustExit_paysAtMostOnePercent() public {
        // Residual worth 0.10 USDT, a third of the minimum: the exit goes through and costs 1% in total.
        uint256 gross = 0.1e18;
        tokenA.mint(address(this), _aForGross(gross));
        _exec(_one(_sell(_aForGross(gross))));
        assertEq(tokenA.balanceOf(address(this)), 0, "exited");
        assertEq(_usdt(FEE_RECIPIENT), gross / 100, "1% of the notional, not 0.30");
        assertEq(_usdt(address(this)), gross - gross / 100, "the account keeps 99%");
    }

    function test_onePercentCap_bindsBelow30Usdt() public {
        assertEq(
            executor.minFeeTopUp(strategyId, 30e18), MIN_FEE - 0.03e18, "at 30 the cap equals the minimum"
        );
        uint256 below = 30e18 - 1;
        assertEq(executor.minFeeTopUp(strategyId, below), below / 100 - below / 1000, "below 30: 1% - 0.1%");
        assertEq(executor.minFeeTopUp(strategyId, 1), 0, "rounds down to nothing");
    }

    function test_exitWithoutUsdtAllowance_goesThroughUncharged() public {
        usdt.approve(address(executor), 0);
        uint256 gross = 10e18;
        tokenA.mint(address(this), _aForGross(gross));
        uint256 due = executor.minFeeTopUp(strategyId, gross);
        assertGt(due, 0);

        vm.expectEmit(true, false, false, true, address(executor));
        emit AtpExecutor.MinFeeCharged(address(this), gross, due, 0);
        _exec(_one(_sell(_aForGross(gross))));
        assertEq(tokenA.balanceOf(address(this)), 0, "the exit was not blocked");
        assertEq(_usdt(FEE_RECIPIENT), gross * FEE_BPS / BPS, "proportional fee only");
    }

    function test_partialAllowance_chargesWhatIsApproved() public {
        usdt.approve(address(executor), 0.05e18);
        uint256 gross = 10e18; // due = 0.10 - 0.01 = 0.09
        tokenA.mint(address(this), _aForGross(gross));
        _exec(_one(_sell(_aForGross(gross))));
        assertEq(_usdt(FEE_RECIPIENT), gross * FEE_BPS / BPS + 0.05e18);
    }

    // ---- buys that leave too little USDT ----

    function test_buySpendingEveryUsdt_goesThroughUncharged() public {
        usdt.mint(address(this), 100e18);
        uint256 due = executor.minFeeTopUp(strategyId, 100e18);
        vm.expectEmit(true, false, false, true, address(executor));
        emit AtpExecutor.MinFeeCharged(address(this), 100e18, due, 0);
        _exec(_one(_buy(100e18)));
        assertEq(_usdt(address(this)), 0);
        assertEq(_usdt(FEE_RECIPIENT), 0, "nothing left to charge");
        assertGt(tokenA.balanceOf(address(this)), 0, "bought");
    }

    function test_buyLeavingLessThanTheTopUp_chargesTheRest() public {
        usdt.mint(address(this), 100.15e18); // due 0.20, 0.15 left after the buy
        _exec(_one(_buy(100e18)));
        assertEq(_usdt(address(this)), 0);
        assertEq(_usdt(FEE_RECIPIENT), 0.15e18);
    }

    // ---- the floor is not touched ----

    function test_minimumFee_doesNotRaiseNorLowerTheFloor() public {
        executor.setMinBatchFee(5e18); // the ceiling: the top-up dwarfs the 10 bps
        usdt.mint(address(this), 20e18);
        AtpExecutor.SwapStep memory step = _buy(10e18);

        // One unit under minGross is still rejected up front, with the same bound as without a minimum fee.
        AtpExecutor.SwapStep memory under = _buy(10e18); // a separate copy: memory structs alias
        under.amountOutMin = step.amountOutMin - 1;
        AtpExecutor.SwapStep[] memory steps = _one(under);
        uint256 deadline = block.timestamp + 300;
        vm.expectRevert(
            abi.encodeWithSelector(AtpExecutor.BelowFloor.selector, step.amountOutMin - 1, step.amountOutMin)
        );
        executor.executeRebalance(address(this), steps, deadline);

        // Exactly minGross settles: the top-up is not grossed into the swap's floor.
        _exec(_one(step));
        assertEq(tokenA.balanceOf(address(this)) + tokenA.balanceOf(FEE_RECIPIENT), step.amountOutMin);
        assertEq(_usdt(FEE_RECIPIENT), 0.1e18 - 0.01e18, "top-up = 1% cap - 0.1%");
    }

    // ---- other fee settings ----

    function test_minBatchFeeZero_isProportionalOnly() public {
        executor.setMinBatchFee(0);
        tokenA.mint(address(this), _aForGross(100e18));
        _exec(_one(_sell(_aForGross(100e18))));
        assertEq(_usdt(FEE_RECIPIENT), 0.1e18);
    }

    function test_strategyFeeAboveOnePercent_neverTopsUp() public {
        registry.setStrategyFeeBps(strategyId, 300);
        assertEq(executor.minFeeTopUp(strategyId, 1e18), 0);
        assertEq(executor.minFeeTopUp(strategyId, 10e18), 0);
        assertEq(executor.minFeeTopUp(strategyId, 299e18), 0);
    }

    function test_zeroProportionalFee_paysTheMinimum() public {
        registry.setDefaultFeeBps(0);
        assertEq(executor.minFeeTopUp(strategyId, 299e18), MIN_FEE);
        assertEq(executor.minFeeTopUp(strategyId, 10_000e18), MIN_FEE, "flat 0.30 at any size");
    }

    // ---- one minimum per account per window (cre8-contracts#47 #2) ----

    /// @dev A 100 USDT purchase the backend splits into four 25 USDT batches inside the window. Per batch the
    /// top-up would be 0.225 each (0.90 in all, three times the one-batch 0.20); per window it is
    /// max over the prefixes of (min(0.30, 1% x cumulative) - 0.1% x cumulative): 0.225 (25), 0.25 (50), 0.225
    /// (75), 0.20 (100), so 0.25 in all - never more than one 0.30 on top of the proportional fee.
    function test_splitPurchase_withinWindow_paysOneMinimum() public {
        usdt.mint(address(this), 101e18);
        for (uint256 i; i < 4; ++i) {
            _exec(_one(_buy(25e18)));
            vm.warp(block.timestamp + 10 minutes);
        }
        assertEq(_usdt(FEE_RECIPIENT), 0.25e18, "one window, one minimum");
        uint256 proportional = tokenA.balanceOf(FEE_RECIPIENT) * 2; // A at 2 USDT
        assertLe(_usdt(FEE_RECIPIENT) + proportional, 0.1e18 + MIN_FEE + 1, "<= proportional + one minimum");
    }

    /// @dev A dust batch first cannot use up the window's minimum: the window as a whole still pays what one
    /// batch of its cumulative notional would (100 USDT -> 0.20).
    function test_dustFirstBatch_cannotDodgeTheMinimum() public {
        usdt.mint(address(this), 101e18);
        _exec(_one(_buy(1e18))); // min(0.30, 0.01) - 0.001 = 0.009
        assertEq(_usdt(FEE_RECIPIENT), 0.009e18);
        _exec(_one(_buy(99e18)));
        assertEq(_usdt(FEE_RECIPIENT), 0.2e18, "the same as one 100 USDT batch");
    }

    /// @dev The window is fixed: it opens with the account's first charged batch and a batch at or after
    /// `start + MIN_FEE_WINDOW` opens the next one, which owes a fresh minimum.
    function test_minFeeWindow_resetsAtExactlyOneHour() public {
        usdt.mint(address(this), 200e18);
        uint256 start = block.timestamp;
        _exec(_one(_buy(25e18)));
        assertEq(_usdt(FEE_RECIPIENT), 0.225e18);

        vm.warp(start + 1 hours - 1); // still the same window: only up to T(50) = 0.25
        _exec(_one(_buy(25e18)));
        assertEq(_usdt(FEE_RECIPIENT), 0.25e18, "same window");

        vm.warp(start + 1 hours); // a new window: a fresh 0.225
        _exec(_one(_buy(25e18)));
        assertEq(_usdt(FEE_RECIPIENT), 0.475e18, "new window");
    }

    /// @dev What a batch could not pay (no USDT left after the buy) stays owed inside the window: the next batch
    /// pays the window's deficit, here min(0.30, 2.00) - 0.20 = 0.10 after a 100 buy and a 100 sale.
    function test_shortfall_isOwedByTheNextBatchInTheWindow() public {
        usdt.mint(address(this), 100e18);
        _exec(_one(_buy(100e18)));
        assertEq(_usdt(FEE_RECIPIENT), 0, "nothing left to charge");

        tokenA.mint(address(this), _aForGross(100e18));
        _exec(_one(_sell(_aForGross(100e18))));
        assertEq(_usdt(FEE_RECIPIENT), 0.1e18 + 0.1e18, "sale's 0.1% + the window's remaining 0.10");
    }

    /// @dev Windows are per account: another account's batch neither uses up nor shares this one's minimum.
    function test_minFeeWindow_isPerAccount() public {
        usdt.mint(address(this), 26e18);
        _exec(_one(_buy(25e18)));
        assertEq(_usdt(FEE_RECIPIENT), 0.225e18);

        MinFeeAccount other = new MinFeeAccount(executor);
        vm.prank(OPERATOR);
        registry.enroll(address(other), strategyId);
        usdt.mint(address(other), 26e18);
        other.approve(address(usdt));
        other.approve(address(tokenA));
        other.run(_one(_buy(25e18)), block.timestamp + 300);
        assertEq(_usdt(FEE_RECIPIENT), 0.45e18, "its own 0.225");
    }

    /// @dev `minFeeDue` is what the next batch of the window is charged; 0 for an empty batch.
    function test_minFeeDue_predictsTheWindowCharge() public {
        usdt.mint(address(this), 101e18);
        assertEq(executor.minFeeDue(address(this), 0), 0);
        assertEq(executor.minFeeDue(address(this), 25e18), 0.225e18, "fresh window = one-batch top-up");
        _exec(_one(_buy(25e18)));
        assertEq(executor.minFeeDue(address(this), 25e18), 0.025e18, "T(50) - 0.225");
        assertEq(executor.minFeeDue(address(this), 50e18), 0, "T(75) < paid");
        (uint64 start, uint192 notional, uint256 paid) = executor.minFeeWindowOf(address(this));
        assertEq(start, block.timestamp);
        assertEq(notional, 25e18);
        assertEq(paid, 0.225e18);
        vm.warp(block.timestamp + 1 hours);
        assertEq(executor.minFeeDue(address(this), 25e18), 0.225e18, "expired window starts afresh");
    }

    /// @dev Over any sequence of batches inside one window: the top-ups total at least what one batch of the
    /// cumulative notional owes (no splitting around the minimum), at most one `minBatchFee`, and each batch's
    /// top-up is at most what it would pay alone, up to 1 wei of rounding (the account holds enough USDT, so
    /// nothing is carried).
    function testFuzz_windowTopUps_boundedByOneMinimum(uint64[5] calldata sizes) public {
        uint256 cumulative;
        uint256 before;
        for (uint256 i; i < sizes.length; ++i) {
            uint256 amount = bound(sizes[i], 1e15, 400e18);
            usdt.mint(address(this), amount + 1e18);
            uint256 alone = executor.minFeeTopUp(strategyId, amount);
            before = _usdt(FEE_RECIPIENT);
            _exec(_one(_buy(amount)));
            // T is subadditive up to rounding: both terms round down, so a batch may pay 1 wei more than alone.
            assertLe(_usdt(FEE_RECIPIENT) - before, alone + 1, "no batch pays more than alone");
            cumulative += amount;
            assertGe(
                _usdt(FEE_RECIPIENT), executor.minFeeTopUp(strategyId, cumulative), ">= one batch of the sum"
            );
            assertLe(_usdt(FEE_RECIPIENT), MIN_FEE, "<= one minimum per window");
        }
    }

    // ---- the formula ----

    /// @dev total = proportional + top-up = max(proportional, min(minBatchFee, 1%)), the top-up never exceeds
    /// the minimum nor 1% of the notional, and it is monotone non-increasing in the proportional rate.
    function testFuzz_topUpFormula(uint256 notional, uint16 feeBps, uint256 minFee) public {
        notional = bound(notional, 0, 1e30);
        feeBps = uint16(bound(feeBps, 0, 300));
        minFee = bound(minFee, 0, 5e18);
        executor.setMinBatchFee(minFee);
        registry.setDefaultFeeBps(feeBps);

        uint256 topUp = executor.minFeeTopUp(strategyId, notional);
        uint256 proportional = notional * feeBps / BPS;
        uint256 minimum = Math.min(minFee, notional / 100);
        assertEq(proportional + topUp, Math.max(proportional, minimum), "max(proportional, minimum)");
        assertLe(topUp, minFee);
        assertLe(topUp, notional / 100);
    }
}
