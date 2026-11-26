// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { RoutingBase } from "./RoutingBase.sol";
import { RoutingTypes as R } from "../../../../src/atp/borrow/v2/RoutingTypes.sol";
import { AtpBorrowRegistryV2 } from "../../../../src/atp/borrow/v2/AtpBorrowRegistryV2.sol";
import { AtpBorrowExecutorV2 } from "../../../../src/atp/borrow/v2/AtpBorrowExecutorV2.sol";
import { AtpBorrowLensV2 } from "../../../../src/atp/borrow/v2/AtpBorrowLensV2.sol";
import { RoutingV2Deployer } from "../../../../src/atp/borrow/v2/RoutingV2Deployer.sol";
import { Erc4626VaultAdapter } from "../../../../src/atp/borrow/v2/VaultAdapters.sol";
import { MockRewardEarnVault } from "../../../../src/testnet/lending/MockRewardEarnVault.sol";

/// @notice The single-use deployer of the registry / lens / executor trio, and the chain 97 reward vault mock
/// end to end (vault emission -> box -> account).
contract RoutingDeployTest is RoutingBase {
    function _registryCode(address executor) internal view returns (bytes memory) {
        return abi.encodePacked(
            type(AtpBorrowRegistryV2).creationCode,
            abi.encode(registry, address(atp), executor, address(comptroller), address(moolah))
        );
    }

    function test_deployer_buildsTheTrio_inOrder_once() public {
        RoutingV2Deployer d = new RoutingV2Deployer(address(this));
        address predicted = d.predictedExecutor();
        assertEq(predicted, vm.computeCreateAddress(address(d), 3));

        // Out of order, or by someone else.
        vm.expectRevert(RoutingV2Deployer.WrongStep.selector);
        d.deployLens(hex"00");
        vm.expectRevert(RoutingV2Deployer.WrongStep.selector);
        d.deployExecutor(hex"00");
        vm.prank(KEEPER);
        vm.expectRevert(RoutingV2Deployer.NotDeployer.selector);
        d.deployRegistry(_registryCode(predicted));
        // A registry bound to any other executor is refused, and the nonce is not consumed.
        vm.expectRevert(RoutingV2Deployer.BadWiring.selector);
        d.deployRegistry(_registryCode(address(0xBEEF)));
        vm.expectRevert(RoutingV2Deployer.CreateFailed.selector);
        d.deployRegistry(hex"fe");

        address reg = d.deployRegistry(_registryCode(predicted));
        vm.expectRevert(RoutingV2Deployer.WrongStep.selector);
        d.deployRegistry(_registryCode(predicted));
        // A lens of another registry is refused.
        vm.expectRevert(RoutingV2Deployer.BadWiring.selector);
        d.deployLens(abi.encodePacked(type(AtpBorrowLensV2).creationCode, abi.encode(address(credit))));
        address l = d.deployLens(abi.encodePacked(type(AtpBorrowLensV2).creationCode, abi.encode(reg)));
        address e = d.deployExecutor(
            abi.encodePacked(type(AtpBorrowExecutorV2).creationCode, abi.encode(reg, l, address(extension)))
        );
        assertEq(e, predicted);
        assertEq(AtpBorrowRegistryV2(reg).executor(), e);
        assertEq(AtpBorrowExecutorV2(e).borrowRegistry(), reg);
        assertEq(AtpBorrowExecutorV2(e).lens(), l);
        assertEq(AtpBorrowLensV2(l).executor(), e);
        vm.expectRevert(RoutingV2Deployer.WrongStep.selector);
        d.deployExecutor(
            abi.encodePacked(type(AtpBorrowExecutorV2).creationCode, abi.encode(reg, l, address(extension)))
        );
        // The deployed trio works: an adapter can be bound to it.
        AtpBorrowRegistryV2(reg).setAdapter(R.VaultKind.ERC4626, address(new Erc4626VaultAdapter(e)));
    }

    function test_rewardVault_emissionReachesTheAccountThroughTheBox() public {
        MockRewardEarnVault vault = new MockRewardEarnVault(usdt, address(this), 450, lista);
        usdt.setMinter(address(vault), true);
        lista.setMinter(address(vault), true);
        vault.setIncentiveAprBps(1_000);
        // An empty vault cannot be listed (its share price could be inflated by a donation).
        vm.expectRevert();
        credit.registerVault(R.VaultKind.ERC4626, address(usdt), address(vault));
        vm.startPrank(LENDER);
        usdt.approve(address(vault), MAX);
        vault.deposit(100_000e18, LENDER);
        vm.stopPrank();
        bytes32 id = credit.registerVault(R.VaultKind.ERC4626, address(usdt), address(vault));
        _open(L_TSLA_T, id, 10e18, 0);
        skip(1); // a report is needed for a vault without an on-chain rate
        vm.expectRevert();
        _open(L_TSLA_T, id, 0, 300e18);
        _reportVault(id, 0.045e18, 0.1e18);
        _open(L_TSLA_T, id, 0, 300e18);
        skip(365 days / 10);
        // 300 USD at 10% for a tenth of a year = 3 reward tokens, owed to the box.
        assertApproxEqRel(vault.rewardOf(_box()), 3e18, 0.02e18);
        vm.prank(KEEPER);
        vault.claimReward(_box());
        assertApproxEqRel(lista.balanceOf(_box()), 3e18, 0.02e18);
        assertEq(lista.balanceOf(address(this)), 0);
        vm.prank(KEEPER);
        uint256 collected = lend.collectRewards(address(this), address(lista));
        assertEq(lista.balanceOf(address(this)), collected);
        assertEq(lista.balanceOf(_box()), 0);
        // The vault's own asset reaching the box directly is strategy money: released only without debt.
        usdt.mint(_box(), 5e18);
        _reduce(L_TSLA_T, id, MAX, MAX, 0);
        assertEq(usdt.balanceOf(_box()), 0, "idle loan token left the box with the release");
        assertGt(usdt.balanceOf(address(this)), 5e18);
    }

    function _reportVault(bytes32 id, uint256 rate, uint256 incentive) internal {
        IRegReports.RouteReport[] memory routes = new IRegReports.RouteReport[](0);
        IRegReports.VaultReport[] memory vaults = new IRegReports.VaultReport[](1);
        vaults[0] = IRegReports.VaultReport(id, rate, incentive);
        vm.prank(REPORTER);
        IRegReports(address(credit)).reportRates(routes, vaults);
    }
}

interface IRegReports {
    struct RouteReport {
        bytes32 routeId;
        uint256 borrowIncentive;
        uint256 collateralIncentive;
    }

    struct VaultReport {
        bytes32 vaultId;
        uint256 baseRate;
        uint256 incentive;
    }

    function reportRates(RouteReport[] calldata routes, VaultReport[] calldata vaults) external;
}
