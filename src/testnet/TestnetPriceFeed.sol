// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IAggregatorV3 } from "../atp/interfaces/IAggregatorV3.sol";

/// @title TestnetPriceFeed
/// @notice TESTNET ONLY (chain 97; cre8-contracts#30). A push feed with the Chainlink AggregatorV3 read shape,
/// standing in for the asset/USD and USDT/USD feeds behind `PushFeedPriceSource`. Only the `keeper` pushes
/// prices; `owner` (the testnet deployer) only appoints the keeper. A feed the keeper stops pushing goes stale
/// exactly like a real one, so the router's fail-closed paths (stale, zero, negative) can be exercised on
/// purpose.
/// @dev Not an independent oracle: the same platform runs the pools and this feed. Never wire it on mainnet;
/// `script/DeployTestnet.s.sol` only runs on chain 97.
contract TestnetPriceFeed is IAggregatorV3 {
    struct Round {
        int256 answer;
        uint64 updatedAt;
    }

    uint8 public immutable decimals;
    string public description;
    uint256 public constant version = 1;

    address public owner;
    address public keeper;
    uint80 public latestRound;
    mapping(uint80 => Round) internal _rounds;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event KeeperSet(address indexed keeper);
    event AnswerUpdated(int256 indexed current, uint256 indexed roundId, uint256 updatedAt);

    error NotOwner();
    error NotKeeper();
    error ZeroAddress();
    error NoRound();

    /// @param initialAnswer First round, stamped at deployment, so the feed is live from the start and goes
    /// stale on the same clock as any other round.
    constructor(
        uint8 decimals_,
        string memory description_,
        address owner_,
        address keeper_,
        int256 initialAnswer
    ) {
        if (owner_ == address(0) || keeper_ == address(0)) revert ZeroAddress();
        decimals = decimals_;
        description = description_;
        owner = owner_;
        keeper = keeper_;
        emit OwnershipTransferred(address(0), owner_);
        emit KeeperSet(keeper_);
        _push(initialAnswer);
    }

    function transferOwnership(address next) external {
        if (msg.sender != owner) revert NotOwner();
        if (next == address(0)) revert ZeroAddress();
        emit OwnershipTransferred(owner, next);
        owner = next;
    }

    function setKeeper(address next) external {
        if (msg.sender != owner) revert NotOwner();
        if (next == address(0)) revert ZeroAddress();
        keeper = next;
        emit KeeperSet(next);
    }

    /// @notice Publish a new round at the current block time. Any value is accepted (zero and negative too), so
    /// failure drills need no special mode; the consumer is what must reject them.
    function push(int256 answer) external {
        if (msg.sender != keeper) revert NotKeeper();
        _push(answer);
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return getRoundData(latestRound);
    }

    function getRoundData(uint80 roundId) public view returns (uint80, int256, uint256, uint256, uint80) {
        Round memory r = _rounds[roundId];
        if (r.updatedAt == 0) revert NoRound();
        return (roundId, r.answer, r.updatedAt, r.updatedAt, roundId);
    }

    function latestAnswer() external view returns (int256) {
        return _rounds[latestRound].answer;
    }

    function _push(int256 answer) internal {
        uint80 roundId = latestRound + 1;
        latestRound = roundId;
        _rounds[roundId] = Round(answer, uint64(block.timestamp));
        emit AnswerUpdated(answer, roundId, block.timestamp);
    }
}
