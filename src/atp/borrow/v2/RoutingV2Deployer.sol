// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IDeployedRegistry {
    function executor() external view returns (address);
}

interface IDeployedLens {
    function borrowRegistry() external view returns (address);
    function executor() external view returns (address);
}

interface IDeployedExecutor {
    function borrowRegistry() external view returns (address);
    function lens() external view returns (address);
}

/// @notice Single-use deployer of the routing v2 trio. The registry is bound to its executor's address at
/// construction and the executor to its registry, so the executor's address must be known before either
/// exists. This contract creates registry, lens and executor with its own first three nonces (1, 2, 3), which
/// nothing else can consume: the executor's address is fixed the moment this contract is deployed, however the
/// three transactions are ordered among other traffic. The three contracts together exceed the init-code and
/// per-transaction gas limits, hence three calls.
contract RoutingV2Deployer {
    address public immutable deployer;
    address public registry;
    address public lens;
    address public executor;

    error NotDeployer();
    error WrongStep();
    error CreateFailed();
    error BadWiring();

    constructor(address deployer_) {
        deployer = deployer_;
    }

    /// @notice Address the executor will get (this contract's third creation).
    function predictedExecutor() public view returns (address) {
        return
            address(
                uint160(uint256(keccak256(abi.encodePacked(bytes2(0xd694), address(this), bytes1(0x03)))))
            );
    }

    /// @param initCode `AtpBorrowRegistryV2` creation code with constructor arguments; the executor argument
    /// must be `predictedExecutor()`.
    function deployRegistry(bytes calldata initCode) external returns (address) {
        if (msg.sender != deployer) revert NotDeployer();
        if (registry != address(0)) revert WrongStep();
        registry = _create(initCode);
        if (IDeployedRegistry(registry).executor() != predictedExecutor()) revert BadWiring();
        return registry;
    }

    /// @param initCode `AtpBorrowLensV2` creation code with this registry as argument.
    function deployLens(bytes calldata initCode) external returns (address) {
        if (msg.sender != deployer) revert NotDeployer();
        if (registry == address(0) || lens != address(0)) revert WrongStep();
        lens = _create(initCode);
        if (
            IDeployedLens(lens).borrowRegistry() != registry
                || IDeployedLens(lens).executor() != predictedExecutor()
        ) {
            revert BadWiring();
        }
        return lens;
    }

    /// @param initCode `AtpBorrowExecutorV2` creation code with (registry, lens) as arguments.
    function deployExecutor(bytes calldata initCode) external returns (address) {
        if (msg.sender != deployer) revert NotDeployer();
        if (lens == address(0) || executor != address(0)) revert WrongStep();
        executor = _create(initCode);
        if (
            executor != predictedExecutor() || IDeployedExecutor(executor).borrowRegistry() != registry
                || IDeployedExecutor(executor).lens() != lens
        ) revert BadWiring();
        return executor;
    }

    function _create(bytes memory initCode) private returns (address created) {
        assembly {
            created := create(0, add(initCode, 0x20), mload(initCode))
        }
        if (created == address(0)) revert CreateFailed();
    }
}
