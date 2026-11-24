// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";
import { DeployBorrowRoutingMainnet } from "../../script/DeployBorrowRoutingMainnet.s.sol";

/// @notice Third review L-2: `DeployBorrowRoutingMainnet.verify` needs ATP_EXECUTOR, and it must be the core
/// recorded in `deployments/mainnet.json`; nothing is read back from the contracts being verified. The rest
/// of `verify` runs on a mainnet fork (test/atp/fork/BorrowRoutingMainnetScriptFork.t.sol).
contract DeployBorrowRoutingMainnetChecksTest is Test {
    /// One test on purpose: it is the only one that sets ATP_EXECUTOR, and environment variables are shared
    /// by every test of a run.
    function test_verify_requiresAtpExecutor_andHoldsItAgainstTheManifest() public {
        DeployBorrowRoutingMainnet script = new DeployBorrowRoutingMainnet();
        string memory json = vm.readFile(string.concat(vm.projectRoot(), "/deployments/mainnet.json"));
        address manifestExecutor = vm.parseJsonAddress(json, ".contracts.AtpExecutor");
        address manifestRegistry = vm.parseJsonAddress(json, ".contracts.AtpRegistry");
        vm.chainId(56);
        vm.mockCall(manifestExecutor, abi.encodeWithSignature("registry()"), abi.encode(manifestRegistry));
        // The routing executor under verification: every read from it returns nothing useful, so each
        // revert below comes from the anchor, before `verify` looks at the routing contracts at all.
        address routing = address(0x5EED);
        vm.mockCall(routing, abi.encodeWithSignature("borrowRegistry()"), abi.encode(address(0)));
        vm.mockCall(routing, abi.encodeWithSignature("lens()"), abi.encode(address(0)));

        // No ATP_EXECUTOR.
        vm.setEnv("ATP_EXECUTOR", "");
        vm.expectRevert();
        script.verify(routing);

        // Another executor, even one that reports the recorded registry.
        address other = address(0xC0FE);
        vm.mockCall(other, abi.encodeWithSignature("registry()"), abi.encode(manifestRegistry));
        vm.setEnv("ATP_EXECUTOR", vm.toString(other));
        vm.expectRevert(bytes("ATP_EXECUTOR is not the AtpExecutor in deployments/mainnet.json"));
        script.verify(routing);

        // The recorded executor pointing at another registry.
        vm.setEnv("ATP_EXECUTOR", vm.toString(manifestExecutor));
        vm.mockCall(manifestExecutor, abi.encodeWithSignature("registry()"), abi.encode(address(0xBAD)));
        vm.expectRevert(bytes("ATP_EXECUTOR.registry() is not the AtpRegistry in deployments/mainnet.json"));
        script.verify(routing);
        vm.mockCall(manifestExecutor, abi.encodeWithSignature("registry()"), abi.encode(manifestRegistry));

        // The manifest is chain 56's.
        vm.chainId(97);
        vm.expectRevert(bytes("deployments/mainnet.json: other chain"));
        script.verify(routing);
        vm.chainId(56);

        // With the recorded core the anchor passes and verification goes on to the routing contracts.
        vm.expectRevert(bytes("missing code"));
        script.verify(routing);
        vm.setEnv("ATP_EXECUTOR", "");
    }
}
