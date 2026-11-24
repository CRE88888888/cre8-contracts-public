// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { CashSwapperBase } from "./CashSwapperBase.sol";
import { MockStablePool } from "./mocks/MockStablePool.sol";
import { AtpBorrowCashSwapper } from "../../../../src/atp/borrow/v2/AtpBorrowCashSwapper.sol";
import { IAtpBorrowCashSwapper as ISwapper } from "../../../../src/atp/borrow/v2/IAtpBorrowCashSwapper.sol";
import { IAtpBorrowExecutorV2 as IExec } from "../../../../src/atp/borrow/v2/IAtpBorrowExecutorV2.sol";
import { IAtpBorrowRegistryV2 as IReg } from "../../../../src/atp/borrow/v2/IAtpBorrowRegistryV2.sol";
import { IAtpBorrowLensV2 as ILens } from "../../../../src/atp/borrow/v2/IAtpBorrowLensV2.sol";
import { RoutingTypes as R } from "../../../../src/atp/borrow/v2/RoutingTypes.sol";
import { MoolahParams } from "../../../../src/atp/yield/YieldInterfaces.sol";
import { TestnetToken } from "../../../../src/testnet/TestnetToken.sol";
import { MockEarnVault } from "../../../../src/testnet/lending/MockEarnVault.sol";
import { LocalPoolDeployer, LocalPoolVenue, LocalV3Pool } from "../../fixtures/batch3/Batch3Fixture.sol";
import { PancakeV3PoolCode } from "../../fixtures/batch3/PancakeV3PoolCode.sol";

/// @notice `AtpBorrowCashSwapper` (docs/borrow-routing-v2.zh-TW.md §17) against the routing v2 unit fixture
/// and a mock pool: the gap it closes, its cap, its peg bound, who may call what, and what a wrongly
/// allowlisted pool could not do.
contract CashSwapperTest is CashSwapperBase {
    // ---- wiring and owner ----

    function test_wiring_everythingComesFromTheExecutor() public {
        assertEq(swapper.executor(), address(lend));
        assertEq(swapper.borrowRegistry(), address(credit));
        assertEq(swapper.lens(), address(lens));
        assertEq(swapper.registry(), address(registry));
        assertEq(swapper.usdt(), address(usdt));
        assertEq(swapper.maxPegBps(), 50);
        assertEq(swapper.bufferBps(), 100);
        assertEq(swapper.poolOf(address(usdc)), address(pool));
        vm.expectRevert(ISwapper.BadParameter.selector);
        new AtpBorrowCashSwapper(address(0xDEAD));
        // An executor its registry does not recognise.
        vm.mockCall(address(credit), abi.encodeWithSignature("executor()"), abi.encode(address(0xBEEF)));
        vm.expectRevert(ISwapper.BadParameter.selector);
        new AtpBorrowCashSwapper(address(lend));
    }

    function test_owner_isTheCoreRegistryOwner_andFollowsAHandover() public {
        vm.startPrank(STRANGER);
        vm.expectRevert(ISwapper.Unauthorized.selector);
        swapper.setPool(address(usdc), address(0));
        vm.expectRevert(ISwapper.Unauthorized.selector);
        swapper.setLimits(10, 10);
        vm.stopPrank();
        // The registry changes hands: so does this contract, with no call here.
        registry.transferOwnership(STRANGER);
        vm.prank(STRANGER);
        registry.acceptOwnership();
        vm.expectRevert(ISwapper.Unauthorized.selector);
        swapper.setLimits(10, 10);
        vm.prank(STRANGER);
        swapper.setLimits(10, 10);
        assertEq(swapper.maxPegBps(), 10);
    }

    function test_setPool_onlyAUsdtPoolOfAnAllowedLoanToken() public {
        // USDT itself, and a token that is not a loan token.
        vm.expectRevert(ISwapper.BadParameter.selector);
        swapper.setPool(address(usdt), address(pool));
        vm.expectRevert(ISwapper.BadParameter.selector);
        swapper.setPool(address(nvda), address(pool));
        // Not a contract; a pool of other tokens; a pool of the token against something else than USDT.
        vm.expectRevert(ISwapper.BadPool.selector);
        swapper.setPool(address(usdc), address(0xB0B));
        MockStablePool other = new MockStablePool(address(usdt), address(nvda), 1e18);
        vm.expectRevert(ISwapper.BadPool.selector);
        swapper.setPool(address(usdc), address(other));
        other = new MockStablePool(address(usdc), address(nvda), 1e18);
        vm.expectRevert(ISwapper.BadPool.selector);
        swapper.setPool(address(usdc), address(other));
        // Replace, then switch the token off.
        other = new MockStablePool(address(usdc), address(usdt), 1e18);
        vm.expectEmit();
        emit ISwapper.PoolSet(address(usdc), address(other));
        swapper.setPool(address(usdc), address(other));
        assertEq(swapper.poolOf(address(usdc)), address(other));
        swapper.setPool(address(usdc), address(0));
        assertEq(swapper.poolOf(address(usdc)), address(0));
        usdc.mint(address(this), 10e18);
        vm.expectRevert(abi.encodeWithSelector(ISwapper.PoolNotSet.selector, address(usdc)));
        swapper.cashOut(address(usdc), 10e18, 0, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(ISwapper.PoolNotSet.selector, address(usdc)));
        swapper.topUp(address(usdc), 1e18, MAX, block.timestamp);
    }

    function test_setLimits_hardCeilings() public {
        vm.expectRevert(ISwapper.BadParameter.selector);
        swapper.setLimits(101, 100);
        vm.expectRevert(ISwapper.BadParameter.selector);
        swapper.setLimits(50, 501);
        vm.expectEmit();
        emit ISwapper.LimitsSet(100, 500);
        swapper.setLimits(100, 500);
        swapper.setLimits(0, 0);
        assertEq(swapper.maxPegBps(), 0);
        assertEq(swapper.bufferBps(), 0);
    }

    // ---- the gap, and closing it ----

    function test_gap_negativeCarryCannotClose_topUpCloses_cashOutReturnsToUsdt() public {
        _openNegativeCarry(2_000e18);
        skip(180 days);
        // Debt outgrew the vault and the account has no USDC: nothing in routing v2 can close this.
        vm.expectPartialRevert(IExec.VaultShortfall.selector);
        _reduce(V_NVDA_C, K_VC, MAX, MAX, 0);

        (uint256 gap, uint256 cap) = _gap();
        uint256 owed = lens.tokenDebt(address(this), address(usdc));
        uint256 held = _held(K_VC);
        assertEq(gap, owed - held, "gap = debt - vault holding (nothing idle yet)");
        assertApproxEqRel(gap, 24.6e18, 0.02e18, "about 180 days of 2.5% on 2,000");
        assertEq(cap, gap + (gap + 99) / 100, "1% buffer, rounded up");

        uint256 usdtBefore = usdt.balanceOf(address(this));
        uint256 poolUsdt = usdt.balanceOf(address(pool));
        vm.expectEmit(true, true, false, false, address(swapper));
        emit ISwapper.ToppedUp(address(this), address(usdc), 0, 0, 0);
        (uint256 usdtIn, uint256 tokenOut) = swapper.topUp(address(usdc), MAX, MAX, block.timestamp);
        assertEq(tokenOut, cap);
        assertEq(lens.idleOf(address(this), address(usdc)), cap, "the box got exactly what was bought");
        assertEq(usdtBefore - usdt.balanceOf(address(this)), usdtIn, "paid by the account");
        assertEq(usdt.balanceOf(address(pool)) - poolUsdt, usdtIn, "straight to the pool");
        assertApproxEqRel(usdtIn, cap, 0.00011e18, "parity plus the pool's 0.01% fee");
        assertEq(usdc.balanceOf(address(this)), 0, "nothing lands in the account");
        _swapperHoldsNothing();
        (gap,) = _gap();
        assertEq(gap, 0, "covered");

        // The ordinary close now works with no account cash; what was bought beyond the debt comes back.
        _reduce(V_NVDA_C, K_VC, MAX, MAX, 0);
        assertEq(lens.tokenDebt(address(this), address(usdc)), 0);
        assertEq(nvda.balanceOf(address(this)), 1_000e18, "collateral back");
        uint256 leftover = usdc.balanceOf(address(this));
        assertApproxEqAbs(leftover, cap - (owed - held), 1e11, "what the top-up bought beyond the gap");
        assertEq(lens.idleOf(address(this), address(usdc)), 0);

        usdtBefore = usdt.balanceOf(address(this));
        vm.expectEmit(address(swapper));
        emit ISwapper.CashedOut(
            address(this), address(usdc), leftover, leftover - (leftover + 9_999) / 10_000
        );
        (uint256 tokenIn, uint256 usdtOut) = swapper.cashOut(address(usdc), MAX, 0, block.timestamp);
        assertEq(tokenIn, leftover);
        assertEq(usdc.balanceOf(address(this)), 0, "no loan token left in the account");
        assertEq(usdt.balanceOf(address(this)) - usdtBefore, usdtOut);
        _swapperHoldsNothing();
        _noResidue();
    }

    function test_topUp_capIsTheShortfallPlusBuffer() public {
        _openNegativeCarry(2_000e18);
        // Opened this block: the vault covers the debt (to the vToken's rounding), nothing to top up.
        skip(1 hours);
        (uint256 gap, uint256 cap) = _gap();
        assertGt(gap, 0);
        skip(90 days);
        (gap, cap) = _gap();
        vm.expectRevert(abi.encodeWithSelector(ISwapper.AboveShortfall.selector, cap + 1, cap));
        swapper.topUp(address(usdc), cap + 1, MAX, block.timestamp);
        vm.expectRevert(ISwapper.ZeroAmount.selector);
        swapper.topUp(address(usdc), 0, MAX, block.timestamp);
        // A part of it, then the rest: the cap follows what is already in the box.
        swapper.topUp(address(usdc), gap / 2, MAX, block.timestamp);
        (uint256 gap2, uint256 cap2) = _gap();
        assertEq(gap2, gap - gap / 2);
        vm.expectRevert(abi.encodeWithSelector(ISwapper.AboveShortfall.selector, cap, cap2));
        swapper.topUp(address(usdc), cap, MAX, block.timestamp);
        swapper.topUp(address(usdc), cap2, MAX, block.timestamp);
        // Covered (by the buffer too): refused until the debt grows past the box again.
        uint256 owed = lens.tokenDebt(address(this), address(usdc));
        uint256 held = _held(K_VC) + lens.idleOf(address(this), address(usdc));
        vm.expectRevert(abi.encodeWithSelector(ISwapper.NoShortfall.selector, owed, held));
        swapper.topUp(address(usdc), 1, MAX, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(ISwapper.NoShortfall.selector, owed, held));
        swapper.topUp(address(usdc), MAX, MAX, block.timestamp);
        // Without a buffer the cap is the gap itself.
        swapper.setLimits(50, 0);
        skip(30 days);
        (gap, cap) = _gap();
        assertGt(gap, 0);
        assertEq(cap, gap);
    }

    function test_topUp_needsABox_aPool_andALiveDeadline() public {
        // No position, no box: there is nothing this could repay.
        vm.expectRevert(ISwapper.NoBox.selector);
        swapper.topUp(address(usdc), 1e18, MAX, block.timestamp);
        vm.prank(STRANGER);
        vm.expectRevert(ISwapper.NoBox.selector);
        swapper.topUp(address(usdc), 1e18, MAX, block.timestamp);
        // A box, but no debt in this token.
        _open(V_TSLA_T, K_T, 100e18, 500e18);
        vm.expectRevert(abi.encodeWithSelector(ISwapper.NoShortfall.selector, 0, 0));
        swapper.topUp(address(usdc), MAX, MAX, block.timestamp);
        _openNegativeCarry(2_000e18);
        skip(30 days);
        vm.expectRevert(ISwapper.DeadlineExpired.selector);
        swapper.topUp(address(usdc), MAX, MAX, block.timestamp - 1);
        vm.expectRevert(ISwapper.DeadlineExpired.selector);
        swapper.cashOut(address(usdc), MAX, 0, block.timestamp - 1);
        // USDT debt is the core's business (it sells assets for USDT): no pool can be set for it.
        vm.expectRevert(abi.encodeWithSelector(ISwapper.PoolNotSet.selector, address(usdt)));
        swapper.topUp(address(usdt), MAX, MAX, block.timestamp);
    }

    function test_topUp_aStrangerOnlyEverActsOnItself() public {
        _openNegativeCarry(2_000e18);
        skip(180 days);
        // There is no account argument: a stranger's call is about the stranger (no box), and cashing out
        // moves the stranger's own tokens to the stranger. The account and its box are untouched.
        uint256 accountUsdt = usdt.balanceOf(address(this));
        usdt.mint(STRANGER, 1_000e18);
        usdc.mint(STRANGER, 1_000e18);
        vm.startPrank(STRANGER);
        usdt.approve(address(swapper), MAX);
        usdc.approve(address(swapper), MAX);
        vm.expectRevert(ISwapper.NoBox.selector);
        swapper.topUp(address(usdc), MAX, MAX, block.timestamp);
        (, uint256 out) = swapper.cashOut(address(usdc), 400e18, 0, block.timestamp);
        vm.stopPrank();
        assertEq(usdc.balanceOf(STRANGER), 600e18);
        assertEq(usdt.balanceOf(STRANGER), 1_000e18 + out);
        assertEq(usdt.balanceOf(address(this)), accountUsdt);
        assertEq(lens.idleOf(address(this), address(usdc)), 0);
    }

    function test_topUp_theBoughtTokenServesAThirdPartyDeleverage() public {
        _openNegativeCarry(2_000e18);
        skip(180 days);
        oracle.setPrice(address(nvda), 45e8); // 4,500 of collateral: debt is past the 40% line
        // A keeper naming a vault the box holds nothing in has nothing to repay with...
        vm.prank(KEEPER);
        vm.expectPartialRevert(ILens.VaultShortfall.selector);
        lend.executeDeleverage(address(this), V_NVDA_C, K_C, MAX);
        // ...until the account's top-up sits in the box.
        (, uint256 bought) = swapper.topUp(address(usdc), MAX, MAX, block.timestamp);
        uint256 owed = lens.tokenDebt(address(this), address(usdc));
        vm.prank(KEEPER);
        uint256 repaid = lend.executeDeleverage(address(this), V_NVDA_C, K_C, MAX);
        assertEq(repaid, bought);
        assertEq(lens.tokenDebt(address(this), address(usdc)), owed - bought);
        assertEq(lens.idleOf(address(this), address(usdc)), 0);
    }

    // ---- peg bound ----

    function test_peg_topUpRefusedAboveTheBound_ownerCanTighten() public {
        _openNegativeCarry(2_000e18);
        skip(180 days);
        _setPremium(60); // USDC at 1.006 USDT
        vm.expectPartialRevert(ISwapper.PegExceeded.selector);
        swapper.topUp(address(usdc), MAX, MAX, block.timestamp);
        _setPremium(40);
        uint256 snapshot = vm.snapshotState();
        (uint256 usdtIn, uint256 tokenOut) = swapper.topUp(address(usdc), MAX, MAX, block.timestamp);
        assertApproxEqRel(usdtIn, tokenOut * 10_041 / 10_000, 0.0001e18, "0.40% premium + 0.01% fee");
        assertLe(usdtIn, tokenOut + tokenOut * 50 / 10_000 + 3);
        vm.revertToState(snapshot);
        // The caller's own bound is tighter than the contract's.
        vm.expectRevert(abi.encodeWithSelector(ISwapper.Slippage.selector, usdtIn, usdtIn - 1));
        swapper.topUp(address(usdc), MAX, usdtIn - 1, block.timestamp);
        swapper.setLimits(30, 100);
        vm.expectPartialRevert(ISwapper.PegExceeded.selector);
        swapper.topUp(address(usdc), MAX, MAX, block.timestamp);
        // A cheap loan token is no reason to refuse buying it.
        _setPremium(-300);
        (usdtIn, tokenOut) = swapper.topUp(address(usdc), MAX, MAX, block.timestamp);
        assertLt(usdtIn, tokenOut);
    }

    function test_peg_cashOutRefusedBelowTheBound() public {
        usdc.mint(address(this), 1_000e18);
        _setPremium(-60); // USDC at 0.994 USDT: selling it would lose more than the bound
        vm.expectPartialRevert(ISwapper.PegExceeded.selector);
        swapper.cashOut(address(usdc), 1_000e18, 0, block.timestamp);
        _setPremium(-40);
        uint256 snapshot = vm.snapshotState();
        (uint256 tokenIn, uint256 usdtOut) = swapper.cashOut(address(usdc), 1_000e18, 0, block.timestamp);
        assertEq(tokenIn, 1_000e18);
        assertApproxEqRel(usdtOut, 995.9e18, 0.0001e18, "0.40% discount + 0.01% fee");
        vm.revertToState(snapshot);
        vm.expectRevert(abi.encodeWithSelector(ISwapper.Slippage.selector, usdtOut, usdtOut + 1));
        swapper.cashOut(address(usdc), 1_000e18, usdtOut + 1, block.timestamp);
        vm.expectRevert(ISwapper.ZeroAmount.selector);
        swapper.cashOut(address(usdc), 0, 0, block.timestamp);
        // A dear loan token sells for more USDT than its face: fine.
        _setPremium(300);
        (, usdtOut) = swapper.cashOut(address(usdc), 1_000e18, 0, block.timestamp);
        assertGt(usdtOut, 1_000e18);
        // Nothing to sell.
        vm.expectRevert(ISwapper.ZeroAmount.selector);
        swapper.cashOut(address(usdc), MAX, 0, block.timestamp);
    }

    function test_peg_countsDecimals_6DecimalLoanToken() public {
        // A 6-decimal loan token on a Lista market, with a 6-decimal vault that earns nothing.
        TestnetToken usd6 = new TestnetToken("USD six", "USD6", 6, address(this));
        oracle.setPrice(address(usd6), 1e8);
        MockEarnVault vault6 = new MockEarnVault(usd6, address(this), 0);
        usd6.setMinter(address(vault6), true);
        MoolahParams memory p = _params(usd6, tsla, 0.7e18);
        moolah.createMarket(p, BORROW_APR);
        usd6.mint(LENDER, 3_000_000e6);
        vm.startPrank(LENDER);
        usd6.approve(address(moolah), MAX);
        usd6.approve(address(vault6), MAX);
        moolah.supply(p, 1_000_000e6, 0, LENDER, "");
        vault6.deposit(1_000_000e6, LENDER);
        vm.stopPrank();
        credit.setLoanToken(address(usd6), true);
        bytes32 route = credit.registerRoute(
            R.Venue.LISTA, address(tsla), address(usd6), moolah.marketId(p), 1_000_000e6
        );
        bytes32 vault = credit.registerVault(R.VaultKind.ERC4626, address(usd6), address(vault6));
        IReg.VaultReport[] memory reports = new IReg.VaultReport[](1);
        reports[0] = IReg.VaultReport(vault, 0.03e18, 0);
        vm.prank(REPORTER);
        credit.reportRates(new IReg.RouteReport[](0), reports);
        _open(route, vault, 100e18, 2_000e6);
        skip(180 days);

        // 1 USDT (1e18 raw) = 1 USD6 (1e6 raw).
        MockStablePool pool6 = new MockStablePool(address(usdt), address(usd6), 1e18);
        bool usdtFirst = pool6.token0() == address(usdt);
        pool6.setPrice(usdtFirst ? 1e6 : 1e30);
        usdt.mint(address(pool6), 1_000_000e18);
        usd6.mint(address(pool6), 1_000_000e6);
        swapper.setPool(address(usd6), address(pool6));
        usd6.approve(address(swapper), MAX);

        (uint256 gap, uint256 cap) = swapper.shortfall(address(this), address(usd6));
        assertApproxEqRel(gap, 24.6e6, 0.02e18);
        (uint256 usdtIn, uint256 tokenOut) = swapper.topUp(address(usd6), MAX, MAX, block.timestamp);
        assertEq(tokenOut, cap);
        assertApproxEqRel(usdtIn, cap * 1e12, 0.00011e18, "18-decimal USDT for 6-decimal token, at parity");
        // 0.6% away from parity, in raw terms a factor of 1e12 either way: refused both ways.
        pool6.setPrice(usdtFirst ? uint256(1e6) * 10_000 / 10_060 : uint256(1e30) * 10_060 / 10_000);
        skip(30 days);
        vm.expectPartialRevert(ISwapper.PegExceeded.selector);
        swapper.topUp(address(usd6), MAX, MAX, block.timestamp);
        usd6.mint(address(this), 500e6);
        pool6.setPrice(usdtFirst ? uint256(1e6) * 10_000 / 9_940 : uint256(1e30) * 9_940 / 10_000);
        vm.expectPartialRevert(ISwapper.PegExceeded.selector);
        swapper.cashOut(address(usd6), 500e6, 0, block.timestamp);
        pool6.setPrice(usdtFirst ? 1e6 : 1e30);
        (, uint256 usdtOut) = swapper.cashOut(address(usd6), 500e6, 0, block.timestamp);
        assertApproxEqRel(usdtOut, 500e18, 0.00011e18);
        assertEq(usd6.balanceOf(address(swapper)), 0);
    }

    function test_peg_dustTopUp_roundingDoesNotBlockIt() public {
        _openNegativeCarry(2_000e18);
        skip(180 days);
        (uint256 gap,) = _gap();
        swapper.topUp(address(usdc), gap - 1, MAX, block.timestamp);
        // One raw unit short: the pool rounds the input and its fee up (2 units for 1), which no peg bound in
        // bps would let through.
        (uint256 usdtIn, uint256 tokenOut) = swapper.topUp(address(usdc), 1, MAX, block.timestamp);
        assertEq(tokenOut, 1);
        assertEq(usdtIn, 2);
        _reduce(V_NVDA_C, K_VC, MAX, MAX, 0);
        assertEq(lens.tokenDebt(address(this), address(usdc)), 0);
    }

    // ---- pause, strategy assets ----

    function test_pause_neitherActionFollowsAPause_likeEveryExit() public {
        _openNegativeCarry(2_000e18);
        skip(180 days);
        credit.setPaused(true);
        atp.setGlobalPaused(true);
        registry.setPaused(address(this), true);
        swapper.topUp(address(usdc), MAX, MAX, block.timestamp);
        _reduce(V_NVDA_C, K_VC, MAX, MAX, 0);
        swapper.cashOut(address(usdc), MAX, 0, block.timestamp);
        assertEq(usdc.balanceOf(address(this)), 0);
        assertEq(lens.tokenDebt(address(this), address(usdc)), 0);
    }

    function test_cashOut_refusedForATokenTheStrategyTrades() public {
        usdc.mint(address(this), 100e18);
        swapper.cashOut(address(usdc), 10e18, 0, block.timestamp);
        // The account moves to a strategy that holds USDC as an asset: its USDC is a holding now.
        address[] memory assets = new address[](2);
        (assets[0], assets[1]) = (address(usdt), address(usdc));
        uint16[] memory weights = new uint16[](2);
        weights[1] = 10_000;
        uint256 id = registry.registerStrategy("stable", "test", true);
        registry.publishVersion(id, assets, weights, keccak256("hold"), 0);
        registry.enroll(address(this), id, 1);
        vm.expectRevert(abi.encodeWithSelector(ISwapper.StrategyAsset.selector, address(usdc)));
        swapper.cashOut(address(usdc), 10e18, 0, block.timestamp);
    }

    // ---- vault readings ----

    function test_cap_unreadableVaultCountsAsEmpty_worstCaseIsTheDebt() public {
        _openNegativeCarry(2_000e18);
        skip(180 days);
        (uint256 trueGap,) = _gap();
        uint256 owed = lens.tokenDebt(address(this), address(usdc));
        // The vault's status cannot be read (broken adapter, or a read starved of gas): it counts as empty.
        vm.mockCallRevert(
            address(lens), abi.encodeCall(ILens.vaultStatus, (K_VC, address(this))), "unreadable"
        );
        (uint256 gap, uint256 cap) = _gap();
        assertEq(gap, owed, "the whole debt");
        assertEq(cap, owed + (owed + 99) / 100);
        vm.expectRevert(abi.encodeWithSelector(ISwapper.AboveShortfall.selector, cap + 1, cap));
        swapper.topUp(address(usdc), cap + 1, MAX, block.timestamp);
        // The most that can be converted: the debt plus the buffer. It sits in the account's own box.
        uint256 usdtBefore = usdt.balanceOf(address(this));
        (uint256 usdtIn, uint256 tokenOut) = swapper.topUp(address(usdc), MAX, MAX, block.timestamp);
        assertEq(tokenOut, cap);
        assertEq(lens.idleOf(address(this), address(usdc)), cap);
        // Once is all: the box now holds more than the debt whatever the vault reads.
        vm.expectPartialRevert(ISwapper.NoShortfall.selector);
        swapper.topUp(address(usdc), 1, MAX, block.timestamp);
        vm.clearMockedCalls();
        // Closing pays the debt from the box and hands the rest back; converted back, the detour cost two
        // pool fees on the amount and nothing else.
        _reduce(V_NVDA_C, K_VC, MAX, MAX, 0);
        (uint256 sold,) = swapper.cashOut(address(usdc), MAX, 0, block.timestamp);
        uint256 cost = usdtBefore - usdt.balanceOf(address(this));
        assertEq(usdc.balanceOf(address(this)), 0);
        assertApproxEqAbs(cost, trueGap + (usdtIn + sold) / 10_000, 1e12, "the real gap + two 0.01% fees");
        _swapperHoldsNothing();
    }

    function test_cap_countsEveryVaultOfTheToken_andIdleMoney() public {
        _openNegativeCarry(2_000e18);
        // Half of the deposit moves to the ERC4626 USDC vault: the cap reads both.
        lend.executeSwitchVault(address(this), K_VC, K_C, 1_000e18, block.timestamp);
        skip(180 days);
        (uint256 gap,) = _gap();
        uint256 owed = lens.tokenDebt(address(this), address(usdc));
        assertEq(gap, owed - _held(K_VC) - _held(K_C));
        // Loan token already idle in the box counts too.
        usdc.mint(_box(), 1e18);
        (uint256 gap2,) = _gap();
        assertEq(gap2, gap - 1e18);
        // A USDT vault of the same box is not USDC money.
        _report(uint256(VAULT_APR) * 1e14, 0, 0.05e18);
        _open(V_NVDA_T, K_T, 0, 500e18);
        (uint256 gap3,) = _gap();
        assertEq(gap3, gap2);
    }

    // ---- a pool that misbehaves ----

    function test_pool_partialFillIsRefused() public {
        _openNegativeCarry(2_000e18);
        skip(180 days);
        _mode(MockStablePool.Mode.PARTIAL);
        (, uint256 cap) = _gap();
        vm.expectRevert(abi.encodeWithSelector(ISwapper.InexactOutput.selector, cap / 2, cap));
        swapper.topUp(address(usdc), MAX, MAX, block.timestamp);
    }

    function test_pool_cannotTradeMoreThanAsked() public {
        _openNegativeCarry(2_000e18);
        skip(180 days);
        usdc.mint(address(this), 1_000e18);
        // At a fair price, but twice the size: more of the account's USDT into the box than the cap allows,
        // or more of its loan token sold than it offered.
        _mode(MockStablePool.Mode.OVERFILL);
        (, uint256 cap) = _gap();
        vm.expectRevert(abi.encodeWithSelector(ISwapper.InexactOutput.selector, cap * 2, cap));
        swapper.topUp(address(usdc), MAX, MAX, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(ISwapper.Overcharged.selector, 800e18, 400e18));
        swapper.cashOut(address(usdc), 400e18, 0, block.timestamp);
    }

    function test_pool_skimOrDoubleChargeFailsThePegBound() public {
        _openNegativeCarry(2_000e18);
        skip(180 days);
        usdc.mint(address(this), 1_000e18);
        _mode(MockStablePool.Mode.SKIM);
        vm.expectPartialRevert(ISwapper.PegExceeded.selector);
        swapper.topUp(address(usdc), MAX, MAX, block.timestamp);
        vm.expectPartialRevert(ISwapper.PegExceeded.selector);
        swapper.cashOut(address(usdc), 1_000e18, 0, block.timestamp);
        _mode(MockStablePool.Mode.DOUBLE_CHARGE);
        vm.expectPartialRevert(ISwapper.PegExceeded.selector);
        swapper.topUp(address(usdc), MAX, MAX, block.timestamp);
        vm.expectPartialRevert(ISwapper.PegExceeded.selector);
        swapper.cashOut(address(usdc), 400e18, 0, block.timestamp);
    }

    function test_pool_cannotChargeAnotherPayerOrAnotherToken() public {
        _openNegativeCarry(2_000e18);
        skip(180 days);
        // A victim that approved the swapper for both tokens.
        usdt.mint(STRANGER, 1_000e18);
        vm.prank(STRANGER);
        usdt.approve(address(swapper), MAX);
        pool.setMode(MockStablePool.Mode.WRONG_PAYER, STRANGER, address(0), "");
        vm.expectRevert(ISwapper.BadCallback.selector);
        swapper.topUp(address(usdc), MAX, MAX, block.timestamp);
        // The caller's other approved token instead of the one being sold.
        usdc.mint(address(this), 1_000e18);
        pool.setMode(MockStablePool.Mode.WRONG_TOKEN, address(0), address(usdt), "");
        vm.expectRevert(ISwapper.BadCallback.selector);
        swapper.cashOut(address(usdc), 400e18, 0, block.timestamp);
        assertEq(usdt.balanceOf(STRANGER), 1_000e18);
    }

    function test_pool_callbackOnlyForTheSwapInFlight() public {
        _openNegativeCarry(2_000e18);
        skip(180 days);
        bytes memory data = abi.encode(address(this), address(usdt));
        // Nobody is swapping: not the allowlisted pool, not anyone.
        vm.prank(address(pool));
        vm.expectRevert(ISwapper.BadCallback.selector);
        swapper.pancakeV3SwapCallback(int256(1e18), -int256(1e18), data);
        vm.prank(STRANGER);
        vm.expectRevert(ISwapper.BadCallback.selector);
        swapper.pancakeV3SwapCallback(int256(1e18), -int256(1e18), data);
        // In the middle of the account's own swap, a third contract tries the callback with the right data.
        _mode(MockStablePool.Mode.ACCOMPLICE);
        swapper.topUp(address(usdc), MAX, MAX, block.timestamp);
        assertEq(bytes4(pool.reentryResult()), ISwapper.BadCallback.selector);
        _swapperHoldsNothing();
    }

    function test_pool_reentryIsRefused() public {
        _openNegativeCarry(2_000e18);
        skip(180 days);
        usdc.mint(address(pool), 1e18);
        bytes[2] memory calls = [
            abi.encodeCall(ISwapper.cashOut, (address(usdc), 1e18, 0, block.timestamp)),
            abi.encodeCall(ISwapper.topUp, (address(usdc), 1, MAX, block.timestamp))
        ];
        for (uint256 i; i < 2; ++i) {
            uint256 snapshot = vm.snapshotState();
            pool.setMode(MockStablePool.Mode.REENTER, address(0), address(0), calls[i]);
            swapper.topUp(address(usdc), MAX, MAX, block.timestamp);
            assertEq(bytes4(pool.reentryResult()), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
            vm.revertToState(snapshot);
        }
    }

    // ---- a real pool's arithmetic (PancakeSwap V3 core 1.0.2 bytecode, offline) ----

    function test_realPoolCode_exactOutputDustAndSize() public {
        LocalV3Pool real = new LocalPoolDeployer()
            .deploy(new PancakeV3PoolCode().creationCode(), address(usdt), address(usdc));
        real.initialize(79_228_162_514_264_337_593_543_950_336); // 1:1
        LocalPoolVenue lp = new LocalPoolVenue(real);
        usdt.mint(address(lp), 1e30);
        usdc.mint(address(lp), 1e30);
        lp.addLiquidity(1e27);
        swapper.setPool(address(usdc), address(real));
        // The fixture's pool charges 0.05% (mainnet's stable pools charge 0.01%).
        _openNegativeCarry(2_000e18);
        skip(180 days);
        (uint256 gap, uint256 cap) = _gap();
        (uint256 usdtIn, uint256 tokenOut) = swapper.topUp(address(usdc), gap - 1, MAX, block.timestamp);
        assertEq(tokenOut, gap - 1, "a V3 pool delivers an exact output exactly");
        assertApproxEqRel(usdtIn, gap, 0.00051e18);
        // One raw unit short: the cap is that unit plus its buffer, rounded up to one more.
        (usdtIn, tokenOut) = swapper.topUp(address(usdc), MAX, MAX, block.timestamp);
        assertEq(tokenOut, 2);
        assertLe(usdtIn, 5, "dust costs at most itself plus the rounding allowance");
        assertLt(tokenOut, cap);
        _reduce(V_NVDA_C, K_VC, MAX, MAX, 0);
        assertEq(usdc.balanceOf(address(this)), 1, "the one unit bought beyond the gap");
        usdc.mint(address(this), 1_000e18);
        (uint256 tokenIn, uint256 usdtOut) = swapper.cashOut(address(usdc), MAX, 0, block.timestamp);
        assertEq(tokenIn, 1_000e18 + 1);
        assertApproxEqRel(usdtOut, 1_000e18, 0.00051e18);
        assertEq(usdc.balanceOf(address(this)), 0);
        _swapperHoldsNothing();
        // A dust sale: 1 raw unit in, nothing out is within the rounding allowance; it is not a loss worth a
        // revert, and nothing is created either.
        usdc.mint(address(this), 2);
        (tokenIn, usdtOut) = swapper.cashOut(address(usdc), 2, 0, block.timestamp);
        assertLe(usdtOut, 2);
    }

    // ---- fuzz ----

    /// @dev Any top-up either reverts or: delivers exactly `amount` to the box, never above the cap, for USDT
    /// from the account within the peg bound, and leaves the swapper empty.
    function testFuzz_topUp_neverAboveTheCap_neverPastThePeg(
        uint256 time,
        uint256 amount,
        int256 premium,
        uint16 peg,
        uint16 buffer
    ) public {
        _openNegativeCarry(2_000e18);
        skip(bound(time, 1 hours, 720 days));
        premium = bound(premium, -200, 200);
        _setPremium(premium);
        swapper.setLimits(uint16(bound(peg, 0, 100)), uint16(bound(buffer, 0, 500)));
        (uint256 gap, uint256 cap) = _gap();
        assertEq(cap, gap + (gap * swapper.bufferBps() + 9_999) / 10_000);
        amount = bound(amount, 1, cap * 2);
        uint256 usdtBefore = usdt.balanceOf(address(this));
        uint256 poolUsdt = usdt.balanceOf(address(pool));
        uint256 poolUsdc = usdc.balanceOf(address(pool));
        try swapper.topUp(address(usdc), amount, MAX, block.timestamp) returns (
            uint256 usdtIn, uint256 tokenOut
        ) {
            assertLe(amount, cap, "above the cap");
            assertEq(tokenOut, amount);
            assertEq(lens.idleOf(address(this), address(usdc)), amount, "box");
            assertEq(usdtBefore - usdt.balanceOf(address(this)), usdtIn, "account paid");
            assertEq(usdt.balanceOf(address(pool)) - poolUsdt, usdtIn, "pool received");
            assertEq(poolUsdc - usdc.balanceOf(address(pool)), tokenOut, "pool paid");
            assertLe(usdtIn, tokenOut + tokenOut * swapper.maxPegBps() / 10_000 + 3, "past the peg bound");
            assertEq(usdc.balanceOf(address(this)), 0);
        } catch (bytes memory reason) {
            bytes4 s = bytes4(reason);
            if (amount > cap) assertEq(s, ISwapper.AboveShortfall.selector);
            else assertEq(s, ISwapper.PegExceeded.selector);
            // The pool's price with its fee really was past the bound.
            if (amount <= cap) assertGt(premium + 1, int256(uint256(swapper.maxPegBps())) - 2);
        }
        _swapperHoldsNothing();
    }

    function testFuzz_cashOut_onlyWithinThePeg(uint256 amount, int256 premium, uint16 peg) public {
        amount = bound(amount, 1, 1_000_000e18);
        premium = bound(premium, -200, 200);
        _setPremium(premium);
        swapper.setLimits(uint16(bound(peg, 0, 100)), 100);
        usdc.mint(address(this), amount);
        uint256 usdtBefore = usdt.balanceOf(address(this));
        uint256 poolUsdc = usdc.balanceOf(address(pool));
        try swapper.cashOut(address(usdc), amount, 0, block.timestamp) returns (
            uint256 tokenIn, uint256 usdtOut
        ) {
            assertEq(tokenIn, amount);
            assertEq(usdc.balanceOf(address(this)), 0);
            assertEq(usdc.balanceOf(address(pool)) - poolUsdc, amount, "pool received");
            assertEq(usdt.balanceOf(address(this)) - usdtBefore, usdtOut, "account received");
            assertLe(tokenIn, usdtOut + usdtOut * swapper.maxPegBps() / 10_000 + 3, "past the peg bound");
        } catch (bytes memory reason) {
            assertEq(bytes4(reason), ISwapper.PegExceeded.selector);
            assertLt(premium - 1, 2 - int256(uint256(swapper.maxPegBps())));
            assertEq(usdc.balanceOf(address(this)), amount);
        }
        _swapperHoldsNothing();
    }
}
