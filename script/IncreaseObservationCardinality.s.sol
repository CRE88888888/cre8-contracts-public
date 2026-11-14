// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Script, console } from "forge-std/Script.sol";
import { IPancakeV3Pool } from "../src/atp/interfaces/IPancakeV3Pool.sol";
import { AtpMainnetSpecs } from "./AtpMainnetSpecs.sol";

/// @dev The one pool write this script makes. Permissionless on every Pancake V3 pool: the caller pays the
/// gas to pre-allocate observation slots, nothing else changes.
interface IPancakeV3PoolCardinality {
    function increaseObservationCardinalityNext(uint16 observationCardinalityNext) external;
}

/// @title IncreaseObservationCardinality
/// @notice Pre-launch step (cre8-contracts#25, review M-2): raise every launch pool's
/// `observationCardinalityNext` to `MIN_OBSERVATION_CARDINALITY` (2,400) so no burst of swaps can push the
/// 30 minute TWAP lookback out of the pool's ring buffer. `DeployAtpMainnet._verify` refuses to deploy until
/// this has been done.
///
/// @dev Run by the user on BSC mainnet, from any funded wallet (it does not need to be the deployer, and using
/// a different wallet keeps the deployer's nonce untouched). Only pools below the target are touched, so
/// re-running it is a no-op. Without `--broadcast` it only simulates and prints what it would send.
///
///   forge script script/IncreaseObservationCardinality.s.sol --rpc-url <BSC> [--broadcast --account <wallet>]
///
/// Each new slot is one storage write (about 22k gas), so raising a pool from 10 to 2,400 costs about 53M gas.
/// Slots are added in steps of at most `MAX_SLOTS_PER_TX` per transaction to stay far below the block gas
/// limit. The new slots only come into use the next time the pool's ring buffer wraps, so a pool that was at
/// 10 needs some trading (and then 30 minutes) before its 30 minute TWAP is servable; `DeployAtpMainnet` reports
/// such a pool as fail-closed instead of failing.
contract IncreaseObservationCardinality is Script, AtpMainnetSpecs {
    /// @dev About 22M gas per transaction.
    uint16 internal constant MAX_SLOTS_PER_TX = 1_000;

    function run() external {
        require(block.chainid == 56, "IncreaseObservationCardinality: BSC mainnet (56) only");
        OracleSpec[] memory specs = _oracleSpecs();

        uint256 txs;
        uint256 slots;
        vm.startBroadcast();
        for (uint256 i; i < specs.length; ++i) {
            IPancakeV3Pool pool = IPancakeV3Pool(specs[i].pool);
            (,,, uint16 cardinality, uint16 next,,) = pool.slot0();
            console.log(
                string.concat(
                    specs[i].symbol,
                    "  pool ",
                    vm.toString(specs[i].pool),
                    "  cardinality ",
                    vm.toString(uint256(cardinality)),
                    "  next ",
                    vm.toString(uint256(next))
                )
            );
            while (next < MIN_OBSERVATION_CARDINALITY) {
                uint16 target = MIN_OBSERVATION_CARDINALITY - next > MAX_SLOTS_PER_TX
                    ? next + MAX_SLOTS_PER_TX
                    : MIN_OBSERVATION_CARDINALITY;
                IPancakeV3PoolCardinality(specs[i].pool).increaseObservationCardinalityNext(target);
                console.log(
                    string.concat(
                        "    -> increaseObservationCardinalityNext(", vm.toString(uint256(target)), ")"
                    )
                );
                slots += target - next;
                next = target;
                ++txs;
            }
        }
        vm.stopBroadcast();

        for (uint256 i; i < specs.length; ++i) {
            (,,,, uint16 next,,) = IPancakeV3Pool(specs[i].pool).slot0();
            require(
                next >= MIN_OBSERVATION_CARDINALITY,
                string.concat("cardinalityNext still low: ", specs[i].symbol)
            );
        }
        console.log(
            string.concat(
                "transactions ",
                vm.toString(txs),
                ", new observation slots ",
                vm.toString(slots),
                "; every pool now has observationCardinalityNext >= ",
                vm.toString(uint256(MIN_OBSERVATION_CARDINALITY))
            )
        );
    }
}
