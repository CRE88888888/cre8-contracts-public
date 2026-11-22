// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { AtpBorrowBase } from "./AtpBorrowBase.sol";
import { AtpBorrowExecutor } from "../../../src/atp/borrow/AtpBorrowExecutor.sol";
import { AtpBorrowRegistry } from "../../../src/atp/borrow/AtpBorrowRegistry.sol";
import { BorrowTypes as B } from "../../../src/atp/borrow/BorrowTypes.sol";
import { MoolahParams } from "../../../src/atp/yield/YieldInterfaces.sol";
import { TestnetToken } from "../../../src/testnet/TestnetToken.sol";

/// @notice #64 EARN_UX §D risk classes (target LTV 35% / 30% / 20%, never above F/2) and the simulated incentives
/// (collateral, borrow, vault) that feed the "extra APY" number and accrue only to the position's own account.
contract AtpBorrowTiersIncentivesTest is AtpBorrowBase {
    address internal constant STRANGER = address(0x5157);

    /// @dev A fresh collateral token with its own Lista market, designated on registration.
    function _listaMarket(B.Tier tier, uint256 lltv, bytes32 id) internal returns (TestnetToken token) {
        token = new TestnetToken("Asset", "AST", 18, address(this));
        oracle.setPrice(address(token), 100e8);
        MoolahParams memory p =
            MoolahParams(address(usdt), address(token), address(oracle), address(moolah), lltv);
        moolah.createMarket(p, BORROW_APR);
        usdt.mint(LENDER, 500_000e18);
        vm.prank(LENDER);
        moolah.supply(p, 500_000e18, 0, LENDER, "");
        B.Market memory m = _listaMarket();
        m.tier = tier;
        m.collateral = address(token);
        m.listaId = moolah.marketId(p);
        credit.registerMarket(id, m);
        credit.setBorrowPolicy(id, 10_000_000e18, true);
        token.mint(address(this), 1_000e18);
        token.approve(address(lend), type(uint256).max);
    }

    function test_targetLtv_isTheLowerOfClassCeilingAndHalfTheFactor() public {
        _listaMarket(B.Tier.INDEX_LARGE_CAP, 0.7e18, bytes32(uint256(1)));
        _listaMarket(B.Tier.INDEX_LARGE_CAP, 0.6e18, bytes32(uint256(2)));
        _listaMarket(B.Tier.STOCK, 0.6e18, bytes32(uint256(3)));
        _listaMarket(B.Tier.STOCK, 0.5e18, bytes32(uint256(4)));
        _listaMarket(B.Tier.CRYPTO_LINKED, 0.6e18, bytes32(uint256(5)));
        assertEq(credit.targetLtv(bytes32(uint256(1))), 0.35e18); // class 35% = F/2 35%
        assertEq(credit.targetLtv(bytes32(uint256(2))), 0.3e18); // F/2 30% < class 35%
        assertEq(credit.targetLtv(bytes32(uint256(3))), 0.3e18); // class 30% = F/2 30% (Venus TSLAB / NVDAB)
        assertEq(credit.targetLtv(bytes32(uint256(4))), 0.25e18); // F/2 25% < class 30% (Venus SPCXB)
        assertEq(credit.targetLtv(bytes32(uint256(5))), 0.2e18); // crypto-linked 20% < F/2 30%
        // The deleverage line stays at 2/3 of the liquidation line whatever the class.
        assertEq(credit.deleverageLtv(bytes32(uint256(5))), 0.4e18);
    }

    function test_cryptoLinked_borrowAt20Passes_oneRawMoreFails() public {
        bytes32 id = bytes32(uint256(5));
        _listaMarket(B.Tier.CRYPTO_LINKED, 0.6e18, id);
        _post(id, 10e18); // 1,000 USD
        vm.expectRevert(abi.encodeWithSelector(AtpBorrowExecutor.LtvTooHigh.selector, 0.2e18 + 1, 0.2e18));
        _borrow(id, 200e18 + 1);
        _borrow(id, 200e18);
        assertEq(_ltv(id), 0.2e18);
    }

    function test_index_borrowAt35Passes_oneRawMoreFails() public {
        bytes32 id = bytes32(uint256(1));
        _listaMarket(B.Tier.INDEX_LARGE_CAP, 0.7e18, id);
        _post(id, 10e18);
        vm.expectRevert(abi.encodeWithSelector(AtpBorrowExecutor.LtvTooHigh.selector, 0.35e18 + 1, 0.35e18));
        _borrow(id, 350e18 + 1);
        _borrow(id, 350e18);
    }

    function test_ownerCannotRaiseAboveClassCeiling_orListWithoutClass() public {
        bytes32 id = bytes32(uint256(5));
        _listaMarket(B.Tier.CRYPTO_LINKED, 0.6e18, id);
        vm.expectRevert(AtpBorrowRegistry.BadParameter.selector);
        credit.setLtvConfig(id, 0.2e18 + 1, 0.4e18);
        credit.setLtvConfig(id, 0.2e18, 0.4e18);
        credit.setLtvConfig(id, 0.15e18, 0.3e18);
        assertEq(credit.targetLtv(id), 0.15e18);

        B.Market memory m = _listaMarket();
        m.tier = B.Tier.NONE; // leveraged / unclassified assets are never listed
        vm.expectRevert(AtpBorrowRegistry.BadMarket.selector);
        credit.registerMarket(bytes32(uint256(99)), m);
    }

    // ---- incentives ----

    function test_venusCollateralIncentive_paidToThePositionAccountOnly() public {
        usdt.setMinter(address(vNvda), true);
        vNvda.setIncentives(address(usdt), 100, 0); // 1% on collateral value
        _post(VENUS_ID, 10e18); // 1,624.13 USD
        skip(365 days);
        assertApproxEqAbs(vNvda.rewardOf(address(this)), 16.2413e18, 1e9);
        uint256 cash = _usdtOf(address(this));
        vm.prank(STRANGER);
        uint256 paid = vNvda.claimReward(address(this));
        assertApproxEqAbs(paid, 16.2413e18, 1e9);
        assertEq(_usdtOf(address(this)), cash + paid, "reward not in the portfolio account");
        assertEq(_usdtOf(STRANGER), 0);
        assertEq(vNvda.rewardOf(address(this)), 0);
    }

    function test_listaIncentives_collateralAndNegativeNetBorrowRate() public {
        bytes32 mid = moolah.marketId(listaParams);
        usdt.setMinter(address(moolah), true);
        moolah.setRewardToken(address(usdt));
        moolah.setIncentives(mid, 200, 300); // 2% on collateral, 3% on debt > 2.5% borrow APR
        _post(LISTA_ID, 10e18); // 1,624.13 USD
        _borrow(LISTA_ID, 300e18);
        B.Status memory s = credit.status(LISTA_ID, address(this));
        assertEq(s.collateralIncentiveRate, 0.02e18);
        assertEq(s.borrowIncentiveRate, 0.03e18);
        assertLt(s.borrowRate, s.borrowIncentiveRate, "net borrow rate should be negative");
        skip(365 days);
        // The mock accrues lazily on the position's value when it is next touched: the claim accrues the
        // year's 2.5% interest first, so the debt counts as 307.5.
        uint256 expected = 1624.13e18 * 200 / 10_000 + 307.5e18 * 300 / 10_000;
        moolah.accrueInterest(listaParams);
        assertApproxEqAbs(moolah.rewardOf(mid, address(this)), expected, 1e9);
        uint256 cash = _usdtOf(address(this));
        vm.prank(STRANGER);
        moolah.claimReward(mid, address(this));
        assertApproxEqAbs(_usdtOf(address(this)) - cash, expected, 1e9);
        assertEq(_usdtOf(STRANGER), 0);
    }

    function test_vaultIncentive_onStrategyShares() public {
        vault.setIncentiveAprBps(100);
        _post(VENUS_ID, 10e18);
        _borrow(VENUS_ID, 300e18);
        skip(365 days);
        // 1% a year on the shares' current value (300 USDT plus the vault's 4.5%).
        assertApproxEqAbs(vault.rewardOf(address(this)), 3.135e18, 0.01e18);
        assertEq(credit.status(VENUS_ID, address(0)).vaultIncentiveRate, 0.01e18);
        uint256 cash = _usdtOf(address(this));
        vault.claimReward(address(this));
        assertApproxEqAbs(_usdtOf(address(this)) - cash, 3.135e18, 0.01e18);
    }

    /// @notice Carry is checked net of incentives: borrow - borrowIncentive vs vault + vaultIncentive.
    function test_carryGate_countsIncentives() public {
        _post(VENUS_ID, 10e18);
        vUsdt.setBorrowAprBps(600); // 6% > 4.5% vault
        assertEq(uint8(credit.status(VENUS_ID, address(0)).gate), uint8(B.Gate.NEGATIVE_CARRY));
        vm.expectRevert(
            abi.encodeWithSelector(AtpBorrowExecutor.BorrowGateClosed.selector, B.Gate.NEGATIVE_CARRY)
        );
        _borrow(VENUS_ID, 1e18);
        vUsdt.setIncentives(address(usdt), 0, 100); // net 5% still > 4.5%
        assertEq(uint8(credit.status(VENUS_ID, address(0)).gate), uint8(B.Gate.NEGATIVE_CARRY));
        vault.setIncentiveAprBps(50); // vault 5% vs net borrow 5%: not negative
        assertEq(uint8(credit.status(VENUS_ID, address(0)).gate), uint8(B.Gate.OPEN));
        _borrow(VENUS_ID, 100e18);
        B.Status memory s = credit.status(VENUS_ID, address(this));
        assertFalse(s.shouldUnwind);
        vault.setIncentiveAprBps(0);
        assertTrue(credit.status(VENUS_ID, address(this)).shouldUnwind);
    }
}
