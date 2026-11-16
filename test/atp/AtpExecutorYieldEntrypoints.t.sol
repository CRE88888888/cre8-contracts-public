// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";
import { AtpExecutor } from "../../src/atp/AtpExecutor.sol";
import { AtpYieldRegistry } from "../../src/atp/yield/AtpYieldRegistry.sol";
import { AtpRegistry } from "../../src/atp/AtpRegistry.sol";
import { PricedRouter, PricedOracle, BurnableToken } from "./AtpExecutorBuyLimit.t.sol";
import { MockPermit2 } from "./AtpExecutor.t.sol";

contract LookalikeYieldRegistry {
    AtpRegistry public immutable registry;
    address public immutable executor;

    constructor(AtpRegistry registry_, address executor_) {
        registry = registry_;
        executor = executor_;
    }
}

/// @notice Written before the yield implementation: the old executor has no typed entrypoints.
contract AtpExecutorYieldEntrypointsTest is Test {
    AtpExecutor internal executor;

    function setUp() public {
        BurnableToken token = new BurnableToken();
        executor = new AtpExecutor(
            new AtpRegistry(),
            new PricedRouter(),
            new PricedOracle(address(token)),
            address(new MockPermit2()),
            address(0xFEE),
            address(token),
            10_000,
            0
        );
    }

    function test_supplyRejectsForeignCaller() public {
        (bool ok, bytes memory reason) = address(executor)
            .call(
                abi.encodeWithSignature(
                    "executeSupply(address,bytes32,uint256,uint256,uint256)",
                    address(0xBEEF),
                    bytes32(uint256(1)),
                    1,
                    1,
                    block.timestamp
                )
            );
        assertFalse(ok);
        assertEq(reason, abi.encodeWithSelector(AtpExecutor.NotAccount.selector));
    }

    function test_withdrawRejectsForeignCaller() public {
        (bool ok, bytes memory reason) = address(executor)
            .call(
                abi.encodeWithSignature(
                    "executeWithdraw(address,bytes32,uint256,uint256,uint256)",
                    address(0xBEEF),
                    bytes32(uint256(1)),
                    1,
                    1,
                    block.timestamp
                )
            );
        assertFalse(ok);
        assertEq(reason, abi.encodeWithSelector(AtpExecutor.NotAccount.selector));
    }

    function test_unknownYieldFailsExplicitly() public {
        (bool ok, bytes memory reason) = address(executor)
            .call(
                abi.encodeWithSignature(
                    "executeSupply(address,bytes32,uint256,uint256,uint256)",
                    address(this),
                    bytes32(uint256(1)),
                    1,
                    1,
                    block.timestamp
                )
            );
        assertFalse(ok);
        assertEq(reason, abi.encodeWithSelector(AtpYieldRegistry.UnknownMarket.selector));
    }

    function test_constructorCreatesImmutableEmptyRegistry() public view {
        AtpYieldRegistry yields = executor.yieldRegistry();
        address expected =
            address(uint160(uint256(keccak256(abi.encodePacked(hex"d694", address(executor), hex"01")))));
        assertEq(address(yields), expected);
        assertEq(address(yields.registry()), address(executor.registry()));
        assertEq(yields.executor(), address(executor));
        assertEq(yields.marketCount(), 0);
    }

    function test_ownerCannotInstallLookalikeYieldRegistry() public {
        LookalikeYieldRegistry fake = new LookalikeYieldRegistry(executor.registry(), address(executor));
        address original = address(executor.yieldRegistry());
        (bool ok,) =
            address(executor).call(abi.encodeWithSignature("setYieldRegistry(address)", address(fake)));
        assertFalse(ok);
        assertEq(address(executor.yieldRegistry()), original);
    }
}
