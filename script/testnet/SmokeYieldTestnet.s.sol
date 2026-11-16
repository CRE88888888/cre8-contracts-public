// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Script, console } from "forge-std/Script.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { AtpExecutor } from "../../src/atp/AtpExecutor.sol";
import { AtpRegistry } from "../../src/atp/AtpRegistry.sol";
import { AtpYieldRegistry } from "../../src/atp/yield/AtpYieldRegistry.sol";
import { YieldTypes as Y } from "../../src/atp/yield/YieldTypes.sol";
import { TestnetToken } from "../../src/testnet/TestnetToken.sol";
import { MockVenus } from "../../src/testnet/yield/MockVenus.sol";
import { MockLista } from "../../src/testnet/yield/MockLista.sol";
import { MockAavePool } from "../../src/testnet/yield/MockAavePool.sol";
import { TestnetYieldBook as B } from "./TestnetYieldBook.sol";
import { TestnetBook } from "./TestnetBook.sol";

/// @dev Local acceptance account. Owner signs every action; quotes and execution share the same block.
/// This avoids claiming that a quote sampled in an earlier block is an executable, accrued Venus quote.
contract YieldSmokeAccount {
    address public immutable owner;

    constructor(address owner_) {
        owner = owner_;
    }
    modifier onlyOwner() {
        require(msg.sender == owner, "smoke owner only");
        _;
    }

    function prepare(AtpExecutor executor, uint256 strategy, bytes32 id, uint256 amount) external onlyOwner {
        AtpYieldRegistry yields = executor.yieldRegistry();
        Y.Market memory m = yields.market(id);
        executor.registry().enroll(address(this), strategy);
        yields.setYieldPolicy(id, amount, true);
        IERC20(m.asset).approve(address(executor), amount);
        IERC20(m.receipt).approve(address(executor), type(uint256).max);
    }

    function supply(AtpExecutor executor, bytes32 id, uint256 amount) external onlyOwner {
        uint256 minimum = executor.yieldRegistry().quoteSupply(id, address(this), amount);
        executor.executeSupply(address(this), id, amount, minimum, block.timestamp);
    }

    function withdrawAll(AtpExecutor executor, bytes32 id) external onlyOwner {
        Y.Market memory m = executor.yieldRegistry().market(id);
        _withdraw(executor, id, IERC20(m.receipt).balanceOf(address(this)));
    }

    function withdraw(AtpExecutor executor, bytes32 id, uint256 shares) external onlyOwner {
        _withdraw(executor, id, shares);
    }

    function _withdraw(AtpExecutor executor, bytes32 id, uint256 shares) private {
        uint256 minimum = executor.yieldRegistry().quoteWithdraw(id, shares);
        executor.executeWithdraw(address(this), id, shares, minimum, block.timestamp);
    }
}

/// @notice LOCAL ANVIL chain 97 acceptance, invoked by fork-e2e.sh: all table rows, supply -> one simulated
/// year -> >=90% utilization -> partial redemption -> liquidity restored -> retry -> zero receipts.
/// The shell checks anvil_nodeInfo. Never run against a public chain (no real signer keys are loaded here).
contract SmokeYieldTestnet is Script {
    uint256 txIndex;

    function run() external {
        require(block.chainid == 97, "yield smoke: chain 97 only");
        AtpExecutor executor = AtpExecutor(vm.envAddress("TESTNET_EXECUTOR"));
        AtpYieldRegistry yields = executor.yieldRegistry();
        address smokeOwner = vm.envAddress("YIELD_SMOKE_OWNER");
        B.Spec[] memory specs = B.specs();
        string memory phase = vm.envString("TESTNET_YIELD_PHASE");
        bool supplyPhase = keccak256(bytes(phase)) == keccak256("supply");
        require(supplyPhase || keccak256(bytes(phase)) == keccak256("exit"), "unknown yield smoke phase");
        uint256 strategy =
            supplyPhase ? _strategy(executor.registry(), specs, executor.numeraire(), smokeOwner) : 0;
        for (uint256 i; i < specs.length; ++i) {
            (address asset, uint256 seed) = B.asset(specs[i], executor.numeraire());
            bytes32 id = B.id(specs[i], asset);
            Y.Market memory m = yields.market(id);
            YieldSmokeAccount account = _account(i, smokeOwner, supplyPhase);
            if (supplyPhase) {
                uint256 amount = seed / 10_000; // 100 USDT of this asset at the deployment baseline.
                TestnetToken token = TestnetToken(asset);
                vm.startBroadcast(TestnetBook.OWNER);
                bool wasMinter = token.isMinter(TestnetBook.OWNER);
                if (!wasMinter) {
                    token.setMinter(TestnetBook.OWNER, true);
                    ++txIndex;
                }
                token.mint(address(account), amount);
                ++txIndex;
                if (!wasMinter) {
                    token.setMinter(TestnetBook.OWNER, false);
                    ++txIndex;
                }
                vm.stopBroadcast();
                vm.startBroadcast(smokeOwner);
                account.prepare(executor, strategy, id, amount);
                ++txIndex;
                account.supply(executor, id, amount);
                _mark("supply", specs[i]);
                vm.stopBroadcast();
                require(IERC20(m.receipt).balanceOf(address(account)) > 0, "supply receipt absent");
                require(IERC20(asset).allowance(address(executor), m.target) == 0, "market allowance left");
            } else {
                uint256 before = IERC20(m.receipt).balanceOf(address(account));
                require(before > 1, "no supplied receipt");
                uint256 partShares = before / 2;
                uint256 minAssets = yields.quoteWithdraw(id, partShares);
                uint256 liquid = minAssets + minAssets / 2 + 1;
                require(liquid < yields.quoteWithdraw(id, before), "full claim must remain illiquid");
                vm.startBroadcast(TestnetBook.OWNER);
                // Leave ~3/4 of this account's claim liquid, redeem an explicit half. The full
                // claim is unavailable; the quarter headroom covers normal mining-time accrual.
                // No caller minimum is discounted, and the same-block quote still binds output.
                _liquidity(m, liquid);
                ++txIndex;
                vm.stopBroadcast();
                vm.startBroadcast(smokeOwner);
                yields.markRiskExit(address(account), id);
                ++txIndex;
                account.withdraw(executor, id, partShares);
                _mark("partial", specs[i]);
                vm.stopBroadcast();
                require(yields.exiting(address(account), id), "partial exit lost its retry state");
                require(
                    IERC20(m.receipt).balanceOf(address(account)) > 0,
                    "partial exit incorrectly cleared all receipts"
                );
                vm.startBroadcast(TestnetBook.OWNER);
                _restore(m);
                ++txIndex;
                vm.stopBroadcast();
                vm.startBroadcast(smokeOwner);
                account.withdrawAll(executor, id);
                _mark("retry", specs[i]);
                vm.stopBroadcast();
                require(
                    IERC20(m.receipt).balanceOf(address(account)) == 0, "receipt remains after full retry"
                );
                require(
                    yields.totalUnits(id) == 0 && !yields.exiting(address(account), id),
                    "exposure remains after full retry"
                );
                require(IERC20(asset).balanceOf(address(account)) > 0, "exit underlying absent");
            }
        }
        console.log("YIELD_SMOKE completed", phase, specs.length);
    }

    function _liquidity(Y.Market memory m, uint256 amount) private {
        if (m.kind == Y.Kind.VENUS) MockVenus(m.target).setLiquidity(amount);
        else if (m.kind == Y.Kind.LISTA) MockLista(m.target).setLiquidity(amount);
        else MockAavePool(m.target).setLiquidity(amount);
    }

    function _restore(Y.Market memory m) private {
        // Simulated borrow is parked inside the mock; restoring it requires no token movement/approval.
        TestnetToken token = TestnetToken(m.asset);
        uint256 backing = token.balanceOf(m.kind == Y.Kind.AAVE ? m.receipt : m.target);
        _liquidity(m, backing);
    }

    function _account(uint256 i, address owner, bool deploy) private returns (YieldSmokeAccount account) {
        string memory label = string.concat("yield.smoke.", vm.toString(i));
        bytes memory code = abi.encodePacked(type(YieldSmokeAccount).creationCode, abi.encode(owner));
        address predicted = TestnetBook.create2Address(label, code);
        if (predicted.code.length == 0) {
            require(deploy, "yield smoke account missing");
            vm.startBroadcast(owner);
            (bool ok,) = CREATE2_FACTORY.call(abi.encodePacked(TestnetBook.salt(label), code));
            ++txIndex;
            require(ok && predicted.code.length != 0, "smoke account deployment failed");
            vm.stopBroadcast();
        }
        return YieldSmokeAccount(predicted);
    }

    function _strategy(AtpRegistry registry, B.Spec[] memory specs, address usdt, address owner)
        private
        returns (uint256 id)
    {
        address[] memory assets = new address[](21);
        uint256 count;
        for (uint256 i; i < specs.length; ++i) {
            (address token,) = B.asset(specs[i], usdt);
            bool seen;
            for (uint256 j; j < count; ++j) {
                if (assets[j] == token) seen = true;
            }
            if (!seen) assets[count++] = token;
        }
        require(count == assets.length, "yield asset count");
        uint16[] memory weights = new uint16[](count);
        for (uint256 i; i < count; ++i) {
            weights[i] = uint16(10_000 / count);
        }
        weights[0] += uint16(10_000 - count * (10_000 / count));
        vm.startBroadcast(owner);
        id = registry.registerStrategy("Yield compatibility", "Local mock APR and exit acceptance", true);
        ++txIndex;
        registry.publishVersion(id, assets, weights, keccak256("yield smoke"), 0);
        ++txIndex;
        vm.stopBroadcast();
    }

    function _mark(string memory phase, B.Spec memory spec) private {
        console.log(
            string.concat(
                "YIELD_TX ", phase, ".", B.protocol(spec.kind), ".", spec.symbol, " ", vm.toString(txIndex)
            )
        );
        ++txIndex;
    }
}
