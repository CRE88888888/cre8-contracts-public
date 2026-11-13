// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";
import { AtpExecutor } from "../../src/atp/AtpExecutor.sol";
import { AtpRegistry } from "../../src/atp/AtpRegistry.sol";
import { IOracleFloor } from "../../src/atp/interfaces/IOracleFloor.sol";
import { IUniversalRouter } from "../../src/atp/interfaces/IUniversalRouter.sol";
import { MockPermit2 } from "./AtpExecutor.t.sol";

/// @dev ERC20 with free mint/burn so the router stub can really consume the input and pay the output.
contract BurnableToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function burn(address from, uint256 amount) external {
        balanceOf[from] -= amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev Fixed-price oracle: `price[asset]` numeraire units per 1e18 asset units, no slippage (minimum = quote).
/// A zero price makes every quote of that asset revert, standing in for a stale or cleared oracle. Pairs
/// without the numeraire are quoted 1:1 so the executor's own route check is what rejects them.
contract PricedOracle is IOracleFloor {
    address public immutable numeraire;
    mapping(address => uint256) public price;

    constructor(address numeraire_) {
        numeraire = numeraire_;
    }

    function setPrice(address asset, uint256 price_) external {
        price[asset] = price_;
    }

    function previewSwap(address tokenIn, address tokenOut, uint256 amountIn)
        external
        view
        returns (uint256 quoted, uint256 minimum)
    {
        require(amountIn != 0, "zero");
        if (tokenOut == numeraire) {
            require(price[tokenIn] != 0, "stale");
            quoted = amountIn * price[tokenIn] / 1e18;
        } else if (tokenIn == numeraire) {
            require(price[tokenOut] != 0, "stale");
            quoted = amountIn * 1e18 / price[tokenOut];
        } else {
            quoted = amountIn;
        }
        minimum = quoted;
    }
}

/// @dev Router stub that executes a single V3_SWAP_EXACT_IN for real: burns `amountIn` of the path's input
/// from the caller (the executor) and mints exactly `amountOutMin` of the path's output to the recipient.
contract PricedRouter is IUniversalRouter {
    function execute(bytes calldata, bytes[] calldata inputs, uint256) external payable {
        (address recipient, uint256 amountIn, uint256 amountOutMin, bytes memory path,) =
            abi.decode(inputs[0], (address, uint256, uint256, bytes, bool));
        address tokenIn;
        address tokenOut;
        assembly {
            tokenIn := shr(96, mload(add(path, 32)))
            tokenOut := shr(96, mload(add(path, 55)))
        }
        BurnableToken(tokenIn).burn(msg.sender, amountIn);
        BurnableToken(tokenOut).mint(recipient, amountOutMin);
    }
}

/// @notice Pins A10-1 (cre8-contracts#10): per account and fixed 24-hour window, buys (numeraire -> asset)
/// total at most `maxBuyBps` of the account's current value; sales to the numeraire are never limited nor
/// counted; only the registry owner sets the cap. This test contract is the registry owner and the enrolled
/// account (it has code), with A priced at 2 and B at 0.5 numeraire units and no swap fee.
contract AtpExecutorBuyLimitTest is Test {
    address internal constant OPERATOR = address(0x0FE7);
    address internal constant OUTSIDER = address(0xCAFE);
    address internal constant FEE_RECIPIENT = address(0xFEE);

    AtpRegistry internal registry;
    AtpExecutor internal executor;
    PricedOracle internal oracle;
    PricedRouter internal router;
    BurnableToken internal usdt;
    BurnableToken internal tokenA;
    BurnableToken internal tokenB;
    uint256 internal strategyId;

    function setUp() public {
        usdt = new BurnableToken();
        tokenA = new BurnableToken();
        tokenB = new BurnableToken();
        oracle = new PricedOracle(address(usdt));
        oracle.setPrice(address(tokenA), 2e18);
        oracle.setPrice(address(tokenB), 0.5e18);
        router = new PricedRouter();

        registry = new AtpRegistry();
        registry.setOperator(OPERATOR);
        executor = new AtpExecutor(
            registry, router, oracle, address(new MockPermit2()), FEE_RECIPIENT, address(usdt), 10_000
        );

        address[] memory assets = new address[](3);
        assets[0] = address(usdt);
        assets[1] = address(tokenA);
        assets[2] = address(tokenB);
        uint16[] memory weights = new uint16[](3);
        weights[0] = 2_000;
        weights[1] = 4_000;
        weights[2] = 4_000;
        strategyId = registry.registerStrategy("index", "buy limit", true);
        registry.publishVersion(strategyId, assets, weights, keccak256("schedule"), 0);
        registry.enroll(address(this), strategyId);

        usdt.approve(address(executor), type(uint256).max);
        tokenA.approve(address(executor), type(uint256).max);
        tokenB.approve(address(executor), type(uint256).max);
        usdt.mint(address(this), 1_000e18);
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
        step.venue = address(router); // the Universal Router venue registered at construction
        step.data = abi.encode(hex"00", inputs);
    }

    function _run(AtpExecutor.SwapStep memory a) internal {
        AtpExecutor.SwapStep[] memory steps = new AtpExecutor.SwapStep[](1);
        steps[0] = a;
        executor.executeRebalance(address(this), steps, block.timestamp + 300);
    }

    function _run(AtpExecutor.SwapStep memory a, AtpExecutor.SwapStep memory b) internal {
        AtpExecutor.SwapStep[] memory steps = new AtpExecutor.SwapStep[](2);
        steps[0] = a;
        steps[1] = b;
        executor.executeRebalance(address(this), steps, block.timestamp + 300);
    }

    function _buy(BurnableToken asset, uint256 usdtIn) internal view returns (AtpExecutor.SwapStep memory) {
        return _step(address(usdt), address(asset), usdtIn);
    }

    function _sell(BurnableToken asset, uint256 amountIn)
        internal
        view
        returns (AtpExecutor.SwapStep memory)
    {
        return _step(address(asset), address(usdt), amountIn);
    }

    function _bought() internal view returns (uint256 bought) {
        (, bought) = executor.buyWindowOf(address(this));
    }

    function _start() internal view returns (uint64 start) {
        (start,) = executor.buyWindowOf(address(this));
    }

    /// @dev The steps are built (oracle reads included) before `expectRevert` is armed, so the expectation
    /// binds to `executeRebalance` and not to a quote.
    function _runExpectLimit(AtpExecutor.SwapStep memory a, uint256 bought, uint256 cap) internal {
        AtpExecutor.SwapStep[] memory steps = new AtpExecutor.SwapStep[](1);
        steps[0] = a;
        _expectLimitOn(steps, bought, cap);
    }

    function _runExpectLimit(
        AtpExecutor.SwapStep memory a,
        AtpExecutor.SwapStep memory b,
        uint256 bought,
        uint256 cap
    ) internal {
        AtpExecutor.SwapStep[] memory steps = new AtpExecutor.SwapStep[](2);
        steps[0] = a;
        steps[1] = b;
        _expectLimitOn(steps, bought, cap);
    }

    function _expectLimitOn(AtpExecutor.SwapStep[] memory steps, uint256 bought, uint256 cap) internal {
        uint256 deadline = block.timestamp + 300;
        vm.expectRevert(abi.encodeWithSelector(AtpExecutor.BuyLimitExceeded.selector, bought, cap));
        executor.executeRebalance(address(this), steps, deadline);
    }

    // ---- configuration ----

    function test_constructor_storesNumeraireAndCap() public view {
        assertEq(executor.numeraire(), address(usdt));
        assertEq(executor.maxBuyBps(), 10_000);
        assertEq(executor.BUY_WINDOW(), 1 days);
    }

    function test_constructor_rejectsCapAboveCeiling() public {
        MockPermit2 permit2 = new MockPermit2();
        vm.expectRevert(abi.encodeWithSelector(AtpExecutor.BuyBpsTooHigh.selector, uint16(20_001)));
        new AtpExecutor(registry, router, oracle, address(permit2), FEE_RECIPIENT, address(usdt), 20_001);
    }

    function test_constructor_rejectsNumeraireWithoutCode() public {
        MockPermit2 permit2 = new MockPermit2();
        vm.expectRevert(AtpExecutor.InvalidConfig.selector);
        new AtpExecutor(registry, router, oracle, address(permit2), FEE_RECIPIENT, address(0xDEAD), 10_000);
    }

    function test_setMaxBuyBps_onlyRegistryOwnerAndBounded() public {
        vm.prank(OUTSIDER);
        vm.expectRevert(AtpExecutor.NotOwner.selector);
        executor.setMaxBuyBps(20_000);

        // The operator can never loosen (or touch) the cap.
        vm.prank(OPERATOR);
        vm.expectRevert(AtpExecutor.NotOwner.selector);
        executor.setMaxBuyBps(20_000);

        vm.expectRevert(abi.encodeWithSelector(AtpExecutor.BuyBpsTooHigh.selector, uint16(20_001)));
        executor.setMaxBuyBps(20_001);

        vm.expectEmit(false, false, false, true, address(executor));
        emit AtpExecutor.MaxBuyBpsSet(20_000);
        executor.setMaxBuyBps(20_000);
        assertEq(executor.maxBuyBps(), 20_000);
    }

    // ---- buys are counted and capped ----

    function test_buyWithinCap_isCountedAndReported() public {
        _run(_buy(tokenA, 600e18));
        assertEq(_bought(), 600e18, "spend recorded");
        assertEq(_start(), block.timestamp, "window opened by the first buy");

        (uint256 cap, uint256 bought, uint64 endsAt) = executor.buyAllowance(address(this));
        assertEq(cap, 1_000e18, "400 USDT + 300 A x 2");
        assertEq(bought, 600e18);
        assertEq(endsAt, block.timestamp + 1 days);
    }

    function test_buyExactlyAtCap_isAllowed() public {
        _run(_buy(tokenA, 1_000e18));
        assertEq(_bought(), 1_000e18);
    }

    function test_buyAboveCap_reverts() public {
        _run(_buy(tokenA, 600e18));
        _runExpectLimit(_buy(tokenB, 500e18), 1_100e18, 1_000e18);
    }

    function test_batchingCannotBypassTheCap() public {
        _runExpectLimit(_buy(tokenA, 600e18), _buy(tokenB, 500e18), 1_100e18, 1_000e18);
        assertEq(_bought(), 0, "a reverted batch records nothing");
    }

    function test_roundTrip_isBlockedOnceTheCapIsSpent() public {
        _run(_buy(tokenA, 1_000e18)); // 500 A, cap spent
        // A -> USDT -> A again: the sale goes through inside the batch, the buy-back hits the cap.
        _runExpectLimit(_sell(tokenA, 500e18), _buy(tokenA, 1_000e18), 2_000e18, 1_000e18);
        assertEq(tokenA.balanceOf(address(this)), 500e18, "whole batch reverted");
    }

    // ---- sales are never limited nor counted ----

    function test_sales_goThroughWhenTheCapIsSpent_andAreNotCounted() public {
        _run(_buy(tokenA, 1_000e18));
        _run(_sell(tokenA, 500e18));
        assertEq(usdt.balanceOf(address(this)), 1_000e18, "exited to USDT");
        assertEq(_bought(), 1_000e18, "sale did not move the counter");
    }

    function test_salesOnlyBatch_opensNoWindow() public {
        tokenA.mint(address(this), 100e18);
        _run(_sell(tokenA, 100e18));
        assertEq(_start(), 0, "no window, no valuation");
        assertEq(_bought(), 0);
    }

    function test_maxBuyBpsZero_isSalesOnly() public {
        tokenA.mint(address(this), 100e18);
        executor.setMaxBuyBps(0);

        _runExpectLimit(_buy(tokenB, 1e18), 1e18, 0);
        _run(_sell(tokenA, 100e18));
        assertEq(tokenA.balanceOf(address(this)), 0, "sale still went through");
    }

    // ---- the window ----

    function test_window_resetsAfter24Hours() public {
        _run(_buy(tokenA, 1_000e18));
        uint256 opened = block.timestamp;

        vm.warp(opened + 1 days - 1);
        _runExpectLimit(_buy(tokenB, 1), 1_000e18 + 1, 1_000e18);

        vm.warp(opened + 1 days);
        (uint256 cap, uint256 bought, uint64 endsAt) = executor.buyAllowance(address(this));
        assertEq(bought, 0, "expired window reads as empty");
        assertEq(endsAt, 0, "next buy opens a new window");
        assertEq(cap, 1_000e18);

        _sellAllA();
        _run(_buy(tokenB, 1_000e18));
        assertEq(_start(), opened + 1 days, "new window");
        assertEq(_bought(), 1_000e18);
    }

    function _sellAllA() internal {
        _run(_sell(tokenA, tokenA.balanceOf(address(this))));
    }

    // ---- the cap follows the current value ----

    function test_cap_growsWithADeposit() public {
        _run(_buy(tokenA, 1_000e18));
        usdt.mint(address(this), 500e18); // top-up within the same window
        _run(_buy(tokenB, 500e18));
        assertEq(_bought(), 1_500e18, "cap = 1500 after the deposit");
    }

    function test_cap_scalesWithMaxBuyBps() public {
        executor.setMaxBuyBps(5_000);
        _runExpectLimit(_buy(tokenA, 600e18), 600e18, 500e18);
        _run(_buy(tokenA, 500e18));
    }

    function test_unpriceableAsset_countsAsZero() public {
        _run(_buy(tokenA, 600e18)); // 400 USDT + 300 A
        oracle.setPrice(address(tokenA), 0); // A's oracle now reverts

        (uint256 cap,,) = executor.buyAllowance(address(this));
        assertEq(cap, 400e18, "A dropped out of the value: cap shrinks, never grows");
        _runExpectLimit(_buy(tokenB, 100e18), 700e18, 400e18);
    }

    function test_tokensOutsideTheVersionDoNotCount() public {
        BurnableToken stray = new BurnableToken();
        oracle.setPrice(address(stray), 1e18);
        stray.mint(address(this), 1_000_000e18);
        (uint256 cap,,) = executor.buyAllowance(address(this));
        assertEq(cap, 1_000e18, "only the pinned version's assets are valued");
    }

    // ---- misc ----

    function test_stepWithoutNumeraire_isRejected() public {
        tokenA.mint(address(this), 10e18);
        AtpExecutor.SwapStep[] memory steps = new AtpExecutor.SwapStep[](1);
        steps[0] = _step(address(tokenA), address(tokenB), 10e18);
        uint256 deadline = block.timestamp + 300;
        vm.expectRevert(
            abi.encodeWithSelector(AtpExecutor.NotNumeraireRoute.selector, address(tokenA), address(tokenB))
        );
        executor.executeRebalance(address(this), steps, deadline);
    }

    function test_buyAllowance_isZeroForAnUnenrolledAccount() public view {
        (uint256 cap, uint256 bought, uint64 endsAt) = executor.buyAllowance(OUTSIDER);
        assertEq(cap, 0);
        assertEq(bought, 0);
        assertEq(endsAt, 0);
    }

    /// @dev Whatever buys the account attempts within one window, what got through never exceeds the cap
    /// the executor computed for the last successful buy, and every rejection is the buy limit.
    function testFuzz_buysWithinOneWindowNeverExceedTheCap(uint96[6] calldata amounts) public {
        uint256 spent;
        for (uint256 i; i < amounts.length; ++i) {
            uint256 amount = bound(amounts[i], 1e12, 600e18);
            BurnableToken asset = i % 2 == 0 ? tokenA : tokenB;
            if (amount > usdt.balanceOf(address(this))) break;
            (uint256 cap,,) = executor.buyAllowance(address(this));
            if (spent + amount > cap) {
                _runExpectLimit(_buy(asset, amount), spent + amount, cap);
            } else {
                _run(_buy(asset, amount));
                spent += amount;
            }
            assertEq(_bought(), spent, "counter tracks successful buys only");
            assertLe(spent, 1_000e18, "never above the account value at a 100% cap");
        }
    }
}
