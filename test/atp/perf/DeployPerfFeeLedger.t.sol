// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";
import { DeployPerfFeeLedger } from "../../../script/testnet/DeployPerfFeeLedger.s.sol";
import { TestnetBook as B } from "../../../script/testnet/TestnetBook.sol";
import { AtpPerfFeeLedger as Ledger } from "../../../src/atp/AtpPerfFeeLedger.sol";
import { AtpRegistry } from "../../../src/atp/AtpRegistry.sol";
import { AtpMultiPoolOracle } from "../../../src/atp/AtpMultiPoolOracle.sol";
import { AtpYieldRegistry } from "../../../src/atp/yield/AtpYieldRegistry.sol";
import { LedgerToken } from "./AtpPerfFeeLedger.t.sol";

contract PerfLedgerFactory {
    fallback() external {
        assembly {
            let salt := calldataload(0)
            calldatacopy(0, 32, sub(calldatasize(), 32))
            let deployed := create2(0, 0, sub(calldatasize(), 32), salt)
            if iszero(deployed) { revert(0, 0) }
            mstore(0, deployed)
            return(12, 20)
        }
    }
}

contract PerfLedgerCorePins {
    AtpRegistry public immutable registry;
    AtpMultiPoolOracle public immutable oracle;
    AtpYieldRegistry public immutable yieldRegistry;
    address public immutable numeraire;

    constructor() {
        registry = new AtpRegistry();
        numeraire = address(new LedgerToken());
        registry.setNumeraire(numeraire);
        oracle = new AtpMultiPoolOracle(numeraire);
        yieldRegistry = new AtpYieldRegistry(registry, address(this));
    }
}

contract DeployPerfFeeLedgerTest is Test {
    DeployPerfFeeLedger internal script;
    PerfLedgerCorePins internal core;
    address internal constant TREASURY = address(0xFEE);

    function setUp() public {
        vm.chainId(97);
        script = new DeployPerfFeeLedger();
        core = new PerfLedgerCorePins();
        vm.etch(B.CREATE2_FACTORY, address(new PerfLedgerFactory()).code);
        vm.deal(B.DEPLOYER, 1 ether);
    }

    function test_deployAndRerun_preserveCoreAndVerifyAllPins() public {
        address predicted = script.predicted(address(core), TREASURY);
        Ledger ledger = script.deploy(address(core), TREASURY);
        assertEq(address(ledger), predicted);
        assertEq(address(ledger.registry()), address(core.registry()));
        assertEq(address(ledger.oracle()), address(core.oracle()));
        assertEq(address(ledger.yieldRegistry()), address(core.yieldRegistry()));
        assertEq(address(ledger.numeraire()), core.numeraire());
        assertEq(ledger.platformRecipient(), TREASURY);
        assertEq(ledger.platformShareBps(), 1_000);
        assertEq(ledger.MAX_PLATFORM_SHARE_BPS(), 2_000);
        assertEq(ledger.PLATFORM_NOTICE(), 7 days);
        assertEq(ledger.registry().VERSION_DELAY(), 1 days);
        assertEq(ledger.registry().PUBLICATION_INTERVAL(), 7 days);
        assertEq(ledger.registry().MAX_STRATEGY_ASSETS(), 128);
        assertEq(ledger.MIN_CREATOR_FEE_BPS(), 500);
        assertEq(ledger.MAX_CREATOR_FEE_BPS(), 2_000);
        uint64 nonce = vm.getNonce(B.DEPLOYER);
        assertEq(address(script.deploy(address(core), TREASURY)), predicted);
        assertEq(vm.getNonce(B.DEPLOYER), nonce);
        assertEq(core.yieldRegistry().marketCount(), 0);
        assertEq(core.registry().numeraire(), core.numeraire());
        assertFalse(ledger.reporters(B.DEPLOYER));
    }

    function test_runReadsOnlyPublicConfiguration() public {
        vm.setEnv("PERF_LEDGER_EXECUTOR", vm.toString(address(core)));
        vm.setEnv("PERF_LEDGER_PLATFORM_RECIPIENT", vm.toString(TREASURY));
        assertEq(address(script.run()), script.predicted(address(core), TREASURY));
    }

    function test_chain56RejectedBeforeDeployment() public {
        vm.chainId(56);
        vm.expectRevert(bytes("perf ledger: chain 97 only"));
        script.deploy(address(core), TREASURY);
        vm.expectRevert(bytes("perf ledger: chain 97 only"));
        script.run();
    }

    function test_rejectMissingExecutorAndRecipient() public {
        vm.expectRevert(bytes("perf ledger: executor missing"));
        script.deploy(address(0), TREASURY);
        vm.expectRevert(bytes("perf ledger: zero recipient"));
        script.deploy(address(core), address(0));
    }

    function test_rejectForeignYieldExecutorAndNumeraire() public {
        vm.mockCall(
            address(core.yieldRegistry()), abi.encodeWithSignature("executor()"), abi.encode(address(this))
        );
        vm.expectRevert(bytes("perf ledger: foreign yield executor"));
        script.deploy(address(core), TREASURY);
        vm.clearMockedCalls();
        vm.mockCall(address(core), abi.encodeWithSignature("numeraire()"), abi.encode(address(0xBAD)));
        vm.expectRevert(bytes("perf ledger: foreign numeraire"));
        script.deploy(address(core), TREASURY);
    }

    function test_rejectMissingOrFailingFactory() public {
        vm.etch(B.CREATE2_FACTORY, hex"");
        vm.expectRevert(bytes("perf ledger: factory missing"));
        script.deploy(address(core), TREASURY);
        vm.etch(B.CREATE2_FACTORY, hex"60006000fd");
        vm.expectRevert(bytes("perf ledger: CREATE2 failed"));
        script.deploy(address(core), TREASURY);
    }

    function test_rerunRejectsWrongPinnedRecipient() public {
        Ledger ledger = script.deploy(address(core), TREASURY);
        vm.mockCall(address(ledger), abi.encodeCall(ledger.platformRecipient, ()), abi.encode(address(0xBAD)));
        vm.expectRevert(bytes("perf ledger: recipient mismatch"));
        script.deploy(address(core), TREASURY);
    }

    function test_rejectIncompatibleRegistryPolicyBeforeAnyBroadcast() public {
        bytes[5] memory calls = [
            abi.encodeCall(core.registry().VERSION_DELAY, ()),
            abi.encodeCall(core.registry().PUBLICATION_INTERVAL, ()),
            abi.encodeCall(core.registry().MIN_PERFORMANCE_FEE_BPS, ()),
            abi.encodeCall(core.registry().MAX_PERFORMANCE_FEE_BPS, ()),
            abi.encodeCall(core.registry().MAX_STRATEGY_ASSETS, ())
        ];
        uint64 nonce = vm.getNonce(B.DEPLOYER);
        for (uint256 i; i < calls.length; ++i) {
            vm.mockCall(address(core.registry()), calls[i], abi.encode(uint256(0)));
            vm.expectRevert(bytes("perf ledger: incompatible registry policy"));
            script.deploy(address(core), TREASURY);
            assertEq(vm.getNonce(B.DEPLOYER), nonce);
            vm.clearMockedCalls();
        }
    }

    function test_missingP11RegistryApiFailsBeforeAnyBroadcast() public {
        uint64 nonce = vm.getNonce(B.DEPLOYER);
        vm.mockCallRevert(
            address(core.registry()), abi.encodeCall(core.registry().VERSION_DELAY, ()), "missing P11"
        );
        vm.expectRevert(bytes("missing P11"));
        script.deploy(address(core), TREASURY);
        assertEq(vm.getNonce(B.DEPLOYER), nonce);
    }
}
