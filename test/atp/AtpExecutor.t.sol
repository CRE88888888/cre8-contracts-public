// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";
import { AtpExecutor } from "../../src/atp/AtpExecutor.sol";
import { AtpRegistry } from "../../src/atp/AtpRegistry.sol";
import { IOracleFloor } from "../../src/atp/interfaces/IOracleFloor.sol";
import { IUniversalRouter } from "../../src/atp/interfaces/IUniversalRouter.sol";

/// @dev Bare Universal Router stub: the executor constructor only needs code at that address.
contract MockUniversalRouter is IUniversalRouter {
    function execute(bytes calldata, bytes[] calldata, uint256) external payable { }
}

/// @dev Bare oracle stub: the executor constructor only needs code at that address.
contract MockOracleFloor is IOracleFloor {
    function previewSwap(address, address, uint256) external pure returns (uint256, uint256) {
        return (0, 0);
    }
}

/// @dev Exposes the executor's internal decoders and floor arithmetic so the byte layout can be pinned
/// directly, without changing the production contract.
contract AtpExecutorHarness is AtpExecutor {
    constructor(AtpRegistry registry_, IUniversalRouter router_, IOracleFloor oracle_, address feeRecipient_)
        AtpExecutor(registry_, router_, oracle_, feeRecipient_)
    { }

    function checkCommands(bytes calldata commands, bytes[] calldata inputs) external view {
        _checkCommands(commands, inputs);
    }

    function checkRecipient(bytes calldata input, uint256 wordIndex) external view {
        _checkRecipient(input, wordIndex);
    }

    function minGross(uint256 oracleFloor, uint16 feeBps) external pure returns (uint256) {
        return _minGross(oracleFloor, feeBps);
    }
}

/// @notice Pins the command/recipient decoding of `AtpExecutor._checkCommands` against the Universal
/// Router payload layout, and the `_minGross` fee gross-up. Both are safety-critical: a decode that
/// reads the wrong word would let a swap pay out anywhere but this executor.
contract AtpExecutorTest is Test {
    // Universal Router command bytes (must match `UniversalRouterCommands`).
    bytes1 internal constant V3_SWAP_EXACT_IN = 0x00;
    bytes1 internal constant V2_SWAP_EXACT_IN = 0x08;
    bytes1 internal constant SWEEP = 0x04;
    bytes1 internal constant TRANSFER = 0x05;
    bytes1 internal constant PAY_PORTION = 0x06;
    bytes1 internal constant FLAG_BIT = 0x20;

    address internal constant PATH_TOKEN_IN = address(0xA11CE);
    address internal constant PATH_TOKEN_OUT = address(0xB0B);
    address internal constant FEE_RECIPIENT = address(0xFEE);
    address internal constant OTHER = address(0xCAFE);

    AtpRegistry internal registry;
    AtpExecutorHarness internal executor;

    function setUp() public {
        registry = new AtpRegistry();
        executor = new AtpExecutorHarness(
            registry, new MockUniversalRouter(), new MockOracleFloor(), FEE_RECIPIENT
        );
    }

    // ---- fixtures ----

    function _command(bytes1 command) internal pure returns (bytes memory commands) {
        commands = new bytes(1);
        commands[0] = command;
    }

    /// @dev Universal Router `V3_SWAP_EXACT_IN` payload: (recipient, amountIn, amountOutMin, path,
    /// payerIsUser). `recipient` is head word 0.
    function _v3SwapInput(address recipient, uint256 amountIn, uint256 amountOutMin)
        internal
        pure
        returns (bytes memory)
    {
        bytes memory path = abi.encodePacked(PATH_TOKEN_IN, uint24(500), PATH_TOKEN_OUT);
        return abi.encode(recipient, amountIn, amountOutMin, path, true);
    }

    /// @dev Universal Router `SWEEP` / `TRANSFER` payload: (token, recipient, amountMin). `recipient` is
    /// head word 1.
    function _sweepInput(address token, address recipient, uint256 amountMin)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(token, recipient, amountMin);
    }

    function _one(bytes memory input) internal pure returns (bytes[] memory inputs) {
        inputs = new bytes[](1);
        inputs[0] = input;
    }

    // ---- _checkCommands: accepted shapes ----

    function test_checkCommands_acceptsV3SwapPayingExecutor() public view {
        executor.checkCommands(_command(V3_SWAP_EXACT_IN), _one(_v3SwapInput(address(executor), 1e18, 0)));
    }

    function test_checkCommands_acceptsV2SwapPayingExecutor() public view {
        executor.checkCommands(_command(V2_SWAP_EXACT_IN), _one(_v3SwapInput(address(executor), 1e18, 0)));
    }

    function test_checkCommands_acceptsSweepAndTransferPayingExecutor() public view {
        executor.checkCommands(_command(SWEEP), _one(_sweepInput(PATH_TOKEN_IN, address(executor), 0)));
        executor.checkCommands(_command(TRANSFER), _one(_sweepInput(PATH_TOKEN_IN, address(executor), 0)));
    }

    function test_checkCommands_acceptsBatchWhereEveryLegPaysExecutor() public view {
        bytes memory commands = abi.encodePacked(V3_SWAP_EXACT_IN, V3_SWAP_EXACT_IN, SWEEP);
        bytes[] memory inputs = new bytes[](3);
        inputs[0] = _v3SwapInput(address(executor), 1e18, 0);
        inputs[1] = _v3SwapInput(address(executor), 1e18, 0);
        inputs[2] = _sweepInput(PATH_TOKEN_IN, address(executor), 0);

        executor.checkCommands(commands, inputs);
    }

    // ---- _checkCommands: recipient pinned to the executor ----

    function test_checkCommands_rejectsSwapPayingThirdParty() public {
        vm.expectRevert(abi.encodeWithSelector(AtpExecutor.BadRecipient.selector, OTHER));
        executor.checkCommands(_command(V3_SWAP_EXACT_IN), _one(_v3SwapInput(OTHER, 1e18, 0)));
    }

    function test_checkCommands_rejectsSwapPayingZeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(AtpExecutor.BadRecipient.selector, address(0)));
        executor.checkCommands(_command(V3_SWAP_EXACT_IN), _one(_v3SwapInput(address(0), 1e18, 0)));
    }

    function test_checkCommands_rejectsSwapPayingTheCaller() public {
        // The caller (this test) is not the executor: an agent cannot route output to itself.
        vm.expectRevert(abi.encodeWithSelector(AtpExecutor.BadRecipient.selector, address(this)));
        executor.checkCommands(_command(V3_SWAP_EXACT_IN), _one(_v3SwapInput(address(this), 1e18, 0)));
    }

    /// @dev SWEEP/TRANSFER read head word 1, not word 0: a payload whose word 0 is the executor but whose
    /// recipient is someone else must still revert.
    function test_checkCommands_rejectsSweepWhoseRecipientIsNotExecutor() public {
        vm.expectRevert(abi.encodeWithSelector(AtpExecutor.BadRecipient.selector, OTHER));
        executor.checkCommands(_command(SWEEP), _one(_sweepInput(address(executor), OTHER, 0)));
    }

    function test_checkCommands_rejectsTransferWhoseRecipientIsNotExecutor() public {
        vm.expectRevert(abi.encodeWithSelector(AtpExecutor.BadRecipient.selector, OTHER));
        executor.checkCommands(_command(TRANSFER), _one(_sweepInput(address(executor), OTHER, 0)));
    }

    function test_checkRecipient_readsWord0OfASwapPayload() public view {
        executor.checkRecipient(_v3SwapInput(address(executor), 1e18, 0), 0);
    }

    function test_checkRecipient_readsWord1OfASweepPayload() public view {
        executor.checkRecipient(_sweepInput(PATH_TOKEN_IN, address(executor), 0), 1);
    }

    function test_checkRecipient_revertsOnTruncatedPayload() public {
        // One word is not enough when the recipient lives in word 1.
        vm.expectRevert(AtpExecutor.BadCommands.selector);
        executor.checkRecipient(abi.encode(PATH_TOKEN_IN), 1);
    }

    // ---- _checkCommands: command allowlist is exact bytes ----

    function test_checkCommands_rejectsPayPortion() public {
        bytes[] memory inputs = _one(_sweepInput(PATH_TOKEN_IN, address(executor), 0));
        vm.expectRevert(abi.encodeWithSelector(AtpExecutor.CommandNotAllowed.selector, PAY_PORTION));
        executor.checkCommands(_command(PAY_PORTION), inputs);
    }

    function test_checkCommands_rejectsSwapCarryingFlagBit() public {
        // V3_SWAP_EXACT_IN | FLAG_ALLOW_REVERT (0x20) is not the exact allowlisted byte.
        bytes1 flagged = V3_SWAP_EXACT_IN | FLAG_BIT;
        vm.expectRevert(abi.encodeWithSelector(AtpExecutor.CommandNotAllowed.selector, flagged));
        executor.checkCommands(_command(flagged), _one(_v3SwapInput(address(executor), 1e18, 0)));
    }

    function test_checkCommands_rejectsBareFlagBit() public {
        vm.expectRevert(abi.encodeWithSelector(AtpExecutor.CommandNotAllowed.selector, FLAG_BIT));
        executor.checkCommands(_command(FLAG_BIT), _one(_sweepInput(PATH_TOKEN_IN, address(executor), 0)));
    }

    function test_checkCommands_rejectsUnknownCommand() public {
        bytes1 unknown = 0x0a;
        vm.expectRevert(abi.encodeWithSelector(AtpExecutor.CommandNotAllowed.selector, unknown));
        executor.checkCommands(_command(unknown), _one(_sweepInput(PATH_TOKEN_IN, address(executor), 0)));
    }

    /// @dev A later leg being wrong must fail the whole batch, not only its own iteration.
    function test_checkCommands_rejectsBatchWithOneBadLeg() public {
        bytes memory commands = abi.encodePacked(V3_SWAP_EXACT_IN, SWEEP);
        bytes[] memory inputs = new bytes[](2);
        inputs[0] = _v3SwapInput(address(executor), 1e18, 0);
        inputs[1] = _sweepInput(PATH_TOKEN_IN, OTHER, 0);

        vm.expectRevert(abi.encodeWithSelector(AtpExecutor.BadRecipient.selector, OTHER));
        executor.checkCommands(commands, inputs);
    }

    // ---- _checkCommands: shape checks ----

    function test_checkCommands_rejectsEmptyBatch() public {
        vm.expectRevert(AtpExecutor.BadCommands.selector);
        executor.checkCommands(new bytes(0), new bytes[](0));
    }

    function test_checkCommands_rejectsInputCountMismatch() public {
        bytes memory commands = abi.encodePacked(V3_SWAP_EXACT_IN, V3_SWAP_EXACT_IN);
        vm.expectRevert(AtpExecutor.BadCommands.selector);
        executor.checkCommands(commands, _one(_v3SwapInput(address(executor), 1e18, 0)));
    }

    function test_checkCommands_rejectsTruncatedSwapInput() public {
        // 31 bytes: not even the first head word, so the recipient cannot be read.
        bytes[] memory inputs = _one(new bytes(31));
        vm.expectRevert(AtpExecutor.BadCommands.selector);
        executor.checkCommands(_command(V3_SWAP_EXACT_IN), inputs);
    }

    function test_checkCommands_rejectsTruncatedSweepInput() public {
        bytes[] memory inputs = _one(abi.encode(PATH_TOKEN_IN));
        vm.expectRevert(AtpExecutor.BadCommands.selector);
        executor.checkCommands(_command(SWEEP), inputs);
    }

    // ---- _minGross: fee gross-up ----

    function test_minGross_grossesTheFloorBackOverTheFee() public view {
        // ceil(10000 * 10000 / 9950) = ceil(10050.25...) = 10051
        assertEq(executor.minGross(10_000, 50), 10_051);
    }

    function test_minGross_isIdentityWithoutFee() public view {
        assertEq(executor.minGross(100, 0), 100);
    }

    function test_minGross_roundsUpAnyRemainder() public view {
        // ceil(1 * 10000 / 9999) = 2
        assertEq(executor.minGross(1, 1), 2);
        // ceil(100 * 10000 / 9900) = 102
        assertEq(executor.minGross(100, 100), 102);
    }

    function test_minGross_rejectsFeeAtOrAboveOneHundredPercent() public {
        vm.expectRevert(abi.encodeWithSelector(AtpExecutor.FeeTooHigh.selector, uint256(10_000)));
        executor.minGross(10_000, 10_000);

        vm.expectRevert(abi.encodeWithSelector(AtpExecutor.FeeTooHigh.selector, uint256(65_535)));
        executor.minGross(10_000, type(uint16).max);
    }

    // ---- constructor ----

    function test_constructor_rejectsConfigWithoutCode() public {
        AtpRegistry freshRegistry = new AtpRegistry();
        MockOracleFloor oracleStub = new MockOracleFloor();
        // Build every stub first: `vm.expectRevert` binds to the very next external call.
        vm.expectRevert(AtpExecutor.InvalidConfig.selector);
        new AtpExecutorHarness(freshRegistry, IUniversalRouter(address(0)), oracleStub, FEE_RECIPIENT);
    }

    function test_constructor_rejectsZeroFeeRecipient() public {
        MockUniversalRouter routerStub = new MockUniversalRouter();
        MockOracleFloor oracleStub = new MockOracleFloor();
        vm.expectRevert(AtpExecutor.InvalidConfig.selector);
        new AtpExecutorHarness(registry, routerStub, oracleStub, address(0));
    }
}
