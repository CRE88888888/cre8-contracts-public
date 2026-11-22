// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

interface IUnderlying {
    function underlying() external view returns (address);
}

/// @notice Chain-97-only lending oracle (#64). The owner sets each asset's USD price, so a liquidation can be
/// rehearsed by marking collateral down. Serves both read shapes: Lista `peek(asset)` (8 decimals per whole
/// token) and Venus `getUnderlyingPrice(vToken)` (scaled so `price * raw / 1e18` is USD with 18 decimals).
/// It does not follow the Pancake pools; the owner moves it on purpose.
contract MockLendingOracle {
    address public immutable owner;
    mapping(address => uint256) public prices;

    event PriceSet(address indexed asset, uint256 priceE8);

    constructor(address owner_) {
        require(block.chainid == 97, "lending mock: chain 97 only");
        require(owner_ != address(0), "lending mock: config");
        owner = owner_;
    }

    function isTestnetLendingMock() external pure returns (bool) {
        return true;
    }

    function setPrice(address asset, uint256 priceE8) external {
        require(msg.sender == owner, "lending mock: owner only");
        require(asset.code.length != 0, "lending mock: asset");
        prices[asset] = priceE8;
        emit PriceSet(asset, priceE8);
    }

    function peek(address asset) public view returns (uint256 price) {
        price = prices[asset];
        require(price != 0, "lending mock: no price");
    }

    function getUnderlyingPrice(address vToken) external view returns (uint256) {
        address asset = IUnderlying(vToken).underlying();
        return peek(asset) * 1e10 * 10 ** (18 - uint256(IERC20Metadata(asset).decimals()));
    }
}
