// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test, stdError } from "forge-std/Test.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { AtpExecutor } from "../../src/atp/AtpExecutor.sol";
import { AtpRegistry } from "../../src/atp/AtpRegistry.sol";
import { BurnableToken, PricedOracle, PricedRouter } from "./AtpExecutorBuyLimit.t.sol";

/// @dev Permit2 stand-in that really moves tokens: per (owner, token, spender) allowance, consumed on
/// `transferFrom`, which then pulls with the owner's ERC20 allowance to this contract (same two legs as Permit2).
contract FunctionalPermit2 {
    mapping(address => mapping(address => mapping(address => uint160))) public allowanceOf;

    function approve(address token, address spender, uint160 amount, uint48) external {
        allowanceOf[msg.sender][token][spender] = amount;
    }

    function transferFrom(address from, address to, uint160 amount, address token) external {
        uint160 allowed = allowanceOf[from][token][msg.sender];
        require(allowed >= amount, "permit2 allowance");
        allowanceOf[from][token][msg.sender] = allowed - amount;
        BurnableToken(token).transferFrom(from, to, amount);
    }
}

/// @dev An aggregator stand-in that is honest or malicious on demand. The executor calls `swap(...)` with the
/// step's raw `data`; `msg.sender` is the executor. `victim` / `stray` are set by the test.
contract EvilVenue {
    enum Mode {
        Honest, // pull amountIn, pay amountOut to the executor
        TakeNoPay, // pull amountIn, pay nothing
        PayElsewhere, // pull amountIn, pay amountOut to someone else
        PullMore, // try to pull amountIn + 1
        PullFromAccount, // try to pull from the account instead of the executor
        PullStray, // try to pull a token the executor happens to hold but never approved
        Reenter, // call back into executeRebalance
        PullHalf, // pull half, pay amountOut (the rest must go back to the account)
        CallAdmin // try the executor's admin functions mid-swap
    }

    address public victim;
    BurnableToken public stray;
    FunctionalPermit2 public permit2; // set for a PERMIT2-kind venue

    function configure(address victim_, BurnableToken stray_, FunctionalPermit2 permit2_) external {
        victim = victim_;
        stray = stray_;
        permit2 = permit2_;
    }

    function _pull(address token, address from, uint256 amount) internal {
        if (address(permit2) != address(0)) {
            permit2.transferFrom(from, address(this), uint160(amount), token);
        } else {
            BurnableToken(token).transferFrom(from, address(this), amount);
        }
    }

    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut, Mode mode)
        external
    {
        if (mode == Mode.Honest) {
            _pull(tokenIn, msg.sender, amountIn);
            BurnableToken(tokenOut).mint(msg.sender, amountOut);
        } else if (mode == Mode.TakeNoPay) {
            _pull(tokenIn, msg.sender, amountIn);
        } else if (mode == Mode.PayElsewhere) {
            _pull(tokenIn, msg.sender, amountIn);
            BurnableToken(tokenOut).mint(address(0xBAD), amountOut);
        } else if (mode == Mode.PullMore) {
            _pull(tokenIn, msg.sender, amountIn + 1);
        } else if (mode == Mode.PullFromAccount) {
            _pull(tokenIn, victim, 1);
        } else if (mode == Mode.PullStray) {
            stray.transferFrom(msg.sender, address(this), 1);
        } else if (mode == Mode.Reenter) {
            AtpExecutor.SwapStep[] memory none;
            AtpExecutor(msg.sender).executeRebalance(victim, none, block.timestamp + 300);
        } else if (mode == Mode.PullHalf) {
            _pull(tokenIn, msg.sender, amountIn / 2);
            BurnableToken(tokenOut).mint(msg.sender, amountOut);
        } else if (mode == Mode.CallAdmin) {
            AtpExecutor(msg.sender)
                .setVenue(address(this), AtpExecutor.VenueKind.ERC20_APPROVE, address(this));
        }
    }

    /// @dev Outside any swap: what a venue could do with a leftover allowance or on its own initiative.
    function pullLater(address token, address from) external {
        BurnableToken(token).transferFrom(from, address(this), 1);
    }

    function startTrade(AtpExecutor executor, address account) external {
        AtpExecutor.SwapStep[] memory none;
        executor.executeRebalance(account, none, block.timestamp + 300);
    }
}

/// @notice Pins the venue allowlist (cre8-contracts#15 §1.2) and walks the §1.3 table: what a malicious or
/// compromised venue can and cannot do. This test contract is the registry owner and the enrolled account;
/// tokenA is priced at 2 USDT, there is no swap fee, and the mock oracle's floor equals its quote.
contract AtpExecutorVenuesTest is Test {
    address internal constant OPERATOR = address(0x0FE7);
    address internal constant OUTSIDER = address(0xCAFE);
    address internal constant FEE_RECIPIENT = address(0xFEE);

    AtpRegistry internal registry;
    AtpExecutor internal executor;
    PricedOracle internal oracle;
    PricedRouter internal ur;
    FunctionalPermit2 internal permit2;
    BurnableToken internal usdt;
    BurnableToken internal tokenA;
    EvilVenue internal venue;

    function setUp() public {
        usdt = new BurnableToken();
        tokenA = new BurnableToken();
        oracle = new PricedOracle(address(usdt));
        oracle.setPrice(address(tokenA), 2e18);
        ur = new PricedRouter();
        permit2 = new FunctionalPermit2();
        registry = new AtpRegistry();
        registry.setOperator(OPERATOR);
        executor =
            new AtpExecutor(registry, ur, oracle, address(permit2), FEE_RECIPIENT, address(usdt), 20_000);

        address[] memory assets = new address[](2);
        assets[0] = address(usdt);
        assets[1] = address(tokenA);
        uint16[] memory weights = new uint16[](2);
        weights[0] = 5_000;
        weights[1] = 5_000;
        uint256 id = registry.registerStrategy("index", "venues", true);
        registry.publishVersion(id, assets, weights, keccak256("schedule"), 0);
        registry.enroll(address(this), id);

        usdt.approve(address(executor), type(uint256).max);
        tokenA.approve(address(executor), type(uint256).max);
        usdt.mint(address(this), 1_000e18);

        venue = new EvilVenue();
        venue.configure(address(this), BurnableToken(address(0)), FunctionalPermit2(address(0)));
        executor.setVenue(address(venue), AtpExecutor.VenueKind.ERC20_APPROVE, address(venue));
    }

    // ---- fixtures ----

    /// @dev Buy `usdtIn` of tokenA through `venue_`, paying `amountOut` in `mode`. Floor = oracle quote.
    function _buyStep(address venue_, uint256 usdtIn, uint256 amountOut, EvilVenue.Mode mode)
        internal
        view
        returns (AtpExecutor.SwapStep[] memory steps)
    {
        (uint256 floor,) = oracle.previewSwap(address(usdt), address(tokenA), usdtIn);
        steps = new AtpExecutor.SwapStep[](1);
        steps[0] = AtpExecutor.SwapStep({
            tokenIn: address(usdt),
            tokenOut: address(tokenA),
            amountIn: usdtIn,
            amountOutMin: floor,
            venue: venue_,
            data: abi.encodeCall(EvilVenue.swap, (address(usdt), address(tokenA), usdtIn, amountOut, mode))
        });
    }

    function _floor(uint256 usdtIn) internal view returns (uint256 floor) {
        (floor,) = oracle.previewSwap(address(usdt), address(tokenA), usdtIn);
    }

    function _run(AtpExecutor.SwapStep[] memory steps) internal {
        executor.executeRebalance(address(this), steps, block.timestamp + 300);
    }

    function _assertUntouched() internal view {
        assertEq(usdt.balanceOf(address(this)), 1_000e18, "account USDT untouched");
        assertEq(tokenA.balanceOf(address(this)), 0, "account tokenA untouched");
        assertEq(usdt.balanceOf(address(executor)), 0, "executor holds nothing");
        assertEq(usdt.allowance(address(executor), address(venue)), 0, "no allowance left");
    }

    // ---- allowlist administration ----

    function test_universalRouter_isRegisteredAtConstruction() public view {
        (AtpExecutor.VenueKind kind, address spender) = executor.venues(address(ur));
        assertEq(uint8(kind), uint8(AtpExecutor.VenueKind.PANCAKE_UR));
        assertEq(spender, address(ur), "UR is its own Permit2 spender");
    }

    function test_setVenue_andRemoveVenue_onlyRegistryOwner() public {
        EvilVenue other = new EvilVenue();
        vm.prank(OUTSIDER);
        vm.expectRevert(AtpExecutor.NotOwner.selector);
        executor.setVenue(address(other), AtpExecutor.VenueKind.ERC20_APPROVE, address(other));

        // The operator can never widen (or narrow) where funds may be routed.
        vm.prank(OPERATOR);
        vm.expectRevert(AtpExecutor.NotOwner.selector);
        executor.setVenue(address(other), AtpExecutor.VenueKind.ERC20_APPROVE, address(other));
        vm.prank(OPERATOR);
        vm.expectRevert(AtpExecutor.NotOwner.selector);
        executor.removeVenue(address(venue));

        vm.expectEmit(true, false, false, true, address(executor));
        emit AtpExecutor.VenueSet(address(other), AtpExecutor.VenueKind.ERC20_APPROVE, address(other));
        executor.setVenue(address(other), AtpExecutor.VenueKind.ERC20_APPROVE, address(other));

        vm.expectEmit(true, false, false, false, address(executor));
        emit AtpExecutor.VenueRemoved(address(other));
        executor.removeVenue(address(other));
        (AtpExecutor.VenueKind kind,) = executor.venues(address(other));
        assertEq(uint8(kind), uint8(AtpExecutor.VenueKind.NONE));
    }

    function test_setVenue_rejectsBadConfig() public {
        vm.expectRevert(AtpExecutor.InvalidConfig.selector);
        executor.setVenue(address(venue), AtpExecutor.VenueKind.NONE, address(venue));
        vm.expectRevert(AtpExecutor.InvalidConfig.selector);
        executor.setVenue(address(0xDEAD), AtpExecutor.VenueKind.ERC20_APPROVE, address(venue)); // no code
        vm.expectRevert(AtpExecutor.InvalidConfig.selector);
        executor.setVenue(address(venue), AtpExecutor.VenueKind.ERC20_APPROVE, address(0xDEAD)); // spender no code

        address[5] memory protocol =
            [address(executor), address(registry), address(oracle), address(permit2), address(usdt)];
        for (uint256 i; i < protocol.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(AtpExecutor.BadVenue.selector, protocol[i]));
            executor.setVenue(protocol[i], AtpExecutor.VenueKind.ERC20_APPROVE, address(venue));
            vm.expectRevert(abi.encodeWithSelector(AtpExecutor.BadVenue.selector, protocol[i]));
            executor.setVenue(address(venue), AtpExecutor.VenueKind.ERC20_APPROVE, protocol[i]);
        }
    }

    function test_unknownOrRemovedVenue_isRejected() public {
        EvilVenue stranger = new EvilVenue();
        AtpExecutor.SwapStep[] memory steps =
            _buyStep(address(stranger), 100e18, _floor(100e18), EvilVenue.Mode.Honest);
        vm.expectRevert(abi.encodeWithSelector(AtpExecutor.VenueNotAllowed.selector, address(stranger)));
        _run(steps);

        executor.removeVenue(address(venue));
        steps = _buyStep(address(venue), 100e18, _floor(100e18), EvilVenue.Mode.Honest);
        vm.expectRevert(abi.encodeWithSelector(AtpExecutor.VenueNotAllowed.selector, address(venue)));
        _run(steps);
    }

    function test_venueOrSpender_cannotBeAStepTokenOrTheAccount() public {
        // A venue the Safe allowed that turns out to be a step token, or whose spender is one, or the account.
        executor.setVenue(address(tokenA), AtpExecutor.VenueKind.ERC20_APPROVE, address(tokenA));
        AtpExecutor.SwapStep[] memory steps = _buyStep(address(tokenA), 100e18, 0, EvilVenue.Mode.Honest);
        vm.expectRevert(abi.encodeWithSelector(AtpExecutor.BadVenue.selector, address(tokenA)));
        _run(steps);

        EvilVenue approvesTokenA = new EvilVenue();
        // (USDT itself is already refused by `setVenue` as the numeraire; tokenA is only caught per step.)
        executor.setVenue(address(approvesTokenA), AtpExecutor.VenueKind.ERC20_APPROVE, address(tokenA));
        steps = _buyStep(address(approvesTokenA), 100e18, 0, EvilVenue.Mode.Honest);
        vm.expectRevert(abi.encodeWithSelector(AtpExecutor.BadVenue.selector, address(approvesTokenA)));
        _run(steps);

        executor.setVenue(address(this), AtpExecutor.VenueKind.ERC20_APPROVE, address(this));
        steps = _buyStep(address(this), 100e18, 0, EvilVenue.Mode.Honest);
        vm.expectRevert(abi.encodeWithSelector(AtpExecutor.BadVenue.selector, address(this)));
        _run(steps);
    }

    // ---- an honest generic venue ----

    function test_erc20Venue_honestSwap_settlesAndZeroesTheAllowance() public {
        uint256 out = _floor(100e18) + 1e18;
        _run(_buyStep(address(venue), 100e18, out, EvilVenue.Mode.Honest));
        assertEq(tokenA.balanceOf(address(this)), out, "output returned to the account");
        assertEq(usdt.balanceOf(address(this)), 900e18, "exactly amountIn spent");
        assertEq(usdt.allowance(address(executor), address(venue)), 0, "allowance zeroed");
        (, uint192 bought) = executor.buyWindowOf(address(this));
        assertEq(bought, 100e18, "A10-1 counts a generic-venue buy");
    }

    function test_permit2Venue_honestSwap_settlesAndZeroesTheErc20Leg() public {
        EvilVenue p2Venue = new EvilVenue();
        p2Venue.configure(address(this), BurnableToken(address(0)), permit2);
        executor.setVenue(address(p2Venue), AtpExecutor.VenueKind.PERMIT2, address(p2Venue));

        uint256 out = _floor(100e18);
        _run(_buyStep(address(p2Venue), 100e18, out, EvilVenue.Mode.Honest));
        assertEq(tokenA.balanceOf(address(this)), out);
        assertEq(usdt.allowance(address(executor), address(permit2)), 0, "ERC20 leg to Permit2 zeroed");
        assertEq(
            permit2.allowanceOf(address(executor), address(usdt), address(p2Venue)), 0, "Permit2 leg used up"
        );

        // Pulling more than the step through Permit2 fails inside Permit2.
        AtpExecutor.SwapStep[] memory steps = _buyStep(address(p2Venue), 100e18, out, EvilVenue.Mode.PullMore);
        vm.expectRevert("permit2 allowance");
        _run(steps);
    }

    // ---- §1.3: what a malicious venue cannot do ----

    function test_takesTokenInPaysNothing_reverts() public {
        AtpExecutor.SwapStep[] memory steps = _buyStep(address(venue), 100e18, 0, EvilVenue.Mode.TakeNoPay);
        vm.expectRevert(abi.encodeWithSelector(AtpExecutor.BelowFloor.selector, 0, _floor(100e18)));
        _run(steps);
        _assertUntouched();
    }

    function test_paysSomeoneElse_reverts() public {
        AtpExecutor.SwapStep[] memory steps =
            _buyStep(address(venue), 100e18, _floor(100e18) * 2, EvilVenue.Mode.PayElsewhere);
        vm.expectRevert(abi.encodeWithSelector(AtpExecutor.BelowFloor.selector, 0, _floor(100e18)));
        _run(steps);
        _assertUntouched();
    }

    /// @dev The one thing a malicious venue CAN do: pay exactly the floor and keep the difference. That is the
    /// bound - the account still receives the oracle floor (after fee) for every step.
    function test_paysExactlyTheFloor_succeeds_lossIsBoundedByTheFloor() public {
        uint256 floor = _floor(100e18);
        _run(_buyStep(address(venue), 100e18, floor, EvilVenue.Mode.Honest));
        assertEq(tokenA.balanceOf(address(this)), floor, "account got exactly the floor");

        uint256 belowFloor = floor - 1;
        AtpExecutor.SwapStep[] memory steps =
            _buyStep(address(venue), 100e18, belowFloor, EvilVenue.Mode.Honest);
        vm.expectRevert(abi.encodeWithSelector(AtpExecutor.BelowFloor.selector, belowFloor, floor));
        _run(steps);
    }

    // ---- cre8-contracts#24: the step's own amountOutMin binds on chain, on every venue kind ----

    /// @dev A venue (or an aggregator API behind it) that pays above the oracle floor but below the step's
    /// amountOutMin is rejected; paying exactly amountOutMin settles. Generic venues get `amountOut` through
    /// opaque calldata, so the executor's own balance check is the only thing that can enforce the bound.
    function _assertAmountOutMinBinds(address venue_) internal {
        uint256 floor = _floor(100e18);
        uint256 minOut = floor + 1e18;
        uint256 between = floor + 0.5e18;

        AtpExecutor.SwapStep[] memory steps = _buyStep(venue_, 100e18, between, EvilVenue.Mode.Honest);
        steps[0].amountOutMin = minOut;
        vm.expectRevert(abi.encodeWithSelector(AtpExecutor.BelowFloor.selector, between, minOut));
        _run(steps);
        _assertUntouched();

        steps = _buyStep(venue_, 100e18, minOut, EvilVenue.Mode.Honest);
        steps[0].amountOutMin = minOut;
        _run(steps);
        assertEq(tokenA.balanceOf(address(this)), minOut, "account got exactly amountOutMin");
    }

    function test_amountOutMin_binds_erc20Venue() public {
        _assertAmountOutMinBinds(address(venue));
    }

    function test_amountOutMin_binds_permit2Venue() public {
        EvilVenue p2Venue = new EvilVenue();
        p2Venue.configure(address(this), BurnableToken(address(0)), permit2);
        executor.setVenue(address(p2Venue), AtpExecutor.VenueKind.PERMIT2, address(p2Venue));
        _assertAmountOutMinBinds(address(p2Venue));
    }

    /// @dev The Universal Router's own amountOutMin (inside `inputs`) is set below the step's: the router would
    /// accept the trade, the executor does not.
    function test_amountOutMin_binds_universalRouter() public {
        uint256 floor = _floor(100e18);
        uint256 minOut = floor + 1e18;
        uint256 between = floor + 0.5e18;
        AtpExecutor.SwapStep[] memory steps = _urStep(100e18, between, minOut);
        vm.expectRevert(abi.encodeWithSelector(AtpExecutor.BelowFloor.selector, between, minOut));
        _run(steps);
        _assertUntouched();

        _run(_urStep(100e18, minOut, minOut));
        assertEq(tokenA.balanceOf(address(this)), minOut, "account got exactly amountOutMin");
    }

    /// @dev `PricedRouter` pays exactly the router-level amountOutMin encoded in `inputs`.
    function _urStep(uint256 usdtIn, uint256 routerPays, uint256 stepMin)
        internal
        view
        returns (AtpExecutor.SwapStep[] memory steps)
    {
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(
            address(executor),
            usdtIn,
            routerPays,
            abi.encodePacked(address(usdt), uint24(500), address(tokenA)),
            true
        );
        steps = new AtpExecutor.SwapStep[](1);
        steps[0] = AtpExecutor.SwapStep({
            tokenIn: address(usdt),
            tokenOut: address(tokenA),
            amountIn: usdtIn,
            amountOutMin: stepMin,
            venue: address(ur),
            data: abi.encode(hex"00", inputs)
        });
    }

    function test_pullsMoreThanAmountIn_reverts() public {
        AtpExecutor.SwapStep[] memory steps = _buyStep(address(venue), 100e18, 0, EvilVenue.Mode.PullMore);
        vm.expectRevert(stdError.arithmeticError); // allowance is exactly amountIn
        _run(steps);
        _assertUntouched();
    }

    function test_pullsFromTheAccount_reverts() public {
        AtpExecutor.SwapStep[] memory steps =
            _buyStep(address(venue), 100e18, 0, EvilVenue.Mode.PullFromAccount);
        vm.expectRevert(stdError.arithmeticError); // the account approved the executor only
        _run(steps);
        _assertUntouched();
    }

    function test_pullsAStrayTokenFromTheExecutor_reverts() public {
        BurnableToken stray = new BurnableToken();
        stray.mint(address(executor), 5e18); // say someone sent the executor tokens by mistake
        venue.configure(address(this), stray, FunctionalPermit2(address(0)));
        AtpExecutor.SwapStep[] memory steps = _buyStep(address(venue), 100e18, 0, EvilVenue.Mode.PullStray);
        vm.expectRevert(stdError.arithmeticError); // never approved
        _run(steps);
        assertEq(stray.balanceOf(address(executor)), 5e18);
    }

    function test_reentry_reverts() public {
        AtpExecutor.SwapStep[] memory steps = _buyStep(address(venue), 100e18, 0, EvilVenue.Mode.Reenter);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        _run(steps);
        _assertUntouched();
    }

    function test_adminCallsMidSwap_revert() public {
        AtpExecutor.SwapStep[] memory steps = _buyStep(address(venue), 100e18, 0, EvilVenue.Mode.CallAdmin);
        vm.expectRevert(AtpExecutor.NotOwner.selector);
        _run(steps);
    }

    function test_leftoverAllowance_isZero_andTheUnusedInputGoesBack() public {
        uint256 out = _floor(100e18);
        _run(_buyStep(address(venue), 100e18, out, EvilVenue.Mode.PullHalf));
        assertEq(usdt.balanceOf(address(this)), 950e18, "the unpulled half went back to the account");
        assertEq(usdt.allowance(address(executor), address(venue)), 0, "allowance zeroed after the call");
        assertEq(usdt.balanceOf(address(executor)), 0, "executor holds nothing between calls");

        // Later, outside any swap, the venue cannot pull anything from the executor or the account.
        vm.expectRevert(stdError.arithmeticError);
        venue.pullLater(address(usdt), address(executor));
        vm.expectRevert(stdError.arithmeticError);
        venue.pullLater(address(usdt), address(this));
    }

    function test_venueCannotStartATrade() public {
        vm.expectRevert(AtpExecutor.NotAccount.selector);
        venue.startTrade(executor, address(this));
    }

    // ---- the other guards still apply to generic venues ----

    function test_genericVenue_respectsGlobalPauseBuyLimitAndRoutes() public {
        uint256 floor = _floor(100e18);

        executor.setGlobalPaused(true);
        AtpExecutor.SwapStep[] memory steps = _buyStep(address(venue), 100e18, floor, EvilVenue.Mode.Honest);
        vm.expectRevert(AtpExecutor.ExecutorPaused.selector);
        _run(steps);
        executor.setGlobalPaused(false);

        executor.setMaxBuyBps(0);
        vm.expectPartialRevert(AtpExecutor.BuyLimitExceeded.selector);
        _run(steps);
        executor.setMaxBuyBps(10_000);

        BurnableToken outside = new BurnableToken();
        steps[0].tokenOut = address(outside);
        vm.expectRevert(AtpExecutor.AssetNotAllowed.selector);
        _run(steps);
    }

    function test_universalRouterVenue_keepsItsCommandAllowlist() public {
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(
            OUTSIDER,
            uint256(100e18),
            uint256(0),
            abi.encodePacked(address(usdt), uint24(500), address(tokenA)),
            true
        );
        AtpExecutor.SwapStep[] memory steps = new AtpExecutor.SwapStep[](1);
        steps[0] = AtpExecutor.SwapStep({
            tokenIn: address(usdt),
            tokenOut: address(tokenA),
            amountIn: 100e18,
            amountOutMin: _floor(100e18),
            venue: address(ur),
            data: abi.encode(hex"00", inputs)
        });
        vm.expectRevert(abi.encodeWithSelector(AtpExecutor.BadRecipient.selector, OUTSIDER));
        _run(steps);

        executor.removeVenue(address(ur));
        vm.expectRevert(abi.encodeWithSelector(AtpExecutor.VenueNotAllowed.selector, address(ur)));
        _run(steps);
    }
}
