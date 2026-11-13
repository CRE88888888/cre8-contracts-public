// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IPriceSource
/// @notice An independent price for one asset against the numeraire, used by `AtpMultiPoolOracle` as a second
/// opinion next to the asset's pool TWAP (cre8-contracts#15 §2).
/// @dev Units: numeraire raw units per 1e18 raw units of the asset, decimals of both tokens already folded in,
/// so `amountOut = amountIn * price / 1e18` for a sale and `amountIn * 1e18 / price` for a buy.
/// MUST revert, never return a stand-in value, when the underlying data is stale, non-positive or otherwise
/// unusable: the router treats a revert as "no trade" (fail closed).
interface IPriceSource {
    function price() external view returns (uint256 numerairePerAssetE18);
}
