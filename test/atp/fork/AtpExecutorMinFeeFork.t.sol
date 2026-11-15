// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { AtpExecutor } from "../../../src/atp/AtpExecutor.sol";
import { AtpRegistry } from "../../../src/atp/AtpRegistry.sol";
import { AtpMultiPoolOracle } from "../../../src/atp/AtpMultiPoolOracle.sol";
import { IOracleFloor } from "../../../src/atp/interfaces/IOracleFloor.sol";
import { IUniversalRouter } from "../../../src/atp/interfaces/IUniversalRouter.sol";
import { IV3Factory, MockSmartAccount } from "./AtpExecutorFork.t.sol";

/// @notice The minimum batch fee (cre8-contracts#33) on a BSC mainnet fork: real USDT, the live WBNB/USDT
/// Pancake V3 pool through the Universal Router, the production oracle router, 10 bps proportional fee and the
/// 0.30 USDT minimum. Every step is sent at `amountOutMin = minGross` (the oracle floor grossed up over the
/// 10 bps only), so these tests also show the minimum fee is not grossed into the floor: a real pool clears the
/// same bound with or without it. The oracle uses a 5% slippage budget so the buys do not depend on where the
/// live spot sits against the TWAP (the fee arithmetic is independent of it).
/// @dev Without `BSC_RPC_URL` the suite is skipped, never passed.
contract AtpExecutorMinFeeForkTest is Test {
    address internal constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address internal constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address internal constant V3_FACTORY = 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865;
    address internal constant V3_UNIVERSAL_ROUTER = 0x1A0A18AC4BECDDbd6389559687d1A73d8927E416;
    address internal constant PERMIT2 = 0x31c2F6fcFf4F8759b3Bd5Bf0e1084A055615c768;
    /// @dev A fresh address: 0xFEE holds real USDT on mainnet, which would pollute the balance checks.
    address internal immutable FEE_RECIPIENT = makeAddr("minFeeRecipient");
    uint16 internal constant FEE_BPS = 10;
    uint256 internal constant MIN_FEE = 0.3e18;
    uint256 internal constant BPS = 10_000;

    AtpRegistry internal registry;
    AtpMultiPoolOracle internal router;
    AtpExecutor internal executor;
    MockSmartAccount internal account;
    uint24 internal fee;
    uint256 internal strategyId;

    function setUp() public {
        string memory rpc = vm.envOr("BSC_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);
        assertEq(block.chainid, 56, "fork is BSC mainnet (56)");

        fee = 500;
        address pool = IV3Factory(V3_FACTORY).getPool(WBNB, USDT, fee);
        if (pool == address(0)) {
            fee = 2500;
            pool = IV3Factory(V3_FACTORY).getPool(WBNB, USDT, fee);
        }
        assertTrue(pool != address(0), "no WBNB/USDT pool");

        registry = new AtpRegistry();
        registry.setDefaultFeeBps(FEE_BPS);
        router = new AtpMultiPoolOracle(USDT);
        // 5% slippage, not production's 1%: these tests are about the fee split, and a buy at a 1% floor reverts
        // in the pool whenever the live spot has run more than 1% above the 30-minute TWAP.
        router.setOracle(WBNB, pool, 30 minutes, 500, 1 hours);
        executor = new AtpExecutor(
            registry,
            IUniversalRouter(V3_UNIVERSAL_ROUTER),
            IOracleFloor(address(router)),
            PERMIT2,
            FEE_RECIPIENT,
            USDT,
            20_000,
            MIN_FEE
        );

        account = new MockSmartAccount();
        strategyId = registry.registerStrategy("WBNB/USDT", "min fee fork", true);
        address[] memory assets = new address[](2);
        assets[0] = WBNB;
        assets[1] = USDT;
        uint16[] memory weights = new uint16[](2);
        weights[0] = 5_000;
        weights[1] = 5_000;
        registry.publishVersion(strategyId, assets, weights, bytes32(0), 0);
        vm.prank(address(account));
        registry.enroll(address(account), strategyId);

        account.approveToken(USDT, address(executor), type(uint256).max);
        account.approveToken(WBNB, address(executor), type(uint256).max);
    }

    // ---- fixtures ----

    function _step(address tokenIn, address tokenOut, uint256 amountIn)
        internal
        view
        returns (AtpExecutor.SwapStep[] memory steps)
    {
        (, uint256 minimum) = router.previewSwap(tokenIn, tokenOut, amountIn);
        uint256 minGross = Math.mulDiv(minimum, BPS, BPS - FEE_BPS, Math.Rounding.Ceil);
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(
            address(executor), amountIn, minGross, abi.encodePacked(tokenIn, fee, tokenOut), true
        );
        steps = new AtpExecutor.SwapStep[](1);
        steps[0] = AtpExecutor.SwapStep({
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            amountIn: amountIn,
            amountOutMin: minGross,
            venue: V3_UNIVERSAL_ROUTER,
            data: abi.encode(hex"00", inputs)
        });
    }

    function _exec(AtpExecutor.SwapStep[] memory steps) internal {
        account.executeRebalance(address(executor), steps, block.timestamp + 300);
    }

    function _usdt(address who) internal view returns (uint256) {
        return IERC20(USDT).balanceOf(who);
    }

    function _expectedTotal(uint256 notional) internal pure returns (uint256) {
        return Math.max(notional * FEE_BPS / BPS, Math.min(MIN_FEE, notional / 100));
    }

    // ---- tests ----

    function test_fork_buy50_paysTheTopUpInUsdt() public {
        deal(USDT, address(account), 60e18);
        _exec(_step(USDT, WBNB, 50e18));
        assertEq(_usdt(FEE_RECIPIENT), MIN_FEE - 0.05e18, "0.30 - 0.05 proportional (taken in WBNB)");
        assertEq(_usdt(address(account)), 10e18 - (MIN_FEE - 0.05e18), "50 spent + top-up");
        assertGt(IERC20(WBNB).balanceOf(FEE_RECIPIENT), 0, "proportional fee still taken in WBNB");
        assertEq(_usdt(address(executor)), 0, "executor keeps nothing");
    }

    function test_fork_buy400_paysNoTopUp() public {
        deal(USDT, address(account), 400e18);
        _exec(_step(USDT, WBNB, 400e18));
        assertEq(_usdt(FEE_RECIPIENT), 0, "proportional 0.40 > 0.30");
        assertEq(_usdt(address(account)), 0);
    }

    function test_fork_fullExit_paysMaxOfProportionalAndMinimum() public {
        deal(USDT, address(account), 100e18);
        _exec(_step(USDT, WBNB, 100e18)); // all-in: no USDT left, the top-up could not be paid (charged 0)
        assertEq(_usdt(address(account)), 0);
        uint256 feeBefore = _usdt(FEE_RECIPIENT);

        _exec(_step(WBNB, USDT, IERC20(WBNB).balanceOf(address(account))));
        assertEq(IERC20(WBNB).balanceOf(address(account)), 0, "exited");
        uint256 feeTaken = _usdt(FEE_RECIPIENT) - feeBefore;
        uint256 gross = _usdt(address(account)) + feeTaken;
        assertGt(gross, 95e18, "pool fee + slippage only");
        // cre8-contracts#47: the buy and the exit share one minimum-fee window, which pays as one batch of
        // ~200 USDT: max(0.1%, min(0.30, 1%)) of the window, i.e. 0.30 in all, less the buy's 0.1% (taken in WBNB).
        // The exit pays its own 0.1% plus the window's remaining top-up, ~0.20 instead of a fresh 0.30.
        uint256 windowTopUp = _expectedTotal(100e18 + gross) - (100e18 + gross) * FEE_BPS / BPS;
        assertEq(
            feeTaken, gross * FEE_BPS / BPS + windowTopUp, "the exit's 0.1% + the window's remaining top-up"
        );
        assertLt(feeTaken, MIN_FEE, "less than a second 0.30 minimum");
        (, uint192 notional, uint256 paid) = executor.minFeeWindowOf(address(account));
        assertEq(notional, 100e18 + gross);
        assertEq(paid, windowTopUp);
    }

    function test_fork_dustExit_goesThroughAtOnePercent() public {
        deal(WBNB, address(account), 0.0002 ether); // ~0.1-0.2 USDT, below the 0.30 minimum
        _exec(_step(WBNB, USDT, 0.0002 ether));
        assertEq(IERC20(WBNB).balanceOf(address(account)), 0, "exited");
        uint256 feeTaken = _usdt(FEE_RECIPIENT);
        uint256 gross = _usdt(address(account)) + feeTaken;
        assertLt(gross, MIN_FEE, "residual below the minimum");
        assertEq(feeTaken, gross / 100, "1% of the residual, never the full 0.30");
    }
}
