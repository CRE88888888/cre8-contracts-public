// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { IOracleFloor } from "./interfaces/IOracleFloor.sol";
import { IAggregatorV3 } from "./interfaces/IAggregatorV3.sol";
import { IPriceSource } from "./interfaces/IPriceSource.sol";
import { PancakeV3TwapOracle } from "./PancakeV3TwapOracle.sol";
import { PushFeedPriceSource } from "./PushFeedPriceSource.sol";

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
///
/// Secondary source (cre8-contracts#15 §2): an asset may additionally carry one independent `IPriceSource`
/// (today `PushFeedPriceSource` over Chainlink / RedStone Push USD feeds), likewise deployed here from feed
/// addresses, never supplied. When present, every quote must agree with it within `maxDeviationBps` and the
/// floor becomes the stricter of the two; a stale or unusable secondary reverts the quote instead of being
/// skipped. Assets without a secondary keep the pool TWAP alone, exactly as before.
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

    /// @notice Upper bound for a secondary's `maxDeviationBps` (10%).
    uint16 public constant MAX_DEVIATION_CEILING_BPS = 1_000;
    uint256 internal constant BPS = 10_000;

    struct Secondary {
        IPriceSource source;
        /// @notice Largest allowed gap between the pool TWAP quote and the secondary quote, in bps of the
        /// secondary quote.
        uint16 maxDeviationBps;
    }

    /// @dev asset -> optional independent second source.
    mapping(address asset => Secondary secondary) private _secondaries;

    // ---- events ----

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OracleSet(address indexed asset, address indexed oracle);
    event OracleCleared(address indexed asset);
    event SecondarySet(address indexed asset, address indexed source, uint16 maxDeviationBps);
    event SecondaryCleared(address indexed asset);

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
    error SecondaryAlreadySet(address asset);
    error SecondaryNotSet(address asset);
    error InvalidDeviation(uint16 maxDeviationBps);
    /// @dev The pool TWAP and the secondary source differ by more than the asset's `maxDeviationBps`.
    error SourcesDisagree(address asset, uint256 poolQuote, uint256 secondaryQuote);

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
        (quoted, minimum) = oracle.previewSwap(tokenIn, tokenOut, amountIn);

        Secondary memory secondary = _secondaries[asset];
        if (address(secondary.source) == address(0)) return (quoted, minimum);

        // Reverts when stale or unusable: no trade rather than a TWAP-only floor.
        uint256 price = secondary.source.price();
        uint256 secondaryQuote = tokenOut == numeraire
            ? Math.mulDiv(amountIn, price, 1e18)  // sale: asset -> numeraire
            : Math.mulDiv(amountIn, 1e18, price); // buy: numeraire -> asset
        uint256 gap = quoted > secondaryQuote ? quoted - secondaryQuote : secondaryQuote - quoted;
        if (secondaryQuote == 0 || gap * BPS > secondaryQuote * secondary.maxDeviationBps) {
            revert SourcesDisagree(asset, quoted, secondaryQuote);
        }
        // Same slippage budget as the pool floor, rounded up; the stricter (higher) floor wins.
        uint256 secondaryFloor =
            Math.mulDiv(secondaryQuote, BPS - oracle.maxSlippageBps(), BPS, Math.Rounding.Ceil);
        if (secondaryFloor > minimum) minimum = secondaryFloor;
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
        // A secondary belongs to the registration it was checked against; a new pool starts without one.
        if (address(_secondaries[asset].source) != address(0)) {
            delete _secondaries[asset];
            emit SecondaryCleared(asset);
        }
    }

    /// @notice The secondary source registered for `asset` (zero address when none) and its deviation bound.
    function secondaryOf(address asset) external view returns (IPriceSource source, uint16 maxDeviationBps) {
        Secondary memory secondary = _secondaries[asset];
        return (secondary.source, secondary.maxDeviationBps);
    }

    /// @notice Deploy and register a `PushFeedPriceSource` (asset/USD and numeraire/USD push feeds, Chainlink
    /// or RedStone Push) as `asset`'s secondary source.
    /// @dev The adapter is created here, never supplied. The asset must already have its pool oracle, and an
    /// existing secondary must be cleared first, like `setOracle`. Only for assets whose token is the feed's
    /// underlying: never an equity feed for a bStock (see `PushFeedPriceSource`).
    function setSecondary(
        address asset,
        IAggregatorV3 assetFeed,
        IAggregatorV3 numeraireFeed,
        uint32 maxAge,
        uint16 maxDeviationBps
    ) external onlyOwner returns (IPriceSource source) {
        if (address(_oracles[asset]) == address(0)) revert OracleNotSet(asset);
        if (address(_secondaries[asset].source) != address(0)) revert SecondaryAlreadySet(asset);
        if (maxDeviationBps == 0 || maxDeviationBps > MAX_DEVIATION_CEILING_BPS) {
            revert InvalidDeviation(maxDeviationBps);
        }
        source = new PushFeedPriceSource(assetFeed, numeraireFeed, asset, numeraire, maxAge);
        _secondaries[asset] = Secondary({ source: source, maxDeviationBps: maxDeviationBps });
        emit SecondarySet(asset, address(source), maxDeviationBps);
    }

    /// @notice Drop `asset`'s secondary source; the asset is then priced by its pool TWAP alone.
    function clearSecondary(address asset) external onlyOwner {
        if (address(_secondaries[asset].source) == address(0)) revert SecondaryNotSet(asset);
        delete _secondaries[asset];
        emit SecondaryCleared(asset);
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
