// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { AtpBorrowBase } from "./AtpBorrowBase.sol";
import { AtpBorrowExecutor } from "../../../src/atp/borrow/AtpBorrowExecutor.sol";

/// @dev A second CRE8 portfolio account (smart account stand-in) driven by the test.
contract OtherPortfolio {
    function exec(address target, bytes calldata data) external returns (bytes memory) {
        (bool ok, bytes memory out) = target.call(data);
        if (!ok) {
            assembly {
                revert(add(out, 32), mload(out))
            }
        }
        return out;
    }
}

/// @notice #64 money isolation (EARN_UX §三種錢): one account's borrowed USDT and strategy position can never be
/// moved to another portfolio account, a user wallet or whoever triggers a public step.
contract AtpBorrowIsolationTest is AtpBorrowBase {
    address internal constant STRANGER = address(0x5157);
    OtherPortfolio internal other;

    function setUp() public override {
        super.setUp();
        other = new OtherPortfolio();
        _as(abi.encodeCall(registry.enroll, (address(other), strategy, 1)), address(registry));
        _as(abi.encodeCall(credit.setBorrowPolicy, (VENUS_ID, 10_000_000e18, true)), address(credit));
        _as(abi.encodeCall(comptroller.updateDelegate, (address(lend), true)), address(comptroller));
        _as(abi.encodeCall(nvda.approve, (address(lend), type(uint256).max)), address(nvda));
        _as(abi.encodeCall(usdt.approve, (address(lend), type(uint256).max)), address(usdt));
        _as(abi.encodeCall(vault.approve, (address(lend), type(uint256).max)), address(vault));
        nvda.mint(address(other), 100e18);

        _post(VENUS_ID, 10e18);
        _borrow(VENUS_ID, 300e18);
        _as(
            abi.encodeCall(lend.executeSupplyCollateral, (address(other), VENUS_ID, 10e18, block.timestamp)),
            address(lend)
        );
        _as(
            abi.encodeCall(lend.executeBorrow, (address(other), VENUS_ID, 200e18, block.timestamp)),
            address(lend)
        );
    }

    function test_borrowedUsdt_neverSurfacesAsCash_inEitherAccount() public view {
        assertEq(_usdtOf(address(other)), 0, "borrowed USDT surfaced as cash");
        assertApproxEqAbs(vault.previewRedeem(vault.balanceOf(address(this))), 300e18, 1);
        assertApproxEqAbs(vault.previewRedeem(vault.balanceOf(address(other))), 200e18, 1);
        assertEq(credit.vaultShares(address(other), VENUS_ID), vault.balanceOf(address(other)));
        _noResidue();
    }

    function test_anotherAccount_cannotBorrowRepayOrWithdrawForThisOne() public {
        bytes[3] memory calls = [
            abi.encodeCall(lend.executeBorrow, (address(this), VENUS_ID, 1e18, block.timestamp)),
            abi.encodeCall(
                lend.executeRepay, (address(this), VENUS_ID, type(uint256).max, true, block.timestamp)
            ),
            abi.encodeCall(lend.executeWithdrawCollateral, (address(this), VENUS_ID, 1e18, block.timestamp))
        ];
        for (uint256 i; i < calls.length; ++i) {
            vm.expectRevert(AtpBorrowExecutor.NotAccount.selector);
            other.exec(address(lend), calls[i]);
            vm.prank(STRANGER);
            vm.expectRevert(AtpBorrowExecutor.NotAccount.selector);
            (bool ok,) = address(lend).call(calls[i]);
            ok;
        }
        assertEq(credit.debt(VENUS_ID, address(this)), 300e18);
    }

    function test_publicDeleverage_movesOnlyThatAccountsMoney() public {
        uint256 otherShares = vault.balanceOf(address(other));
        uint256 otherDebt = credit.debt(VENUS_ID, address(other));
        uint256 mineShares = vault.balanceOf(address(this));
        // A: 300 / 1,624.13 = 18.5% LTV; at 70 USD it is 42.9% (line 33.3%). B: 200 / 700 = 28.6% stays below it.
        oracle.setPrice(address(nvda), 70e8);
        vm.prank(STRANGER);
        lend.executeDeleverage(address(this), VENUS_ID);

        assertLt(vault.balanceOf(address(this)), mineShares, "own shares not used");
        assertEq(vault.balanceOf(address(other)), otherShares, "other account's shares touched");
        assertEq(credit.debt(VENUS_ID, address(other)), otherDebt, "other account's debt touched");
        assertEq(_usdtOf(STRANGER), 0, "caller got USDT");
        assertEq(vault.balanceOf(STRANGER), 0, "caller got vault shares");
        assertEq(_usdtOf(address(other)), 0);
        _noResidue();

        vm.prank(STRANGER);
        vm.expectRevert(AtpBorrowExecutor.NothingToDo.selector);
        lend.executeDeleverage(address(other), VENUS_ID);
    }

    function test_closingOneAccount_returnsItsRestToItself_only() public {
        uint256 mineShares = vault.balanceOf(address(this));
        uint256 mineCash = _usdtOf(address(this));
        skip(30 days);
        _as(
            abi.encodeCall(
                lend.executeRepay, (address(other), VENUS_ID, type(uint256).max, true, block.timestamp)
            ),
            address(lend)
        );
        _as(
            abi.encodeCall(
                lend.executeWithdrawCollateral, (address(other), VENUS_ID, type(uint256).max, block.timestamp)
            ),
            address(lend)
        );
        assertEq(credit.debt(VENUS_ID, address(other)), 0);
        assertEq(vault.balanceOf(address(other)), 0);
        assertGt(_usdtOf(address(other)), 0, "carry not in the closing account");
        assertEq(nvda.balanceOf(address(other)), 100e18, "collateral not back in the closing account");
        assertEq(vault.balanceOf(address(this)), mineShares, "open account's shares touched");
        assertEq(_usdtOf(address(this)), mineCash, "open account's cash touched");
        _noResidue();
    }

    function _as(bytes memory data, address target) internal {
        other.exec(target, data);
    }
}
