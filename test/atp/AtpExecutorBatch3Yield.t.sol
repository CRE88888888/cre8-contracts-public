// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import { AtpExecutor } from "../../src/atp/AtpExecutor.sol";
import { AtpYieldRegistry } from "../../src/atp/yield/AtpYieldRegistry.sol";
import { YieldReader } from "../../src/atp/yield/YieldReader.sol";
import { YieldActions } from "../../src/atp/yield/YieldActions.sol";
import { YieldTypes as Y } from "../../src/atp/yield/YieldTypes.sol";
import { MockVenus } from "../../src/testnet/yield/MockVenus.sol";
import { MockLista } from "../../src/testnet/yield/MockLista.sol";
import { MockAavePool } from "../../src/testnet/yield/MockAavePool.sol";
import { Batch3Fixture } from "./fixtures/batch3/Batch3Fixture.sol";

contract AtpExecutorBatch3YieldTest is Batch3Fixture {
    AtpYieldRegistry private yields;
    MockVenus private venus;
    MockLista private lista;
    MockAavePool private aave;
    bytes32[3] private ids;
    address[3] private receipts;

    function setUp() public override {
        super.setUp();
        _warm();
        yields = executor.yieldRegistry();
        venus = new MockVenus(usdt, address(this), 0);
        lista = new MockLista(usdt, address(this), 0);
        aave = new MockAavePool(usdt, address(this), 0);
        receipts = [address(venus), address(lista), aave.receipt()];
        // Background liquidity is independent of the enrolled account and never part of its NAV.
        usdt.mint(address(this), 3_000_000e18);
        usdt.approve(address(venus), type(uint256).max);
        usdt.approve(address(lista), type(uint256).max);
        usdt.approve(address(aave), type(uint256).max);
        assertEq(venus.mint(1_000_000e18), 0);
        lista.deposit(1_000_000e18, address(this));
        aave.supply(address(usdt), 1_000_000e18, address(this), 0);
        for (uint256 i; i < ids.length; ++i) {
            ids[i] = keccak256(abi.encode("batch3 cash yield", i));
            address target = i == 0 ? address(venus) : i == 1 ? address(lista) : address(aave);
            IERC20 receipt = IERC20(receipts[i]);
            receipt.transfer(address(0xB0), receipt.balanceOf(address(this)));
            Y.Market memory m = Y.Market(
                97,
                Y.Kind(i + 1),
                address(usdt),
                receipts[i],
                target,
                target,
                bytes32(0),
                i == 0 ? 1e27 : 1e17,
                i == 0 ? 1e30 : 1e20,
                true,
                false
            );
            m.configuration = YieldReader.health(m).configuration;
            yields.registerMarket(ids[i], m);
            yields.setYieldPolicy(ids[i], 1_000e18, true);
            receipt.approve(address(executor), type(uint256).max);
        }
    }

    function test_allProtocols_receiptsAreNAV_notSpendableCash_thenRedeemAndBuy() public {
        for (uint256 i; i < ids.length; ++i) {
            uint256 snapshot = vm.snapshotState();
            _supply(i);
            usdt.transfer(SECOND, usdt.balanceOf(address(this)));
            (uint256 cap,,) = executor.previewBuyAllowance(address(this));
            assertEq(cap, 1_100e18, "100 USDT claim + 1000 liquid asset, counted once");
            AtpExecutor.SwapStep[] memory steps = _one(_step(true, 10e18));
            vm.expectRevert(
                abi.encodeWithSelector(
                    IERC20Errors.ERC20InsufficientBalance.selector, address(this), 0, 10e18
                )
            );
            executor.executeRebalance(address(this), steps, block.timestamp);
            _assertNoSwapCharge();
            uint256 held = IERC20(receipts[i]).balanceOf(address(this));
            uint256 quote = yields.quoteWithdraw(ids[i], held);
            vm.expectEmit(true, true, false, true, address(executor));
            emit AtpExecutor.WithdrawExecuted(address(this), ids[i], held, quote, 0);
            executor.executeWithdraw(address(this), ids[i], held, quote, block.timestamp);
            assertEq(usdt.balanceOf(address(this)), quote, "receipt promise became actual cash");
            assertEq(IERC20(receipts[i]).balanceOf(address(this)), 0);
            assertEq(yields.totalUnits(ids[i]), 0);
            _assertNoSwapCharge();
            _run(address(this), steps);
            assertEq(usdt.balanceOf(address(this)), quote - 10e18 - 0.09e18);
            (, uint192 bought) = executor.buyWindowOf(address(this));
            assertEq(bought, 10e18, "redemption consumes no buy quota");
            _assertClean();
            assertTrue(vm.revertToState(snapshot));
        }
    }

    function test_allProtocols_illiquidAndPartialRedemption_cannotSpendUnreceivedRemainder() public {
        for (uint256 i; i < ids.length; ++i) {
            uint256 snapshot = vm.snapshotState();
            _supply(i);
            usdt.transfer(SECOND, usdt.balanceOf(address(this)));
            _setLiquidity(i, 40e18);
            uint256 held = IERC20(receipts[i]).balanceOf(address(this));
            uint256 quote = yields.quoteWithdraw(ids[i], held);
            if (i == 0) vm.expectRevert(abi.encodeWithSelector(YieldActions.ProtocolError.selector, 2));
            else if (i == 1) vm.expectRevert(YieldActions.InexactTransfer.selector);
            else vm.expectRevert(bytes("withdraw unavailable"));
            executor.executeWithdraw(address(this), ids[i], held, quote, block.timestamp);
            assertEq(IERC20(receipts[i]).balanceOf(address(this)), held);
            assertEq(usdt.balanceOf(address(this)), 0);
            _assertNoSwapCharge();
            uint256 shares = held * 40 / 100;
            quote = yields.quoteWithdraw(ids[i], shares);
            executor.executeWithdraw(address(this), ids[i], shares, quote, block.timestamp);
            assertEq(usdt.balanceOf(address(this)), 40e18);
            AtpExecutor.SwapStep[] memory steps = _one(_step(true, 40e18 + 1));
            vm.expectRevert(
                abi.encodeWithSelector(
                    IERC20Errors.ERC20InsufficientBalance.selector, address(this), 40e18, 40e18 + 1
                )
            );
            executor.executeRebalance(address(this), steps, block.timestamp);
            _assertNoSwapCharge();
            _run(address(this), _one(_step(true, 10e18)));
            _setLiquidity(i, 1_000_000e18);
            held = IERC20(receipts[i]).balanceOf(address(this));
            quote = yields.quoteWithdraw(ids[i], held);
            executor.executeWithdraw(address(this), ids[i], held, quote, block.timestamp);
            assertEq(usdt.balanceOf(address(this)), 100e18 - 10e18 - 0.09e18);
            assertEq(yields.totalUnits(ids[i]), 0);
            _assertClean();
            assertTrue(vm.revertToState(snapshot));
        }
    }

    function test_confirmedRedemption_survivesLaterSwapFailure_retryChargesOnlyOnce() public {
        _supply(0);
        usdt.transfer(SECOND, usdt.balanceOf(address(this)));
        uint256 held = venus.balanceOf(address(this));
        executor.executeWithdraw(
            address(this), ids[0], held, yields.quoteWithdraw(ids[0], held), block.timestamp
        );
        uint256 gross = _realOutput(true, 10e18);
        AtpExecutor.SwapStep[] memory steps = _one(_step(true, 10e18));
        steps[0].amountOutMin = gross + 1;
        vm.expectRevert(abi.encodeWithSelector(AtpExecutor.BelowFloor.selector, gross, gross + 1));
        executor.executeRebalance(address(this), steps, block.timestamp);
        assertEq(usdt.balanceOf(address(this)), 100e18, "earlier confirmed withdrawal remains settled");
        assertEq(venus.balanceOf(address(this)), 0);
        _assertNoSwapCharge();
        steps[0].amountOutMin = gross;
        _run(address(this), steps);
        assertEq(usdt.balanceOf(FEE_RECIPIENT), 0.09e18);
        assertEq(usdt.balanceOf(address(this)), 89.91e18);
        _assertClean();
    }

    function test_globalPause_blocksRedeemAndBuy_ownerCanStillRedeemDirectly() public {
        _supply(0);
        AtpExecutor.SwapStep[] memory steps = _one(_step(true, 10e18));
        uint256 held = venus.balanceOf(address(this));
        uint256 quote = yields.quoteWithdraw(ids[0], held);
        executor.setGlobalPaused(true);
        vm.expectRevert(AtpExecutor.ExecutorPaused.selector);
        executor.executeWithdraw(address(this), ids[0], held, quote, block.timestamp);
        vm.expectRevert(AtpExecutor.ExecutorPaused.selector);
        executor.executeRebalance(address(this), steps, block.timestamp);
        assertEq(venus.redeem(held), 0);
        yields.reconcile(address(this), ids[0]);
        assertEq(yields.totalUnits(ids[0]), 0);
        assertEq(usdt.balanceOf(address(this)), 1_000e18);
        _assertNoSwapCharge();
    }

    function _supply(uint256 i) private {
        executor.executeSupply(
            address(this), ids[i], 100e18, yields.quoteSupply(ids[i], address(this), 100e18), block.timestamp
        );
    }

    function _setLiquidity(uint256 i, uint256 amount) private {
        if (i == 0) venus.setLiquidity(amount);
        else if (i == 1) lista.setLiquidity(amount);
        else aave.setLiquidity(amount);
    }

    function _assertNoSwapCharge() private view {
        (uint64 start, uint192 bought) = executor.buyWindowOf(address(this));
        assertEq(start, 0);
        assertEq(bought, 0);
        (uint64 feeStart, uint192 notional, uint256 paid) = executor.minFeeWindowOf(address(this));
        assertEq(feeStart, 0);
        assertEq(notional, 0);
        assertEq(paid, 0);
        assertEq(usdt.balanceOf(FEE_RECIPIENT), 0);
        assertEq(asset.balanceOf(FEE_RECIPIENT), 0);
    }
}
