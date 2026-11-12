// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IOracleFloor } from "./interfaces/IOracleFloor.sol";
import { PancakeV3TwapOracle } from "./PancakeV3TwapOracle.sol";

/// @title AtpMultiPoolOracle
/// @notice `IOracleFloor` router: one numeraire, one `PancakeV3TwapOracle` per asset, forwarded per call.
/// @dev `AtpExecutor` pins a single immutable `oracle`, and `PancakeV3TwapOracle` pins a single pool, so a
/// stack built from exactly those two contracts can only ever rebalance the one pair that pool holds.
/// Neither link is actually single-pair by nature: `IOracleFloor.previewSwap` is already pair-agnostic (it
/// takes both legs as arguments) and `PancakeV3TwapOracle`'s constructor is generic (pool, tokenA, tokenB),
/// so "one instance per pair" is a deployment choice, not a limitation of either contract. This contract is
/// the missing indirection: a registry from `asset -> per-pair oracle` that answers a quote by forwarding to
/// the right instance. A new index asset then costs one `setOracle` call instead of a redeploy of the
/// money-handling executor, and the TWAP math stays in the one contract whose tests already pin it.
///
/// Scope: v1 prices only the two paths that pass through `numeraire` - `asset -> numeraire` and
/// `numeraire -> asset`. A route where neither leg is the numeraire (`assetA -> assetB`, i.e. a multi-hop
/// route through the numeraire) reverts with `UnsupportedRoute` rather than inventing a path no registered
/// pool prices. The executor consumes the floor as a per-step bound, so refusing an unpriceable step is the
/// fail-closed answer; composing hops needs an explicit route argument in `IOracleFloor`, which is a
/// different change than this one and not something to approximate here.
///
/// Value: this is a read-only quote router and is deliberately built so that it cannot become a second entry
/// point for funds. It has no payable function, no `receive`, no `fallback`, no `transfer` / `transferFrom` /
/// `approve`, and no `call` / `delegatecall`; every outbound call it can make goes through a `view` on a
/// typed interface, which the compiler emits as STATICCALL, so even a hostile implementation behind
/// `PancakeV3TwapOracle` cannot be used to write state from here. It holds no balance and grants no
/// allowance, and the only call the executor ever makes on it is `previewSwap`.
///
/// Access: `owner` is a Safe on mainnet and hands over in two steps, matching `AtpRegistry`. `setOracle`
/// never accepts an oracle address: it deploys the `PancakeV3TwapOracle` itself from (pool, window,
/// slippage, age), so the only code this router ever forwards to is the audited TWAP contract. Even the
/// owner cannot plug in a look-alike that answers `token0` / `token1` correctly but returns a zero-discount
/// floor. The oracle's pair is immutable and its constructor checks the pool holds exactly
/// {asset, numeraire}, so a registration can never be re-pointed at the wrong pool.
contract AtpMultiPoolOracle is IOracleFloor {
    // ---- configuration ----

    /// @notice The quote asset every registered pair must contain (for example USDT).
    address public immutable numeraire;
    /// @notice Admin allowed to register and clear per-asset oracles.
    address public owner;
    /// @notice Proposed next owner; becomes `owner` only when it calls `acceptOwnership`.
    address public pendingOwner;
    /// @dev asset -> the per-pair oracle that prices `asset` against `numeraire`.
    mapping(address asset => PancakeV3TwapOracle oracle) private _oracles;

    // ---- events ----

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OracleSet(address indexed asset, address indexed oracle);
    event OracleCleared(address indexed asset);

    // ---- errors ----

    error NotOwner();
    error NotPendingOwner();
    error ZeroAddress();
    /// @dev The numeraire must be a contract: a quote asset without code is a typo, and every quote against
    /// it would revert downstream rather than here.
    error InvalidNumeraire();
    /// @dev Registering the numeraire against itself; there is no such pair.
    error NumeraireAsAsset();
    /// @dev The asset already has an oracle; `clearOracle` first so replacing a live oracle is deliberate.
    error OracleAlreadySet(address asset);
    error OracleNotSet(address asset);
    /// @dev Both legs are the same token. This is also the `numeraire -> numeraire` case: there is exactly
    /// one numeraire, so a pair with both legs on the numeraire collapses into this check.
    error SameToken();
    /// @dev Neither leg is the numeraire: a multi-hop route, which v1 does not price.
    error UnsupportedRoute(address tokenIn, address tokenOut);

    /// @param numeraire_ Quote asset every registered pair is priced against.
    constructor(address numeraire_) {
        if (numeraire_ == address(0) || numeraire_.code.length == 0) revert InvalidNumeraire();
        numeraire = numeraire_;
        owner = msg.sender;
        emit OwnershipTransferred(address(0), msg.sender);
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    // ---- IOracleFloor ----

    /// @inheritdoc IOracleFloor
    /// @dev Pure routing, no math: the numeraire leg identifies the asset, the asset's registered oracle
    /// answers, and that answer is returned unchanged. The quote is therefore bit-identical to calling the
    /// pair oracle directly - no re-derivation, no re-rounding, no second slippage discount - which is what
    /// keeps the TWAP and sandwich-floor semantics audited in exactly one contract.
    /// @dev Reverts on: the same token on both legs (`SameToken`, covering `numeraire -> numeraire`), a
    /// route with no numeraire leg (`UnsupportedRoute`, multi-hop is not priced), an asset with no
    /// registration (`OracleNotSet`, never a zero quote as a stand-in for "unknown"). `amountIn == 0` is
    /// rejected by the pair oracle (`ZeroAmount`), so `IOracleFloor`'s zero-input rule still holds on every
    /// path this contract admits.
    function previewSwap(address tokenIn, address tokenOut, uint256 amountIn)
        external
        view
        returns (uint256 quoted, uint256 minimum)
    {
        if (tokenIn == tokenOut) revert SameToken();

        // Exactly one leg must be the numeraire. `tokenIn != tokenOut` above means at most one branch matches.
        address asset;
        if (tokenOut == numeraire) {
            asset = tokenIn;
        } else if (tokenIn == numeraire) {
            asset = tokenOut;
        } else {
            revert UnsupportedRoute(tokenIn, tokenOut);
        }

        PancakeV3TwapOracle oracle = _oracles[asset];
        if (address(oracle) == address(0)) revert OracleNotSet(asset);

        // The pair is re-checked against `tokenIn` / `tokenOut` by the oracle itself; the registration check
        // guarantees that pair is exactly `asset` / `numeraire`, so this forward cannot price a third token.
        return oracle.previewSwap(tokenIn, tokenOut, amountIn);
    }

    // ---- registry ----

    /// @notice The per-pair oracle registered for `asset`, or the zero address when there is none.
    function oracleOf(address asset) external view returns (PancakeV3TwapOracle) {
        return _oracles[asset];
    }

    /// @notice Deploy and register the TWAP oracle that prices `asset` against `numeraire` from `pool`.
    /// @dev The oracle is created here, never supplied, so a registration is always the audited
    /// `PancakeV3TwapOracle`. Its constructor rejects a pool that does not hold exactly {asset, numeraire}
    /// and out-of-range window / slippage / age parameters, so those checks are not repeated here.
    /// @dev Re-registering an existing asset reverts with `OracleAlreadySet` instead of overwriting: swapping
    /// the oracle that prices a live index is a deliberate act, so it takes an explicit `clearOracle` first.
    function setOracle(
        address asset,
        address pool,
        uint32 twapWindow,
        uint16 maxSlippageBps,
        uint32 maxOracleAge
    ) external onlyOwner returns (PancakeV3TwapOracle oracle) {
        if (asset == address(0) || pool == address(0)) revert ZeroAddress();
        if (asset == numeraire) revert NumeraireAsAsset();
        if (address(_oracles[asset]) != address(0)) revert OracleAlreadySet(asset);

        oracle = new PancakeV3TwapOracle(pool, asset, numeraire, twapWindow, maxSlippageBps, maxOracleAge);
        _oracles[asset] = oracle;
        emit OracleSet(asset, address(oracle));
    }

    /// @notice Remove `asset`'s oracle, making that asset unquotable until a new one is registered.
    /// @dev Exists so that `setOracle` can refuse to overwrite: retiring a live oracle is then two explicit
    /// statements instead of one accidental one, and the gap in between fails closed with `OracleNotSet`.
    function clearOracle(address asset) external onlyOwner {
        if (address(_oracles[asset]) == address(0)) revert OracleNotSet(asset);
        delete _oracles[asset];
        emit OracleCleared(asset);
    }

    // ---- admin ----

    /// @notice Propose `next` as the new owner; nothing changes until `next` calls `acceptOwnership`.
    /// Proposing `address(0)` cancels a pending handover.
    function transferOwnership(address next) external onlyOwner {
        pendingOwner = next;
        emit OwnershipTransferStarted(owner, next);
    }

    /// @notice Complete a handover started by `transferOwnership`; callable only by the proposed owner.
    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        emit OwnershipTransferred(owner, msg.sender);
        owner = msg.sender;
        pendingOwner = address(0);
    }
}
