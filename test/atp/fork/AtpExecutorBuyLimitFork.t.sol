// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { ForkPoolHelpers } from "./ForkPoolHelpers.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { AtpExecutor } from "../../../src/atp/AtpExecutor.sol";
import { AtpRegistry } from "../../../src/atp/AtpRegistry.sol";
import { AtpMultiPoolOracle } from "../../../src/atp/AtpMultiPoolOracle.sol";
import { IOracleFloor } from "../../../src/atp/interfaces/IOracleFloor.sol";
import { IUniversalRouter } from "../../../src/atp/interfaces/IUniversalRouter.sol";
import { IV3Factory, MockSmartAccount } from "./AtpExecutorFork.t.sol";

/// @notice A10-1 negative tests on a BSC mainnet fork (cre8-contracts#10): the account calls the executor
/// directly, exactly what a leaked session key reaches through the Kernel CallPolicy (`account ->
/// executeRebalance`), and every swap really runs through the PCS V3 Universal Router on the live WBNB/USDT
/// pool, priced by the production oracle router. A real Kernel + session key + bundler UserOp version is X1's
/// (A3), per the #10 decision.
/// @dev Covered: an A -> USDT -> A round trip is stopped once the window's buys reach the cap; a buy above the
/// cap reverts; sales to USDT still go through with the cap spent and are not counted; the cap is back in the
/// next 24-hour window. Swap fee and minimum batch fee are 0 so each step only has to clear the oracle floor (1%
/// slippage on WBNB); the minimum fee on the fork is AtpExecutorMinFeeFork.t.sol.
/// @dev Without `BSC_RPC_URL` the suite is skipped, never passed.
contract AtpExecutorBuyLimitForkTest is ForkPoolHelpers {
    address internal constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address internal constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address internal constant V3_FACTORY = 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865;
    address internal constant V3_UNIVERSAL_ROUTER = 0x1A0A18AC4BECDDbd6389559687d1A73d8927E416;
    address internal constant PERMIT2 = 0x31c2F6fcFf4F8759b3Bd5Bf0e1084A055615c768;
    address internal constant FEE_RECIPIENT = address(0xFEE);
    uint256 internal constant DEPOSIT = 100e18; // 100 USDT

    AtpRegistry internal registry;
    AtpMultiPoolOracle internal router;
    AtpExecutor internal executor;
    MockSmartAccount internal account;
    uint24 internal fee;
    address internal pool;

    function setUp() public {
        string memory rpc = vm.envOr("BSC_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);
        assertEq(block.chainid, 56, "fork is BSC mainnet (56)");

        fee = 500;
        pool = IV3Factory(V3_FACTORY).getPool(WBNB, USDT, fee);
        if (pool == address(0)) {
            fee = 2500;
            pool = IV3Factory(V3_FACTORY).getPool(WBNB, USDT, fee);
        }
        assertTrue(pool != address(0), "no WBNB/USDT pool");

        registry = new AtpRegistry();
        router = new AtpMultiPoolOracle(USDT);
        router.setOracle(WBNB, pool, 30 minutes, 100, 1 hours);
        executor = new AtpExecutor(
            registry,
            IUniversalRouter(V3_UNIVERSAL_ROUTER),
            IOracleFloor(address(router)),
            PERMIT2,
            FEE_RECIPIENT,
            USDT,
            10_000,
            0
        );

        account = new MockSmartAccount();
        uint256 id = registry.registerStrategy("WBNB/USDT", "buy limit fork", true);
        address[] memory assets = new address[](2);
        assets[0] = WBNB;
        assets[1] = USDT;
        uint16[] memory weights = new uint16[](2);
        weights[0] = 5_000;
        weights[1] = 5_000;
        registry.publishVersion(id, assets, weights, bytes32(0), 0);
        vm.prank(address(account));
        registry.enroll(address(account), id);

        deal(USDT, address(account), DEPOSIT);
        account.approveToken(USDT, address(executor), type(uint256).max);
        account.approveToken(WBNB, address(executor), type(uint256).max);
    }

    // ---- fixtures ----

    /// @dev One exact-input V3 hop paying the executor, `amountOutMin` = the oracle floor (no swap fee).
    function _step(address tokenIn, address tokenOut, uint256 amountIn)
        internal
        view
        returns (AtpExecutor.SwapStep memory step)
    {
        (, uint256 minimum) = router.previewSwap(tokenIn, tokenOut, amountIn);
        step.tokenIn = tokenIn;
        step.tokenOut = tokenOut;
        step.amountIn = amountIn;
        step.amountOutMin = minimum;
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(
            address(executor), amountIn, minimum, abi.encodePacked(tokenIn, fee, tokenOut), true
        );
        step.venue = V3_UNIVERSAL_ROUTER;
        step.data = abi.encode(hex"00", inputs);
    }

    function _buy(uint256 usdtIn) internal view returns (AtpExecutor.SwapStep memory) {
        return _step(USDT, WBNB, usdtIn);
    }

    function _sellAll() internal view returns (AtpExecutor.SwapStep memory) {
        return _step(WBNB, USDT, IERC20(WBNB).balanceOf(address(account)));
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
        account.executeRebalance(address(executor), steps, block.timestamp + 300);
    }

    /// @dev Steps are built (oracle reads included) before the expectation is armed.
    function _execExpectLimit(AtpExecutor.SwapStep[] memory steps) internal {
        uint256 deadline = block.timestamp + 300;
        vm.expectPartialRevert(AtpExecutor.BuyLimitExceeded.selector);
        account.executeRebalance(address(executor), steps, deadline);
    }

    function _bought() internal view returns (uint256 bought) {
        (, bought) = executor.buyWindowOf(address(account));
    }

    function _usdt() internal view returns (uint256) {
        return IERC20(USDT).balanceOf(address(account));
    }

    function _wbnb() internal view returns (uint256) {
        return IERC20(WBNB).balanceOf(address(account));
    }

    // ---- tests ----

    function test_fork_roundTripIsBlockedOnceTheCapIsSpent() public {
        _exec(_one(_buy(DEPOSIT))); // all-in: buys = 100 USDT = the whole account value
        assertEq(_bought(), DEPOSIT, "buy counted");
        uint256 wbnb = _wbnb();
        assertGt(wbnb, 0, "WBNB bought");

        // A -> USDT -> A: the sale would go through, the buy-back hits the cap and reverts the whole batch.
        _execExpectLimit(_two(_sellAll(), _buy(50e18)));
        assertEq(_wbnb(), wbnb, "nothing moved");
        assertEq(_bought(), DEPOSIT, "counter unchanged");
    }

    function test_fork_buyAboveTheCapReverts() public {
        _exec(_one(_buy(60e18)));
        // Account value ~ 40 USDT + 60 USDT of WBNB at the TWAP, so 60 + 50 > cap.
        _execExpectLimit(_one(_buy(40e18 + 10e18)));
        (uint256 cap, uint256 bought,) = executor.buyAllowance(address(account));
        assertEq(bought, 60e18);
        assertGt(cap, 90e18, "cap ~ account value");
        assertLt(cap, 110e18, "cap ~ account value");
    }

    function test_fork_salesGoThroughWithTheCapSpent_andAreNotCounted() public {
        _exec(_one(_buy(DEPOSIT)));
        _exec(_one(_sellAll()));
        assertEq(_wbnb(), 0, "sold everything");
        assertGt(_usdt(), 95e18, "exited to USDT (pool fee + slippage only)");
        assertEq(_bought(), DEPOSIT, "sale not counted");
    }

    function test_fork_capIsBackInTheNextWindow() public {
        _exec(_one(_buy(DEPOSIT)));
        _exec(_one(_sellAll()));
        uint256 opened = block.timestamp;

        // Same window: the cap is spent, any buy reverts.
        _execExpectLimit(_one(_buy(10e18)));

        // 24 hours later the window resets. The fork has no other traders, so one trade stands in for the live
        // WBNB market: without it the pool would look idle for a day and the oracle would fail closed
        // (`maxOracleAge`, cre8-contracts#25); the TWAP extrapolates the tick over the rest of the gap.
        vm.warp(opened + 1 days);
        _touch(pool);
        (, uint256 bought, uint64 endsAt) = executor.buyAllowance(address(account));
        assertEq(bought, 0, "expired window reads as empty");
        assertEq(endsAt, 0, "next buy opens a new window");

        uint256 usdtIn = _usdt();
        _exec(_one(_buy(usdtIn)));
        assertEq(_bought(), usdtIn, "new window counts from zero");
        assertGt(_wbnb(), 0, "bought again");
    }

    function test_fork_salesOnlyMode() public {
        _exec(_one(_buy(50e18)));
        executor.setMaxBuyBps(0); // this test is the registry owner

        _execExpectLimit(_one(_buy(10e18)));
        _exec(_one(_sellAll()));
        assertEq(_wbnb(), 0, "sales still go through with buys stopped");
    }
}
