// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import "./AtpExecutorBuyLimit.t.sol";
import { AtpYieldRegistry } from "../../src/atp/yield/AtpYieldRegistry.sol";
import { YieldTypes as Y } from "../../src/atp/yield/YieldTypes.sol";
import { TestnetToken } from "../../src/testnet/TestnetToken.sol";
import { MockVenus } from "../../src/testnet/yield/MockVenus.sol";
import { YieldReaderHarness } from "./AtpYieldSafety.t.sol";

contract AtpYieldBuyGasTest is AtpExecutorBuyLimitTest {
    function test_review12_buyGas_emptyRegistry() public {
        _measure(0);
    }

    function test_review12_buyGas_30Markets_noPositions() public {
        _measure(30);
    }

    function _measure(uint256 count) private {
        vm.chainId(97);
        AtpYieldRegistry yields = executor.yieldRegistry();
        for (uint256 i; i < count; ++i) {
            TestnetToken token = new TestnetToken("background", "BG", 18, address(this));
            MockVenus v = new MockVenus(token, address(this), 0);
            Y.Market memory m = Y.Market(
                97,
                Y.Kind.VENUS,
                address(token),
                address(v),
                address(v),
                address(v),
                bytes32(uint256(1)),
                1e27,
                1e30,
                true,
                false
            );
            yields.registerMarket(bytes32(i + 1), m);
            vm.cool(address(v));
        }
        AtpExecutor.SwapStep[] memory steps = new AtpExecutor.SwapStep[](1);
        steps[0] = _buy(tokenA, 100e18);
        vm.cool(address(yields));
        uint256 before = gasleft();
        executor.executeRebalance(address(this), steps, block.timestamp);
        uint256 gasUsed = before - gasleft();
        emit log_named_uint("BUY_GAS", gasUsed);
        assertLt(gasUsed, 600_000, "unheld markets must not be scanned on each buy");
        assertGt(tokenA.balanceOf(address(this)), 0);
    }
}
