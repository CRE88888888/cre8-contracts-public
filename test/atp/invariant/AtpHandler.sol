// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { AtpExecutor } from "../../../src/atp/AtpExecutor.sol";
import { AtpRegistry } from "../../../src/atp/AtpRegistry.sol";
import { AtpMultiPoolOracle } from "../../../src/atp/AtpMultiPoolOracle.sol";
import { BurnableToken, PricedRouter } from "../AtpExecutorBuyLimit.t.sol";
import { FunctionalPermit2 } from "../AtpExecutorVenues.t.sol";
import { MockToken, MockPool } from "../AtpMultiPoolOracle.t.sol";
import { MockAggregator } from "../AtpMultiPoolOracleSecondary.t.sol";
import { SlippageOracle, TestAccount, RandomVenue } from "./InvariantMocks.sol";

/// @notice Drives random sequences against the real `AtpExecutor` and `AtpRegistry` (plus a real
/// `AtpMultiPoolOracle` for the admin surface) and records every property violation in a ghost counter. The
/// handler itself is the registry / router owner, i.e. the Safe. Handler calls that revert are expected
/// (fail closed) and ignored; only the counters decide (cre8-contracts#21).
contract AtpHandler is Test {
    address internal constant OPERATOR = address(0x0FE7);
    address internal constant OUTSIDER = address(0xCAFE);
    address internal constant FEE_RECIPIENT = address(0xFEE);
    uint16 internal constant SLIPPAGE_BPS = 300;
    uint256 internal constant BPS = 10_000;
    /// @dev The production default (0.30 USDT), so small swaps pay a top-up and large ones do not.
    uint256 internal constant MIN_FEE = 0.3e18;

    AtpRegistry public registry;
    AtpExecutor public executor;
    SlippageOracle public oracle;
    PricedRouter public ur;
    FunctionalPermit2 public permit2;
    RandomVenue public erc20Venue;
    RandomVenue public permit2Venue;
    RandomVenue public unlistedVenue;
    AtpMultiPoolOracle public router; // admin surface only
    // Router fixtures chosen so that every admin call below WOULD succeed for the owner: a failure can then
    // only be the access check, never a masking validation error.
    address public routerAssetWithSecondary; // oracle + secondary: clearOracle / clearSecondary would pass
    address public routerAssetNoSecondary; // oracle only: setSecondary would pass
    address public routerAssetUnregistered; // no oracle: setOracle on `routerSparePool` would pass
    address public routerSparePool;
    MockAggregator public spareFeedA;
    MockAggregator public spareFeedB;

    BurnableToken public usdt;
    BurnableToken public tokenA;
    BurnableToken public tokenB;
    BurnableToken public tokenC;
    BurnableToken public stray;
    BurnableToken[5] internal _tokens;
    TestAccount[2] public accounts;
    uint256 public strategyAB; // [USDT, A, B]
    uint256 public strategyAC; // [USDT, A, C]

    // ---- model of the registry (A10-2) ----
    mapping(address => bool) public modelEnrolled;
    mapping(address => uint256) public modelStrategy;
    mapping(address => uint8) public modelFlags;

    // ---- ghosts ----
    mapping(address => uint256) public ghostDonated;
    uint256 public ghostFloorViolations; // (7) account received less than the oracle floor
    uint256 public ghostMinOutViolations; // (7) a step settled with gross output below its amountOutMin
    uint256 public ghostInOverspend; // (2) more tokenIn left the account than amountIn
    uint256 public ghostFeeViolations; // (2) fee != floor(gross x feeBps) or went elsewhere
    uint256 public ghostMinFeeViolations; // (2) min-fee top-up above what was due, or short while USDT was left
    uint256 public ghostLeaks; // (2) the other account's balances moved
    uint256 public ghostNotAllowedExecuted; // (2) a token outside the pinned version was traded
    uint256 public ghostUnlistedVenueExecuted; // (2) a venue off the allowlist was used
    uint256 public ghostUnauthorizedAdmin; // (3) a non-Safe caller changed configuration
    uint256 public ghostEnrollViolations; // (4)
    uint256 public ghostPauseViolations; // (4)
    uint256 public ghostBuyLimitViolations; // (5) bought after a batch > cap at its start
    uint256 public ghostSaleBlockedByBuyLimit; // (5) a sale reverted with BuyLimitExceeded
    uint256 public ghostPausedButExecuted; // (6)

    // ---- coverage ----
    uint256 public callsSwapOk;
    uint256 public callsSwapReverted;
    uint256 public callsMinFeeCharged; // swaps that paid a non-zero minimum-fee top-up
    uint256 public callsBuyOk;
    uint256 public callsSellOk;
    uint256 public callsMaliciousOk; // a non-Pay mode that still went through (only PullHalf / DonateStray can)
    uint256 public callsAdminAttempts;
    uint256 public callsEnroll;
    uint256 public callsPause;

    constructor() {
        usdt = new BurnableToken();
        tokenA = new BurnableToken();
        tokenB = new BurnableToken();
        tokenC = new BurnableToken();
        stray = new BurnableToken();
        _tokens = [usdt, tokenA, tokenB, tokenC, stray];

        oracle = new SlippageOracle(address(usdt), SLIPPAGE_BPS);
        oracle.setPrice(address(tokenA), 2e18);
        oracle.setPrice(address(tokenB), 0.5e18);
        oracle.setPrice(address(tokenC), 7e18);
        ur = new PricedRouter();
        permit2 = new FunctionalPermit2();
        registry = new AtpRegistry();
        registry.setOperator(OPERATOR);
        executor = new AtpExecutor(
            registry, ur, oracle, address(permit2), FEE_RECIPIENT, address(usdt), 10_000, MIN_FEE
        );
        erc20Venue = new RandomVenue(FunctionalPermit2(address(0)), stray);
        permit2Venue = new RandomVenue(permit2, stray);
        unlistedVenue = new RandomVenue(FunctionalPermit2(address(0)), stray);
        executor.setVenue(address(erc20Venue), AtpExecutor.VenueKind.ERC20_APPROVE, address(erc20Venue));
        executor.setVenue(address(permit2Venue), AtpExecutor.VenueKind.PERMIT2, address(permit2Venue));

        strategyAB = _strategy(address(tokenB));
        strategyAC = _strategy(address(tokenC));

        for (uint256 i; i < 2; ++i) {
            TestAccount account = new TestAccount();
            accounts[i] = account;
            for (uint256 t; t < 4; ++t) {
                account.approve(_tokens[t], address(executor));
            }
            usdt.mint(address(account), 10_000e18);
            tokenA.mint(address(account), 1_000e18);
            tokenB.mint(address(account), 1_000e18);
        }
        // Account 0 is enrolled by the operator (first enrollment); account 1 starts unenrolled.
        vm.prank(address(accounts[0]));
        registry.approveEnrollment(strategyAB, 1);
        vm.prank(OPERATOR);
        registry.enroll(address(accounts[0]), strategyAB, 1);
        _modelEnroll(address(accounts[0]), strategyAB, false);

        // A real router, only to attack its admin surface.
        MockToken numeraire = new MockToken(18);
        router = new AtpMultiPoolOracle(address(numeraire));
        routerAssetWithSecondary = address(new MockToken(18));
        routerAssetNoSecondary = address(new MockToken(18));
        routerAssetUnregistered = address(new MockToken(18));
        router.setOracle(
            routerAssetWithSecondary, _pool(numeraire, routerAssetWithSecondary), 30 minutes, 100, 1 hours
        );
        router.setOracle(
            routerAssetNoSecondary, _pool(numeraire, routerAssetNoSecondary), 30 minutes, 100, 1 hours
        );
        routerSparePool = _pool(numeraire, routerAssetUnregistered);
        spareFeedA = new MockAggregator(8, 1e8);
        spareFeedB = new MockAggregator(8, 1e8);
        router.setSecondary(routerAssetWithSecondary, spareFeedA, spareFeedB, 1 hours, 1 hours, 200);
    }

    function _pool(MockToken numeraire, address asset) internal returns (address) {
        MockPool pool = new MockPool(address(numeraire), asset);
        pool.setMeanTick(0, 30 minutes);
        return address(pool);
    }

    function _strategy(address third) internal returns (uint256 id) {
        id = registry.registerStrategy("s", "invariant", true);
        address[] memory assets = new address[](3);
        assets[0] = address(usdt);
        assets[1] = address(tokenA);
        assets[2] = third;
        uint16[] memory weights = new uint16[](3);
        weights[0] = 2_000;
        weights[1] = 4_000;
        weights[2] = 4_000;
        registry.publishVersion(id, assets, weights, keccak256("schedule"), 0);
        vm.warp(block.timestamp + 1 days);
    }

    function tokens() external view returns (BurnableToken[5] memory) {
        return _tokens;
    }

    // =========================================================== rebalance

    struct Pre {
        bool paused;
        bool allowed;
        bool listed;
        uint16 feeBps;
        uint256 strategyId;
        uint256 minimum;
        uint256 amountOutMin;
        uint256 accIn;
        uint256 accOut;
        uint256 feeOut;
        uint256 feeUsdt;
        uint256 otherIn;
        uint256 otherOut;
        uint256 cap;
        /// @dev The account's minimum-fee window before the batch, already reset if it had expired.
        uint256 windowNotional;
        uint256 windowPaid;
    }

    /// @param modeSeed selects the venue behaviour; `payBps` scales what an honest-ish venue pays vs the quote;
    /// `minBps` sets the step's `amountOutMin` vs the quote, never below `minGross` (the executor's own bound).
    function rebalance(
        uint256 accountSeed,
        bool buy,
        uint256 assetSeed,
        uint256 amountSeed,
        uint256 venueSeed,
        uint256 modeSeed,
        uint256 payBps,
        uint256 minBps
    ) external {
        TestAccount account = accounts[accountSeed % 2];
        TestAccount other = accounts[(accountSeed + 1) % 2];
        BurnableToken asset = [tokenA, tokenB, tokenC][assetSeed % 3];
        (BurnableToken tokenIn, BurnableToken tokenOut) = buy ? (usdt, asset) : (asset, usdt);
        uint256 amount = _bound(amountSeed, 1e15, buy ? 3_000e18 : 1_500e18);

        uint256 quote;
        Pre memory pre;
        try oracle.previewSwap(address(tokenIn), address(tokenOut), amount) returns (uint256 q, uint256 m) {
            quote = q;
            pre.minimum = m;
        } catch {
            return;
        }
        uint256 payout = quote * _bound(payBps, 9_400, 10_600) / BPS;
        // amountOutMin anywhere from the executor's minGross (oracle floor grossed up over the fee) to 3% above
        // the quote, so payouts land below, between and above the two bounds.
        AtpRegistry.Enrollment memory enrollment = registry.enrollments(address(account));
        pre.feeBps = registry.effectiveFeeBps(enrollment.strategyId);
        pre.strategyId = enrollment.strategyId;
        uint256 minGross = Math.mulDiv(pre.minimum, BPS, BPS - pre.feeBps, Math.Rounding.Ceil);
        pre.amountOutMin = Math.max(minGross, quote * _bound(minBps, 9_000, 10_300) / BPS);

        AtpExecutor.SwapStep[] memory steps = new AtpExecutor.SwapStep[](1);
        steps[0].tokenIn = address(tokenIn);
        steps[0].tokenOut = address(tokenOut);
        steps[0].amountIn = amount;
        steps[0].amountOutMin = pre.amountOutMin;
        // Weighted: 6 of 16 draws are an honest(-ish) payment, the other 10 one of the ten behaviours, so enough
        // swaps settle for the floor / fee / buy-limit checks to bite while every malicious path keeps running.
        uint256 draw = modeSeed % 16;
        RandomVenue.Mode mode = draw < 10 ? RandomVenue.Mode(draw) : RandomVenue.Mode.Pay;
        // 2/8 Universal Router, 3/8 ERC20 venue, 2/8 Permit2 venue, 1/8 a venue that is not on the allowlist.
        uint256 venueChoice = [uint256(0), 0, 1, 1, 1, 2, 2, 3][venueSeed % 8];
        if (venueChoice == 0) {
            bytes[] memory inputs = new bytes[](1);
            inputs[0] = abi.encode(
                address(executor), amount, payout, abi.encodePacked(tokenIn, uint24(500), tokenOut), true
            );
            steps[0].venue = address(ur);
            steps[0].data = abi.encode(hex"00", inputs);
            mode = RandomVenue.Mode.Pay;
        } else {
            RandomVenue venue =
                venueChoice == 1 ? erc20Venue : venueChoice == 2 ? permit2Venue : unlistedVenue;
            steps[0].venue = address(venue);
            steps[0].data = abi.encodeCall(
                RandomVenue.swap,
                (address(tokenIn), address(tokenOut), amount, payout, mode, address(account))
            );
        }

        // ---- pre-state ----
        pre.paused = executor.globalPaused() || enrollment.paused;
        pre.allowed = registry.isEnrolled(address(account))
            && registry.isAssetAllowed(enrollment.strategyId, enrollment.version, address(tokenIn))
            && registry.isAssetAllowed(enrollment.strategyId, enrollment.version, address(tokenOut));
        (AtpExecutor.VenueKind kind,) = executor.venues(steps[0].venue);
        pre.listed = kind != AtpExecutor.VenueKind.NONE;
        pre.accIn = tokenIn.balanceOf(address(account));
        pre.accOut = tokenOut.balanceOf(address(account));
        pre.feeOut = tokenOut.balanceOf(FEE_RECIPIENT);
        pre.feeUsdt = usdt.balanceOf(FEE_RECIPIENT);
        pre.otherIn = tokenIn.balanceOf(address(other));
        pre.otherOut = tokenOut.balanceOf(address(other));
        if (buy) (pre.cap,,) = executor.buyAllowance(address(account));
        (uint64 windowStart, uint192 windowNotional, uint256 windowPaid) =
            executor.minFeeWindowOf(address(account));
        if (windowStart != 0 && block.timestamp < uint256(windowStart) + executor.MIN_FEE_WINDOW()) {
            pre.windowNotional = windowNotional;
            pre.windowPaid = windowPaid;
        }

        try account.exec(executor, steps, block.timestamp + 300) {
            _afterSuccess(account, other, tokenIn, tokenOut, amount, buy, mode, pre);
        } catch (bytes memory reason) {
            ++callsSwapReverted;
            if (!buy && reason.length >= 4 && bytes4(reason) == AtpExecutor.BuyLimitExceeded.selector) {
                ++ghostSaleBlockedByBuyLimit;
            }
        }
    }

    function _afterSuccess(
        TestAccount account,
        TestAccount other,
        BurnableToken tokenIn,
        BurnableToken tokenOut,
        uint256 amount,
        bool buy,
        RandomVenue.Mode mode,
        Pre memory pre
    ) internal {
        ++callsSwapOk;
        if (buy) ++callsBuyOk;
        else ++callsSellOk;
        if (mode != RandomVenue.Mode.Pay) ++callsMaliciousOk;
        if (mode == RandomVenue.Mode.DonateStray) ghostDonated[address(stray)] += 1e18;

        if (pre.paused) ++ghostPausedButExecuted;
        if (!pre.allowed) ++ghostNotAllowedExecuted;
        if (!pre.listed) ++ghostUnlistedVenueExecuted;

        // Everything the fee recipient got in USDT beyond a sale's proportional fee is the minimum-fee top-up,
        // pulled from the account after the swap; the swap itself (gross, proportional fee, floor) is checked
        // without it, since the top-up never comes out of a swap's output.
        uint256 usdtFee = usdt.balanceOf(FEE_RECIPIENT) - pre.feeUsdt;
        uint256 accOut = tokenOut.balanceOf(address(account));
        uint256 gross;
        uint256 fee;
        uint256 charged;
        if (buy) {
            fee = tokenOut.balanceOf(FEE_RECIPIENT) - pre.feeOut;
            gross = accOut - pre.accOut + fee;
            charged = usdtFee;
        } else {
            gross = accOut + usdtFee - pre.accOut;
            fee = gross * pre.feeBps / BPS;
            if (usdtFee < fee) ++ghostFeeViolations;
            else charged = usdtFee - fee;
        }
        if (tokenIn.balanceOf(address(account)) + amount + (buy ? charged : 0) < pre.accIn) {
            ++ghostInOverspend;
        }
        if (gross - fee < pre.minimum) ++ghostFloorViolations;
        if (gross < pre.amountOutMin) ++ghostMinOutViolations;
        if (fee != gross * pre.feeBps / BPS) ++ghostFeeViolations;
        _checkMinFee(account, buy ? amount : gross, charged, pre);
        if (
            tokenIn.balanceOf(address(other)) != pre.otherIn
                || tokenOut.balanceOf(address(other)) != pre.otherOut
        ) ++ghostLeaks;

        if (buy) {
            (, uint192 bought) = executor.buyWindowOf(address(account));
            if (bought > pre.cap) ++ghostBuyLimitViolations;
        }
    }

    /// @dev Per account and window (cre8-contracts#47) the top-up is what the window still owes: the one-batch
    /// top-up of its cumulative notional (`minFeeTopUp`, at most `minBatchFee` and 1% of it) less what the window
    /// already paid. It is short only when the account ran out of USDT (allowances here are unlimited), and the
    /// window records exactly this batch's notional and charge.
    function _checkMinFee(TestAccount account, uint256 notional, uint256 charged, Pre memory pre) internal {
        uint256 cumulative = pre.windowNotional + notional;
        uint256 owed = executor.minFeeTopUp(pre.strategyId, cumulative);
        uint256 due = owed > pre.windowPaid ? owed - pre.windowPaid : 0;
        if (charged > 0) ++callsMinFeeCharged;
        (, uint192 windowNotional, uint256 windowPaid) = executor.minFeeWindowOf(address(account));
        if (
            charged > due || owed > executor.minBatchFee() || owed > cumulative / 100
                || (charged < due && usdt.balanceOf(address(account)) != 0) || windowNotional != cumulative
                || windowPaid != pre.windowPaid + charged
        ) ++ghostMinFeeViolations;
    }

    // =========================================================== market / time / funds

    function movePrice(uint256 assetSeed, uint256 bpsSeed, bool up) external {
        BurnableToken asset = [tokenA, tokenB, tokenC][assetSeed % 3];
        uint256 delta = _bound(bpsSeed, 0, 500);
        uint256 price = oracle.price(address(asset));
        oracle.setPrice(address(asset), up ? price * (BPS + delta) / BPS : price * (BPS - delta) / BPS + 1);
    }

    function warp(uint256 secondsSeed) external {
        vm.warp(block.timestamp + _bound(secondsSeed, 0, 2 days));
    }

    function deposit(uint256 accountSeed, uint256 tokenSeed, uint256 amountSeed) external {
        _tokens[tokenSeed % 4].mint(address(accounts[accountSeed % 2]), _bound(amountSeed, 0, 5_000e18));
    }

    /// @dev Someone sends tokens to the executor directly. Not the executor's fault and not its money; the
    /// invariant is that it never ends up holding anything beyond such donations.
    function donate(uint256 tokenSeed, uint256 amountSeed) external {
        BurnableToken token = _tokens[tokenSeed % 5];
        uint256 amount = _bound(amountSeed, 0, 100e18);
        token.mint(address(executor), amount);
        ghostDonated[address(token)] += amount;
    }

    // =========================================================== Safe administration

    function safeAdmin(uint256 actionSeed, uint256 valueSeed) external {
        uint256 action = actionSeed % 7;
        if (action == 0) {
            executor.setGlobalPaused(!executor.globalPaused());
        } else if (action == 1) {
            executor.setMaxBuyBps(uint16(_bound(valueSeed, 0, 20_000)));
        } else if (action == 2) {
            registry.setDefaultFeeBps(uint16(_bound(valueSeed, 0, 300)));
        } else if (action == 3) {
            RandomVenue venue = valueSeed % 2 == 0 ? erc20Venue : permit2Venue;
            (AtpExecutor.VenueKind kind,) = executor.venues(address(venue));
            if (kind == AtpExecutor.VenueKind.NONE) {
                executor.setVenue(
                    address(venue),
                    venue == erc20Venue ? AtpExecutor.VenueKind.ERC20_APPROVE : AtpExecutor.VenueKind.PERMIT2,
                    address(venue)
                );
            } else {
                executor.removeVenue(address(venue));
            }
        } else if (action == 4) {
            registry.setOperator(registry.operator() == address(0) ? OPERATOR : address(0));
        } else if (action == 5) {
            executor.setMinBatchFee(_bound(valueSeed, 0, executor.minBatchFeeCeiling()));
        } else {
            registry.setStrategyFeeBps(
                valueSeed % 2 == 0 ? strategyAB : strategyAC, uint16(_bound(valueSeed, 0, 300))
            );
        }
    }

    /// @dev (3) A non-Safe caller tries one admin function; any success is a violation.
    function unauthorizedAdmin(uint256 callerSeed, uint256 actionSeed, uint256 valueSeed) external {
        address caller = [
            OPERATOR, OUTSIDER, address(accounts[0]), address(accounts[1]), address(erc20Venue)
        ][callerSeed % 5];
        ++callsAdminAttempts;
        uint256 action = actionSeed % 16;
        address target;
        bytes memory data;
        if (action == 0) {
            (target, data) =
            (
                address(executor),
                abi.encodeCall(
                    AtpExecutor.setVenue,
                    (address(unlistedVenue), AtpExecutor.VenueKind.ERC20_APPROVE, address(unlistedVenue))
                )
            );
        } else if (action == 1) {
            (target, data) = (address(executor), abi.encodeCall(AtpExecutor.removeVenue, (address(ur))));
        } else if (action == 2) {
            (target, data) = (address(executor), abi.encodeCall(AtpExecutor.setFeeRecipient, (caller)));
        } else if (action == 3) {
            (target, data) =
            (address(executor), abi.encodeCall(AtpExecutor.setGlobalPaused, (valueSeed % 2 == 0)));
        } else if (action == 4) {
            (target, data) =
            (
                address(executor),
                abi.encodeCall(AtpExecutor.setMaxBuyBps, (uint16(_bound(valueSeed, 0, 20_000))))
            );
        } else if (action == 5) {
            (target, data) = (address(registry), abi.encodeCall(AtpRegistry.setOperator, (caller)));
        } else if (action == 6) {
            (target, data) =
            (
                address(registry),
                abi.encodeCall(AtpRegistry.setDefaultFeeBps, (uint16(_bound(valueSeed, 0, 300))))
            );
        } else if (action == 7) {
            (target, data) =
            (
                address(registry),
                abi.encodeCall(AtpRegistry.setStrategyFeeBps, (strategyAB, uint16(_bound(valueSeed, 1, 300))))
            );
        } else if (action == 8) {
            (target, data) = (address(registry), abi.encodeCall(AtpRegistry.transferOwnership, (caller)));
        } else if (action == 9) {
            address[] memory assets = new address[](1);
            assets[0] = address(tokenC);
            uint16[] memory weights = new uint16[](1);
            weights[0] = 10_000;
            (target, data) =
            (
                address(registry),
                abi.encodeCall(AtpRegistry.publishVersion, (strategyAB, assets, weights, bytes32(0), 0))
            );
        } else if (action == 10) {
            (target, data) =
            (
                address(router),
                abi.encodeCall(
                    AtpMultiPoolOracle.setOracle,
                    (routerAssetUnregistered, routerSparePool, 30 minutes, 100, 1 hours)
                )
            );
        } else if (action == 11) {
            (target, data) =
            (address(router), abi.encodeCall(AtpMultiPoolOracle.clearOracle, (routerAssetWithSecondary)));
        } else if (action == 12) {
            (target, data) =
            (address(router), abi.encodeCall(AtpMultiPoolOracle.clearSecondary, (routerAssetWithSecondary)));
        } else if (action == 13) {
            (target, data) =
            (
                address(router),
                abi.encodeCall(
                    AtpMultiPoolOracle.setSecondary,
                    (routerAssetNoSecondary, spareFeedA, spareFeedB, 1 hours, 1 hours, 200)
                )
            );
        } else if (action == 14) {
            (target, data) = (address(router), abi.encodeCall(AtpMultiPoolOracle.transferOwnership, (caller)));
        } else {
            (target, data) =
            (address(executor), abi.encodeCall(AtpExecutor.setMinBatchFee, (valueSeed % 5e18)));
        }
        vm.prank(caller);
        (bool ok,) = target.call(data);
        if (ok) ++ghostUnauthorizedAdmin;
    }

    // =========================================================== enrollment and pause sources (A10-2)

    function enroll(uint256 callerSeed, uint256 accountSeed, bool strategySeed) external {
        ++callsEnroll;
        TestAccount account = accounts[accountSeed % 2];
        uint256 id = strategySeed ? strategyAB : strategyAC;
        uint256 who = callerSeed % 4; // 0 account itself, 1 operator, 2 outsider, 3 Safe
        address operator = registry.operator();
        if (!modelEnrolled[address(account)]) {
            vm.prank(address(account));
            registry.approveEnrollment(id, 1);
        }
        bool expected = who == 0 || (who == 1 && operator == OPERATOR && !modelEnrolled[address(account)]);
        bool ok;
        if (who == 0) {
            try account.enroll(registry, id) {
                ok = true;
            } catch { }
        } else {
            vm.prank(who == 1 ? OPERATOR : who == 2 ? OUTSIDER : address(this));
            try registry.enroll(address(account), id, 1) {
                ok = true;
            } catch { }
        }
        if (ok != expected) ++ghostEnrollViolations;
        if (ok) _modelEnroll(address(account), id, who == 0);
    }

    function _modelEnroll(address account, uint256 id, bool byAccount) internal {
        modelEnrolled[account] = true;
        modelStrategy[account] = id;
        if (byAccount) modelFlags[account] = 0;
    }

    function setPaused(uint256 callerSeed, uint256 accountSeed, bool paused) external {
        ++callsPause;
        TestAccount account = accounts[accountSeed % 2];
        uint256 who = callerSeed % 4; // 0 account itself, 1 operator, 2 outsider, 3 Safe
        bool operatorActive = registry.operator() == OPERATOR;
        bool expected =
            modelEnrolled[address(account)] && (who == 0 || who == 3 || (who == 1 && operatorActive));
        bool ok;
        if (who == 0) {
            try account.setPaused(registry, paused) {
                ok = true;
            } catch { }
        } else {
            vm.prank(who == 1 ? OPERATOR : who == 2 ? OUTSIDER : address(this));
            try registry.setPaused(address(account), paused) {
                ok = true;
            } catch { }
        }
        if (ok != expected) ++ghostPauseViolations;
        if (!ok) return;
        uint8 flags = modelFlags[address(account)];
        if (who == 0) flags = paused ? flags | 4 : 0;
        else if (who == 3) flags = paused ? flags | 1 : flags & ~uint8(3);
        else flags = paused ? flags | 2 : flags & ~uint8(2);
        modelFlags[address(account)] = flags;
    }
}
