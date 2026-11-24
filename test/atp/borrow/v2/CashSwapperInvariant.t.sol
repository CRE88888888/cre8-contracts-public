// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { CashSwapperBase } from "./CashSwapperBase.sol";
import { MockStablePool } from "./mocks/MockStablePool.sol";
import { AtpBorrowCashSwapper } from "../../../../src/atp/borrow/v2/AtpBorrowCashSwapper.sol";
import { IAtpBorrowCashSwapper as ISwapper } from "../../../../src/atp/borrow/v2/IAtpBorrowCashSwapper.sol";
import { IAtpBorrowExecutorV2 as IExec } from "../../../../src/atp/borrow/v2/IAtpBorrowExecutorV2.sol";
import { IAtpBorrowRegistryV2 as IReg } from "../../../../src/atp/borrow/v2/IAtpBorrowRegistryV2.sol";
import { AtpBorrowRegistryV2 } from "../../../../src/atp/borrow/v2/AtpBorrowRegistryV2.sol";
import { AtpBorrowLensV2 } from "../../../../src/atp/borrow/v2/AtpBorrowLensV2.sol";
import { MockLendingOracle } from "../../../../src/testnet/lending/MockLendingOracle.sol";
import { TestnetToken } from "../../../../src/testnet/TestnetToken.sol";

/// @notice Random sequences around the cash swapper: the account (a session key's reach) opens USDC positions
/// that lose to their debt, tops up, repays, closes and cashes out; the pool's price moves and the pool
/// itself turns hostile; the owner moves the limits; time passes; a keeper deleverages. After every swapper
/// call that went through, the handler compares every balance it knows before and after:
/// a top-up moved USDT account -> pool and USDC pool -> the account's box, nothing else, no more than the cap,
/// within the peg bound; a cash-out moved USDC account -> pool and USDT pool -> account, within the peg bound.
contract CashSwapperHandler is Test {
    uint256 internal constant MAX = type(uint256).max;

    AtpBorrowCashSwapper public immutable swapper;
    MockStablePool public immutable pool;
    IExec public immutable lend;
    AtpBorrowRegistryV2 public immutable credit;
    AtpBorrowLensV2 public immutable lens;
    MockLendingOracle public immutable oracle;
    TestnetToken public immutable usdt;
    TestnetToken public immutable usdc;
    address[3] public collaterals;
    address public immutable account;
    address public immutable owner;
    address public immutable reporter;
    address public immutable keeper;
    address public immutable victim;
    bytes32[] public routes;
    bytes32[] public vaults;
    address[] public holders;

    uint256 public toppedUp;
    uint256 public toppedUpTokens;
    uint256 public cashedOut;
    uint256 public cashedOutTokens;
    uint256 public refusedByPeg;
    uint256 public refusedByCap;
    uint256 public hostileAttempts;
    /// @dev Calls that went through on a misbehaving pool (they still had to pass every check above).
    uint256 public hostileSuccesses;
    uint256 public opened;
    uint256 public closed;
    uint256 public deleveraged;
    /// @dev Set when a swapper call that went through moved anything it should not have. Must stay empty.
    string public violation;

    constructor(
        AtpBorrowCashSwapper swapper_,
        MockStablePool pool_,
        IExec lend_,
        AtpBorrowRegistryV2 credit_,
        AtpBorrowLensV2 lens_,
        MockLendingOracle oracle_,
        TestnetToken usdt_,
        TestnetToken usdc_,
        address[3] memory collaterals_,
        address[4] memory actors, // account (also the owner), reporter, keeper, victim
        bytes32[] memory routes_,
        bytes32[] memory vaults_,
        address[] memory holders_
    ) {
        (swapper, pool, lend, credit, lens, oracle) = (swapper_, pool_, lend_, credit_, lens_, oracle_);
        (usdt, usdc, collaterals) = (usdt_, usdc_, collaterals_);
        (account, owner, reporter, keeper, victim) = (actors[0], actors[0], actors[1], actors[2], actors[3]);
        routes = routes_;
        vaults = vaults_;
        holders = holders_;
    }

    // ---- the account ----

    function open(uint256 routeSeed, uint256 vaultSeed, uint256 collateral, uint256 borrow) external {
        _reportRates();
        bytes32 route = routes[routeSeed % routes.length];
        vm.prank(account);
        try lend.executeOpen(
            account,
            route,
            vaults[vaultSeed % vaults.length],
            _bound(collateral, 0, 20e18),
            _bound(borrow, 0, 600e18),
            block.timestamp
        ) {
            ++opened;
        } catch { }
    }

    function reduce(uint256 routeSeed, uint256 vaultSeed, uint256 percent, bool close) external {
        bytes32 route = routes[routeSeed % routes.length];
        uint256 owed = lens.routeDebt(route, account);
        vm.prank(account);
        try lend.executeReduce(
            account,
            route,
            vaults[vaultSeed % vaults.length],
            close ? MAX : owed * _bound(percent, 1, 100) / 100,
            close ? MAX : 0,
            0, // no account cash: only the box pays, so a short box needs the top-up
            block.timestamp
        ) {
            if (close) ++closed;
        } catch { }
    }

    function topUp(uint256 amount, uint256 maxIn) external {
        (uint256 gap, uint256 cap) = swapper.shortfall(account, address(usdc));
        // Mostly inside the cap; sometimes "all", sometimes a little above.
        if (amount % 5 == 0) amount = MAX;
        else amount = _bound(amount, 1, cap == 0 ? 10e18 : cap * 21 / 20);
        maxIn = maxIn % 4 == 0 ? _bound(maxIn, 0, 2 * cap) : MAX;
        address box = lend.boxOf(account);
        uint256[] memory before = _snapshot();
        bool hostile = _hostile();
        vm.prank(account);
        try swapper.topUp(address(usdc), amount, maxIn, block.timestamp) returns (
            uint256 usdtIn, uint256 tokenOut
        ) {
            ++toppedUp;
            toppedUpTokens += tokenOut;
            if (hostile) ++hostileSuccesses;
            if (gap == 0 || tokenOut > cap) violation = "top-up above the cap";
            if (amount != MAX && tokenOut != amount) violation = "top-up delivered another amount";
            if (usdtIn > maxIn) violation = "top-up above the caller's bound";
            if (usdtIn > tokenOut + tokenOut * swapper.maxPegBps() / 10_000 + 3) {
                violation = "top-up past the peg bound";
            }
            _moved(before, address(usdt), account, address(pool), usdtIn, "top-up USDT");
            _moved(before, address(usdc), address(pool), box, tokenOut, "top-up USDC");
        } catch (bytes memory reason) {
            _count(reason);
            _moved(before, address(usdt), account, account, 0, "failed top-up");
        }
        _calm();
    }

    function cashOut(uint256 amount, uint256 minOut) external {
        uint256 balance = usdc.balanceOf(account);
        amount = amount % 3 == 0 ? MAX : _bound(amount, 0, balance + 1);
        minOut = minOut % 4 == 0 ? _bound(minOut, 0, 2 * balance) : 0;
        uint256[] memory before = _snapshot();
        bool hostile = _hostile();
        vm.prank(account);
        try swapper.cashOut(address(usdc), amount, minOut, block.timestamp) returns (
            uint256 tokenIn, uint256 usdtOut
        ) {
            ++cashedOut;
            cashedOutTokens += tokenIn;
            if (hostile) ++hostileSuccesses;
            if (tokenIn != (amount == MAX ? balance : amount)) violation = "cash-out sold another amount";
            if (usdtOut < minOut) violation = "cash-out below the caller's bound";
            if (tokenIn > usdtOut + usdtOut * swapper.maxPegBps() / 10_000 + 3) {
                violation = "cash-out past the peg bound";
            }
            _moved(before, address(usdc), account, address(pool), tokenIn, "cash-out USDC");
            _moved(before, address(usdt), address(pool), account, usdtOut, "cash-out USDT");
        } catch (bytes memory reason) {
            _count(reason);
            _moved(before, address(usdt), account, account, 0, "failed cash-out");
        }
        _calm();
    }

    // ---- the world ----

    function warp(uint256 time) external {
        skip(_bound(time, 1 hours, 120 days));
    }

    /// @dev Loan token a closed position left in the account (the vault's yield beyond the debt).
    function leftover(uint256 amount) external {
        vm.prank(owner);
        usdc.mint(account, _bound(amount, 1, 50e18));
    }

    /// @dev The ERC4626 vault's status cannot be read (or reads again): the cap then counts it as empty.
    function blindVault(bool blind) external {
        bytes memory call = abi.encodeCall(lens.vaultStatus, (vaults[1], account));
        if (blind) vm.mockCallRevert(address(lens), call, "unreadable");
        else vm.clearMockedCalls();
    }

    /// @dev USDC mostly within 0.3% of USDT, sometimes up to 1.5% away: on both sides of every bound the
    /// owner can set.
    function movePeg(uint256 seed) external {
        uint256 ratio = seed % 3 == 0 ? _bound(seed >> 8, 9_850, 10_150) : _bound(seed >> 8, 9_970, 10_030);
        pool.setPrice(pool.token0() == address(usdt) ? 1e18 * 10_000 / ratio : 1e18 * ratio / 10_000);
    }

    /// @dev One of the ways a wrong pool could behave, for the next swapper call only.
    function setPoolMode(uint256 seed) external {
        MockStablePool.Mode mode = MockStablePool.Mode(1 + (seed >> 8) % 8);
        bytes memory reentry = (seed >> 16) % 2 == 0
            ? abi.encodeCall(swapper.cashOut, (address(usdc), 1e18, 0, MAX))
            : abi.encodeCall(swapper.topUp, (address(usdc), 1, MAX, MAX));
        pool.setMode(mode, victim, address(usdt), reentry);
    }

    function setLimits(uint256 peg, uint256 buffer) external {
        vm.prank(owner);
        swapper.setLimits(uint16(_bound(peg, 0, 100)), uint16(_bound(buffer, 0, 500)));
    }

    function dropAndDeleverage(uint256 routeSeed, uint256 vaultSeed, uint256 percent) external {
        _price(100e8 * _bound(percent, 30, 70) / 100);
        vm.prank(keeper);
        try lend.executeDeleverage(
            account, routes[routeSeed % routes.length], vaults[vaultSeed % vaults.length], MAX
        ) {
            ++deleveraged;
        } catch { }
        _price(100e8);
    }

    function _price(uint256 price) internal {
        vm.startPrank(owner);
        for (uint256 i; i < 3; ++i) {
            oracle.setPrice(collaterals[i], price);
        }
        vm.stopPrank();
    }

    // ---- bookkeeping ----

    function _hostile() internal returns (bool hostile) {
        hostile = pool.mode() != MockStablePool.Mode.HONEST;
        if (hostile) ++hostileAttempts;
    }

    function _calm() internal {
        pool.setMode(MockStablePool.Mode.HONEST, address(0), address(0), "");
    }

    function _reportRates() internal {
        IReg.RouteReport[] memory r = new IReg.RouteReport[](routes.length);
        for (uint256 i; i < r.length; ++i) {
            r[i] = IReg.RouteReport(routes[i], 0.05e18, 0);
        }
        IReg.VaultReport[] memory v = new IReg.VaultReport[](vaults.length);
        for (uint256 i; i < v.length; ++i) {
            v[i] = IReg.VaultReport(vaults[i], 0.01e18, 0);
        }
        vm.prank(reporter);
        credit.reportRates(r, v);
    }

    function _count(bytes memory reason) internal {
        bytes4 s = bytes4(reason);
        if (s == ISwapper.PegExceeded.selector) ++refusedByPeg;
        if (s == ISwapper.AboveShortfall.selector || s == ISwapper.NoShortfall.selector) {
            ++refusedByCap;
        }
    }

    /// @dev USDT then USDC balance of every holder.
    function _snapshot() internal view returns (uint256[] memory b) {
        b = new uint256[](holders.length * 2);
        for (uint256 i; i < holders.length; ++i) {
            b[2 * i] = usdt.balanceOf(holders[i]);
            b[2 * i + 1] = usdc.balanceOf(holders[i]);
        }
    }

    /// @dev Since `before`, exactly `amount` of `token` went `from` -> `to` and no other holder's balance of
    /// it changed (`from == to`: nothing of either token moved at all).
    function _moved(
        uint256[] memory before,
        address token,
        address from,
        address to,
        uint256 amount,
        string memory what
    ) internal {
        bool nothing = from == to;
        for (uint256 i; i < holders.length; ++i) {
            for (uint256 t; t < 2; ++t) {
                address tok = t == 0 ? address(usdt) : address(usdc);
                if (!nothing && tok != token) continue;
                uint256 was = before[2 * i + t];
                uint256 is_ = IERC20(tok).balanceOf(holders[i]);
                uint256 expected = was;
                if (!nothing && holders[i] == from) expected = was - amount;
                if (!nothing && holders[i] == to) expected = was + amount;
                if (is_ != expected) {
                    violation = string.concat(what, ": a balance moved that should not have");
                }
            }
        }
    }
}

/// forge-config: default.invariant.runs = 48
/// forge-config: default.invariant.depth = 80
/// forge-config: default.invariant.fail-on-revert = false
/// forge-config: ci.invariant.runs = 96
/// forge-config: ci.invariant.depth = 100
contract CashSwapperInvariantTest is CashSwapperBase {
    CashSwapperHandler internal handler;

    function setUp() public override {
        super.setUp();
        // USDC routes only (Venus NVDA, Lista TSLA and QQQ) and the two USDC vaults: the Venus one earns almost
        // nothing and the ERC4626 one is reported below the borrow rate, so every position ends up short.
        bytes32[] memory routes = new bytes32[](3);
        (routes[0], routes[1], routes[2]) = (V_NVDA_C, L_TSLA_C, L_QQQ_C);
        bytes32[] memory vaults = new bytes32[](2);
        (vaults[0], vaults[1]) = (K_VC, K_C);
        vaultC.setAprBps(100);
        // A victim that approved the swapper for both tokens, like any other account would have.
        usdt.mint(STRANGER, 1_000_000e18);
        usdc.mint(STRANGER, 1_000_000e18);
        vm.startPrank(STRANGER);
        usdt.approve(address(swapper), MAX);
        usdc.approve(address(swapper), MAX);
        vm.stopPrank();
        address[] memory holders = new address[](9);
        holders[0] = address(this);
        holders[1] = lend.boxOf(address(this));
        holders[2] = address(pool);
        holders[3] = address(swapper);
        holders[4] = STRANGER;
        holders[5] = address(lend);
        holders[6] = WALLET;
        holders[7] = KEEPER;
        holders[8] = address(pool.accomplice());
        handler = new CashSwapperHandler(
            swapper,
            pool,
            lend,
            credit,
            lens,
            oracle,
            usdt,
            usdc,
            [address(nvda), address(tsla), address(qqq)],
            [address(this), REPORTER, KEEPER, STRANGER],
            routes,
            vaults,
            holders
        );
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](19);
        selectors[0] = CashSwapperHandler.open.selector;
        selectors[1] = CashSwapperHandler.open.selector;
        selectors[2] = CashSwapperHandler.open.selector;
        selectors[3] = CashSwapperHandler.warp.selector;
        selectors[4] = CashSwapperHandler.warp.selector;
        selectors[5] = CashSwapperHandler.topUp.selector;
        selectors[6] = CashSwapperHandler.topUp.selector;
        selectors[7] = CashSwapperHandler.topUp.selector;
        selectors[8] = CashSwapperHandler.reduce.selector;
        selectors[9] = CashSwapperHandler.reduce.selector;
        selectors[10] = CashSwapperHandler.cashOut.selector;
        selectors[11] = CashSwapperHandler.cashOut.selector;
        selectors[12] = CashSwapperHandler.movePeg.selector;
        selectors[13] = CashSwapperHandler.setPoolMode.selector;
        selectors[14] = CashSwapperHandler.setLimits.selector;
        selectors[15] = CashSwapperHandler.dropAndDeleverage.selector;
        selectors[16] = CashSwapperHandler.leftover.selector;
        selectors[17] = CashSwapperHandler.blindVault.selector;
        selectors[18] = CashSwapperHandler.cashOut.selector;
        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
    }

    /// The swapper never holds a token and never keeps an allowance: the pool pays the destination itself and
    /// the callback moves the input from the caller straight to the pool.
    function invariant_swapperHoldsNothing() public view {
        _swapperHoldsNothing();
        assertEq(nvda.balanceOf(address(swapper)), 0);
    }

    /// Money a swapper call moved only went: account -> pool and pool -> the account's box (top-up), or
    /// account -> pool and pool -> account (cash-out); never above the cap, never past the peg bound.
    function invariant_moneyOnlyGoesToTheBoxOrTheAccount() public view {
        assertEq(bytes(handler.violation()).length, 0, handler.violation());
    }

    /// Nobody else's approval of the swapper is ever used: the victim keeps everything.
    function invariant_otherApproversAreUntouched() public view {
        assertEq(usdt.balanceOf(STRANGER), 1_000_000e18);
        assertEq(usdc.balanceOf(STRANGER), 1_000_000e18);
    }

    /// The executor's own rule still holds with the swapper around: nothing rests in it or its adapters.
    function invariant_executorHoldsNothing() public view {
        _noResidue();
    }

    /// @dev Makes a vacuous campaign visible (the counters of every run add up in the process environment).
    function afterInvariant() public {
        _tally("runs", 1);
        _tally("opened", handler.opened());
        _tally("closed", handler.closed());
        _tally("top_ups", handler.toppedUp());
        _tally("top_up_whole_tokens", handler.toppedUpTokens() / 1e18);
        _tally("cash_outs", handler.cashedOut());
        _tally("cash_out_whole_tokens", handler.cashedOutTokens() / 1e18);
        _tally("refused_by_peg", handler.refusedByPeg());
        _tally("refused_by_cap", handler.refusedByCap());
        _tally("attempts_on_a_hostile_pool", handler.hostileAttempts());
        _tally("of_which_went_through", handler.hostileSuccesses());
        _tally("deleveraged", handler.deleveraged());
    }

    function _tally(string memory name, uint256 n) internal {
        string memory key = string.concat("CASH_SWAPPER_INVARIANT_", name);
        uint256 total = vm.envOr(key, uint256(0)) + n;
        vm.setEnv(key, vm.toString(total));
        emit log_named_uint(string.concat("campaign total: ", name), total);
    }
}
