// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { RoutingBase } from "./RoutingBase.sol";
import { RoutingTypes as R } from "../../../../src/atp/borrow/v2/RoutingTypes.sol";
import { IAtpBorrowExecutorV2 as IExec } from "../../../../src/atp/borrow/v2/IAtpBorrowExecutorV2.sol";
import { IAtpBorrowRegistryV2 as IReg } from "../../../../src/atp/borrow/v2/IAtpBorrowRegistryV2.sol";
import { AtpBorrowRegistryV2 } from "../../../../src/atp/borrow/v2/AtpBorrowRegistryV2.sol";
import { AtpBorrowLensV2 } from "../../../../src/atp/borrow/v2/AtpBorrowLensV2.sol";
import { MockLendingOracle } from "../../../../src/testnet/lending/MockLendingOracle.sol";
import { TestnetToken } from "../../../../src/testnet/TestnetToken.sol";

interface IRedeemable {
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256);
    function redeem(uint256 tokens) external returns (uint256);
    function withdraw(address token, uint256 amount, address receiver) external returns (uint256);
}

/// @notice Drives random sequences of what a session key (and anyone) can do to one portfolio account, of what
/// the owner can change under it (tiers, lines) and of what the world does (prices, time, rewards), and checks
/// after every successful action on the account that no position ended closer to trouble than the rules allow
/// and that no loan-token value went anywhere: per loan token, wallet + box + vault holdings - debt is the
/// same before and after. The account is the invariant test contract itself (it also owns the registry and
/// the mocks); this handler acts as it with `vm.prank`.
contract RoutingHandler is Test {
    uint256 internal constant MAX = type(uint256).max;

    IExec public immutable lend;
    AtpBorrowRegistryV2 public immutable credit;
    AtpBorrowLensV2 public immutable lens;
    MockLendingOracle public immutable oracle;
    address public immutable account;
    address public immutable reporter;
    bytes32[] public routes;
    bytes32[] public vaults;
    address[] public collaterals;
    bytes32[] public reportedVaults;
    address[] public loans;
    TestnetToken public immutable reward;
    address public immutable stranger;

    /// @dev Loan-token value an action may round away, raw units of 18 decimals: a vToken is 1e-8 of a token
    /// times its exchange rate, so one mint or redeem rounds by up to about 1e10.
    uint256 internal constant DUST = 1e11;

    uint256 public actions;
    uint256 public opened;
    uint256 public reduced;
    uint256 public migrated;
    uint256 public switched;
    uint256 public released;
    uint256 public rescued;
    uint256 public deleveraged;
    uint256 public deleveragedAmount;
    uint256 public rewardsCollected;
    uint256 public rewardsSwept;
    uint256 public rewardMinted;
    uint256 public tierChanges;
    uint256 public lineChanges;
    /// @dev Successful account actions on a position whose collateral has no tier (budget zero).
    uint256 public reducedWithoutBudget;
    /// @dev Set when an account action left a position worse than the rules allow. Must stay empty.
    string public violation;
    /// @dev Set when an action changed the account's loan-token value. Must stay empty.
    string public leak;
    int256[] internal _equity;

    constructor(
        IExec lend_,
        AtpBorrowRegistryV2 credit_,
        AtpBorrowLensV2 lens_,
        MockLendingOracle oracle_,
        address account_,
        address reporter_,
        bytes32[] memory routes_,
        bytes32[] memory vaults_,
        address[] memory collaterals_,
        bytes32[] memory reportedVaults_,
        address[] memory loans_,
        TestnetToken reward_,
        address stranger_
    ) {
        lend = lend_;
        credit = credit_;
        lens = lens_;
        oracle = oracle_;
        account = account_;
        reporter = reporter_;
        routes = routes_;
        vaults = vaults_;
        collaterals = collaterals_;
        reportedVaults = reportedVaults_;
        loans = loans_;
        reward = reward_;
        stranger = stranger_;
        _equity = new int256[](loans_.length);
    }

    // ---- account actions (what a session key may send) ----

    function open(uint256 routeSeed, uint256 vaultSeed, uint256 collateral, uint256 borrow) external {
        bytes32 route = routes[routeSeed % routes.length];
        bytes32 vault = _vaultFor(route, vaultSeed);
        R.Route memory r = credit.route(route);
        collateral = _bound(collateral, 0, 20e18);
        R.Health[] memory before = _snapshot();
        // Room under the budget once the collateral is in (all prices are per whole 18-decimal token), and
        // sometimes a little more than the room, which must be refused.
        R.Health memory h = lens.health(route, account);
        uint256 added = collateral * oracle.prices(r.collateral) * 1e10 / 1e18 * lens.targetLtv(route) / 1e18;
        uint256 room = h.budgetValue + added > h.debtValue ? h.budgetValue + added - h.debtValue : 0;
        borrow = _bound(borrow, 0, room * 104 / 100);
        vm.prank(account);
        try lend.executeOpen(account, route, vault, collateral, borrow, block.timestamp) {
            ++opened;
            _check(before, true, "open");
        } catch { }
    }

    function reduce(uint256 routeSeed, uint256 vaultSeed, uint256 percent, uint256 mode) external {
        bytes32 route = _heldRoute(routeSeed);
        bytes32 vault = _heldVaultFor(route, vaultSeed);
        R.Health[] memory before = _snapshot();
        uint256 owed = lens.routeDebt(route, account);
        uint256 posted = lens.collateral(route, account);
        percent = _bound(percent, 1, 100);
        uint256 repay;
        uint256 withdraw;
        mode = mode % 5;
        if (mode == 0) {
            repay = owed * percent / 100; // repay only
        } else if (mode == 1) {
            (repay, withdraw) = (owed * percent / 100, posted * percent / 110); // shrink in proportion
        } else if (mode == 2) {
            withdraw = posted * percent / 100; // collateral only: allowed only inside the budget
        } else if (mode == 3) {
            (repay, withdraw) = (owed * percent / 200, posted * percent / 100); // too much collateral
        } else {
            (repay, withdraw) = (MAX, MAX); // close
        }
        vm.prank(account);
        try lend.executeReduce(account, route, vault, repay, withdraw, 1e18, block.timestamp) {
            ++reduced;
            if (before[_index(route)].budgetValue == 0 && before[_index(route)].debtValue != 0) {
                ++reducedWithoutBudget;
            }
            _check(before, false, "reduce");
        } catch { }
    }

    function migrate(uint256 fromSeed, uint256 toSeed, uint256 vaultSeed, uint256 borrow) external {
        bytes32 from = _heldRoute(fromSeed);
        // A destination for the same collateral (when the seed lands on another one it must be refused).
        address collateral = credit.route(from).collateral;
        bytes32 to = routes[toSeed % routes.length];
        for (uint256 i; i < routes.length && toSeed % 9 != 0; ++i) {
            bytes32 id = routes[(toSeed + i) % routes.length];
            if (id != from && credit.route(id).collateral == collateral) {
                to = id;
                break;
            }
        }
        R.Health[] memory before = _snapshot();
        // Up to what the destination's target allows for this collateral, sometimes a little above.
        uint256 value = lens.collateral(from, account) * oracle.prices(collateral) * 1e10 / 1e18;
        borrow = _bound(borrow, 0, value * lens.targetLtv(to) / 1e18 * 102 / 100);
        bytes32 fromVault = _heldVaultFor(from, vaultSeed);
        bytes32 toVault = _vaultFor(to, vaultSeed >> 8);
        vm.prank(account);
        try lend.executeMigrate(account, from, fromVault, to, toVault, borrow, 1e18, block.timestamp) {
            ++migrated;
            _check(before, false, "migrate");
        } catch { }
    }

    function switchVault(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        bytes32[] memory held = credit.accountVaults(account);
        bytes32 from = held.length == 0 ? vaults[fromSeed % vaults.length] : held[fromSeed % held.length];
        // Mostly another vault of the same token.
        bytes32 to = vaults[toSeed % vaults.length];
        address token = credit.vault(from).token;
        for (uint256 i; i < vaults.length && toSeed % 6 != 0; ++i) {
            bytes32 id = vaults[(toSeed + i) % vaults.length];
            if (id != from && credit.vault(id).token == token) {
                to = id;
                break;
            }
        }
        amount = amount % 3 == 0 ? MAX : _bound(amount, 1, 200e18);
        R.Health[] memory before = _snapshot();
        vm.prank(account);
        try lend.executeSwitchVault(account, from, to, amount, block.timestamp) {
            ++switched;
            _check(before, false, "switch");
        } catch { }
    }

    function release(uint256 vaultSeed) external {
        bytes32 id = _heldVault(vaultSeed);
        if (vaultSeed % 2 == 0) _closeToken(credit.vault(id).token, id);
        R.Health[] memory before = _snapshot();
        vm.prank(account);
        try lend.executeRelease(account, id, block.timestamp) {
            ++released;
            _check(before, false, "release");
        } catch { }
    }

    /// @dev The owner-only exit: receipts as they are, to the account, which redeems them itself right away
    /// (so the "account holds no receipt" invariant keeps its meaning for everything else).
    function rescue(uint256 vaultSeed) external {
        bytes32 id = _heldVault(vaultSeed);
        R.Vault memory v = credit.vault(id);
        if (vaultSeed % 2 == 0) _closeToken(v.token, id);
        R.Health[] memory before = _snapshot();
        vm.prank(account);
        try lend.executeRescue(account, id, block.timestamp) {
            ++rescued;
            uint256 held = IERC20(v.receipt).balanceOf(account);
            vm.startPrank(account);
            if (v.kind == R.VaultKind.ERC4626) IRedeemable(v.target).redeem(held, account, account);
            else if (v.kind == R.VaultKind.VENUS) IRedeemable(v.target).redeem(held);
            else IRedeemable(v.target).withdraw(v.token, MAX, account);
            vm.stopPrank();
            _check(before, false, "rescue");
        } catch { }
    }

    // ---- rewards ----

    /// @dev A venue pays an incentive: to the box (vault rewards) or to the account (borrow rewards).
    function payReward(uint256 amount, bool toAccount) external {
        amount = _bound(amount, 1, 5e18);
        rewardMinted += amount;
        address to = toAccount ? account : lend.boxOf(account);
        vm.prank(account); // the test account is the reward token's minter
        reward.mint(to, amount);
    }

    /// @dev Anyone: box -> account.
    function collectRewards() external {
        vm.prank(stranger);
        try lend.collectRewards(account, address(reward)) returns (uint256 amount) {
            if (amount != 0) ++rewardsCollected;
        } catch { }
    }

    /// @dev The account (session key): box and up to `amount` of the account's own -> the owner's recipient.
    function sweepRewards(uint256 amount) external {
        amount = amount % 4 == 0 ? MAX : _bound(amount, 0, 6e18);
        vm.prank(account);
        try lend.executeSweepRewards(account, address(reward), amount, block.timestamp) {
            ++rewardsSwept;
        } catch { }
    }

    // ---- the owner ----

    /// @dev A collateral changes tier or loses it (one time in six): budgets move under open positions.
    function setTier(uint256 tokenSeed, uint256 tierSeed) external {
        vm.prank(account);
        R.Tier tier = tierSeed % 6 == 0 ? R.Tier.NONE : R.Tier(1 + tierSeed % 3);
        credit.setAssetTier(collaterals[tokenSeed % collaterals.length], tier);
        ++tierChanges;
    }

    /// @dev The owner tightens (or resets) a route's target and deleverage lines.
    function setLines(uint256 routeSeed, uint256 target, uint256 deleverage) external {
        bytes32 route = routes[routeSeed % routes.length];
        vm.startPrank(account);
        credit.setLtvConfig(route, 0, 0);
        (uint256 targetCap, uint256 deleverageCap,) = lens.routeLines(route);
        if (targetCap != 0 && target % 5 != 0) {
            target = _bound(target, targetCap / 2, targetCap);
            deleverage = _bound(deleverage, (target + deleverageCap) / 2, deleverageCap);
            try credit.setLtvConfig(route, target, deleverage) { } catch { }
        }
        vm.stopPrank();
        ++lineChanges;
    }

    // ---- anyone ----

    function deleverage(uint256 routeSeed, uint256 vaultSeed) external {
        bytes32 route = _heldRoute(routeSeed);
        _deleverage(route, _heldVaultFor(route, vaultSeed));
    }

    function _deleverage(bytes32 route, bytes32 vault) internal {
        // Accrue everything first, so interest is not mistaken for the action's effect.
        _measure(true);
        lens.sync(route, account);
        R.Health memory before = lens.health(route, account);
        vm.prank(stranger);
        try lend.executeDeleverage(account, route, vault, MAX) returns (uint256 repaid) {
            ++deleveraged;
            deleveragedAmount += repaid;
            R.Health memory h = lens.health(route, account);
            if (h.debtValue > before.debtValue) violation = "deleverage raised the debt";
            _measure(false);
        } catch { }
    }

    /// @dev The price of a held, indebted route's collateral falls far enough to cross its deleverage line
    /// (short of the venue's liquidation line), then a stranger deleverages it.
    function dropAndDeleverage(uint256 routeSeed, uint256 vaultSeed, uint256 depth) external {
        bytes32[] memory held = credit.accountRoutes(account);
        bytes32 route;
        for (uint256 i; i < held.length && route == bytes32(0); ++i) {
            bytes32 id = held[(routeSeed + i) % held.length];
            if (credit.principal(account, id) != 0) route = id;
        }
        if (route == bytes32(0)) return;
        lens.sync(route, account);
        R.Health memory h = lens.health(route, account);
        if (h.debtValue < h.deleverageValue && h.deleverageValue != 0) {
            // Somewhere between the deleverage line and halfway to the liquidation line.
            uint256 atLine = h.debtValue * 1e18 / h.deleverageValue;
            uint256 atLiquidation = h.debtValue * 1e18 / h.liquidationValue;
            uint256 factor = atLine - _bound(depth, 1, 50) * (atLine - atLiquidation) / 100;
            address token = credit.route(route).collateral;
            uint256 price = oracle.prices(token) * factor / 1e18;
            if (price == 0) return;
            vm.prank(account);
            oracle.setPrice(token, price);
        }
        _deleverage(route, _heldVaultFor(route, vaultSeed));
    }

    function reconcile(uint256 routeSeed) external {
        credit.reconcile(account, routes[routeSeed % routes.length]);
    }

    // ---- the world ----

    function movePrice(uint256 tokenSeed, uint256 priceE8) external {
        // Between 50 and 140 USD around the 100 USD start: enough to cross the deleverage lines in both
        // directions (nobody liquidates here: liquidations are out of scope).
        address token = collaterals[tokenSeed % collaterals.length];
        priceE8 = _bound(priceE8, 50e8, 140e8);
        vm.prank(account); // the test account also owns the mock oracle
        oracle.setPrice(token, priceE8);
    }

    function warp(uint256 time) public {
        skip(bound(time, 1 hours, 3 days));
        // Rates as the backend would report them: a borrow incentive on every route (so that the low-yield
        // Venus supply vault is still a positive carry) and the ERC4626 vaults' rate.
        IReg.RouteReport[] memory none = new IReg.RouteReport[](routes.length);
        for (uint256 i; i < none.length; ++i) {
            none[i] = IReg.RouteReport(routes[i], 0.03e18, 0);
        }
        IReg.VaultReport[] memory reports = new IReg.VaultReport[](reportedVaults.length);
        for (uint256 i; i < reports.length; ++i) {
            reports[i] = IReg.VaultReport(reportedVaults[i], 0.045e18, 0);
        }
        vm.prank(reporter);
        credit.reportRates(none, reports);
    }

    // ---- internals ----

    /// @dev A route the account has a position on, when it has any.
    function _heldRoute(uint256 seed) internal view returns (bytes32) {
        bytes32[] memory held = credit.accountRoutes(account);
        return held.length == 0 || seed % 11 == 0 ? routes[seed % routes.length] : held[seed % held.length];
    }

    /// @dev Close every position of the account in `token` through a vault other than `keep` where it holds
    /// one, with the account's own cash for any shortfall: what `keep` holds is then left without debt
    /// (the state release and rescue are for).
    function _closeToken(address token, bytes32 keep) internal {
        bytes32[] memory held = credit.accountRoutes(account);
        bytes32[] memory boxed = credit.accountVaults(account);
        bytes32 through = keep;
        for (uint256 i; i < boxed.length; ++i) {
            if (boxed[i] != keep && credit.vault(boxed[i]).token == token) through = boxed[i];
        }
        for (uint256 i; i < held.length; ++i) {
            if (credit.route(held[i]).loan != token) continue;
            R.Health[] memory before = _snapshot();
            uint256 cash = IERC20(token).balanceOf(account);
            vm.prank(account);
            try lend.executeReduce(account, held[i], through, MAX, MAX, cash, block.timestamp) {
                ++reduced;
                _check(before, false, "close");
            } catch { }
        }
    }

    function _index(bytes32 route) internal view returns (uint256 i) {
        while (routes[i] != route) ++i;
    }

    /// @dev A vault the account's box holds something in, when there is one.
    function _heldVault(uint256 seed) internal view returns (bytes32) {
        bytes32[] memory held = credit.accountVaults(account);
        return held.length == 0 || seed % 9 == 0 ? vaults[seed % vaults.length] : held[seed % held.length];
    }

    /// @dev A vault of the route's loan token that the account's box actually holds, when there is one.
    function _heldVaultFor(bytes32 route, uint256 seed) internal view returns (bytes32) {
        address loan = credit.route(route).loan;
        bytes32[] memory held = credit.accountVaults(account);
        for (uint256 i; i < held.length && seed % 13 != 0; ++i) {
            bytes32 id = held[(seed + i) % held.length];
            if (credit.vault(id).token == loan) return id;
        }
        return _vaultFor(route, seed);
    }

    function _vaultFor(bytes32 route, uint256 seed) internal view returns (bytes32) {
        // Mostly a vault of the route's loan token, sometimes any vault (must be refused).
        address loan = credit.route(route).loan;
        for (uint256 i; i < vaults.length; ++i) {
            bytes32 id = vaults[(seed + i) % vaults.length];
            if (seed % 7 == 0 || credit.vault(id).token == loan) return id;
        }
        return vaults[0];
    }

    /// @dev Health of every route after accruing it, so interest is not mistaken for the action's effect.
    function _snapshot() internal returns (R.Health[] memory h) {
        ++actions;
        h = new R.Health[](routes.length);
        for (uint256 i; i < routes.length; ++i) {
            lens.sync(routes[i], account);
            h[i] = lens.health(routes[i], account);
        }
        _measure(true);
    }

    /// @dev Per loan token: wallet + idle in the box + vault holdings - debt, everything accrued. Recorded
    /// before an action, compared after it: an action moves value between these places, never out of them.
    function _measure(bool record) internal {
        for (uint256 t; t < loans.length; ++t) {
            address token = loans[t];
            lens.syncToken(account, token);
            uint256 has = IERC20(token).balanceOf(account) + lens.idleOf(account, token);
            for (uint256 i; i < vaults.length; ++i) {
                if (credit.vault(vaults[i]).token == token) {
                    has += lens.vaultStatus(vaults[i], account).assets;
                }
            }
            int256 equity = int256(has) - int256(lens.tokenDebt(account, token));
            if (record) {
                _equity[t] = equity;
            } else if (equity > _equity[t] + int256(DUST) || equity < _equity[t] - int256(DUST)) {
                leak = string.concat(
                    "loan-token value changed by ",
                    vm.toString(equity - _equity[t]),
                    " in ",
                    vm.toString(token)
                );
            }
        }
    }

    /// @dev The rule: after an account action every position is within its budget, or (never for new debt)
    /// ended with debt / budget not higher and health factor not lower than before. And the loan-token value
    /// is where it was.
    function _check(R.Health[] memory before, bool newDebt, string memory what) internal {
        _measure(false);
        for (uint256 i; i < routes.length; ++i) {
            R.Health memory h = lens.health(routes[i], account);
            if (h.debtValue <= h.budgetValue) continue;
            bool worse = h.debtValue * before[i].budgetValue > before[i].debtValue * h.budgetValue
                || h.debtValue * before[i].liquidationValue > before[i].debtValue * h.liquidationValue;
            bool changed =
                h.debtValue != before[i].debtValue || h.collateralValue != before[i].collateralValue;
            if (worse || (newDebt && changed && h.debtValue > before[i].debtValue)) {
                violation = string.concat(what, ": a position ended past its budget and worse than before");
            }
        }
    }
}

/// @notice Review "Tests": invariants of routing v2 under random session-key action sequences, price moves,
/// time and third-party calls.
/// forge-config: default.invariant.runs = 48
/// forge-config: default.invariant.depth = 80
/// forge-config: default.invariant.fail-on-revert = false
/// forge-config: ci.invariant.runs = 64
/// forge-config: ci.invariant.depth = 100
contract RoutingInvariantTest is RoutingBase {
    RoutingHandler internal handler;
    address[5] internal loansAndCollaterals;

    function setUp() public override {
        super.setUp();
        bytes32[] memory routes = new bytes32[](7);
        (routes[0], routes[1], routes[2], routes[3]) = (V_NVDA_T, V_NVDA_C, V_TSLA_T, V_TSLA_C);
        (routes[4], routes[5], routes[6]) = (L_TSLA_T, L_TSLA_C, L_QQQ_C);
        bytes32[] memory vaults = new bytes32[](4);
        (vaults[0], vaults[1], vaults[2], vaults[3]) = (K_T, K_C, K_VC, K_AT);
        address[] memory collaterals = new address[](3);
        (collaterals[0], collaterals[1], collaterals[2]) = (address(nvda), address(tsla), address(qqq));
        bytes32[] memory reported = new bytes32[](2);
        (reported[0], reported[1]) = (K_T, K_C);
        address[] memory loans = new address[](2);
        (loans[0], loans[1]) = (address(usdt), address(usdc));
        handler = new RoutingHandler(
            lend,
            credit,
            lens,
            oracle,
            address(this),
            REPORTER,
            routes,
            vaults,
            collaterals,
            reported,
            loans,
            lista,
            KEEPER
        );
        // Venus collateral that is not all alike: TSLA counts for 90% at the venue but sits in the 20% tier
        // (target 20%, deleverage 60%); NVDA counts for 60% in the 30% tier (target 30%, deleverage 40%).
        // What one unit of budget costs in health factor differs between them (the review's H1b).
        comptroller.setCollateralFactor(address(vTsla), 0.9e18);
        credit.setAssetTier(address(tsla), R.Tier.CRYPTO_LINKED);
        // A little of the account's own loan tokens: a fresh position's vault is a raw unit short of its debt
        // (share rounding), and closing or migrating it needs that unit from the account (`maxCashIn`).
        usdt.mint(address(this), 100e18);
        usdc.mint(address(this), 100e18);
        usdt.approve(address(lend), MAX);
        usdc.approve(address(lend), MAX);
        lista.approve(address(lend), MAX);
        handler.warp(1 hours); // first rate report, incentives included
        targetContract(address(handler));
        // Weighted towards the account's own actions: they are the point.
        bytes4[] memory selectors = new bytes4[](24);
        selectors[0] = RoutingHandler.open.selector;
        selectors[1] = RoutingHandler.open.selector;
        selectors[2] = RoutingHandler.open.selector;
        selectors[3] = RoutingHandler.open.selector;
        selectors[4] = RoutingHandler.reduce.selector;
        selectors[5] = RoutingHandler.reduce.selector;
        selectors[6] = RoutingHandler.reduce.selector;
        selectors[7] = RoutingHandler.reduce.selector;
        selectors[8] = RoutingHandler.migrate.selector;
        selectors[9] = RoutingHandler.migrate.selector;
        selectors[10] = RoutingHandler.switchVault.selector;
        selectors[11] = RoutingHandler.deleverage.selector;
        selectors[12] = RoutingHandler.movePrice.selector;
        selectors[13] = RoutingHandler.warp.selector;
        selectors[14] = RoutingHandler.release.selector;
        selectors[15] = RoutingHandler.reconcile.selector;
        selectors[16] = RoutingHandler.dropAndDeleverage.selector;
        selectors[17] = RoutingHandler.dropAndDeleverage.selector;
        selectors[18] = RoutingHandler.rescue.selector;
        selectors[19] = RoutingHandler.payReward.selector;
        selectors[20] = RoutingHandler.collectRewards.selector;
        selectors[21] = RoutingHandler.sweepRewards.selector;
        selectors[22] = RoutingHandler.setTier.selector;
        selectors[23] = RoutingHandler.setLines.selector;
        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
    }

    /// The executor, its extension and the adapters hold nothing and keep no allowance between calls.
    function invariant_executorAndAdaptersHoldNothing() public view {
        _noResidue();
        address[5] memory tokens = [address(usdt), address(usdc), address(nvda), address(tsla), address(qqq)];
        for (uint256 i; i < tokens.length; ++i) {
            assertEq(IERC20(tokens[i]).balanceOf(address(extension)), 0, "extension holds tokens");
        }
    }

    /// Strategy money is only ever in the venues or the box: the account holds no vault receipt, and nobody
    /// else (the handler, the keeper, the reporter, the reward recipient) ever received a token.
    function invariant_fundsOnlyInAccountBoxAndVenues() public view {
        _accountHoldsNoStrategyMoney();
        address[4] memory outsiders = [address(handler), KEEPER, REPORTER, WALLET];
        address[5] memory tokens = [address(usdt), address(usdc), address(nvda), address(tsla), address(qqq)];
        for (uint256 o; o < outsiders.length; ++o) {
            for (uint256 t; t < tokens.length; ++t) {
                assertEq(IERC20(tokens[t]).balanceOf(outsiders[o]), 0, "an outsider received tokens");
            }
        }
    }

    /// Collateral is conserved: what the account holds plus what it posted (Lista positions, Venus vTokens)
    /// is what it started with. No action can lose or leak collateral.
    function invariant_collateralIsConserved() public view {
        assertApproxEqAbs(
            nvda.balanceOf(address(this)) + lens.collateral(V_NVDA_T, address(this)), 1_000e18, 1e11, "NVDA"
        );
        assertApproxEqAbs(
            tsla.balanceOf(address(this)) + lens.collateral(V_TSLA_T, address(this))
                + lens.collateral(L_TSLA_T, address(this)) + lens.collateral(L_TSLA_C, address(this)),
            1_000e18,
            1e11,
            "TSLA"
        );
        assertEq(qqq.balanceOf(address(this)) + lens.collateral(L_QQQ_C, address(this)), 1_000e18, "QQQ");
    }

    /// No account action ever left a position past its budget and worse than before (checked inside the
    /// handler after every successful open / reduce / migrate / switch), and deleverage never raised debt.
    function invariant_noActionWorsensAPositionPastItsBudget() public view {
        assertEq(bytes(handler.violation()).length, 0, handler.violation());
    }

    /// The registry's books add up: the account's principal in USD is the sum over its routes, never above
    /// the consent ceiling, and a route without a position carries no principal.
    function invariant_principalBooksAddUp() public view {
        uint256 sum;
        bytes32[7] memory ids = [V_NVDA_T, V_NVDA_C, V_TSLA_T, V_TSLA_C, L_TSLA_T, L_TSLA_C, L_QQQ_C];
        for (uint256 i; i < ids.length; ++i) {
            sum += credit.principal(address(this), ids[i]);
        }
        assertEq(credit.accountPrincipalUsd(address(this)), sum, "principal sum");
        assertLe(sum, credit.policy(address(this)).maxDebt, "above the consent ceiling");
        assertLe(credit.accountRoutes(address(this)).length, 7);
        assertLe(credit.accountVaults(address(this)).length, 4);
    }

    /// Loan-token value is conserved: per loan token, wallet + box + vault holdings - debt was the same
    /// before and after every successful action on the account (open, reduce, migrate, switch, release,
    /// rescue, third-party deleverage), within rounding dust. Nothing an action does can move it elsewhere.
    function invariant_loanTokenValueIsConserved() public view {
        assertEq(bytes(handler.leak()).length, 0, handler.leak());
    }

    /// Reward tokens only ever sit in the box, in the account, or with the recipient the owner signed for.
    function invariant_rewardsOnlyReachTheAccountOrItsRecipient() public view {
        assertEq(
            lista.balanceOf(lend.boxOf(address(this))) + lista.balanceOf(address(this))
                + lista.balanceOf(WALLET),
            handler.rewardMinted(),
            "reward tokens went elsewhere"
        );
    }

    /// @dev Makes a vacuous campaign visible. Each run's counters are added to a running total kept in the
    /// process environment (the EVM state is reset between runs); the last run's log is the whole campaign.
    function afterInvariant() public {
        _tally("runs", 1);
        _tally("opened", handler.opened());
        _tally("reduced", handler.reduced());
        _tally("reduced_without_budget", handler.reducedWithoutBudget());
        _tally("migrated", handler.migrated());
        _tally("vault_switches", handler.switched());
        _tally("released", handler.released());
        _tally("rescued", handler.rescued());
        _tally("deleveraged", handler.deleveraged());
        _tally("deleveraged_whole_tokens", handler.deleveragedAmount() / 1e18);
        _tally("rewards_collected", handler.rewardsCollected());
        _tally("rewards_swept", handler.rewardsSwept());
        _tally("tier_changes", handler.tierChanges());
        _tally("line_changes", handler.lineChanges());
    }

    function _tally(string memory name, uint256 n) internal {
        string memory key = string.concat("ROUTING_INVARIANT_", name);
        uint256 total = vm.envOr(key, uint256(0)) + n;
        vm.setEnv(key, vm.toString(total));
        emit log_named_uint(string.concat("campaign total: ", name), total);
    }
}
