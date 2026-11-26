// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC1271 } from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";

interface IBoxExecutor {
    function borrowRegistry() external view returns (address);
}

interface IBoxRegistry {
    function rewardProofSuffix() external view returns (bytes memory);
}

/// @notice One per portfolio account (a minimal clone the routing executor deploys with CREATE2, salt = account).
/// It holds the strategy's vault receipts (ERC4626 shares, vTokens, aTokens) and whatever rewards they earn, so
/// they never sit in the portfolio account where `AtpExecutor` or a session key could reach them. It has no
/// logic of its own: only the executor can make it approve a vault adapter or send a token.
/// @dev ERC-1271 is deliberately narrow. Reward programs (Lista's emission proof API) hand out a merkle proof
/// only to a caller that signs a login text as the address being claimed for, and the box is the depositor of
/// record. The box therefore confirms exactly one kind of message: a short text ending with the registry's
/// reward-proof suffix, hashed the personal_sign way (EIP-191) and signed by its account. Verified on BSC
/// mainnet on 2026-11-24: Lista calls `isValidSignature(bytes32,bytes)` with the EIP-191 hash and nothing
/// else, so no other form is accepted. An EIP-191 text hash can never equal an EIP-712 digest (permits,
/// Permit2: their preimage starts with 0x1901), so whoever signs, a signature can never move what the box holds.
contract StrategyBox {
    using SafeERC20 for IERC20;

    /// @dev Longest text in front of the suffix (an ISO timestamp is 24 bytes).
    uint256 internal constant MAX_PREFIX = 64;
    bytes4 internal constant MAGIC = 0x1626ba7e;
    bytes4 internal constant INVALID = 0xffffffff;

    address public immutable executor;
    /// @notice The portfolio account this box belongs to (set once by the executor when it deploys the clone).
    address public account;

    error NotExecutor();
    error AlreadyInitialized();

    constructor(address executor_) {
        executor = executor_;
    }

    modifier onlyExecutor() {
        if (msg.sender != executor) revert NotExecutor();
        _;
    }

    function init(address account_) external onlyExecutor {
        if (account != address(0)) revert AlreadyInitialized();
        account = account_;
    }

    function approve(IERC20 token, address spender) external onlyExecutor {
        token.forceApprove(spender, type(uint256).max);
    }

    function send(IERC20 token, address to, uint256 amount) external onlyExecutor {
        token.safeTransfer(to, amount);
    }

    /// @notice ERC-1271. `signature` = abi.encode(bytes message, bytes accountSignature). Valid only when
    /// `message` ends with the registry's reward-proof suffix (at most 64 bytes in front of it), `hash` is that
    /// message's personal_sign hash, and the account itself confirms `accountSignature` for the same hash.
    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4) {
        address owner = account;
        if (owner == address(0) || signature.length < 128) return INVALID;
        (bytes memory message, bytes memory inner) = abi.decode(signature, (bytes, bytes));
        bytes memory suffix = IBoxRegistry(IBoxExecutor(executor).borrowRegistry()).rewardProofSuffix();
        uint256 n = suffix.length;
        if (n == 0 || message.length < n || message.length - n > MAX_PREFIX) return INVALID;
        uint256 offset = message.length - n;
        for (uint256 i; i < n; ++i) {
            if (message[offset + i] != suffix[i]) return INVALID;
        }
        if (hash != _personalHash(message)) return INVALID;
        try IERC1271(owner).isValidSignature(hash, inner) returns (bytes4 magic) {
            return magic == MAGIC ? MAGIC : INVALID;
        } catch {
            return INVALID;
        }
    }

    function _personalHash(bytes memory message) private pure returns (bytes32) {
        return keccak256(
            abi.encodePacked("\x19Ethereum Signed Message:\n", Strings.toString(message.length), message)
        );
    }
}
