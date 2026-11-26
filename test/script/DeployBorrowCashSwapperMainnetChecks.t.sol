// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";
import { DeployBorrowCashSwapperMainnet } from "../../script/DeployBorrowCashSwapperMainnet.s.sol";

/// @notice Fourth review L-A: `DeployBorrowCashSwapperMainnet.verify` takes the routing executor from
/// `deployments/mainnet.json` (`borrowV2.executor`), never from the environment or from the swapper under
/// verification. The rest of `verify` runs on a mainnet fork (test/atp/fork/BorrowCashSwapperFork.t.sol).
contract DeployBorrowCashSwapperMainnetChecksTest is Test {
    string internal constant NO_EXECUTOR =
        "deployments/mainnet.json has no borrowV2.executor: record the verified routing v2 executor first";

    /// One test on purpose: it sets ROUTING_EXECUTOR, and environment variables are shared by every test
    /// of a run.
    function test_verify_takesTheRoutingExecutorFromTheManifestOnly() public {
        DeployBorrowCashSwapperMainnet script = new DeployBorrowCashSwapperMainnet();
        string memory json = vm.readFile(string.concat(vm.projectRoot(), "/deployments/mainnet.json"));
        address swapper = address(0x5EED);

        // The manifest is chain 56's.
        vm.chainId(97);
        vm.expectRevert(bytes("deployments/mainnet.json: other chain"));
        script.verify(swapper);
        vm.chainId(56);

        // An executor named in the environment (a stand-in stack that points at the real core registry
        // would have passed before) is not an anchor.
        vm.setEnv("ROUTING_EXECUTOR", vm.toString(address(0xE0E0)));
        if (vm.keyExistsJson(json, ".borrowV2.executor")) {
            // Routing v2 is recorded: verification goes on to the contracts, and stops at the swapper, which
            // is not one.
            vm.expectRevert();
            script.verify(swapper);
        } else {
            // Not on mainnet yet: there is nothing to verify a swapper against.
            vm.expectRevert(bytes(NO_EXECUTOR));
            script.verify(swapper);
            vm.setEnv("ROUTING_EXECUTOR", "");
            vm.expectRevert(bytes(NO_EXECUTOR));
            script.verify(swapper);
        }
        vm.setEnv("ROUTING_EXECUTOR", "");
    }
}
