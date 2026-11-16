// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";
import { DeployTestnet } from "../../script/DeployTestnet.s.sol";
import { TestnetBook as B } from "../../script/testnet/TestnetBook.sol";
import { YieldView } from "../../src/atp/yield/YieldView.sol";
import { AtpYieldRegistry } from "../../src/atp/yield/AtpYieldRegistry.sol";
import { TestnetAssets } from "../../script/testnet/TestnetAssets.sol";
import { DeployYieldView, YieldViewPin } from "../../script/testnet/DeployYieldView.s.sol";

contract YieldViewPinHarness is YieldViewPin {
    function hashes() external pure returns (bytes32, bytes32) {
        return (YIELD_VIEW_INIT_CODEHASH, YIELD_VIEW_RUNTIME_CODEHASH);
    }

    function verify(address reader) external view {
        _verifyYieldView(reader);
    }

    function runtimeHash(bytes memory code) external pure returns (bytes32) {
        return _yieldViewRuntimeHash(code);
    }
}

contract YieldViewReportHarness is DeployTestnet {
    function report(AtpYieldRegistry yields) external view {
        Core memory core;
        core.yields = yields;
        _report(core, new TestnetAssets.AssetSpec[](0), new AssetOut[](0));
    }
}

contract DeployYieldViewPinTest is Test {
    YieldViewPinHarness pin;
    address expected;

    function setUp() public {
        vm.chainId(97);
        pin = new YieldViewPinHarness();
        expected = pin.expectedYieldView();
    }

    function _install() private {
        deployCodeTo("YieldView.sol:YieldView", expected);
    }

    function _reportWithReader(address reader)
        private
        returns (YieldViewReportHarness script, AtpYieldRegistry yields)
    {
        script = new YieldViewReportHarness();
        yields = AtpYieldRegistry(makeAddr("reported yields"));
        vm.mockCall(address(yields), abi.encodeCall(yields.reader, ()), abi.encode(reader));
    }

    function test_pinsMatchFreshUnlinkedArtifactAndBootstrapCreate2() public {
        (bytes32 initHash, bytes32 runtimeHash) = pin.hashes();
        bytes memory initCode = type(YieldView).creationCode;
        assertEq(initHash, keccak256(initCode), "unlinked initcode pin");
        assertEq(
            runtimeHash,
            pin.runtimeHash(vm.getDeployedCode("YieldView.sol:YieldView")),
            "unlinked runtime pin"
        );
        assertEq(expected, B.create2Address("yieldView", initCode), "bootstrap CREATE2 calculation");
        assertEq(new DeployYieldView().expectedYieldView(), expected);
    }

    function test_run_rejectsWrongLinkedLibraryBeforeDeployment() public {
        assertTrue(address(YieldView) != expected, "test runner links a nonce-deployed library");
        assertGt(address(YieldView).code.length, 0, "wrong address still has library code");
        DeployTestnet script = new DeployTestnet();
        vm.expectRevert(bytes("yield view: address mismatch"));
        script.run();
    }

    function test_verify_acceptsExactUnlinkedRuntimeAtCreate2Address() public {
        _install();
        pin.verify(expected);
    }

    function test_verify_rejectsZeroAndWrongAddressEvenWithCorrectCode() public {
        _install();
        address wrong = makeAddr("wrong library with identical code");
        vm.etch(wrong, expected.code);
        vm.expectRevert(bytes("yield view: address mismatch"));
        pin.verify(address(0));
        vm.expectRevert(bytes("yield view: address mismatch"));
        pin.verify(wrong);
    }

    function test_verify_rejectsMissingRuntime() public {
        vm.expectRevert(bytes("yield view: no code"));
        pin.verify(expected);
    }

    function test_verify_rejectsTruncatedBodyAndMetadataChanges() public {
        _install();
        bytes memory original = expected.code;
        uint256[3] memory offsets = [uint256(0), original.length / 2, original.length - 1];
        for (uint256 i; i < offsets.length; ++i) {
            bytes memory altered = abi.encodePacked(original);
            altered[offsets[i]] = altered[offsets[i]] ^ bytes1(0x01);
            vm.etch(expected, altered);
            vm.expectRevert(bytes("yield view: code mismatch"));
            pin.verify(expected);
        }
        vm.etch(expected, hex"60");
        vm.expectRevert(bytes("yield view: code mismatch"));
        pin.verify(expected);
    }

    function test_runtimeHash_masksOnlyCompletePush20AddressOperand() public {
        bytes memory tail = hex"3014604052";
        assertEq(
            pin.runtimeHash(abi.encodePacked(bytes1(0x73), address(this), tail)),
            keccak256(abi.encodePacked(bytes1(0x73), address(0), tail))
        );
        assertTrue(
            pin.runtimeHash(abi.encodePacked(bytes1(0x73), address(this), tail))
                != pin.runtimeHash(abi.encodePacked(bytes1(0x73), address(this), hex"3014604053")),
            "the byte after the address operand remains checked"
        );
        bytes memory shortPrefix = abi.encodePacked(bytes1(0x73), bytes19(type(uint152).max));
        assertEq(pin.runtimeHash(shortPrefix), keccak256(shortPrefix), "20 bytes is incomplete");
        assertEq(
            pin.runtimeHash(abi.encodePacked(bytes1(0x73), address(this))),
            keccak256(abi.encodePacked(bytes1(0x73), address(0))),
            "21 bytes contains a complete operand"
        );
        assertEq(pin.runtimeHash(hex""), keccak256(hex""));
    }

    function test_report_rejectsWrongReaderBeforeAnyManifestLine() public {
        (YieldViewReportHarness script, AtpYieldRegistry yields) = _reportWithReader(address(YieldView));
        vm.expectRevert(bytes("yield view: address mismatch"));
        script.report(yields);
    }

    function test_report_rechecksMissingRuntimeBeforeAnyManifestLine() public {
        (YieldViewReportHarness script, AtpYieldRegistry yields) = _reportWithReader(expected);
        vm.expectRevert(bytes("yield view: no code"));
        script.report(yields);
    }

    function test_report_rechecksTamperedRuntimeBeforeAnyManifestLine() public {
        _install();
        (YieldViewReportHarness script, AtpYieldRegistry yields) = _reportWithReader(expected);
        vm.etch(expected, hex"60006000f3");
        vm.expectRevert(bytes("yield view: code mismatch"));
        script.report(yields);
    }

    function test_bootstrap_reusesVerifiedLibraryWithoutChangingDeployerNonce() public {
        _install();
        uint64 beforeNonce = vm.getNonce(B.DEPLOYER);
        new DeployYieldView().run();
        assertEq(vm.getNonce(B.DEPLOYER), beforeNonce);
        pin.verify(expected);
    }

    function test_bootstrap_rejectsTamperedExistingRuntime() public {
        vm.etch(expected, hex"00");
        DeployYieldView script = new DeployYieldView();
        vm.expectRevert(bytes("yield view: code mismatch"));
        script.run();
    }
}
