// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { AtpPerfFeeLedger as Ledger, PerfFeeNavMath } from "../../../src/atp/AtpPerfFeeLedger.sol";
import { AtpRegistry } from "../../../src/atp/AtpRegistry.sol";
import { AtpMultiPoolOracle } from "../../../src/atp/AtpMultiPoolOracle.sol";
import { AtpYieldRegistry } from "../../../src/atp/yield/AtpYieldRegistry.sol";
import { PancakeV3TwapOracle } from "../../../src/atp/PancakeV3TwapOracle.sol";
import { PushFeedPriceSource } from "../../../src/atp/PushFeedPriceSource.sol";
import { IPriceSource } from "../../../src/atp/interfaces/IPriceSource.sol";
import { MockPancakeV3Pool } from "../PancakeV3TwapOracle.t.sol";
import { MockAggregator } from "../AtpMultiPoolOracleSecondary.t.sol";

contract LedgerToken is ERC20 {
    address public taxedRecipient;
    address public taxedSender;
    address public callbackTarget;
    bytes public callbackData;
    bool public callbackBlocked;

    constructor() ERC20("Ledger test", "LT") { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }

    function senderTax(address from) external {
        taxedSender = from;
    }

    function tax(address to) external {
        taxedRecipient = to;
    }

    function arm(address target, bytes calldata data) external {
        callbackTarget = target;
        callbackData = data;
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (callbackTarget != address(0) && from != address(0)) {
            (bool ok, bytes memory reason) = callbackTarget.call(callbackData);
            callbackBlocked = !ok && bytes4(reason) == ReentrancyGuard.ReentrancyGuardReentrantCall.selector;
        }
        if (taxedSender != address(0) && from == taxedSender && amount != 0) {
            super._update(from, address(0), 1);
        }
        if (to == taxedRecipient && amount != 0) {
            super._update(from, address(0), 1);
            --amount;
        }
        super._update(from, to, amount);
    }
}

contract LedgerAccount {
    address private immutable owner = msg.sender;

    function execute(address target, bytes calldata data) external returns (bytes memory result) {
        require(msg.sender == owner, "account: owner only");
        bool ok;
        (ok, result) = target.call(data);
        if (!ok) {
            assembly { revert(add(result, 32), mload(result)) }
        }
    }
}

contract AtpPerfFeeLedgerTest is Test {
    Ledger internal ledger;
    AtpRegistry internal registry;
    AtpMultiPoolOracle internal oracle;
    AtpYieldRegistry internal yields;
    LedgerToken internal cash;
    LedgerToken internal asset;
    MockPancakeV3Pool internal pool;
    LedgerAccount internal wallet;
    address internal account;
    address internal constant CREATOR = address(0xC8);
    address internal constant PLATFORM = address(0xFEE);
    address internal constant RECIPIENT = address(0xCA5);
    address internal constant REPORTER = address(0xA11);
    uint256 internal strategy;

    function setUp() public {
        vm.warp(100 days);
        cash = new LedgerToken();
        asset = new LedgerToken();
        registry = new AtpRegistry();
        registry.setNumeraire(address(cash));
        oracle = new AtpMultiPoolOracle(address(cash));
        pool = new MockPancakeV3Pool(address(asset), address(cash));
        pool.setMeanTick(0, 30 minutes);
        oracle.setOracle(address(asset), address(pool), 30 minutes, 50, 1 hours);
        yields = new AtpYieldRegistry(registry, address(this));
        ledger = new Ledger(registry, oracle, yields, PLATFORM);
        vm.prank(CREATOR);
        strategy = registry.registerStrategy("test", "test", true);
        _publish(0);
        wallet = new LedgerAccount();
        account = address(wallet);
        uint16 initialVersion = registry.activeVersion(strategy);
        vm.startPrank(account);
        registry.enroll(account, strategy, initialVersion);
        cash.approve(address(ledger), type(uint256).max);
        ledger.start();
        vm.stopPrank();
        cash.mint(address(this), 1e36);
        cash.approve(address(ledger), type(uint256).max);
        ledger.setReporter(REPORTER, true);
    }

    function _enroll() internal {
        uint16 current = registry.activeVersion(strategy);
        vm.prank(account);
        registry.enroll(account, strategy, current);
    }

    function _nextPublication() internal {
        if (registry.versionCount(strategy) != 0) {
            uint256 earliest = uint256(registry.lastPublishedAt(strategy)) + registry.PUBLICATION_INTERVAL();
            if (block.timestamp < earliest) vm.warp(earliest);
        }
    }

    function _schedule(address[] memory assets, uint16[] memory weights, uint16 bps, uint64 activeAt)
        internal
        returns (uint16 v)
    {
        _nextPublication();
        vm.prank(CREATOR);
        v = registry.publishSettingsVersion(strategy, assets, weights, bytes32(0), bytes32(0), bps, activeAt);
    }

    function _publishAssets(address[] memory assets, uint16[] memory weights, uint16 bps) internal {
        uint16 v = _schedule(assets, weights, bps, 0);
        vm.warp(registry.version(strategy, v).activeAt);
    }

    function _publish(uint64 activeAt) internal {
        address[] memory assets = new address[](2);
        assets[0] = address(cash);
        assets[1] = address(asset);
        uint16[] memory weights = new uint16[](2);
        weights[0] = 5_000;
        weights[1] = 5_000;
        uint16 v = _schedule(assets, weights, 2_000, activeAt);
        if (activeAt == 0) vm.warp(registry.version(strategy, v).activeAt);
    }

    function _principal() internal view returns (uint256 p) {
        (p,,,) = ledger.accounts(account);
    }

    function _withdraw(uint256 amount) internal returns (Ledger.Withdrawal memory) {
        vm.prank(account);
        return ledger.withdraw(amount, RECIPIENT, 0, block.timestamp);
    }

    function test_example100_150_60_splitsOnlyProfit() public {
        ledger.deposit(account, 100e18);
        cash.mint(account, 50e18);
        Ledger.Withdrawal memory w = _withdraw(60e18);
        assertEq(w.value, 150e18);
        assertEq(w.profit, 20e18);
        assertEq(w.fee, 4e18);
        assertEq(w.platformFee, 0.4e18);
        assertEq(_principal(), 60e18);
        assertEq(cash.balanceOf(RECIPIENT), 56e18);
        assertEq(cash.balanceOf(CREATOR), 3.6e18);
        assertEq(cash.balanceOf(PLATFORM), 0.4e18);
        assertEq(cash.balanceOf(address(ledger)), 0);
    }

    function test_breakEven_noFee_fullClearsBasis() public {
        ledger.deposit(account, 100e18);
        Ledger.Withdrawal memory w = _withdraw(100e18);
        assertEq(w.profit, 0);
        assertEq(w.fee, 0);
        assertEq(_principal(), 0);
        assertEq(cash.balanceOf(RECIPIENT), 100e18);
    }

    function test_loss_partialAndFull_noFee() public {
        ledger.deposit(account, 100e18);
        cash.burn(account, 20e18);
        Ledger.Withdrawal memory w = _withdraw(40e18);
        assertEq(w.fee, 0);
        assertEq(_principal(), 50e18);
        w = _withdraw(40e18);
        assertEq(w.fee, 0);
        assertEq(_principal(), 0);
    }

    function test_multipleDepositsAndWithdrawals_preserveBasis() public {
        ledger.deposit(account, 100e18);
        cash.mint(account, 50e18);
        _withdraw(60e18);
        ledger.deposit(account, 30e18);
        assertEq(_principal(), 90e18);
        Ledger.Withdrawal memory w = _withdraw(120e18);
        assertEq(w.profit, 30e18);
        assertEq(w.fee, 6e18);
        assertEq(_principal(), 0);
        assertEq(cash.balanceOf(PLATFORM) + cash.balanceOf(CREATOR), 10e18);
    }

    function test_donationsAreProfit_andNeverImportedAsBasis() public {
        cash.mint(account, 100e18);
        assertEq(_principal(), 0);
        Ledger.Withdrawal memory w = _withdraw(100e18);
        assertEq(w.profit, 100e18);
        assertEq(w.fee, 20e18);
        assertEq(w.remainingPrincipal, 0);
    }

    function test_rounding_keepsBasisAndRoundsProfitFeeDown() public {
        ledger.deposit(account, 2);
        cash.mint(account, 1);
        Ledger.Withdrawal memory w = _withdraw(1);
        assertEq(w.profit, 0);
        assertEq(w.fee, 0);
        assertEq(_principal(), 2); // ceil(2 * 2 / 3)
        w = _withdraw(2);
        assertEq(w.remainingPrincipal, 0);
        assertEq(w.fee, 0);
    }

    function testFuzz_formulaAndConservation(uint128 pSeed, uint128 vSeed, uint128 wSeed) public {
        uint256 p = bound(uint256(pSeed), 0, 1e30);
        uint256 v = bound(uint256(vSeed), 1, 1e30);
        uint256 gross = bound(uint256(wSeed), 1, v);
        if (p != 0) ledger.deposit(account, p);
        if (v >= p) cash.mint(account, v - p);
        else cash.burn(account, p - v);
        Ledger.Withdrawal memory w = _withdraw(gross);
        uint256 expectedProfit = v > p ? gross * (v - p) / v : 0;
        assertEq(w.profit, expectedProfit);
        assertEq(w.fee, expectedProfit * 2_000 / 10_000);
        assertEq(w.platformFee, w.fee / 10);
        assertEq(w.remainingPrincipal, Math.ceilDiv(p * (v - gross), v));
        assertEq(cash.balanceOf(RECIPIENT) + cash.balanceOf(CREATOR) + cash.balanceOf(PLATFORM), gross);
        assertEq(cash.balanceOf(account), v - gross);
        assertEq(cash.balanceOf(address(ledger)), 0);
    }

    function testFuzz_splitWithdrawalNeverOvercharges(uint96 pSeed, uint96 gainSeed, uint96 splitSeed)
        public
    {
        uint256 p = bound(uint256(pSeed), 1, 1e24);
        uint256 gain = bound(uint256(gainSeed), 0, 1e24);
        uint256 v = p + gain;
        uint256 split = bound(uint256(splitSeed), 1, v);
        ledger.deposit(account, p);
        cash.mint(account, gain);
        Ledger.Withdrawal memory first = _withdraw(split);
        uint256 fees = first.fee;
        if (split != v) fees += _withdraw(v - split).fee;
        assertLe(fees, gain / 5);
        assertEq(_principal(), 0);
    }

    function test_depositRejectsZeroSelfAndInactive() public {
        vm.expectRevert(Ledger.InvalidAmount.selector);
        ledger.deposit(account, 0);
        vm.prank(account);
        vm.expectRevert(Ledger.InvalidAmount.selector);
        ledger.deposit(account, 1);
        vm.expectRevert(Ledger.ServiceNotActive.selector);
        ledger.deposit(address(0xBAD), 1);
    }

    function test_startRequiresAccountEnrollmentAndActiveVersion() public {
        vm.prank(RECIPIENT);
        vm.expectRevert(Ledger.Unauthorized.selector);
        ledger.start();
        LedgerAccount other = new LedgerAccount();
        vm.prank(address(other));
        vm.expectRevert(Ledger.NotEnrolled.selector);
        ledger.start();
        _publish(0);
        vm.startPrank(address(other));
        registry.enroll(address(other), strategy, 2);
        ledger.start(); // No provider fee registration or asset sync is required.
        vm.stopPrank();
        (,,, Ledger.Status status) = ledger.accounts(address(other));
        assertEq(uint256(status), uint256(Ledger.Status.ACTIVE));
        vm.prank(account);
        vm.expectRevert(Ledger.AlreadyActive.selector);
        ledger.start();
    }

    function test_creatorFeeBoundsExplicitVersionAndImmutable() public {
        AtpRegistry.Version memory v = registry.version(strategy, 0);
        _nextPublication();
        vm.startPrank(CREATOR);
        vm.expectRevert(abi.encodeWithSelector(AtpRegistry.PerformanceFeeOutOfRange.selector, uint16(499)));
        registry.publishSettingsVersion(
            strategy, v.assets, v.weightsBps, v.scheduleHash, v.settingsHash, 499, 0
        );
        vm.expectRevert(abi.encodeWithSelector(AtpRegistry.PerformanceFeeOutOfRange.selector, uint16(2_001)));
        registry.publishSettingsVersion(
            strategy, v.assets, v.weightsBps, v.scheduleHash, v.settingsHash, 2_001, 0
        );
        registry.publishSettingsVersion(
            strategy, v.assets, v.weightsBps, v.scheduleHash, v.settingsHash, 500, 0
        );
        vm.stopPrank();
        assertEq(registry.version(strategy, 1).performanceFeeBps, 2_000);
        assertEq(registry.version(strategy, 0).performanceFeeBps, 500);
        assertEq(
            v.configHash,
            keccak256(abi.encode(v.assets, v.weightsBps, v.scheduleHash, v.settingsHash, uint16(2_000)))
        );
        assertTrue(v.configHash != registry.version(strategy, 0).configHash);
        cash.mint(account, 100e18);
        assertEq(_withdraw(10e18).fee, 0.5e18);
    }

    function test_ownerAndReporterCannotRegisterCreatorFees() public {
        address[3] memory callers = [address(this), REPORTER, CREATOR];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            (bool ok,) = address(ledger)
                .call(
                    abi.encodeWithSignature(
                        "registerCreatorFee(uint256,uint16,uint16)", strategy, uint16(1), uint16(500)
                    )
                );
            assertFalse(ok, "fee bridge must be removed for every caller");
        }
        assertEq(registry.version(strategy, 0).performanceFeeBps, 2_000);
    }

    function test_oldEnrollmentFollowsLatestFeeAndChargesPausedExits() public {
        cash.mint(account, 100e18);
        assertEq(_withdraw(10e18).fee, 2e18);
        AtpRegistry.Version memory v = registry.version(strategy, 0);
        _publishAssets(v.assets, v.weightsBps, 500);
        assertEq(registry.enrollments(account).version, 1);
        vm.prank(account);
        registry.setPaused(account, true);
        assertEq(_withdraw(10e18).fee, 0.5e18);
    }

    function test_futureVersionNotChargedBeforeActiveAt() public {
        AtpRegistry.Version memory v = registry.version(strategy, 0);
        _publishAssets(v.assets, v.weightsBps, 500);
        cash.mint(account, 100e18);
        _schedule(v.assets, v.weightsBps, 2_000, 0);
        uint64 at = registry.version(strategy, 3).activeAt;
        assertEq(at, block.timestamp + 1 days);
        vm.warp(at - 1);
        assertEq(_withdraw(10e18).fee, 0.5e18);
        vm.warp(at);
        assertEq(_withdraw(10e18).fee, 2e18);
        assertEq(registry.enrollments(account).version, 1);
    }

    function test_crossStrategyCannotAttributeOldProfitToNewCreator() public {
        uint256 other = registry.registerStrategy("other", "other", true);
        address[] memory assets = new address[](1);
        assets[0] = address(cash);
        uint16[] memory weights = new uint16[](1);
        weights[0] = 10_000;
        registry.publishVersion(other, assets, weights, bytes32(0), 0);
        vm.warp(registry.version(other, 1).activeAt);
        vm.prank(account);
        registry.enroll(account, other, 1);
        vm.expectRevert(Ledger.StrategyChanged.selector);
        ledger.deposit(account, 1);
    }

    function test_platformNoticeBoundsReplacementAndExactBoundary() public {
        assertEq(ledger.platformShareBps(), 1_000);
        vm.expectRevert(Ledger.InvalidFee.selector);
        ledger.schedulePlatformShare(2_001);
        ledger.schedulePlatformShare(2_000);
        uint256 at = ledger.platformShareActiveAt();
        vm.warp(at - 1);
        assertEq(ledger.platformShareBps(), 1_000);
        vm.warp(at);
        assertEq(ledger.platformShareBps(), 2_000);
        cash.mint(account, 100e18);
        assertEq(_withdraw(10e18).platformFee, 0.4e18);
        ledger.schedulePlatformShare(0);
        vm.warp(block.timestamp + 1 days);
        ledger.schedulePlatformShare(1_500); // replacing a pending change restarts its notice
        vm.warp(ledger.platformShareActiveAt() - 1);
        assertEq(ledger.platformShareBps(), 2_000);
        vm.warp(block.timestamp + 1);
        assertEq(ledger.platformShareBps(), 1_500);
        ledger.schedulePlatformShare(0);
        vm.warp(ledger.platformShareActiveAt());
        assertEq(_withdraw(10e18).platformFee, 0);
    }

    function test_adminFollowsRegistryTwoStepOwner_reporterCannotAdmin() public {
        vm.startPrank(REPORTER);
        vm.expectRevert(Ledger.Unauthorized.selector);
        ledger.schedulePlatformShare(0);
        vm.expectRevert(Ledger.Unauthorized.selector);
        ledger.setReporter(RECIPIENT, true);
        vm.stopPrank();
        vm.expectRevert(Ledger.InvalidConfig.selector);
        ledger.setReporter(address(0), true);
        registry.transferOwnership(RECIPIENT);
        vm.prank(RECIPIENT);
        registry.acceptOwnership();
        vm.expectRevert(Ledger.Unauthorized.selector);
        ledger.schedulePlatformShare(0);
        vm.prank(RECIPIENT);
        ledger.schedulePlatformShare(0);
    }

    function test_reporterStopOnce_preservesBasisAndFunds_ownerRestartsFromZero() public {
        ledger.deposit(account, 100e18);
        vm.prank(RECIPIENT);
        vm.expectRevert(Ledger.Unauthorized.selector);
        ledger.stopService(account, 1, bytes32(0));
        vm.expectEmit(true, true, true, true, address(ledger));
        emit Ledger.ServiceStopped(account, 1, REPORTER, keccak256("transfer evidence"));
        vm.prank(REPORTER);
        ledger.stopService(account, 1, keccak256("transfer evidence"));
        assertEq(_principal(), 100e18);
        assertEq(cash.balanceOf(account), 100e18);
        vm.prank(REPORTER);
        vm.expectRevert(Ledger.ServiceNotActive.selector);
        ledger.stopService(account, 1, bytes32(0));
        vm.expectRevert(Ledger.ServiceNotActive.selector);
        ledger.deposit(account, 1);
        vm.prank(account);
        vm.expectRevert(Ledger.ServiceNotActive.selector);
        ledger.withdraw(1, RECIPIENT, 0, block.timestamp);
        vm.prank(REPORTER);
        vm.expectRevert(Ledger.Unauthorized.selector);
        ledger.start();
        vm.prank(account);
        ledger.start();
        assertEq(_principal(), 0);
        (,, uint256 epoch, Ledger.Status status) = ledger.accounts(account);
        assertEq(epoch, 2);
        assertEq(uint256(status), uint256(Ledger.Status.ACTIVE));
        vm.prank(REPORTER);
        vm.expectRevert(Ledger.ServiceNotActive.selector);
        ledger.stopService(account, 1, bytes32(0));
        assertEq(_withdraw(100e18).fee, 20e18);
    }

    function test_revokedReporterAndLossCannotStopService() public {
        ledger.deposit(account, 100e18);
        cash.burn(account, 99e18);
        ledger.setReporter(REPORTER, false);
        vm.prank(REPORTER);
        vm.expectRevert(Ledger.Unauthorized.selector);
        ledger.stopService(account, 1, bytes32(0));
        assertEq(_withdraw(1e18).fee, 0);
    }

    function test_conservativeValue_usesLowerMeanInBothDirections() public {
        cash.mint(account, 100e18);
        asset.mint(account, 100e18);
        pool.setMeanTick(1_000, 30 minutes);
        pool.setRecentMeanTick(-1_000);
        (uint256 twap, uint256 recent,) =
            oracle.oracleOf(address(asset)).previewSwapWindows(address(asset), address(cash), 100e18);
        assertLt(recent, twap);
        // Independent floor(100e18 * (10000/10001)^1000), rather than an execution quote.
        assertEq(ledger.accountValue(account), 100e18 + 90_484_194_193_276_887_808);
        pool.setRecentMeanTick(2_000);
        assertEq(ledger.accountValue(account), 100e18 + 110_516_539_260_323_269_724);
    }

    function test_historicalAssetsCountOnceAndUnlistedGiftsAreExcluded() public {
        asset.mint(account, 10e18);
        cash.mint(account, 20e18);
        _publish(0); // duplicate asset across versions
        _enroll();
        assertEq(ledger.accountValue(account), 30e18);
        address[] memory assets = new address[](1);
        assets[0] = address(cash);
        uint16[] memory weights = new uint16[](1);
        weights[0] = 10_000;
        _publishAssets(assets, weights, 2_000);
        _enroll();
        LedgerToken gift = new LedgerToken();
        gift.mint(account, 1e30);
        vm.mockCallRevert(
            address(registry), abi.encodeCall(registry.version, (strategy, 1)), "old history read"
        );
        vm.mockCallRevert(
            address(registry), abi.encodeCall(registry.version, (strategy, 2)), "old history read"
        );
        assertEq(ledger.accountValue(account), 30e18);
    }

    function test_oracleFailuresAtomic_butOwnerCanTransferDirectly() public {
        ledger.deposit(account, 100e18);
        asset.mint(account, 1e18);
        pool.setObserveReverts(true);
        vm.expectRevert(PancakeV3TwapOracle.TwapUnavailable.selector);
        _withdraw(10e18);
        assertEq(_principal(), 100e18);
        assertEq(cash.balanceOf(RECIPIENT), 0);
        wallet.execute(address(cash), abi.encodeCall(cash.transfer, (RECIPIENT, 100e18)));
        assertEq(cash.balanceOf(RECIPIENT), 100e18);
    }

    function test_zeroHoldingsAvoidOracle_andFullUsdtExitWorksWithClearedOracle() public {
        ledger.deposit(account, 100e18);
        oracle.clearOracle(address(asset));
        assertEq(ledger.accountValue(account), 100e18);
        _withdraw(100e18);
        assertEq(_principal(), 0);
    }

    function test_badBalanceReadFailsClosed() public {
        cash.mint(account, 10e18);
        vm.mockCallRevert(address(asset), abi.encodeCall(asset.balanceOf, (account)), "unavailable");
        vm.expectRevert(bytes("unavailable"));
        _withdraw(1e18);
    }

    function test_withdrawRejectsZeroOverValueWrongCallerAndBadRecipient() public {
        ledger.deposit(account, 10e18);
        vm.expectRevert(Ledger.InvalidAmount.selector);
        _withdraw(0);
        vm.expectRevert(Ledger.InvalidAmount.selector);
        _withdraw(10e18 + 1);
        vm.prank(RECIPIENT);
        vm.expectRevert(Ledger.ServiceNotActive.selector);
        ledger.withdraw(1, account, 0, block.timestamp);
        vm.startPrank(account);
        vm.expectRevert(Ledger.InvalidRecipient.selector);
        ledger.withdraw(1, account, 0, block.timestamp);
        vm.expectRevert(Ledger.InvalidRecipient.selector);
        ledger.withdraw(1, address(0), 0, block.timestamp);
        vm.expectRevert(Ledger.InvalidRecipient.selector);
        ledger.withdraw(1, address(ledger), 0, block.timestamp);
        vm.expectRevert(Ledger.DeadlineExpired.selector);
        ledger.withdraw(1, RECIPIENT, 0, block.timestamp - 1);
        vm.expectRevert(Ledger.BelowMinimum.selector);
        ledger.withdraw(1, RECIPIENT, 2, block.timestamp);
        vm.stopPrank();
    }

    function test_missingAllowanceRollsBackBasis() public {
        ledger.deposit(account, 10e18);
        vm.prank(account);
        cash.approve(address(ledger), 0);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, address(ledger), uint256(0), uint256(1e18)
            )
        );
        _withdraw(1e18);
        assertEq(_principal(), 10e18);
        cash.approve(address(ledger), 0);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, address(ledger), uint256(0), uint256(1)
            )
        );
        ledger.deposit(account, 1);
        assertEq(_principal(), 10e18);
    }

    function test_missingPayerBalanceCannotCreateBasis() public {
        uint256 balance = cash.balanceOf(address(this));
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, address(this), balance, balance + 1
            )
        );
        ledger.deposit(account, balance + 1);
        assertEq(_principal(), 0);
        assertEq(cash.balanceOf(account), 0);
    }

    function test_taxedDepositRollsBack() public {
        cash.tax(account);
        vm.expectRevert(Ledger.TransferMismatch.selector);
        ledger.deposit(account, 10e18);
        assertEq(_principal(), 0);
        assertEq(cash.balanceOf(account), 0);
    }

    function test_taxedWithdrawalPayoutRollsBackAndHonorsMinNet() public {
        ledger.deposit(account, 10e18);
        cash.tax(RECIPIENT);
        vm.prank(account);
        vm.expectRevert(Ledger.TransferMismatch.selector);
        ledger.withdraw(10e18, RECIPIENT, 10e18, block.timestamp);
        assertEq(_principal(), 10e18);
        assertEq(cash.balanceOf(account), 10e18);
        assertEq(cash.balanceOf(RECIPIENT), 0);
    }

    function test_senderTaxDepositAndWithdrawalRollBack() public {
        cash.senderTax(address(this));
        vm.expectRevert(Ledger.TransferMismatch.selector);
        ledger.deposit(account, 10e18);
        assertEq(_principal(), 0);
        cash.senderTax(address(0));
        ledger.deposit(account, 10e18);
        cash.senderTax(account);
        vm.expectRevert(Ledger.TransferMismatch.selector);
        _withdraw(1e18);
        assertEq(_principal(), 10e18);
        assertEq(cash.balanceOf(account), 10e18);
    }

    function test_creatorAndPlatformPayoutFailuresRollBackEarlierTransfers() public {
        ledger.deposit(account, 100e18);
        cash.mint(account, 50e18);
        cash.tax(CREATOR);
        vm.expectRevert(Ledger.TransferMismatch.selector);
        _withdraw(60e18);
        assertEq(_principal(), 100e18);
        assertEq(cash.balanceOf(RECIPIENT), 0);
        assertEq(cash.balanceOf(PLATFORM), 0);
        cash.tax(PLATFORM);
        vm.expectRevert(Ledger.TransferMismatch.selector);
        _withdraw(60e18);
        assertEq(_principal(), 100e18);
        assertEq(cash.balanceOf(RECIPIENT), 0);
        assertEq(cash.balanceOf(CREATOR), 0);
    }

    function test_routerSecondaryFailureCannotBeBypassedByValidPairWindows() public {
        cash.mint(account, 100e18);
        asset.mint(account, 100e18);
        assertEq(ledger.accountValue(account), 200e18);
        bytes memory reason = abi.encodeWithSelector(
            AtpMultiPoolOracle.SourcesDisagree.selector, address(asset), uint256(1e18), uint256(0.1e18)
        );
        vm.mockCallRevert(
            address(oracle), abi.encodeCall(oracle.previewSwap, (address(asset), address(cash), 1e18)), reason
        );
        vm.expectRevert(reason);
        _withdraw(10e18);
        assertEq(cash.balanceOf(RECIPIENT), 0);
        (uint256 twap, uint256 recent,) =
            oracle.oracleOf(address(asset)).previewSwapWindows(address(asset), address(cash), 100e18);
        assertEq(twap, 100e18);
        assertEq(recent, 100e18);
    }

    function test_93HeldAssetsAndTenVersions_gasReport() public {
        address[] memory assets = new address[](93);
        uint16[] memory weights = new uint16[](93);
        assets[0] = address(cash);
        assets[1] = address(asset);
        for (uint256 i = 1; i < 93; ++i) {
            LedgerToken token = i == 1 ? asset : new LedgerToken();
            assets[i] = address(token);
            weights[i] = i == 92 ? 172 : 108;
            token.mint(account, 1e18);
            if (i > 1) {
                MockPancakeV3Pool pair = new MockPancakeV3Pool(address(token), address(cash));
                pair.setMeanTick(0, 30 minutes);
                oracle.setOracle(address(token), address(pair), 30 minutes, 50, 1 hours);
            }
        }
        cash.mint(account, 100e18);
        _publishAssets(assets, weights, 2_000);
        _enroll();
        uint256 beforeGas = gasleft();
        uint256 nav = ledger.accountValue(account);
        emit log_named_uint("NAV_GAS_93_HELD_2_VERSIONS_WARM", beforeGas - gasleft());
        assertEq(nav, 192e18);
        for (uint256 i; i < 8; ++i) {
            _publishAssets(assets, weights, 2_000);
        }
        _enroll();
        beforeGas = gasleft();
        nav = ledger.accountValue(account);
        uint256 used = beforeGas - gasleft();
        emit log_named_uint("NAV_GAS_93_HELD_10_VERSIONS_WARM", used);
        assertEq(nav, 192e18);
        assertLt(used, 12_000_000);
    }

    // Review SpecRegression: the true NAV upper bound is below principal in either sale direction.
    function _roundingLossFixture(bool reverse) internal {
        ledger.deposit(account, 100e18);
        cash.burn(account, 50e18);
        asset.mint(account, 49_996e15);
        if (reverse) {
            oracle.clearOracle(address(asset));
            pool = new MockPancakeV3Pool(address(cash), address(asset));
            oracle.setOracle(address(asset), address(pool), 30 minutes, 50, 1 hours);
            pool.setCumulatives(0, -900, 30 minutes);
        } else {
            pool.setCumulatives(0, 900, 30 minutes);
        }
        uint256 trueUpperBound = 50e18 + uint256(49_996e15) * 100_005 / 100_000;
        assertLt(trueUpperBound, _principal());
        Ledger.Withdrawal memory w = _withdraw(50e18);
        assertLe(w.value, trueUpperBound);
        assertEq(w.fee, 0);
    }

    function test_spec_noFeeOnLossToken0() public {
        _roundingLossFixture(false);
        assertEq(cash.balanceOf(CREATOR) + cash.balanceOf(PLATFORM), 0, "loss must not incur performance fee");
    }

    function test_spec_noFeeOnLossToken1() public {
        _roundingLossFixture(true);
        assertEq(cash.balanceOf(CREATOR) + cash.balanceOf(PLATFORM), 0, "loss must not incur performance fee");
    }

    function test_platformShareRejectsAboveTwentyPercent() public {
        vm.expectRevert(Ledger.InvalidFee.selector);
        ledger.schedulePlatformShare(2_001);
    }

    function _twentyVersionWithdrawal(bool allCash, bool extremeTicks) internal {
        test_93HeldAssetsAndTenVersions_gasReport();
        address[] memory assets = registry.version(strategy, 10).assets;
        uint16[] memory weights = registry.version(strategy, 10).weightsBps;
        if (allCash) {
            for (uint256 i = 1; i < assets.length; ++i) {
                LedgerToken token = LedgerToken(assets[i]);
                token.burn(account, token.balanceOf(account));
            }
        }
        for (uint16 v = 11; v <= 20; ++v) {
            _publishAssets(assets, weights, 2_000);
        }
        _enroll();
        // Simulate a fresh transaction, including all pool/token/oracle storage reads being cold.
        for (uint256 i = 1; i < assets.length; ++i) {
            PancakeV3TwapOracle pair = oracle.oracleOf(assets[i]);
            MockPancakeV3Pool source = MockPancakeV3Pool(address(pair.pool()));
            if (extremeTicks) source.setMeanTick(887_272, 30 minutes);
            vm.cool(address(source));
            vm.cool(address(pair));
            vm.cool(assets[i]);
        }
        vm.cool(address(cash));
        vm.cool(address(oracle));
        vm.cool(address(yields));
        vm.cool(address(registry));
        vm.cool(address(ledger));
        uint256 beforeGas = gasleft();
        vm.prank(account);
        (bool ok, bytes memory result) = address(ledger).call{ gas: 12_000_000 }(
            abi.encodeCall(ledger.withdraw, (100e18, RECIPIENT, 0, block.timestamp))
        );
        uint256 used = beforeGas - gasleft();
        emit log_named_uint(
            allCash ? "COLD_ALL_CASH_WITHDRAW_GAS_93_20" : "COLD_HELD_WITHDRAW_GAS_93_20", used
        );
        assertTrue(ok, "complete withdrawal must fit UserOp gas allowance");
        assertLt(used, 12_000_000);
        Ledger.Withdrawal memory w = abi.decode(result, (Ledger.Withdrawal));
        if (extremeTicks) {
            uint256 upper =
                100e18 + 92 * 340_256_786_836_388_094_050_805_785_052_946_541_066_751_507_546_701_582_068;
            assertLe(w.value, upper);
            assertGe(w.value, upper - upper / 1e18);
        } else {
            assertEq(w.value, allCash ? 100e18 : 192e18);
        }
        assertEq(cash.balanceOf(account), 0);
        assertEq(cash.balanceOf(RECIPIENT) + cash.balanceOf(CREATOR) + cash.balanceOf(PLATFORM), 100e18);
    }

    function test_93AssetsTwentyVersions_completeWithdrawalWithinGasCap() public {
        _twentyVersionWithdrawal(false, false);
    }

    function test_93AssetsTwentyVersions_allCashWithdrawalWithinGasCap() public {
        _twentyVersionWithdrawal(true, false);
    }

    function test_93AssetsTwentyVersions_extremeTicksWithdrawalWithinGasCap() public {
        _twentyVersionWithdrawal(false, true);
    }

    function test_navFractionalTicksRoundDownInEverySaleDirection() public {
        asset.mint(account, 10001);
        pool.setCumulatives(0, -900, 30 minutes); // token0: floor(-0.5) = -1
        assertEq(ledger.accountValue(account), 9999);
        pool.setCumulatives(0, 900, 30 minutes); // token0: floor(+0.5) = 0
        assertEq(ledger.accountValue(account), 10001);
        oracle.clearOracle(address(asset));
        pool = new MockPancakeV3Pool(address(cash), address(asset));
        oracle.setOracle(address(asset), address(pool), 30 minutes, 50, 1 hours);
        pool.setCumulatives(0, 900, 30 minutes); // token1: ceil(+0.5) = +1, inverse sale tick -1
        assertEq(ledger.accountValue(account), 9999);
        pool.setCumulatives(0, -900, 30 minutes); // token1: ceil(-0.5) = 0
        assertEq(ledger.accountValue(account), 10001);
    }

    function test_navValidZeroValueAllowsExitAndRecentWindowMustExist() public {
        asset.mint(account, 1);
        cash.mint(account, 10e18);
        pool.setMeanTick(-1, 30 minutes);
        assertEq(ledger.accountValue(account), 10e18);
        assertEq(_withdraw(1e18).value, 10e18);
        assertEq(cash.balanceOf(RECIPIENT), 0.8e18);
        pool.setMeanTick(0, 30 minutes);
        pool.setRecentObserveReverts(true);
        vm.expectRevert(PancakeV3TwapOracle.TwapUnavailable.selector);
        _withdraw(1e18);
        assertEq(cash.balanceOf(account), 9e18);
        assertEq(cash.balanceOf(RECIPIENT), 0.8e18);
    }

    function test_registryHistoryNeedsNoSyncAndExcludesPendingAssets() public {
        LedgerToken future = new LedgerToken();
        future.mint(account, 100e18); // Missing oracle proves any premature inclusion fails closed.
        address[] memory assets = new address[](1);
        assets[0] = address(future);
        uint16[] memory weights = new uint16[](1);
        weights[0] = 10_000;
        _schedule(assets, weights, 2_000, 0);
        assertEq(ledger.accountValue(account), 0);
        vm.warp(registry.version(strategy, 2).activeAt);
        vm.expectRevert(abi.encodeWithSelector(AtpMultiPoolOracle.OracleNotSet.selector, address(future)));
        ledger.accountValue(account);
        _publish(0); // Historical v2 holdings remain included after removal, without re-enrollment.
        vm.expectRevert(abi.encodeWithSelector(AtpMultiPoolOracle.OracleNotSet.selector, address(future)));
        ledger.accountValue(account);
        MockPancakeV3Pool pair = new MockPancakeV3Pool(address(future), address(cash));
        pair.setMeanTick(0, 30 minutes);
        oracle.setOracle(address(future), address(pair), 30 minutes, 50, 1 hours);
        assertEq(ledger.accountValue(account), 100e18);
        assertEq(ledger.accountValue(account), 100e18); // Repeated reads do not duplicate assets.
        assertEq(registry.enrollments(account).version, 1);
        (bool ok,) =
            address(ledger).call(abi.encodeWithSignature("syncAssets(uint256,uint16)", strategy, uint16(3)));
        assertFalse(ok, "obsolete synchronization API must be removed");
    }

    function test_feeOnlyDecreaseAppliesImmediatelyWithoutNewEnrollment() public {
        AtpRegistry.Version memory v = registry.version(strategy, 0);
        cash.mint(account, 100e18);
        assertEq(ledger.previewWithdraw(account, 10e18).fee, 2e18);
        _schedule(v.assets, v.weightsBps, 500, 0);
        assertEq(registry.version(strategy, 2).activeAt, block.timestamp);
        assertEq(registry.activeVersion(strategy), 2);
        assertEq(registry.enrollments(account).version, 1);
        assertEq(_withdraw(10e18).fee, 0.5e18);
    }

    function test_withdrawReportsTheActiveConfigHashAndFee() public {
        ledger.deposit(account, 100e18);
        cash.mint(account, 50e18);
        AtpRegistry.Version memory old = registry.version(strategy, 0);
        _schedule(old.assets, old.weightsBps, 500, 0);
        AtpRegistry.Version memory current = registry.version(strategy, 0);
        Ledger.Withdrawal memory quote = ledger.previewWithdraw(account, 60e18);
        assertEq(quote.performanceFeeBps, 500);
        assertEq(quote.configHash, current.configHash);
        assertTrue(quote.configHash != old.configHash);
        vm.expectEmit(true, true, true, true, address(ledger));
        emit Ledger.Withdrawn(
            account, RECIPIENT, CREATOR, 60e18, 150e18, 20e18, 1e18, 0.1e18, 60e18, 500, current.configHash
        );
        Ledger.Withdrawal memory actual = _withdraw(60e18);
        assertEq(abi.encode(actual), abi.encode(quote));
        assertEq(registry.enrollments(account).version, 1);
    }

    function test_cancelledFeeAndAssetsNeverAffectSettlementAfterOriginalActivation() public {
        LedgerToken cancelledOnly = new LedgerToken();
        cancelledOnly.mint(account, 10e18); // Deliberately no oracle: any accidental inclusion reverts.
        address[] memory assets = new address[](1);
        assets[0] = address(cancelledOnly);
        uint16[] memory weights = new uint16[](1);
        weights[0] = 10_000;
        cash.mint(account, 100e18);
        bytes32 effectiveHash = registry.version(strategy, 0).configHash;
        _schedule(assets, weights, 500, 0);
        uint64 at = registry.version(strategy, 2).activeAt;
        vm.prank(CREATOR);
        registry.cancelVersion(strategy);
        vm.warp(at + 1);
        Ledger.Withdrawal memory quote = ledger.previewWithdraw(account, 10e18);
        assertEq(quote.value, 100e18);
        assertEq(quote.fee, 2e18);
        assertEq(quote.configHash, effectiveHash);
        _publish(0);
        assertEq(_withdraw(10e18).fee, 2e18);
        assertEq(registry.historicalAssets(strategy).length, 2);
    }

    function test_invalidActiveConfigRejectsZeroAndOutOfBoundsFeesWithoutChangingBasis() public {
        ledger.deposit(account, 10e18);
        AtpRegistry.Version memory current = registry.version(strategy, 0);
        uint16[3] memory invalidFees = [uint16(0), uint16(499), uint16(2_001)];
        for (uint256 i; i < invalidFees.length; ++i) {
            current.performanceFeeBps = invalidFees[i];
            vm.mockCall(
                address(registry), abi.encodeCall(registry.version, (strategy, 0)), abi.encode(current)
            );
            vm.expectRevert(Ledger.InvalidFee.selector);
            ledger.deposit(account, 1);
            vm.expectRevert(Ledger.InvalidFee.selector);
            _withdraw(1e18);
            assertEq(_principal(), 10e18);
            assertEq(cash.balanceOf(account), 10e18);
        }
        vm.clearMockedCalls();
        assertEq(_withdraw(10e18).fee, 0);
    }

    function test_activeVersionReadFailureCannotStartOrDepositAndPendingCannotStart() public {
        LedgerAccount other = new LedgerAccount();
        vm.prank(address(other));
        registry.enroll(address(other), strategy, 1);
        vm.mockCallRevert(
            address(registry), abi.encodeCall(registry.version, (strategy, 0)), "registry unavailable"
        );
        vm.prank(address(other));
        vm.expectRevert(bytes("registry unavailable"));
        ledger.start();
        vm.expectRevert(bytes("registry unavailable"));
        ledger.deposit(account, 10e18);
        assertEq(_principal(), 0);
        assertEq(cash.balanceOf(account), 0);
        vm.clearMockedCalls();
        AtpRegistry.Version memory current = registry.version(strategy, 0);
        current.activeAt = uint64(block.timestamp + 1);
        vm.mockCall(address(registry), abi.encodeCall(registry.version, (strategy, 0)), abi.encode(current));
        vm.prank(address(other));
        vm.expectRevert(Ledger.VersionNotActive.selector);
        ledger.start();
        (uint256 p,, uint256 epoch, Ledger.Status status) = ledger.accounts(address(other));
        assertEq(p, 0);
        assertEq(epoch, 0);
        assertEq(uint256(status), uint256(Ledger.Status.NEW));
        vm.clearMockedCalls();
        vm.prank(address(other));
        ledger.start();
    }

    function _dustFixture(bool reverse) internal {
        ledger.deposit(account, 100e18);
        if (reverse) {
            oracle.clearOracle(address(asset));
            pool = new MockPancakeV3Pool(address(cash), address(asset));
            oracle.setOracle(address(asset), address(pool), 30 minutes, 50, 1 hours);
        }
        pool.setMeanTick(reverse ? int24(1) : int24(-1), 30 minutes);
        asset.mint(REPORTER, 1);
        vm.prank(REPORTER);
        asset.transfer(account, 1); // Third-party dust, not a ledger deposit.
    }

    function _validDustExit(bool reverse) internal {
        _dustFixture(reverse);
        (uint256 executionQuote,) = oracle.previewSwap(address(asset), address(cash), 1);
        assertEq(executionQuote, 1);
        Ledger.Withdrawal memory w = _withdraw(100e18);
        assertEq(w.value, 100e18);
        assertEq(w.fee, 0);
        assertEq(w.remainingPrincipal, 0);
        assertEq(cash.balanceOf(RECIPIENT), 100e18);
        assertEq(asset.balanceOf(account), 1);
    }

    function test_validOneWeiDustToken0DoesNotBlockFullExit() public {
        _validDustExit(false);
    }

    function test_validOneWeiDustToken1DoesNotBlockFullExit() public {
        _validDustExit(true);
    }

    // ThirdRound.t.sol reviewer regressions: the execution quote rounds to 1 while the
    // healthy secondary rounds to 0 at the donated amount, in either pool direction.
    function _secondaryDust(bool reverse) internal {
        _dustFixture(reverse);
        MockAggregator price = new MockAggregator(8, 99_990_000);
        MockAggregator stable = new MockAggregator(8, 100_000_000);
        oracle.setSecondary(address(asset), price, stable, 1 hours, 1 hours, 200);
        (uint256 executionQuote,) =
            oracle.oracleOf(address(asset)).previewSwap(address(asset), address(cash), 1);
        assertEq(executionQuote, 1);
    }

    function _secondaryDustExit(bool reverse) internal {
        _secondaryDust(reverse);
        assertEq(ledger.accountValue(account), 100e18);
        vm.prank(account);
        Ledger.Withdrawal memory w = ledger.withdraw(100e18, RECIPIENT, 100e18, block.timestamp);
        assertEq(w.fee, 0);
        assertEq(w.remainingPrincipal, 0);
        assertEq(cash.balanceOf(RECIPIENT), 100e18);
        assertEq(asset.balanceOf(account), 1);
    }

    function test_spec_secondaryDustToken0AllowsFullExit() public {
        _secondaryDustExit(false);
    }

    function test_spec_secondaryDustToken1AllowsFullExit() public {
        _secondaryDustExit(true);
    }

    function testFuzz_secondaryValidationDoesNotDependOnHolding(uint80 seed, bool reverse) public {
        _secondaryDust(reverse);
        uint256 held = bound(uint256(seed), 1, 1e24);
        asset.mint(account, held - 1);
        uint256 expected = 100e18 + held * 10_000 / 10_001;
        uint256 value = ledger.accountValue(account);
        assertLe(value, expected);
        assertLe(expected - value, 1);
        assertEq(_withdraw(50e18).value, value);
    }

    function test_secondaryDeviationBoundaryInclusiveAndOneUnitOutsideReverts() public {
        ledger.deposit(account, 100e18);
        asset.mint(account, 1);
        // At tick 0, (1e18 - price) * 10000 == price * 240 exactly.
        int256 boundaryPrice = 976_562_500_000_000_000;
        MockAggregator price = new MockAggregator(18, boundaryPrice);
        MockAggregator stable = new MockAggregator(18, 1e18);
        oracle.setSecondary(address(asset), price, stable, 1 hours, 1 hours, 240);
        assertEq(ledger.accountValue(account), 100e18 + 1);
        price.set(boundaryPrice - 1, block.timestamp);
        vm.expectRevert(
            abi.encodeWithSelector(
                AtpMultiPoolOracle.SourcesDisagree.selector,
                address(asset),
                uint256(1e18),
                uint256(boundaryPrice - 1)
            )
        );
        _withdraw(100e18);
        assertEq(_principal(), 100e18);
        assertEq(cash.balanceOf(account), 100e18);
        assertEq(cash.balanceOf(RECIPIENT), 0);
        price.set(boundaryPrice, block.timestamp);
        assertEq(_withdraw(100e18).fee, 0);
    }

    function test_secondaryDustStillRejectsStaleInvalidAndFailedFeeds() public {
        _secondaryDust(false);
        (IPriceSource independent,) = oracle.secondaryOf(address(asset));
        PushFeedPriceSource source = PushFeedPriceSource(address(independent));
        MockAggregator price = MockAggregator(address(source.assetFeed()));
        MockAggregator stable = MockAggregator(address(source.numeraireFeed()));
        price.set(99_990_000, block.timestamp - 1 hours - 1);
        vm.expectRevert(
            abi.encodeWithSelector(PushFeedPriceSource.StaleFeed.selector, address(price), price.updatedAt())
        );
        _withdraw(100e18);
        price.set(99_990_000, block.timestamp);
        stable.set(100_000_000, block.timestamp - 1 hours - 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                PushFeedPriceSource.StaleFeed.selector, address(stable), stable.updatedAt()
            )
        );
        _withdraw(100e18);
        stable.set(100_000_000, block.timestamp);
        price.set(0, block.timestamp);
        vm.expectRevert(
            abi.encodeWithSelector(PushFeedPriceSource.InvalidAnswer.selector, address(price), int256(0))
        );
        _withdraw(100e18);
        price.set(99_990_000, block.timestamp);
        vm.mockCallRevert(address(price), abi.encodeCall(price.latestRoundData, ()), "feed unavailable");
        vm.expectRevert(bytes("feed unavailable"));
        _withdraw(100e18);
        assertEq(_principal(), 100e18);
        assertEq(cash.balanceOf(account), 100e18);
        assertEq(cash.balanceOf(RECIPIENT), 0);
        vm.clearMockedCalls();
        assertEq(_withdraw(100e18).fee, 0);
    }

    function test_dustStillRejectsStaleMissingAndFailedSourcesAtomically() public {
        _dustFixture(false);
        pool.setObservationAge(1 hours + 1);
        vm.expectRevert(PancakeV3TwapOracle.TwapUnavailable.selector);
        _withdraw(100e18);
        pool.setObservationAge(0);
        pool.setObserveReverts(true);
        vm.expectRevert(PancakeV3TwapOracle.TwapUnavailable.selector);
        _withdraw(100e18);
        pool.setObserveReverts(false);
        vm.mockCallRevert(
            address(oracle),
            abi.encodeCall(oracle.previewSwap, (address(asset), address(cash), 1e18)),
            "secondary unavailable"
        );
        vm.expectRevert(bytes("secondary unavailable"));
        _withdraw(100e18);
        vm.clearMockedCalls();
        oracle.clearOracle(address(asset));
        vm.expectRevert(abi.encodeWithSelector(AtpMultiPoolOracle.OracleNotSet.selector, address(asset)));
        _withdraw(100e18);
        assertEq(_principal(), 100e18);
        assertEq(cash.balanceOf(account), 100e18);
        assertEq(cash.balanceOf(RECIPIENT), 0);
    }

    function test_pendingVersionOnlyValuedAtExactActivation() public {
        LedgerToken fresh = new LedgerToken();
        MockPancakeV3Pool freshPool = new MockPancakeV3Pool(address(fresh), address(cash));
        freshPool.setMeanTick(0, 30 minutes);
        oracle.setOracle(address(fresh), address(freshPool), 30 minutes, 50, 1 hours);
        address[] memory assets = new address[](1);
        assets[0] = address(fresh);
        uint16[] memory weights = new uint16[](1);
        weights[0] = 10_000;
        _schedule(assets, weights, 500, 0);
        uint64 at = registry.version(strategy, 2).activeAt;
        fresh.mint(account, 10e18);
        ledger.deposit(account, 100e18);
        assertEq(ledger.accountValue(account), 100e18);
        vm.warp(at - 1);
        assertEq(ledger.accountValue(account), 100e18);
        vm.warp(at);
        assertEq(ledger.accountValue(account), 110e18);
        assertEq(_withdraw(55e18).fee, 0.25e18);
        assertEq(registry.enrollments(account).version, 1);
    }

    function test_cancelledVersionNeverValuedAndRegistryReadFailuresRollBack() public {
        LedgerToken fresh = new LedgerToken();
        fresh.mint(account, 10e18); // No oracle: cancelled-only asset must never be read/priced.
        address[] memory assets = new address[](1);
        assets[0] = address(fresh);
        uint16[] memory weights = new uint16[](1);
        weights[0] = 10_000;
        _schedule(assets, weights, 500, 0);
        uint64 cancelledAt = registry.version(strategy, 2).activeAt;
        ledger.deposit(account, 100e18);
        assertEq(ledger.accountValue(account), 100e18);
        vm.prank(CREATOR);
        registry.cancelVersion(strategy);
        vm.warp(cancelledAt);
        assertEq(ledger.accountValue(account), 100e18);
        _publish(0); // v3 effective, v2 number is not reused.
        assertTrue(registry.cancelledVersion(strategy, 2));
        assertEq(registry.activeVersion(strategy), 3);
        assertEq(ledger.accountValue(account), 100e18);
        vm.mockCallRevert(
            address(registry), abi.encodeCall(registry.historicalAssets, (strategy)), "history unavailable"
        );
        vm.expectRevert(bytes("history unavailable"));
        _withdraw(10e18);
        assertEq(_principal(), 100e18);
        assertEq(cash.balanceOf(account), 100e18);
        vm.clearMockedCalls();
        vm.mockCallRevert(
            address(registry), abi.encodeCall(registry.version, (strategy, 0)), "active config unavailable"
        );
        vm.expectRevert(bytes("active config unavailable"));
        _withdraw(10e18);
        assertEq(_principal(), 100e18);
        assertEq(cash.balanceOf(RECIPIENT), 0);
        vm.clearMockedCalls();
        assertEq(_withdraw(100e18).fee, 0);
    }

    function _fractionalTickFeeBound(bool reverse, bool positive) internal {
        uint256 principal = positive ? 100e18 : 99e18;
        uint256 held = 50e18;
        ledger.deposit(account, principal);
        cash.burn(account, principal - held);
        asset.mint(account, held);
        if (reverse) {
            oracle.clearOracle(address(asset));
            pool = new MockPancakeV3Pool(address(cash), address(asset));
            oracle.setOracle(address(asset), address(pool), 30 minutes, 50, 1 hours);
        }
        int56 saleDelta = positive ? int56(900) : int56(-900);
        pool.setCumulatives(0, reverse ? -saleDelta : saleDelta, 30 minutes);
        // Exact integer square root gives floor(held * 1.0001^(+/-0.5)), independently of NAV math.
        uint256 referenceAsset =
            Math.sqrt(held * held * (positive ? 10_001 : 10_000) / (positive ? 10_000 : 10_001));
        uint256 referenceNAV = held + referenceAsset;
        uint256 referenceFee = (held * (referenceNAV - principal) / referenceNAV) / 5;
        uint256 referenceBasis = Math.ceilDiv(principal * (referenceNAV - held), referenceNAV);
        Ledger.Withdrawal memory first = _withdraw(held);
        // Less than one sale tick (1/10001 of true asset value), plus <1 wei fixed-point error
        // and <1 wei amount rounding for these n=-1/0 vectors. This is NOT a <=1 wei fee promise.
        uint256 navErrorBound = Math.ceilDiv(referenceAsset, 10_001) + 2;
        assertLe(first.value, referenceNAV, "NAV must never round up");
        assertLe(referenceNAV - first.value, navErrorBound);
        uint256 basisErrorBound =
            Math.mulDiv(principal * held, navErrorBound, referenceNAV * first.value, Math.Rounding.Ceil);
        assertLe(first.fee, referenceFee, "same-state fee may only undercharge");
        assertLe(referenceFee - first.fee, Math.ceilDiv(basisErrorBound, 5) + 2);
        assertLe(first.remainingPrincipal, referenceBasis);
        assertLe(referenceBasis - first.remainingPrincipal, basisErrorBound + 1);
        emit log_named_uint("FRACTIONAL_FIRST_FEE_SHORTFALL", referenceFee - first.fee);
        emit log_named_uint("FRACTIONAL_BASIS_SHORTFALL", referenceBasis - first.remainingPrincipal);
        // Honest liquidation can move the deferred fee into the next withdrawal. Check the whole exit,
        // not a misleading <=1 wei bound on that second fee considered in isolation.
        asset.burn(account, held);
        cash.mint(account, referenceAsset);
        Ledger.Withdrawal memory second = _withdraw(referenceAsset);
        uint256 referenceSecondFee = (referenceAsset - referenceBasis) / 5;
        assertLe(first.fee + second.fee, referenceFee + referenceSecondFee);
        assertLe(first.fee + second.fee, (referenceNAV - principal) / 5);
        assertEq(_principal(), 0);
    }

    function test_fractionalFeeBoundToken0PositiveMean() public {
        _fractionalTickFeeBound(false, true);
    }

    function test_fractionalFeeBoundToken0NegativeMean() public {
        _fractionalTickFeeBound(false, false);
    }

    function test_fractionalFeeBoundToken1PositiveMean() public {
        _fractionalTickFeeBound(true, false);
    }

    function test_fractionalFeeBoundToken1NegativeMean() public {
        _fractionalTickFeeBound(true, true);
    }

    function test_platformShareAffectsOnlyFuturePayments() public {
        cash.mint(account, 100e18);
        assertEq(_withdraw(10e18).platformFee, 0.2e18);
        ledger.schedulePlatformShare(2_000);
        uint256 at = ledger.platformShareActiveAt();
        assertEq(at, block.timestamp + 7 days);
        vm.warp(at - 1);
        assertEq(_withdraw(10e18).platformFee, 0.2e18);
        vm.warp(at);
        assertEq(_withdraw(10e18).platformFee, 0.4e18);
        assertEq(cash.balanceOf(PLATFORM), 0.8e18);
        assertEq(cash.balanceOf(CREATOR), 5.2e18);
        assertEq(cash.balanceOf(RECIPIENT), 24e18);
    }

    function testFuzz_navPriceNeverExceedsExactRational(uint96 amountSeed, int8 tickSeed) public pure {
        uint256 amount = bound(uint256(amountSeed), 1, 1e24);
        int56 tick = int56(bound(int256(tickSeed), -12, 12));
        uint256 exponent = uint256(uint56(tick < 0 ? -tick : tick));
        uint256 numerator = (tick < 0 ? uint256(10_000) : uint256(10_001)) ** exponent;
        uint256 denominator = (tick < 0 ? uint256(10_001) : uint256(10_000)) ** exponent;
        uint256 exact = amount * numerator / denominator;
        uint256 nav = PerfFeeNavMath.quote(amount, tick);
        assertLe(nav, exact);
        assertLe(exact - nav, 1);
    }

    function _navReference(int56 tick, uint256 amount, uint256 exact) internal pure {
        uint256 nav = PerfFeeNavMath.quote(amount, tick);
        assertLe(nav, exact);
        assertLe(exact - nav, 1 + exact / 1e18);
        // The documented universal fixed-point error bound, independent of the exponentiation code.
        uint256 n = uint256(uint56(tick < 0 ? -tick : tick));
        if (n == 0) {
            assertEq(nav, exact);
        } else {
            uint256 unit = tick < 0 ? 1 << 192 : 1 << 128;
            uint256 errorBound =
                Math.mulDiv(tick < 0 ? amount : exact + 1, 2 * n - 1, unit, Math.Rounding.Ceil) + 1;
            assertLe(exact - nav, errorBound);
        }
    }

    function test_navPricePrecisionAtTickAndDecimalBoundaries() public pure {
        // Independently computed with 200-digit decimal rational exponentiation.
        _navReference(-887_272, 1e60, 2_938_956_807_585_584_838_874);
        _navReference(
            887_272, 1e18, 340_256_786_836_388_094_050_805_785_052_946_541_066_751_507_546_701_582_068
        );
        _navReference(-443_636, 1e40, 542_121_463_104_495_138_644);
        _navReference(443_636, 1e18, 18_446_050_711_097_703_529_776_342_895_396_472_065);
        _navReference(-276_324, 1000e18, 1_000_002_643); // Raw 18 -> 6 ratio; no second decimal scaling.
        _navReference(276_324, 1000e6, 999_997_356_176_039_153_113);
        _navReference(-1, 10001, 10000);
        _navReference(1, 10000, 10001);
        assertEq(PerfFeeNavMath.quote(1, 0), 1);
        assertEq(PerfFeeNavMath.quote(0, 887_272), 0);
        assertEq(PerfFeeNavMath.quote(1, -887_272), 0);
    }

    function test_tokenCallbacksCannotReenterDepositWithdrawOrStop() public {
        cash.arm(address(ledger), abi.encodeCall(ledger.deposit, (account, 1)));
        ledger.deposit(account, 10e18);
        assertTrue(cash.callbackBlocked());
        cash.arm(address(ledger), abi.encodeCall(ledger.withdraw, (1, RECIPIENT, 0, block.timestamp)));
        _withdraw(1e18);
        assertTrue(cash.callbackBlocked());
        ledger.setReporter(address(cash), true);
        cash.arm(address(ledger), abi.encodeCall(ledger.stopService, (account, 1, bytes32(0))));
        _withdraw(1e18);
        assertTrue(cash.callbackBlocked());
        assertEq(_principal(), 8e18);
    }

    function test_constructorRejectsMissingContractsAndMismatchedPins() public {
        vm.expectRevert(Ledger.InvalidConfig.selector);
        new Ledger(AtpRegistry(address(0)), oracle, yields, PLATFORM);
        vm.expectRevert(Ledger.InvalidConfig.selector);
        new Ledger(registry, AtpMultiPoolOracle(address(0)), yields, PLATFORM);
        vm.expectRevert(Ledger.InvalidConfig.selector);
        new Ledger(registry, oracle, AtpYieldRegistry(address(0)), PLATFORM);
        vm.expectRevert(Ledger.InvalidConfig.selector);
        new Ledger(registry, oracle, yields, address(0));
        AtpMultiPoolOracle other = new AtpMultiPoolOracle(address(asset));
        vm.expectRevert(Ledger.InvalidConfig.selector);
        new Ledger(registry, other, yields, PLATFORM);
        AtpYieldRegistry foreign = new AtpYieldRegistry(new AtpRegistry(), address(this));
        vm.expectRevert(Ledger.InvalidConfig.selector);
        new Ledger(registry, oracle, foreign, PLATFORM);
    }
}
