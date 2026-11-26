// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import { TestnetToken } from "../../src/testnet/TestnetToken.sol";
import { MockVenus } from "../../src/testnet/yield/MockVenus.sol";
import { MockLista } from "../../src/testnet/yield/MockLista.sol";
import { MockAavePool } from "../../src/testnet/yield/MockAavePool.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

// Deliberately hostile protocol fixtures. None of these controls exist in deployed testnet mocks.
contract AdversarialVenus is MockVenus {
    constructor(TestnetToken asset, address admin, uint16 apr) MockVenus(asset, admin, apr) { }

    function setExchangeRate(uint256 r) external {
        exchangeRateStored = r;
    }

    function setReserves(uint256 r) external {
        accrueInterest();
        totalReserves = r;
        exchangeRateStored = Math.mulDiv(getCash() + totalBorrows - r, 1e18, totalSupply());
    }

    function setErrorCodes(uint256 a, uint256 b) external {
        mintError = a;
        redeemError = b;
    }

    function setSupplyCap(uint256 c) external {
        supplyCapAssets = c;
    }
}

contract AdversarialLista is MockLista {
    constructor(TestnetToken asset, address admin, uint16 apr) MockLista(asset, admin, apr) { }

    function setFee(uint96 f) external {
        fee = f;
    }

    function setExitFeeBps(uint16 f) external {
        exitFeeBps = f;
    }

    function setRiskCore(address c) external {
        riskCore = c;
    }

    function setSupplyCap(uint256 c) external {
        supplyCapAssets = c;
    }
}

contract AdversarialAave is MockAavePool {
    constructor(TestnetToken asset, address admin, uint16 apr) MockAavePool(asset, admin, apr) { }

    function setSupplyCap(uint256 c) external {
        supplyCapWhole = c;
    }
}
