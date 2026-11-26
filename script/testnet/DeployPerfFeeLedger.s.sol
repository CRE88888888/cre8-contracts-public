// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Script, console } from "forge-std/Script.sol";
import { AtpPerfFeeLedger } from "../../src/atp/AtpPerfFeeLedger.sol";
import { AtpRegistry } from "../../src/atp/AtpRegistry.sol";
import { AtpMultiPoolOracle } from "../../src/atp/AtpMultiPoolOracle.sol";
import { AtpYieldRegistry } from "../../src/atp/yield/AtpYieldRegistry.sol";
import { TestnetBook as B } from "./TestnetBook.sol";

interface IPerfFeeExecutorPins {
    function registry() external view returns (AtpRegistry);
    function oracle() external view returns (AtpMultiPoolOracle);
    function yieldRegistry() external view returns (AtpYieldRegistry);
    function numeraire() external view returns (address);
}

/// @notice Optional, independent chain-97 deployment AFTER the core. Reads no key files or secrets.
/// Requires the P11 registry policy; no core reconfiguration, reporters or balances are changed.
contract DeployPerfFeeLedger is Script {
    function predicted(address executor, address recipient) public view returns (address expected) {
        bytes memory initCode = _initCode(executor, recipient);
        expected = B.create2Address("perfFeeLedger.v1", initCode);
    }

    function run() external returns (AtpPerfFeeLedger ledger) {
        require(block.chainid == 97, "perf ledger: chain 97 only");
        address executor = vm.envAddress("PERF_LEDGER_EXECUTOR");
        address recipient = vm.envOr("PERF_LEDGER_PLATFORM_RECIPIENT", B.FEE_RECIPIENT);
        ledger = deploy(executor, recipient);
        console.log("PERF_FEE_LEDGER", address(ledger));
        console.log("PERF_FEE_REGISTRY", address(ledger.registry()));
        console.log("PERF_FEE_ORACLE", address(ledger.oracle()));
        console.log("PERF_FEE_YIELD_REGISTRY", address(ledger.yieldRegistry()));
        console.log("PERF_FEE_NUMERAIRE", address(ledger.numeraire()));
        console.log("PERF_FEE_PLATFORM_RECIPIENT", ledger.platformRecipient());
        console.log("PERF_FEE_REGISTRY_VERSION_DELAY_SECONDS", ledger.registry().VERSION_DELAY());
        console.log(
            "PERF_FEE_REGISTRY_PUBLICATION_INTERVAL_SECONDS", ledger.registry().PUBLICATION_INTERVAL()
        );
        console.log("PERF_FEE_MAX_STRATEGY_ASSETS", ledger.registry().MAX_STRATEGY_ASSETS());
        console.log("PERF_FEE_MIN_CREATOR_FEE_BPS", ledger.MIN_CREATOR_FEE_BPS());
        console.log("PERF_FEE_MAX_CREATOR_FEE_BPS", ledger.MAX_CREATOR_FEE_BPS());
    }

    function deploy(address executor, address recipient) public returns (AtpPerfFeeLedger ledger) {
        require(block.chainid == 97, "perf ledger: chain 97 only");
        bytes memory initCode = _initCode(executor, recipient);
        address expected = B.create2Address("perfFeeLedger.v1", initCode);
        if (expected.code.length == 0) {
            require(B.CREATE2_FACTORY.code.length != 0, "perf ledger: factory missing");
            vm.startBroadcast(B.DEPLOYER);
            (bool ok, bytes memory result) =
                B.CREATE2_FACTORY.call(abi.encodePacked(B.salt("perfFeeLedger.v1"), initCode));
            vm.stopBroadcast();
            require(ok && result.length == 20, "perf ledger: CREATE2 failed");
            require(address(bytes20(result)) == expected, "perf ledger: address mismatch");
        }
        ledger = AtpPerfFeeLedger(expected);
        IPerfFeeExecutorPins core = IPerfFeeExecutorPins(executor);
        require(address(ledger.registry()) == address(core.registry()), "perf ledger: registry mismatch");
        require(address(ledger.oracle()) == address(core.oracle()), "perf ledger: oracle mismatch");
        require(
            address(ledger.yieldRegistry()) == address(core.yieldRegistry()), "perf ledger: yield mismatch"
        );
        require(address(ledger.numeraire()) == core.numeraire(), "perf ledger: numeraire mismatch");
        require(ledger.platformRecipient() == recipient, "perf ledger: recipient mismatch");
    }

    function _initCode(address executor, address recipient) private view returns (bytes memory) {
        require(executor.code.length != 0, "perf ledger: executor missing");
        require(recipient != address(0), "perf ledger: zero recipient");
        IPerfFeeExecutorPins core = IPerfFeeExecutorPins(executor);
        AtpRegistry registry = core.registry();
        require(
            registry.VERSION_DELAY() == 1 days && registry.PUBLICATION_INTERVAL() == 7 days
                && registry.MIN_PERFORMANCE_FEE_BPS() == 500 && registry.MAX_PERFORMANCE_FEE_BPS() == 2_000
                && registry.MAX_STRATEGY_ASSETS() == 128,
            "perf ledger: incompatible registry policy"
        );
        AtpMultiPoolOracle oracle = core.oracle();
        AtpYieldRegistry yields = core.yieldRegistry();
        require(address(yields.executor()) == executor, "perf ledger: foreign yield executor");
        require(address(yields.registry()) == address(registry), "perf ledger: foreign yield registry");
        require(core.numeraire() == registry.numeraire(), "perf ledger: foreign numeraire");
        return abi.encodePacked(
            type(AtpPerfFeeLedger).creationCode, abi.encode(registry, oracle, yields, recipient)
        );
    }
}
