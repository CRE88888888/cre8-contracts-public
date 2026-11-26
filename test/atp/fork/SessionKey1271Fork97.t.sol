// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test, console2 } from "forge-std/Test.sol";
import { StrategyBox } from "../../../src/atp/borrow/v2/StrategyBox.sol";
import { ListaProofProbeHost } from "../../../script/mainnet-verify/ListaProofProbe.sol";

interface IKernelPermission {
    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4);

    struct PermissionConfig {
        bytes2 flag;
        address signer;
        bytes22[] policies;
    }

    function permissionConfig(bytes4 permissionId) external view returns (PermissionConfig memory);
}

interface IPolicy {
    function checkSignaturePolicy(bytes32 id, address sender, bytes32 hash, bytes calldata sig)
        external
        view
        returns (uint256);
}

/// @notice Review L3, against the REAL thing: a live CRE8 portfolio account on BSC testnet (Kernel v3.3) with the
/// session permission the backend installs today (ECDSA signer + CallPolicy v0.0.4 + GasPolicy +
/// TimestampPolicy, all flags 0). The question was whether a session key can make the account's ERC-1271
/// answer "valid".
///
/// It can. The three deployed policies answer `checkSignaturePolicy` with 0 (pass) for any hash and any
/// requester, and the permission is not flagged "not for signatures". The only thing left between a session
/// key and a valid account signature is the session signer's own ECDSA check, which the key holder satisfies
/// by definition (stood in for here by mocking that one call; the test does not have the backend's key).
///
/// So the strategy box must not rely on the account refusing session keys, and it does not: with a session
/// signature the box validates the Lista login text and nothing else (no permit / Permit2 / EIP-712 digest).
/// The account-level exposure (anything that accepts ERC-1271 from the portfolio account) is outside this
/// repository: the session permission needs a signature policy, or the "not for signatures" flag.
///
/// Needs BSC_TESTNET_RPC_URL; skipped without it, and skipped (with a note) when the pinned account's
/// permission has since expired or been replaced.
contract SessionKey1271Fork97Test is Test {
    // A portfolio account that sent session-key user operations at block 144,614,663 (2026-11-24).
    address internal constant ACCOUNT = 0x074e3667F4c433D3aA36Ed8D4659C6F713FC45B6;
    bytes4 internal constant PERMISSION = 0xc23d3c4c;
    address internal constant CALL_POLICY = 0x9a52283276A0ec8740DF50bF01B28A80D880eaf2;
    address internal constant GAS_POLICY = 0xaeFC5AbC67FfD258abD0A3E54f65E70326F84b23;
    address internal constant TIMESTAMP_POLICY = 0xB9f8f524bE6EcD8C945b1b87f9ae5C192FdCE20F;
    bytes internal constant SUFFIX = "\nThank you for your support of listaDAO.";
    bytes4 internal constant MAGIC = 0x1626ba7e;

    address internal signer;
    bool internal live;

    function setUp() public {
        string memory rpc = vm.envOr("BSC_TESTNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);
        if (ACCOUNT.code.length == 0) {
            vm.skip(true);
            return;
        }
        IKernelPermission.PermissionConfig memory config =
            IKernelPermission(ACCOUNT).permissionConfig(PERMISSION);
        bytes2 flag = config.flag;
        bytes22[] memory policies = config.policies;
        signer = config.signer;
        live = signer != address(0) && policies.length == 3;
        if (!live) {
            console2.log(
                "pinned session permission is gone: pick a current portfolio account and permission id"
            );
            vm.skip(true);
            return;
        }
        assertEq(flag, bytes2(0), "permission-level flag: allowed for signatures");
        assertEq(address(bytes20(policies[0] << 16)), CALL_POLICY);
        assertEq(address(bytes20(policies[1] << 16)), GAS_POLICY);
        assertEq(address(bytes20(policies[2] << 16)), TIMESTAMP_POLICY);
        for (uint256 i; i < 3; ++i) {
            assertEq(bytes2(policies[i]), bytes2(0), "policy flag: applies to signatures");
        }
    }

    /// @dev A session-key signature as Kernel v3 expects it: 0x02 (permission) | permission id | 0xff (no
    /// per-policy data) | the session signer's signature.
    function _sessionSignature() internal pure returns (bytes memory) {
        return abi.encodePacked(bytes1(0x02), PERMISSION, bytes1(0xff), new bytes(65));
    }

    function _personal(bytes memory message) internal pure returns (bytes32) {
        return
            keccak256(
                abi.encodePacked("\x19Ethereum Signed Message:\n", vm.toString(message.length), message)
            );
    }

    function test_fork97_sessionKey_passesTheAccounts1271_butTheBoxOnlyForTheListaText() public {
        bytes32 permitLike = keccak256(abi.encodePacked("\x19\x01", keccak256("domain"), keccak256("Permit")));
        // The policies, asked exactly as Kernel asks them, do not object to an arbitrary digest.
        address[3] memory policies = [CALL_POLICY, GAS_POLICY, TIMESTAMP_POLICY];
        for (uint256 i; i < 3; ++i) {
            vm.prank(ACCOUNT);
            uint256 answer =
                IPolicy(policies[i]).checkSignaturePolicy(bytes32(PERMISSION), address(this), permitLike, "");
            if (answer != 0) {
                console2.log("a policy now refuses (permission expired?): re-pin the test", i);
                vm.skip(true);
                return;
            }
        }
        // Without the session key: refused (the signer's ECDSA check fails).
        (bool ok, bytes memory ret) = ACCOUNT.staticcall(
            abi.encodeCall(IKernelPermission.isValidSignature, (permitLike, _sessionSignature()))
        );
        assertTrue(!ok || abi.decode(ret, (bytes4)) != MAGIC, "a garbage signature must not pass");

        // With it (the one check the key holder satisfies, mocked): the account says "valid" for ANY digest.
        vm.mockCall(
            signer,
            abi.encodeWithSignature("checkSignature(bytes32,address,bytes32,bytes)"),
            abi.encode(MAGIC)
        );
        assertEq(
            IKernelPermission(ACCOUNT).isValidSignature(permitLike, _sessionSignature()),
            MAGIC,
            "expected: the deployed session permission lets a session key pass the account's ERC-1271"
        );

        // The strategy box bound to this account (the real StrategyBox code) still confirms one message only.
        ListaProofProbeHost host = new ListaProofProbeHost(ACCOUNT, SUFFIX);
        StrategyBox box = StrategyBox(host.box());
        bytes memory text = abi.encodePacked("2026-11-24T10:00:00.000Z", SUFFIX);
        assertEq(box.isValidSignature(_personal(text), abi.encode(text, _sessionSignature())), MAGIC);
        // A permit-like digest, with or without the login text attached, is refused by the box.
        assertEq(box.isValidSignature(permitLike, abi.encode(text, _sessionSignature())), bytes4(0xffffffff));
        assertEq(box.isValidSignature(permitLike, _sessionSignature()), bytes4(0xffffffff));
        bytes memory other = bytes("Sign in to another app");
        assertEq(
            box.isValidSignature(_personal(other), abi.encode(other, _sessionSignature())), bytes4(0xffffffff)
        );
        assertEq(
            box.isValidSignature(keccak256(text), abi.encode(text, _sessionSignature())), bytes4(0xffffffff)
        );
    }
}
