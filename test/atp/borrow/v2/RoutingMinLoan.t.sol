// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { RoutingBase } from "./RoutingBase.sol";
import { MinLoanMoolah } from "./mocks/MinLoanMoolah.sol";
import { MoolahParams } from "../../../../src/atp/yield/YieldInterfaces.sol";
import { RoutingTypes as R } from "../../../../src/atp/borrow/v2/RoutingTypes.sol";
import { IAtpBorrowExecutorV2 as IExec } from "../../../../src/atp/borrow/v2/IAtpBorrowExecutorV2.sol";
import { IAtpBorrowRegistryV2 as IReg } from "../../../../src/atp/borrow/v2/IAtpBorrowRegistryV2.sol";
import { AtpBorrowExecutorV2 } from "../../../../src/atp/borrow/v2/AtpBorrowExecutorV2.sol";
import { AtpBorrowRegistryV2 } from "../../../../src/atp/borrow/v2/AtpBorrowRegistryV2.sol";
import { AtpBorrowLensV2 } from "../../../../src/atp/borrow/v2/AtpBorrowLensV2.sol";
import { Erc4626VaultAdapter } from "../../../../src/atp/borrow/v2/VaultAdapters.sol";
import { TestnetToken } from "../../../../src/testnet/TestnetToken.sol";
import { MockEarnVault } from "../../../../src/testnet/lending/MockEarnVault.sol";

/// @notice Review M2: Lista's Moolah refuses to be left with a debt below its minimum loan (about 15 USD).
/// A second routing deployment bound to `MinLoanMoolah`, which enforces that rule; also the place for
/// tokens that do not have 18 decimals (a 6-decimal loan token against an 8-decimal collateral).
contract RoutingMinLoanTest is RoutingBase {
    MinLoanMoolah internal strict;
    AtpBorrowRegistryV2 internal credit2;
    AtpBorrowLensV2 internal lens2;
    IExec internal lend2;
    TestnetToken internal usd6;
    TestnetToken internal btc8;
    MockEarnVault internal vault6;
    bytes32 internal ROUTE; // TSLA / USDT, LLTV 70%, 18 decimals
    bytes32 internal ROUTE6; // BTC (8 decimals) / USD6 (6 decimals), LLTV 80%
    bytes32 internal VAULT;
    bytes32 internal VAULT6;

    function setUp() public override {
        super.setUp();
        strict = new MinLoanMoolah();
        usd6 = new TestnetToken("USD six", "USD6", 6, address(this));
        btc8 = new TestnetToken("BTC eight", "BTC8", 8, address(this));
        oracle.setPrice(address(usd6), 1e8);
        oracle.setPrice(address(btc8), 60_000e8);
        vault6 = new MockEarnVault(usd6, address(this), VAULT_APR);
        usd6.setMinter(address(vault6), true);
        MoolahParams memory p =
            MoolahParams(address(usdt), address(tsla), address(oracle), address(strict), 0.7e18);
        MoolahParams memory p6 =
            MoolahParams(address(usd6), address(btc8), address(oracle), address(strict), 0.8e18);
        strict.createMarket(p);
        strict.createMarket(p6);
        usd6.mint(LENDER, 3_000_000e6);
        vm.startPrank(LENDER);
        usdt.approve(address(strict), MAX);
        usd6.approve(address(strict), MAX);
        usd6.approve(address(vault6), MAX);
        strict.supply(p, 1_000_000e18, 0, LENDER, "");
        strict.supply(p6, 1_000_000e6, 0, LENDER, "");
        vault6.deposit(1_000_000e6, LENDER);
        vm.stopPrank();

        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 2);
        credit2 = new AtpBorrowRegistryV2(registry, address(atp), predicted, address(0), address(strict));
        lens2 = new AtpBorrowLensV2(credit2);
        lend2 = IExec(address(new AtpBorrowExecutorV2(credit2, lens2, address(extension))));
        credit2.setAdapter(R.VaultKind.ERC4626, address(new Erc4626VaultAdapter(address(lend2))));
        credit2.setLoanToken(address(usdt), true);
        credit2.setLoanToken(address(usd6), true);
        credit2.setAssetTier(address(tsla), R.Tier.STOCK);
        credit2.setAssetTier(address(btc8), R.Tier.CRYPTO_LINKED);
        credit2.setRateReporter(REPORTER);
        ROUTE = credit2.registerRoute(
            R.Venue.LISTA, address(tsla), address(usdt), strict.marketId(p), 1_000_000e18
        );
        ROUTE6 = credit2.registerRoute(
            R.Venue.LISTA, address(btc8), address(usd6), strict.marketId(p6), 1_000_000e6
        );
        VAULT = credit2.registerVault(R.VaultKind.ERC4626, address(usdt), address(vaultT));
        VAULT6 = credit2.registerVault(R.VaultKind.ERC4626, address(usd6), address(vault6));
        IReg.VaultReport[] memory vaults = new IReg.VaultReport[](2);
        vaults[0] = IReg.VaultReport(VAULT, 0.045e18, 0);
        vaults[1] = IReg.VaultReport(VAULT6, 0.045e18, 0);
        vm.prank(REPORTER);
        credit2.reportRates(new IReg.RouteReport[](0), vaults);

        strict.setAuthorization(address(lend2), true);
        credit2.setStrategyPolicy(10_000_000e18, WALLET, true);
        tsla.approve(address(lend2), MAX);
        btc8.approve(address(lend2), MAX);
        btc8.mint(address(this), 10e8);
    }

    function _box2() internal view returns (address) {
        return lend2.boxOf(address(this));
    }

    function test_minLoan_isPublished_andBindsOpenAndPartialRepay() public {
        assertEq(lens2.minLoan(ROUTE), 15e18);
        assertEq(lens2.minLoan(ROUTE6), 15e6);
        lend2.executeOpen(address(this), ROUTE, bytes32(0), 10e18, 0, block.timestamp);
        vm.expectRevert(bytes("remain borrow too low"));
        lend2.executeOpen(address(this), ROUTE, VAULT, 0, 14e18, block.timestamp);
        lend2.executeOpen(address(this), ROUTE, VAULT, 0, 100e18, block.timestamp);
        // A partial repayment may not leave less than the minimum; repaying everything is always possible.
        vm.expectRevert(bytes("remain borrow too low"));
        lend2.executeReduce(address(this), ROUTE, VAULT, 90e18, 0, 0, block.timestamp);
        lend2.executeReduce(address(this), ROUTE, VAULT, 85e18, 0, 0, block.timestamp);
        usdt.mint(address(this), 1e18);
        usdt.approve(address(lend2), MAX);
        lend2.executeReduce(address(this), ROUTE, VAULT, MAX, MAX, 1e18, block.timestamp);
        assertEq(lens2.debt(ROUTE, address(this)), 0);
    }

    /// @dev The reviewer's fork PoC, on a mock: the box holds a few units less than the debt and the health
    /// line asks for the whole debt. Before the fix the executor repaid "all it has", left dust below the
    /// minimum and reverted (after walking the vault twice).
    function test_M2_deleverage_boxAFewUnitsShort_leavesTheMinimumInsteadOfReverting() public {
        lend2.executeOpen(address(this), ROUTE, VAULT, 10e18, 300e18, block.timestamp);
        // The box loses a little of its holding, so it is short of the debt by dust.
        address box = _box2();
        vm.prank(box);
        vaultT.transfer(address(0xdead), 1e12);
        oracle.setPrice(address(tsla), 3e8); // collateral 30 USD: far past the line, plan = the whole debt
        uint256 owed = lens2.debt(ROUTE, address(this));
        assertEq(lens2.deleverageAmount(ROUTE, address(this)), owed);
        vm.prank(KEEPER);
        uint256 repaid = lend2.executeDeleverage(address(this), ROUTE, VAULT, MAX);
        uint256 left = lens2.debt(ROUTE, address(this));
        assertEq(repaid + left, owed);
        assertGe(left, 15e18, "never below the venue's minimum");
        assertApproxEqAbs(left, 15.15e18, 2, "the minimum plus the 1% margin");
        // What the vault gave beyond the repayment is back in the box, and the next repayment uses it first.
        assertGt(lens2.idleOf(address(this), address(usdt)), 15e18);
        assertEq(usdt.balanceOf(address(this)), 0);
        assertEq(usdt.balanceOf(address(lend2)), 0);
        usdt.mint(address(this), 1e18);
        usdt.approve(address(lend2), MAX);
        lend2.executeReduce(address(this), ROUTE, bytes32(0), MAX, 0, 1e18, block.timestamp);
        assertEq(lens2.debt(ROUTE, address(this)), 0);
        assertEq(lens2.idleOf(address(this), address(usdt)), 0);
    }

    function test_M2_deleverageAmount_roundsUpToAFullRepaymentNearTheMinimum() public {
        lend2.executeOpen(address(this), ROUTE, VAULT, 10e18, 40e18, block.timestamp);
        // Back to budget would leave about 13 USD (< 15): the plan is the whole debt instead.
        oracle.setPrice(address(tsla), 4.4e8); // collateral 44 USD, budget 13.2, line 20.5
        uint256 owed = lens2.debt(ROUTE, address(this));
        assertEq(lens2.deleverageAmount(ROUTE, address(this)), owed);
        vm.prank(KEEPER);
        assertEq(lend2.executeDeleverage(address(this), ROUTE, VAULT, MAX), owed);
        assertEq(lens2.debt(ROUTE, address(this)), 0);
        // A capped call that would leave dust is trimmed to leave the minimum, not reverted.
        oracle.setPrice(address(tsla), PRICE_E8);
        lend2.executeOpen(address(this), ROUTE, VAULT, 0, 200e18, block.timestamp);
        oracle.setPrice(address(tsla), 30e8);
        vm.prank(KEEPER);
        uint256 repaid = lend2.executeDeleverage(address(this), ROUTE, VAULT, 50e18);
        assertEq(repaid, 50e18);
    }

    // ---- tokens without 18 decimals ----

    function test_decimals_6DecimalLoan_8DecimalCollateral() public {
        // 1 BTC8 = 60,000 USD; crypto-linked: 20%.
        lend2.executeOpen(address(this), ROUTE6, bytes32(0), 1e8, 0, block.timestamp);
        assertEq(lens2.targetLtv(ROUTE6), 0.2e18);
        vm.expectRevert();
        lend2.executeOpen(address(this), ROUTE6, VAULT6, 0, 12_000e6 + 1, block.timestamp);
        lend2.executeOpen(address(this), ROUTE6, VAULT6, 0, 12_000e6, block.timestamp);
        R.Health memory h = lens2.health(ROUTE6, address(this));
        assertEq(h.collateralValue, 60_000e18);
        assertEq(h.debtValue, 12_000e18);
        assertEq(h.budgetValue, 12_000e18);
        // The consent ceiling counts every loan token at 1 USD with 18 decimals.
        assertEq(credit2.accountPrincipalUsd(address(this)), 12_000e18);
        assertEq(credit2.principal(address(this), ROUTE6), 12_000e6);
        assertEq(usd6.balanceOf(address(this)), 0);
        assertApproxEqAbs(lens2.vaultStatus(VAULT6, address(this)).assets, 12_000e6, 2);
        // Deleverage after a price drop, then close.
        oracle.setPrice(address(btc8), 20_000e8); // 60% >= 53.3%
        vm.prank(KEEPER);
        uint256 repaid = lend2.executeDeleverage(address(this), ROUTE6, VAULT6, MAX);
        assertApproxEqAbs(repaid, 8_000e6, 2);
        h = lens2.health(ROUTE6, address(this));
        assertLe(h.debtValue, h.budgetValue);
        oracle.setPrice(address(btc8), 60_000e8);
        skip(10 days);
        lend2.executeReduce(address(this), ROUTE6, VAULT6, MAX, MAX, 0, block.timestamp);
        assertEq(btc8.balanceOf(address(this)), 10e8);
        assertGt(usd6.balanceOf(address(this)), 0, "carry paid out in the 6-decimal token");
        assertEq(credit2.accountPrincipalUsd(address(this)), 0);
        assertEq(usd6.balanceOf(address(lend2)), 0);
        assertEq(btc8.balanceOf(address(lend2)), 0);
    }
}
