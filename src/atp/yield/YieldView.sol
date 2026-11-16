// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { YieldTypes as Y } from "./YieldTypes.sol";
import { YieldReader } from "./YieldReader.sol";

/// @notice Stateless, linked view library. No storage, approvals, protocol mutations or administration.
/// The linked address is fixed in bytecode; registry storage and every admission decision stay there.
library YieldView {
    function validate(Y.Market memory m) public view {
        YieldReader.validate(m);
    }

    function identity(Y.Market memory m) public view returns (bytes32) {
        return YieldReader.identity(m);
    }

    function rate(Y.Market memory m) public view returns (uint256) {
        return YieldReader.rate(m);
    }

    function units(Y.Market memory m, address account) public view returns (uint256) {
        return YieldReader.units(m, account);
    }

    function assets(Y.Market memory m, uint256 shares, bool roundUp) public view returns (uint256) {
        return YieldReader.assets(m, shares, roundUp);
    }

    function quoteSupply(Y.Market memory m, address account, uint256 amount) public view returns (uint256) {
        return YieldReader.quoteSupply(m, account, amount);
    }

    function quoteWithdraw(Y.Market memory m, uint256 shares) public view returns (uint256) {
        return YieldReader.quoteWithdraw(m, shares);
    }

    function supplyCapacity(Y.Market memory m, address account) public view returns (uint256) {
        return YieldReader.supplyCapacity(m, account);
    }

    function health(Y.Market memory m) public view returns (Y.Health memory) {
        return YieldReader.health(m);
    }

    function rateAcceptable(Y.Market memory m, uint256 current, uint256 previousRate, uint256 observedAt)
        public
        view
        returns (bool)
    {
        uint256 supply = IERC20(m.receipt).totalSupply();
        uint256 rounding = Math.ceilDiv(previousRate, Math.max(supply, 1));
        uint256 growth = Math.mulDiv(previousRate, block.timestamp - observedAt, 365 days, Math.Rounding.Ceil);
        return current >= m.minRate && current <= m.maxRate && current >= previousRate
            && current <= previousRate + growth + rounding;
    }
}
