// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";
import { StrategyBox } from "../../src/atp/borrow/v2/StrategyBox.sol";

/// @notice Detects HOW an off-chain verifier (Lista's reward-proof API) calls a contract signer. The call is an
/// eth_call and cannot be logged, so seven of these are deployed, each accepting exactly one call form; which
/// address the API accepts tells the form. `signature` must be `abi.encode(bytes message, bytes anything)`
/// with `message` ending in the reward-proof text (forms 0 and 3 accept anything).
///   0  isValidSignature(bytes32,bytes)   any hash, any signature
///   1  isValidSignature(bytes32,bytes)   hash == EIP-191 personal_sign hash of message
///   2  isValidSignature(bytes32,bytes)   hash == keccak256(message)
///   3  isValidSignature(bytes,bytes)     any data, any signature
///   4  isValidSignature(bytes,bytes)     data == message
///   5  isValidSignature(bytes,bytes)     data == the 32-byte EIP-191 hash
///   6  isValidSignature(bytes,bytes)     data == the 32-byte keccak256(message)
/// @dev Holds nothing, owns nothing, authorizes nothing: "valid" here has no consequence anywhere. There is
/// deliberately no signer check, the probe only answers "was I called this way".
contract SignatureFormProbe {
    bytes4 internal constant MAGIC = 0x1626ba7e;
    bytes4 internal constant LEGACY_MAGIC = 0x20c13b0b;
    bytes4 internal constant INVALID = 0xffffffff;

    uint8 public immutable form;
    bytes public suffix;

    constructor(uint8 form_, bytes memory suffix_) {
        form = form_;
        suffix = suffix_;
    }

    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4) {
        if (form == 0) return MAGIC;
        if (form != 1 && form != 2) return INVALID;
        (bool ok, bytes memory message) = _message(signature);
        if (!ok) return INVALID;
        return hash == (form == 1 ? _personalHash(message) : keccak256(message)) ? MAGIC : INVALID;
    }

    function isValidSignature(bytes calldata data, bytes calldata signature) external view returns (bytes4) {
        if (form == 3) return LEGACY_MAGIC;
        if (form < 4) return INVALID;
        (bool ok, bytes memory message) = _message(signature);
        if (!ok) return INVALID;
        if (form == 4) return keccak256(data) == keccak256(message) ? LEGACY_MAGIC : INVALID;
        if (data.length != 32) return INVALID;
        return
            bytes32(data) == (form == 5 ? _personalHash(message) : keccak256(message))
                ? LEGACY_MAGIC
                : INVALID;
    }

    function _message(bytes calldata signature) private view returns (bool, bytes memory message) {
        if (signature.length < 128) return (false, message);
        (message,) = abi.decode(signature, (bytes, bytes));
        bytes memory tail = suffix;
        if (message.length < tail.length) return (false, message);
        uint256 offset = message.length - tail.length;
        for (uint256 i; i < tail.length; ++i) {
            if (message[offset + i] != tail[i]) return (false, message);
        }
        return (true, message);
    }

    function _personalHash(bytes memory message) private pure returns (bytes32) {
        return keccak256(
            abi.encodePacked("\x19Ethereum Signed Message:\n", Strings.toString(message.length), message)
        );
    }
}

/// @notice Stands in for the routing executor and registry so that the REAL `StrategyBox` (the same bytecode
/// v2 deploys, as an EIP-1167 clone initialized for one account) can exist on chain without the rest of v2.
/// The only thing the box reads from its executor is `borrowRegistry().rewardProofSuffix()`, served here.
/// Differences from production: this host has no function that calls the box's `approve` / `send`, so the box
/// is inert forever; and the suffix is fixed at construction instead of owner-settable.
/// One deployment creates: this host, the box implementation, the box clone, and the seven form probes.
contract ListaProofProbeHost {
    address public immutable account;
    address public immutable boxImplementation;
    address public immutable box;
    bytes public rewardProofSuffix;
    address[7] public probes;

    constructor(address account_, bytes memory suffix_) {
        require(account_.code.length != 0 && suffix_.length >= 16, "probe host: config");
        account = account_;
        rewardProofSuffix = suffix_;
        boxImplementation = address(new StrategyBox(address(this)));
        box = Clones.clone(boxImplementation);
        StrategyBox(box).init(account_);
        for (uint8 i; i < 7; ++i) {
            probes[i] = address(new SignatureFormProbe(i, suffix_));
        }
    }

    function borrowRegistry() external view returns (address) {
        return address(this);
    }
}
