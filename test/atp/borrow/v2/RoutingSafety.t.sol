// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { RoutingBase } from "./RoutingBase.sol";
import { RoutingTypes as R } from "../../../../src/atp/borrow/v2/RoutingTypes.sol";
import { IAtpBorrowExecutorV2 as IExec } from "../../../../src/atp/borrow/v2/IAtpBorrowExecutorV2.sol";
import { IAtpBorrowRegistryV2 as IReg } from "../../../../src/atp/borrow/v2/IAtpBorrowRegistryV2.sol";
import { StrategyBox } from "../../../../src/atp/borrow/v2/StrategyBox.sol";
import { VaultAdapterBase } from "../../../../src/atp/borrow/v2/VaultAdapters.sol";

/// @notice Auto-deleverage, liquidation bookkeeping, the strategy box (who can move receipts, what it signs)
/// and reward tokens.
contract RoutingSafetyTest is RoutingBase {
    bytes internal constant SUFFIX = "\nThank you for your support of listaDAO.";

    // ---- deleverage ----

    function test_deleverage_lista_atTheLine_anyoneRestoresTarget() public {
        _open(L_TSLA_T, K_T, 10e18, 300e18); // LLTV 70%: deleverage line 46.67%
        vm.prank(KEEPER);
        vm.expectRevert(IExec.NothingToDo.selector);
        lend.executeDeleverage(address(this), L_TSLA_T, K_T, MAX);
        // 300 / (10 x 64.29) = 46.66% < line: still nothing to do. At 64.28: 46.67% >= line.
        oracle.setPrice(address(tsla), 64.29e8);
        assertFalse(lens.routeStatus(L_TSLA_T, address(this)).shouldDeleverage);
        oracle.setPrice(address(tsla), 64.28e8);
        assertTrue(lens.routeStatus(L_TSLA_T, address(this)).shouldDeleverage);
        uint256 expected = lens.deleverageAmount(L_TSLA_T, address(this));
        vm.prank(KEEPER);
        uint256 repaid = lend.executeDeleverage(address(this), L_TSLA_T, K_T, MAX);
        assertEq(repaid, expected);
        R.Health memory h = _health(L_TSLA_T);
        assertLe(h.debtValue, h.budgetValue, "back inside the target");
        assertApproxEqAbs(h.debtValue, h.budgetValue, 1e6);
        assertEq(usdt.balanceOf(KEEPER), 0, "caller gets nothing");
        assertEq(usdt.balanceOf(address(this)), 0);
        assertApproxEqAbs(_held(K_T), 300e18 - repaid, 3);
        assertEq(credit.principal(address(this), L_TSLA_T), 300e18 - repaid);
        _noResidue();
    }

    function test_deleverage_venus_accountWide() public {
        _open(V_NVDA_T, K_T, 10e18, 300e18);
        _open(V_TSLA_C, K_C, 10e18, 300e18);
        // Budget 600, line 800 at 2000 USD. NVDA to 40: collateral 1400, line 560 < 600 debt.
        oracle.setPrice(address(nvda), 40e8);
        R.Health memory h = _health(V_NVDA_T);
        assertEq(h.deleverageValue, 560e18);
        assertEq(h.budgetValue, 420e18);
        // 180 USD must go; either token's vault may pay its own token's debt.
        vm.prank(KEEPER);
        uint256 repaid = lend.executeDeleverage(address(this), V_TSLA_C, K_C, MAX);
        assertApproxEqAbs(repaid, 180e18, 2);
        h = _health(V_NVDA_T);
        assertLe(h.debtValue, h.budgetValue);
        vm.prank(KEEPER);
        vm.expectRevert(IExec.NothingToDo.selector);
        lend.executeDeleverage(address(this), V_NVDA_T, K_T, MAX);
    }

    function test_deleverage_cappedByMaxRepayAndByTheVault() public {
        _open(L_TSLA_T, K_T, 10e18, 300e18);
        oracle.setPrice(address(tsla), 50e8); // 60% LTV; back to 30% needs 150
        // Wrong token vault / nothing held in the named vault.
        vm.prank(KEEPER);
        vm.expectRevert(IExec.TokenMismatch.selector);
        lend.executeDeleverage(address(this), L_TSLA_T, K_C, MAX);
        vm.prank(KEEPER);
        vm.expectRevert(abi.encodeWithSelector(IExec.VaultShortfall.selector, 300e18, 0));
        lend.executeDeleverage(address(this), L_TSLA_T, K_AT, MAX);
        vm.prank(KEEPER);
        assertEq(lend.executeDeleverage(address(this), L_TSLA_T, K_T, 40e18), 40e18);
        // A vault that cannot pay the full amount now: the call reverts, a smaller maxRepay goes through.
        vaultT.setLiquidity(30e18);
        vm.prank(KEEPER);
        vm.expectRevert();
        lend.executeDeleverage(address(this), L_TSLA_T, K_T, MAX);
        vm.prank(KEEPER);
        assertEq(lend.executeDeleverage(address(this), L_TSLA_T, K_T, 30e18), 30e18);
        vm.prank(KEEPER);
        vm.expectRevert(IExec.NothingToRepay.selector);
        lend.executeDeleverage(address(this), L_QQQ_C, K_C, MAX);
    }

    /// @dev Review L1: vault utilization can be pushed past 95% inside one block, so it is not a trigger a
    /// stranger can use. The status still reports it, and the account itself exits.
    function test_vaultAbove95Percent_isNotPermissionless_accountExits() public {
        _open(L_TSLA_T, K_AT, 10e18, 300e18);
        aaveT.setLiquidity(1_000_300e18 * 5 / 100 - 1e18);
        assertTrue(lens.vaultStatus(K_AT, address(this)).shouldExit);
        vm.prank(KEEPER);
        vm.expectRevert(IExec.NothingToDo.selector);
        lend.executeDeleverage(address(this), L_TSLA_T, K_AT, MAX);
        // The account (session key) moves the deposit to another vault, or repays.
        lend.executeSwitchVault(address(this), K_AT, K_T, 100e18, block.timestamp);
        _reduce(L_TSLA_T, K_AT, 200e18, 0, 0);
        assertApproxEqAbs(lens.debt(L_TSLA_T, address(this)), 100e18, 1);
    }

    function test_negativeCarry_isNotPermissionless() public {
        _open(L_TSLA_T, K_T, 10e18, 300e18);
        _report(0.001e18, 0, 0); // carry now negative
        assertEq(uint8(lens.quote(L_TSLA_T, K_T).gate), uint8(R.Gate.NEGATIVE_CARRY));
        vm.prank(KEEPER);
        vm.expectRevert(IExec.NothingToDo.selector);
        lend.executeDeleverage(address(this), L_TSLA_T, K_T, MAX);
        skip(3 days); // the report expires: still nothing a stranger can do
        vm.prank(KEEPER);
        vm.expectRevert(IExec.NothingToDo.selector);
        lend.executeDeleverage(address(this), L_TSLA_T, K_T, MAX);
        // The account (session key) unwinds it.
        _reduce(L_TSLA_T, K_T, MAX, MAX, 0);
        assertEq(lens.debt(L_TSLA_T, address(this)), 0);
    }

    function test_removedTier_keepsDeleverageLine() public {
        _open(L_TSLA_T, K_T, 10e18, 300e18);
        credit.setAssetTier(address(tsla), R.Tier.NONE);
        R.Health memory h = _health(L_TSLA_T);
        assertEq(h.budgetValue, 0);
        assertGt(h.deleverageValue, h.debtValue);
        vm.prank(KEEPER);
        vm.expectRevert(IExec.NothingToDo.selector);
        lend.executeDeleverage(address(this), L_TSLA_T, K_T, MAX);
    }

    // ---- liquidation ----

    function test_liquidation_thenReconcile_andClose() public {
        _open(L_TSLA_T, K_T, 10e18, 300e18);
        oracle.setPrice(address(tsla), 40e8); // LTV 75% > LLTV 70%
        vm.prank(LIQUIDATOR);
        moolah.liquidate(_params(usdt, tsla, 0.7e18), address(this), 3e18, 0, "");
        uint256 owed = lens.debt(L_TSLA_T, address(this));
        assertLt(owed, 300e18);
        assertEq(credit.principal(address(this), L_TSLA_T), 300e18);
        vm.prank(KEEPER);
        credit.reconcile(address(this), L_TSLA_T);
        assertEq(credit.principal(address(this), L_TSLA_T), owed);
        assertEq(credit.accountPrincipalUsd(address(this)), owed);
        assertEq(credit.totalPrincipal(L_TSLA_T), owed);
        // The vault still holds the full 300: closing pays the rest and returns the surplus.
        _reduce(L_TSLA_T, K_T, MAX, MAX, 0);
        assertEq(tsla.balanceOf(address(this)), 997e18);
        assertApproxEqAbs(usdt.balanceOf(address(this)), 300e18 - owed, 3);
        assertEq(credit.accountRoutes(address(this)).length, 0);
    }

    function test_reconcile_venusSharedDebt() public {
        _open(V_NVDA_T, K_T, 10e18, 200e18);
        _open(V_TSLA_T, K_T, 10e18, 100e18);
        // Someone repays 150 of the shared USDT debt from outside.
        usdt.mint(KEEPER, 150e18);
        vm.startPrank(KEEPER);
        usdt.approve(address(vUsdt), MAX);
        vUsdt.repayBorrowBehalf(address(this), 150e18);
        credit.reconcile(address(this), V_NVDA_T);
        vm.stopPrank();
        assertEq(credit.principal(address(this), V_NVDA_T), 50e18);
        assertEq(credit.principal(address(this), V_TSLA_T), 100e18);
        assertEq(credit.accountPrincipalUsd(address(this)), 150e18);
        assertEq(lens.routeDebt(V_NVDA_T, address(this)), 50e18);
    }

    // ---- liquidity ----

    function test_vaultCannotPay_repayReverts_closeLeavesHoldingForLater() public {
        _open(L_TSLA_T, K_T, 10e18, 300e18);
        vaultT.setLiquidity(0);
        vm.expectRevert();
        _reduce(L_TSLA_T, K_T, 100e18, 0, 0);
        // Repay from the account's own cash instead, without naming the vault: the holding stays in the box.
        usdt.mint(address(this), 300e18);
        usdt.approve(address(lend), MAX);
        _reduce(L_TSLA_T, bytes32(0), MAX, MAX, 300e18);
        assertEq(tsla.balanceOf(address(this)), 1_000e18);
        assertGt(vaultT.balanceOf(_box()), 0);
        // Naming an illiquid vault on a close that needs none of it does not block the close either.
        _open(L_TSLA_T, K_AT, 10e18, 100e18);
        usdt.mint(address(this), 100e18);
        _reduce(L_TSLA_T, bytes32(0), MAX, 0, 100e18);
        _reduce(L_TSLA_T, K_T, 0, MAX, 0);
        assertGt(vaultT.balanceOf(_box()), 0, "illiquid vault skipped, not lost");
        vm.expectRevert();
        lend.executeRelease(address(this), K_T, block.timestamp);
        vaultT.setLiquidity(1_000_000e18);
        lend.executeRelease(address(this), K_T, block.timestamp);
        assertEq(vaultT.balanceOf(_box()), 0);
    }

    function test_borrowMoreThanTheVenueHas_reverts() public {
        _open(L_TSLA_T, bytes32(0), 1_000e18, 0);
        vm.prank(LENDER);
        moolah.withdraw(_params(usdt, tsla, 0.7e18), 999_990e18, 0, LENDER, LENDER);
        credit.setRouteMaxUtilization(L_TSLA_T, 10_000);
        vm.expectRevert();
        _open(L_TSLA_T, K_T, 0, 11e18);
        _open(L_TSLA_T, K_T, 0, 10e18);
    }

    // ---- the box ----

    function test_box_guards() public {
        _open(L_TSLA_T, K_T, 10e18, 200e18);
        _open(L_TSLA_T, K_AT, 0, 100e18);
        StrategyBox box = StrategyBox(_box());
        assertEq(box.account(), address(this));
        assertEq(box.executor(), address(lend));
        // Neither the account (owner or session key) nor anyone else can make the box do anything.
        vm.expectRevert(StrategyBox.NotExecutor.selector);
        box.send(IERC20(address(vaultT)), address(this), 1);
        vm.expectRevert(StrategyBox.NotExecutor.selector);
        box.approve(IERC20(address(vaultT)), address(this));
        vm.expectRevert(StrategyBox.NotExecutor.selector);
        box.init(KEEPER);
        vm.prank(address(lend));
        vm.expectRevert(StrategyBox.AlreadyInitialized.selector);
        box.init(KEEPER);
        // The implementation itself holds nothing and obeys only the executor too.
        StrategyBox implementation = StrategyBox(lend.boxImplementation());
        vm.expectRevert(StrategyBox.NotExecutor.selector);
        implementation.init(KEEPER);
        // The box's only allowances are its receipts to the adapter of their kind.
        assertEq(vaultT.allowance(address(box), address(erc4626Adapter)), MAX);
        assertEq(IERC20(aaveT.receipt()).allowance(address(box), address(aaveAdapter)), MAX);
        address[6] memory others =
            [address(this), address(lend), address(atp), KEEPER, address(venusAdapter), address(credit)];
        for (uint256 i; i < others.length; ++i) {
            assertEq(vaultT.allowance(address(box), others[i]), 0);
            assertEq(IERC20(aaveT.receipt()).allowance(address(box), others[i]), 0);
            assertEq(usdt.allowance(address(box), others[i]), 0);
        }
        assertEq(vaultT.allowance(address(box), address(aaveAdapter)), 0);
        // The account holds no receipt, so the old AtpExecutor path has nothing to redeem.
        _accountHoldsNoStrategyMoney();
        // Adapters obey the executor only.
        vm.expectRevert(VaultAdapterBase.NotExecutor.selector);
        erc4626Adapter.withdraw(address(vaultT), address(usdt), 1e18, address(box), address(this));
        vm.expectRevert(VaultAdapterBase.NotExecutor.selector);
        aaveAdapter.withdraw(address(aaveT), address(usdt), 1e18, address(box), address(this));
        vm.expectRevert(VaultAdapterBase.NotExecutor.selector);
        venusAdapter.deposit(address(vUsdc), address(usdc), 1, address(box));
        // One box per account, at the predicted address, created on first deposit.
        assertEq(lend.boxOf(KEEPER).code.length, 0);
        assertTrue(lend.boxOf(KEEPER) != address(box));
    }

    // ---- ERC-1271: one message only ----

    function _personal(bytes memory message) internal pure returns (bytes32) {
        return
            keccak256(
                abi.encodePacked("\x19Ethereum Signed Message:\n", vm.toString(message.length), message)
            );
    }

    function test_box_signsOnlyTheRewardProofMessage() public {
        _open(L_TSLA_T, K_T, 10e18, 100e18);
        StrategyBox box = StrategyBox(_box());
        bytes memory message = abi.encodePacked("2026-11-24T10:00:00.000Z", SUFFIX);
        bytes32 hash = _personal(message);
        bytes memory signature = abi.encode(message, bytes("account signature"));
        // Not signed by the account yet.
        assertEq(box.isValidSignature(hash, signature), bytes4(0xffffffff));
        signed[hash] = true;
        assertEq(box.isValidSignature(hash, signature), bytes4(0x1626ba7e));
        // Only the form Lista's verifier uses exists (mainnet probe, 2026-11-24): the bytes form of ERC-1271
        // is not implemented, and the plain keccak256 of the message is not accepted.
        (bool ok,) = address(box)
            .staticcall(abi.encodeWithSignature("isValidSignature(bytes,bytes)", message, signature));
        assertFalse(ok);
        signed[keccak256(message)] = true;
        assertEq(box.isValidSignature(keccak256(message), signature), bytes4(0xffffffff));

        // Any other digest is refused even though the account signs it: a permit / Permit2 digest...
        bytes32 permitDigest =
            keccak256(abi.encodePacked("\x19\x01", keccak256("domain"), keccak256("Permit")));
        signed[permitDigest] = true;
        assertEq(box.isValidSignature(permitDigest, signature), bytes4(0xffffffff));
        assertEq(box.isValidSignature(permitDigest, abi.encode(bytes(""), bytes("x"))), bytes4(0xffffffff));
        assertEq(box.isValidSignature(permitDigest, bytes("raw 65 byte signature")), bytes4(0xffffffff));
        // ...another text...
        bytes memory other = bytes("Sign in to some other app");
        signed[_personal(other)] = true;
        assertEq(box.isValidSignature(_personal(other), abi.encode(other, bytes("x"))), bytes4(0xffffffff));
        // ...the right suffix behind a long arbitrary text...
        bytes memory long = abi.encodePacked(
            "I authorize the transfer of all vault shares to 0x000000000000000000000000000000000000dEaD",
            SUFFIX
        );
        signed[_personal(long)] = true;
        assertEq(box.isValidSignature(_personal(long), abi.encode(long, bytes("x"))), bytes4(0xffffffff));
        // ...a hash that is not the message's...
        assertEq(box.isValidSignature(permitDigest, abi.encode(message, bytes("x"))), bytes4(0xffffffff));
        // ...and everything once the owner clears the suffix.
        credit.setRewardProofSuffix("");
        assertEq(box.isValidSignature(hash, signature), bytes4(0xffffffff));
        vm.expectRevert(IReg.BadParameter.selector);
        credit.setRewardProofSuffix("short");
    }

    // ---- rewards ----

    function test_rewards_collectToAccount_anyone_noDeadline() public {
        _open(L_TSLA_T, K_T, 10e18, 100e18);
        lista.mint(_box(), 7e18); // vault emissions land in the box (it is the depositor)
        vm.prank(KEEPER);
        assertEq(lend.collectRewards(address(this), address(lista)), 7e18);
        assertEq(lista.balanceOf(address(this)), 7e18, "rewards stay in the portfolio account");
        assertEq(lista.balanceOf(KEEPER), 0);
        assertEq(lend.collectRewards(address(this), address(lista)), 0);
        assertEq(lend.collectRewards(KEEPER, address(lista)), 0, "no box: nothing");
        // Only allowlisted reward tokens: never the loan token, a receipt or the collateral.
        vm.expectRevert(abi.encodeWithSelector(IExec.RewardNotAllowed.selector, address(usdt)));
        lend.collectRewards(address(this), address(usdt));
        vm.expectRevert(abi.encodeWithSelector(IExec.RewardNotAllowed.selector, address(vaultT)));
        lend.collectRewards(address(this), address(vaultT));
        vm.expectRevert(abi.encodeWithSelector(IExec.RewardNotAllowed.selector, address(tsla)));
        lend.collectRewards(address(this), address(tsla));
        assertGt(vaultT.balanceOf(_box()), 0);
    }

    function test_rewards_sweepOnExit_toOwnersRecipient() public {
        _open(L_TSLA_T, K_T, 10e18, 100e18);
        lista.mint(_box(), 3e18);
        lista.mint(address(this), 10e18); // borrow rewards were claimed to the account
        lista.approve(address(lend), MAX);
        lend.executeSweepRewards(address(this), address(lista), 4e18, block.timestamp);
        assertEq(lista.balanceOf(WALLET), 7e18);
        assertEq(lista.balanceOf(address(this)), 6e18);
        lend.executeSweepRewards(address(this), address(lista), MAX, block.timestamp);
        assertEq(lista.balanceOf(WALLET), 13e18);
        vm.expectRevert(IExec.NothingToDo.selector);
        lend.executeSweepRewards(address(this), address(lista), 0, block.timestamp);
        // Collateral and loan tokens can never be reward tokens.
        vm.expectRevert(IReg.BadParameter.selector);
        credit.setRewardToken(address(nvda), true);
        vm.expectRevert(IReg.BadParameter.selector);
        credit.setRewardToken(address(vNvda), true);
        vm.expectRevert(abi.encodeWithSelector(IExec.RewardNotAllowed.selector, address(usdc)));
        lend.executeSweepRewards(address(this), address(usdc), 1e18, block.timestamp);
        // A token the account's strategy trades is a holding, not a reward: never taken from the account.
        address[] memory assets = new address[](2);
        (assets[0], assets[1]) = (address(usdt), address(lista));
        uint16[] memory weights = new uint16[](2);
        weights[1] = 10_000;
        uint256 next = registry.registerStrategy("holds the reward token", "test", true);
        registry.publishVersion(next, assets, weights, keccak256("hold"), 0);
        registry.enroll(address(this), next, 1);
        lista.mint(address(this), 1e18);
        vm.expectRevert(abi.encodeWithSelector(IExec.RewardNotAllowed.selector, address(lista)));
        lend.executeSweepRewards(address(this), address(lista), 1e18, block.timestamp);
        // What the box holds still reaches the account through the permissionless collect.
        lista.mint(_box(), 2e18);
        assertEq(lend.collectRewards(address(this), address(lista)), 2e18);
    }

    function test_rewards_noRecipient_onlyBoxToAccount() public {
        credit.setStrategyPolicy(1_000e18, address(0), true);
        _open(L_TSLA_T, K_T, 10e18, 100e18);
        lista.mint(_box(), 3e18);
        lista.mint(address(this), 10e18);
        lista.approve(address(lend), MAX);
        lend.executeSweepRewards(address(this), address(lista), 5e18, block.timestamp);
        assertEq(lista.balanceOf(address(this)), 13e18);
    }
}
