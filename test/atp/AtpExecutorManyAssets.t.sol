// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";
import { AtpExecutor } from "../../src/atp/AtpExecutor.sol";
import { AtpRegistry } from "../../src/atp/AtpRegistry.sol";
import { MockPermit2 } from "./AtpExecutor.t.sol";
import { BurnableToken, PricedOracle, PricedRouter } from "./AtpExecutorBuyLimit.t.sol";

/// @notice cre8-contracts#45: a version is no longer capped at 16 assets. With USDT + 92 assets (the testnet's
/// full list) the executor's allowlist reaches every asset, the buy-limit valuation counts holdings at any index,
/// and a full buy-in or exit can be split into batches of at most 16 steps or sent as one batch. This test
/// contract is the registry owner and the enrolled account; prices are exact and there is no fee, so the account
/// value stays at its USDT deposit.
contract AtpExecutorManyAssetsTest is Test {
    uint256 internal constant ASSETS = 92;
    uint256 internal constant STEPS_PER_BATCH = 16;
    uint256 internal constant DEPOSIT = 1_000e18;
    uint256 internal constant BUY_EACH = 10e18;
    /// @dev Each quote rounds down: a buy loses under one asset unit, worth at most the asset's price (<= 46) in
    /// numeraire wei, and the sale back loses under one more wei, so 92 round trips lose well under 10,000 wei.
    uint256 internal constant ROUNDING = 10_000;

    AtpRegistry internal registry;
    AtpExecutor internal executor;
    PricedOracle internal oracle;
    PricedRouter internal router;
    BurnableToken internal usdt;
    BurnableToken[] internal tokens;
    uint256 internal strategyId;

    function setUp() public {
        usdt = new BurnableToken();
        oracle = new PricedOracle(address(usdt));
        router = new PricedRouter();
        registry = new AtpRegistry();
        executor = new AtpExecutor(
            registry, router, oracle, address(new MockPermit2()), address(0xFEE), address(usdt), 10_000, 0
        );

        address[] memory assets = new address[](ASSETS + 1);
        uint16[] memory weights = new uint16[](ASSETS + 1);
        assets[0] = address(usdt);
        weights[0] = uint16(10_000 - 108 * ASSETS);
        for (uint256 i; i < ASSETS; ++i) {
            BurnableToken token = new BurnableToken();
            tokens.push(token);
            // Distinct prices (0.5, 1, 1.5, ... numeraire per unit) so a mix-up between assets would show.
            oracle.setPrice(address(token), (i + 1) * 0.5e18);
            token.approve(address(executor), type(uint256).max);
            assets[i + 1] = address(token);
            weights[i + 1] = 108;
        }
        strategyId = registry.registerStrategy("all testnet assets", "cre8-contracts#45", true);
        registry.publishVersion(strategyId, assets, weights, keccak256("schedule"), 0);
        vm.warp(block.timestamp + 1 days);
        registry.enroll(address(this), strategyId, 1);

        usdt.approve(address(executor), type(uint256).max);
        usdt.mint(address(this), DEPOSIT);
    }

    // ---- fixtures ----

    function _step(address tokenIn, address tokenOut, uint256 amountIn)
        internal
        view
        returns (AtpExecutor.SwapStep memory step)
    {
        (uint256 quoted,) = oracle.previewSwap(tokenIn, tokenOut, amountIn);
        step.tokenIn = tokenIn;
        step.tokenOut = tokenOut;
        step.amountIn = amountIn;
        step.amountOutMin = quoted;
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(
            address(executor), amountIn, quoted, abi.encodePacked(tokenIn, uint24(500), tokenOut), true
        );
        step.venue = address(router);
        step.data = abi.encode(hex"00", inputs);
    }

    /// @dev Buys (`buy`) or sells everything of tokens[from, to) in one batch.
    function _batch(uint256 from, uint256 to, bool buy) internal {
        AtpExecutor.SwapStep[] memory steps = new AtpExecutor.SwapStep[](to - from);
        for (uint256 i = from; i < to; ++i) {
            address token = address(tokens[i]);
            steps[i - from] = buy
                ? _step(address(usdt), token, BUY_EACH)
                : _step(token, address(usdt), tokens[i].balanceOf(address(this)));
        }
        executor.executeRebalance(address(this), steps, block.timestamp + 300);
    }

    function _inBatches(bool buy) internal returns (uint256 batches) {
        for (uint256 from; from < ASSETS; from += STEPS_PER_BATCH) {
            uint256 to = from + STEPS_PER_BATCH;
            _batch(from, to > ASSETS ? ASSETS : to, buy);
            ++batches;
        }
    }

    function _bought() internal view returns (uint256 bought) {
        (, bought) = executor.buyWindowOf(address(this));
    }

    // ---- tests ----

    function test_versionHoldsAllNinetyThreeAssets() public view {
        assertEq(registry.version(strategyId, 0).assets.length, ASSETS + 1);
        assertTrue(registry.isAssetAllowed(strategyId, 0, address(tokens[ASSETS - 1])));
    }

    function test_buyAndSellEveryAssetInBatchesOfSixteen() public {
        assertEq(_inBatches(true), 6);
        for (uint256 i; i < ASSETS; ++i) {
            assertEq(tokens[i].balanceOf(address(this)), BUY_EACH * 1e18 / ((i + 1) * 0.5e18));
        }
        assertEq(_bought(), BUY_EACH * ASSETS);
        // Value is conserved at exact prices, so the valuation must have counted all 92 holdings.
        (uint256 cap,,) = executor.buyAllowance(address(this));
        assertApproxEqAbs(cap, DEPOSIT, ROUNDING);

        assertEq(_inBatches(false), 6);
        for (uint256 i; i < ASSETS; ++i) {
            assertEq(tokens[i].balanceOf(address(this)), 0);
        }
        assertApproxEqAbs(usdt.balanceOf(address(this)), DEPOSIT, ROUNDING);
        // Sales are never counted against the buy window.
        assertEq(_bought(), BUY_EACH * ASSETS);
    }

    function test_buyAndSellEveryAssetInOneBatch() public {
        _batch(0, ASSETS, true);
        assertEq(_bought(), BUY_EACH * ASSETS);
        assertEq(tokens[ASSETS - 1].balanceOf(address(this)), BUY_EACH * 1e18 / (ASSETS * 0.5e18));

        _batch(0, ASSETS, false);
        assertEq(tokens[ASSETS - 1].balanceOf(address(this)), 0);
        assertApproxEqAbs(usdt.balanceOf(address(this)), DEPOSIT, ROUNDING);
    }

    /// @dev Holding only the last asset (index 92 of the version) doubles the value; with `maxBuyBps` at 40% the
    /// cap is exactly 800, which it could only be if the valuation reached that asset (else it would be 400).
    function test_buyCapCountsHoldingAtTheLastIndex() public {
        BurnableToken last = tokens[ASSETS - 1];
        oracle.setPrice(address(last), 1e18);
        last.mint(address(this), DEPOSIT); // worth exactly DEPOSIT
        executor.setMaxBuyBps(4_000);
        (uint256 cap,,) = executor.buyAllowance(address(this));
        assertEq(cap, 800e18);

        AtpExecutor.SwapStep[] memory steps = new AtpExecutor.SwapStep[](1);
        steps[0] = _step(address(usdt), address(last), 800e18);
        executor.executeRebalance(address(this), steps, block.timestamp + 300);
        assertEq(_bought(), 800e18);

        steps[0] = _step(address(usdt), address(last), 1);
        vm.expectRevert(abi.encodeWithSelector(AtpExecutor.BuyLimitExceeded.selector, 800e18 + 1, 800e18));
        executor.executeRebalance(address(this), steps, block.timestamp + 300);
    }

    function test_assetOutsideTheLargeVersionIsRejected() public {
        BurnableToken stranger = new BurnableToken();
        oracle.setPrice(address(stranger), 1e18);
        AtpExecutor.SwapStep[] memory steps = new AtpExecutor.SwapStep[](1);
        steps[0] = _step(address(usdt), address(stranger), BUY_EACH);
        vm.expectRevert(AtpExecutor.AssetNotAllowed.selector);
        executor.executeRebalance(address(this), steps, block.timestamp + 300);
    }
}
