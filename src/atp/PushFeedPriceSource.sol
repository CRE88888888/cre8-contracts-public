// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { IAggregatorV3 } from "./interfaces/IAggregatorV3.sol";
import { IPriceSource } from "./interfaces/IPriceSource.sol";

/// @title PushFeedPriceSource
/// @notice `IPriceSource` over two USD push feeds (Chainlink or RedStone Push, AggregatorV3 interface):
/// asset/USD divided by numeraire/USD, so the numeraire is never assumed to be worth exactly 1 USD.
/// @dev Deployed only by `AtpMultiPoolOracle.setSecondary`, never supplied. Both feeds must be fresh
/// (`updatedAt` within `maxAge`, not in the future) and positive, otherwise `price()` reverts.
/// Only for assets whose token IS the feed's underlying (WBNB vs BNB/USD, BTCB vs BTC/USD, ...). A wrapped
/// stock (bStock) is not: its token-per-share multiplier is not 1 for many issues (docs#28), so an equity
/// feed must not be wired here.
contract PushFeedPriceSource is IPriceSource {
    /// @notice Bounds for `maxAge`: below a minute every block would be "stale" on a slow feed, above a day
    /// the check stops meaning anything.
    uint32 public constant MIN_MAX_AGE = 1 minutes;
    uint32 public constant MAX_MAX_AGE = 1 days;

    IAggregatorV3 public immutable assetFeed;
    IAggregatorV3 public immutable numeraireFeed;
    uint32 public immutable maxAge;
    /// @dev 10 ** (18 - feed decimals), so both feeds read as 18-decimal USD.
    uint256 internal immutable _assetFeedScale;
    uint256 internal immutable _numeraireFeedScale;
    /// @dev 10 ** numeraire decimals and 10 ** asset decimals, folding token units into the price.
    uint256 internal immutable _numeraireUnit;
    uint256 internal immutable _assetUnit;

    error InvalidConfig();
    error InvalidAnswer(address feed, int256 answer);
    error StaleFeed(address feed, uint256 updatedAt);

    constructor(
        IAggregatorV3 assetFeed_,
        IAggregatorV3 numeraireFeed_,
        address asset,
        address numeraire,
        uint32 maxAge_
    ) {
        if (
            address(assetFeed_).code.length == 0 || address(numeraireFeed_).code.length == 0
                || address(assetFeed_) == address(numeraireFeed_) || maxAge_ < MIN_MAX_AGE
                || maxAge_ > MAX_MAX_AGE
        ) revert InvalidConfig();
        uint8 assetFeedDecimals = assetFeed_.decimals();
        uint8 numeraireFeedDecimals = numeraireFeed_.decimals();
        uint8 assetDecimals = IERC20Metadata(asset).decimals();
        uint8 numeraireDecimals = IERC20Metadata(numeraire).decimals();
        if (
            assetFeedDecimals > 18 || numeraireFeedDecimals > 18 || assetDecimals > 36
                || numeraireDecimals > 36
        ) {
            revert InvalidConfig();
        }

        assetFeed = assetFeed_;
        numeraireFeed = numeraireFeed_;
        maxAge = maxAge_;
        _assetFeedScale = 10 ** (18 - assetFeedDecimals);
        _numeraireFeedScale = 10 ** (18 - numeraireFeedDecimals);
        _numeraireUnit = 10 ** numeraireDecimals;
        _assetUnit = 10 ** assetDecimals;
    }

    /// @inheritdoc IPriceSource
    /// @dev price = (assetUsd / numeraireUsd) * 10^numeraireDecimals / 10^assetDecimals * 1e18, i.e. numeraire
    /// raw units per 1e18 asset raw units. Rounded down; the router applies its own direction-aware rounding.
    function price() external view returns (uint256) {
        uint256 assetUsd = _read(assetFeed) * _assetFeedScale;
        uint256 numeraireUsd = _read(numeraireFeed) * _numeraireFeedScale;
        return Math.mulDiv(Math.mulDiv(assetUsd, _numeraireUnit, numeraireUsd), 1e18, _assetUnit);
    }

    function _read(IAggregatorV3 feed) internal view returns (uint256) {
        (, int256 answer,, uint256 updatedAt,) = feed.latestRoundData();
        if (answer <= 0) revert InvalidAnswer(address(feed), answer);
        if (updatedAt == 0 || updatedAt > block.timestamp || block.timestamp - updatedAt > maxAge) {
            revert StaleFeed(address(feed), updatedAt);
        }
        return uint256(answer);
    }
}
