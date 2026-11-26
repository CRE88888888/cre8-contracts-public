// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice One supply venue kind behind the routing executor (ERC4626 / Venus vToken / Aave v3).
/// Adapters are stateless, hold nothing between calls and only obey the executor. Receipts (vault shares,
/// vTokens, aTokens) always sit in the account's strategy box (`holder`), which approves the adapter for them.
interface IStrategyVaultAdapter {
    /// @notice The `RoutingTypes.VaultKind` this adapter serves.
    function kind() external view returns (uint8);

    /// @notice Check that `target` really is a vault of this kind for `token`; returns its receipt token.
    function validate(address target, address token) external view returns (address receipt);

    /// @notice Executor only. The executor has transferred `assets` of `token` to this adapter; supply them for
    /// `holder`. Returns the value added to the holder's position in `token` raw units (>= assets - rounding).
    function deposit(address target, address token, uint256 assets, address holder) external returns (uint256);

    /// @notice Executor only. Take up to `assets` of `token` out of `holder`'s position and send them to `to`
    /// (`type(uint256).max` = everything). A holding smaller than `assets` is paid out whole instead of
    /// reverting, and `to` may receive slightly more than asked where the adapter prices shares from a stored
    /// total. Reverts only when the venue itself cannot pay. Returns what `to` received.
    function withdraw(address target, address token, uint256 assets, address holder, address to)
        external
        returns (uint256 received);

    /// @notice Accrue the venue so the reads below are current (no-op where not needed).
    function accrue(address target, address token) external;

    /// @notice What `holder`'s position is worth now in `token` raw units, rounded down.
    function assetsOf(address target, address token, address holder) external view returns (uint256);

    /// @notice Yearly supply rate (18 decimals) when the protocol publishes it on chain.
    function supplyRate(address target, address token) external view returns (bool known, uint256 rate);

    /// @notice Utilization of the pool behind the vault in bps, when it can be read cheaply on chain.
    function utilizationBps(address target, address token) external view returns (bool known, uint256 bps);
}
