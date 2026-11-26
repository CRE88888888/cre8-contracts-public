// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { console } from "forge-std/Script.sol";
import { AtpExecutor } from "../../src/atp/AtpExecutor.sol";
import { YieldTypes as Y } from "../../src/atp/yield/YieldTypes.sol";
import { YieldView } from "../../src/atp/yield/YieldView.sol";
import { DeployTestnet } from "../DeployTestnet.s.sol";
import { TestnetBook } from "./TestnetBook.sol";
import { TestnetYieldBook as YieldBook } from "./TestnetYieldBook.sol";

/// @title DeployExecutorTestnet
/// @notice Chain 97 only (cre8-contracts#76): deploy a new `AtpExecutor` next to the running testnet and admit the 30
/// Cash Earn yield markets into the `AtpYieldRegistry` it creates, without touching anything else.
/// @dev `DeployTestnet.run()` cannot simply be rerun once the price keeper has moved the pools: it refuses every pool
/// more than 1% off its spec price (cre8-contracts#47). This entry point runs only `_core()` (every other core contract
/// already exists, so the executor is the one CREATE2 that sends a transaction) and the yield-market phase, then checks
/// the executor's wiring. Markets are the same contracts as before (same CREATE2 addresses); each gets the same market
/// id and is registered with the bounds `_yieldMarket` computes. The Strategy Earn vault (cre8-contracts#64) is not
/// admitted: it belongs to `AtpBorrowExecutor`, which stays bound to the previous executor.
///
/// Run from a clean checkout of origin/main (addresses depend on every source file's hash), with the YieldView library
/// pinned and both keys in the environment only:
///   DAPP_LIBRARIES=src/atp/yield/YieldView.sol:YieldView:<manifest yieldView> TESTNET_DEPLOYER_KEY=… TESTNET_OWNER_KEY=…
///   TESTNET_YIELD_MARKETS_PER_RUN=30 forge script script/testnet/DeployExecutorTestnet.s.sol \
///     --sig "executorOnly()" --rpc-url <97> --broadcast --slow --sender <DEPLOYER>
contract DeployExecutorTestnet is DeployTestnet {
    function executorOnly() external {
        require(block.chainid == 97, "DeployExecutorTestnet: BSC testnet (97) only");
        _verifyYieldView(address(YieldView));
        rememberKey("TESTNET_DEPLOYER_KEY", TestnetBook.DEPLOYER);
        rememberKey("TESTNET_OWNER_KEY", TestnetBook.OWNER);

        vm.startBroadcast(TestnetBook.DEPLOYER);
        Core memory core = _core();
        vm.stopBroadcast();

        uint256 pending = _yieldMarkets(core);
        if (pending != 0) {
            console.log("PENDING_YIELD_MARKETS", pending);
            return;
        }

        require(address(core.executor.registry()) == address(core.registry), "executor registry");
        require(address(core.executor.oracle()) == address(core.router), "executor oracle");
        require(address(core.executor.universalRouter()) == V3_UNIVERSAL_ROUTER, "executor UR");
        require(address(core.executor.permit2()) == PERMIT2, "executor permit2");
        require(core.executor.numeraire() == address(core.usdt), "executor numeraire");
        require(core.executor.feeRecipient() == TestnetBook.FEE_RECIPIENT, "executor fee recipient");
        require(core.executor.maxBuyBps() == MAX_BUY_BPS && !core.executor.globalPaused(), "executor guards");
        require(core.executor.minBatchFee() == MIN_BATCH_FEE, "executor minBatchFee");
        require(core.executor.GROSS_BUY_MULTIPLE() == 2, "executor gross buy multiple");
        (AtpExecutor.VenueKind kind,) = core.executor.venues(V3_UNIVERSAL_ROUTER);
        require(kind == AtpExecutor.VenueKind.PANCAKE_UR, "UR venue");
        require(
            address(core.executor.yieldRegistry()) == address(core.yields)
                && core.yields.marketCount() == YieldBook.COUNT
                && core.yields.reader() == expectedYieldView(),
            "yield registry pins"
        );
        YieldBook.Spec[] memory specs = YieldBook.specs();
        for (uint256 i; i < specs.length; ++i) {
            (address asset,) = YieldBook.asset(specs[i], address(core.usdt));
            Y.Market memory m = core.yields.market(YieldBook.id(specs[i], asset));
            require(m.supplyEnabled && !m.retired && m.asset == asset, "yield market");
        }

        console.log("");
        console.log("MANIFEST executor", address(core.executor));
        console.log("MANIFEST yieldRegistry", address(core.yields));
        _reportYield(core);
    }
}
