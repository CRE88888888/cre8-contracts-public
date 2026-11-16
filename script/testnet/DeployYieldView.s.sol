// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Script, console } from "forge-std/Script.sol";
import { YieldView } from "../../src/atp/yield/YieldView.sol";
import { TestnetBook as B } from "./TestnetBook.sol";

/// @dev Pins from the UNLINKED solc 0.8.37 / via-IR / optimizer-200 artifact. Linking changes metadata,
/// so DeployTestnet must not derive these hashes from its own linked type(YieldView).creationCode.
/// The artifact regression test checks both pins against a fresh unlinked build.
abstract contract YieldViewPin is Script {
    bytes32 internal constant YIELD_VIEW_INIT_CODEHASH =
        0x64f6b640325667fe7ae1a446f44fabd289b399a6048a7a56355e2a1c52f2285a;
    bytes32 internal constant YIELD_VIEW_RUNTIME_CODEHASH =
        0x967b2b0026a972d87b984c5604ce1dd883ce1dbfe35f7166cf908fc1975c0116;

    function expectedYieldView() public pure returns (address) {
        return address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            bytes1(0xff), B.CREATE2_FACTORY, B.salt("yieldView"), YIELD_VIEW_INIT_CODEHASH
                        )
                    )
                )
            )
        );
    }

    function _verifyYieldView(address reader) internal view {
        require(reader == expectedYieldView(), "yield view: address mismatch");
        bytes memory code = reader.code;
        require(code.length != 0, "yield view: no code");
        require(_yieldViewRuntimeHash(code) == YIELD_VIEW_RUNTIME_CODEHASH, "yield view: code mismatch");
    }

    /// @dev Legacy library runtimes begin with PUSH20 <self address>. Mask ONLY that address operand;
    /// this all-view via-IR artifact has no such prefix and is compared in full, including metadata.
    function _yieldViewRuntimeHash(bytes memory code) internal pure returns (bytes32) {
        if (code.length >= 21 && code[0] == 0x73) {
            for (uint256 i = 1; i <= 20; ++i) {
                code[i] = 0;
            }
        }
        return keccak256(code);
    }
}

/// @notice Bootstrap the linked view library independently, before linking the full deployment.
/// This avoids nesting its creation code inside the executor's EIP-3860-limited initcode.
contract DeployYieldView is YieldViewPin {
    function run() external {
        require(block.chainid == 97, "yield view: chain 97 only");
        uint256 key = vm.envOr("TESTNET_DEPLOYER_KEY", uint256(0));
        if (key != 0) require(vm.rememberKey(key) == B.DEPLOYER, "yield view: deployer mismatch");
        bytes memory initCode = type(YieldView).creationCode;
        require(keccak256(initCode) == YIELD_VIEW_INIT_CODEHASH, "yield view: unlinked artifact mismatch");
        address expected = B.create2Address("yieldView", initCode);
        if (expected.code.length == 0) {
            vm.startBroadcast(B.DEPLOYER);
            (bool ok, bytes memory result) =
                B.CREATE2_FACTORY.call(abi.encodePacked(B.salt("yieldView"), initCode));
            vm.stopBroadcast();
            require(ok && result.length == 20, "yield view: CREATE2 failed");
            require(address(bytes20(result)) == expected, "yield view: address mismatch");
        }
        _verifyYieldView(expected);
        console.log("YIELD_VIEW", expected);
    }
}
