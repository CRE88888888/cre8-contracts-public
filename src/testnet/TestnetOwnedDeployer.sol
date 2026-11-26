// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @dev The two-step ownership both `AtpRegistry` and `AtpMultiPoolOracle` implement.
interface ITwoStepOwnable {
    function transferOwnership(address next) external;
}

/// @title TestnetOwnedDeployer
/// @notice TESTNET ONLY (chain 97; cre8-contracts#30). Deploys a contract whose constructor makes
/// `msg.sender` the owner (`AtpRegistry`, `AtpMultiPoolOracle`) at a CREATE2 address, then proposes the caller
/// as owner; the caller finishes with `acceptOwnership()`. This gives the testnet deployment addresses that are
/// a pure function of (caller, salt, init code), so the deploy script reruns idempotently and a local fork
/// predicts the public chain's addresses exactly.
/// @dev The salt is bound to the caller, so nobody else can occupy the caller's address or become its owner;
/// a stranger calling with the same arguments deploys at a different address and owns only that.
contract TestnetOwnedDeployer {
    event Deployed(address indexed caller, bytes32 indexed salt, address deployed);

    error DeployFailed();

    function deploy(bytes32 salt, bytes calldata initCode) external returns (address deployed) {
        bytes32 bound = keccak256(abi.encode(msg.sender, salt));
        bytes memory code = initCode;
        assembly {
            deployed := create2(0, add(code, 32), mload(code), bound)
        }
        if (deployed == address(0)) revert DeployFailed();
        ITwoStepOwnable(deployed).transferOwnership(msg.sender);
        emit Deployed(msg.sender, salt, deployed);
    }

    function predict(address caller, bytes32 salt, bytes32 initCodeHash) external view returns (address) {
        bytes32 bound = keccak256(abi.encode(caller, salt));
        return address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), bound, initCodeHash))))
        );
    }
}
