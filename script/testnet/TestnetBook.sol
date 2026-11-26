// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { TestnetToken, TestnetBStock } from "../../src/testnet/TestnetToken.sol";
import { TestnetAssets } from "./TestnetAssets.sol";

/// @title TestnetBook
/// @notice Where the chain 97 deployment lives (cre8-contracts#30): CREATE2 salts and init codes shared by
/// `DeployTestnet` (which deploys at these addresses) and the smoke / ops scripts (which find them again from
/// the deployer address alone, with no file to read).
library TestnetBook {
    /// @dev forge-std's `CREATE2_FACTORY`, the deterministic deployer present on chain 97.
    address internal constant CREATE2_FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    /// @dev Bumped together with any change that should produce a fresh deployment instead of a rerun.
    string internal constant SALT_NAMESPACE = "cre8.testnet.97.v1";

    // ---- roles: chain-97-only keys in ~/.cre8-testnet/ (addresses.txt), new for the testnet (#30) ----
    // Private keys never enter this repo. tBNB goes to DEPLOYER only; `DeployTestnet` funds the others.
    /// @dev Deploys everything, owns the mock tokens / feeds and the LP positions.
    address internal constant DEPLOYER = 0x55662B4183fcA1230694D5D57F56E4F2E0e3008a;
    /// @dev Stands in for the mainnet Safe: owns the registry, the oracle router and the paymaster.
    address internal constant OWNER = 0x09BBB9A06a0C49Ad24bddB18808944041783054e;
    /// @dev Registry operator (backend relayer) and testnet-USDT minter (faucet `claimFor`).
    address internal constant OPERATOR = 0xd8CE3295e05cA138e0d0d7214C4FD630c43F9d7F;
    /// @dev Only feed pusher; minter of every mock token (moves pool prices).
    address internal constant KEEPER = 0xa38dDFB9FDF0043Cf61B00E1a8d12FA1431f92d5;
    /// @dev Signs `VerifyingPaymaster` sponsorships off chain; holds no tBNB.
    address internal constant PAYMASTER_SIGNER = 0xF5645Ff8Fa773246010F7C9DDDFF8e590e800495;
    /// @dev Receives the executor's swap fee.
    address internal constant FEE_RECIPIENT = 0x3b5EDE5aF574e7d8f3B72143E09DC242dD1F0462;
    /// @dev alto `--executor-private-keys`: submits `handleOps`, reimbursed by the EntryPoint.
    address internal constant BUNDLER_EXECUTOR = 0xcc0ea01356d75aa5295d364344753f136b77ee28;
    /// @dev alto `--utility-private-key`: tops up the executor wallet.
    address internal constant BUNDLER_UTILITY = 0x6735c14bf84c8cB0d64BF2FB51b7587AdE7b2960;

    function salt(string memory label) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(SALT_NAMESPACE, "/", label));
    }

    function create2Address(string memory label, bytes memory initCode) internal pure returns (address) {
        bytes32 hash =
            keccak256(abi.encodePacked(bytes1(0xff), CREATE2_FACTORY, salt(label), keccak256(initCode)));
        return address(uint160(uint256(hash)));
    }

    function tokenLabel(TestnetAssets.AssetSpec memory spec) internal pure returns (string memory) {
        return string.concat("token.", spec.symbol);
    }

    function tokenInitCode(TestnetAssets.AssetSpec memory spec, address owner)
        internal
        pure
        returns (bytes memory)
    {
        return spec.uiMultiplier == 0
            ? abi.encodePacked(
                type(TestnetToken).creationCode, abi.encode(spec.name, spec.symbol, spec.decimals, owner)
            )
            : abi.encodePacked(
                type(TestnetBStock).creationCode,
                abi.encode(spec.name, spec.symbol, spec.decimals, owner, spec.uiMultiplier)
            );
    }

    function tokenAddress(TestnetAssets.AssetSpec memory spec, address owner)
        internal
        pure
        returns (address)
    {
        return create2Address(tokenLabel(spec), tokenInitCode(spec, owner));
    }
}
