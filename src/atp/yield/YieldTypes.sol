// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

library YieldTypes {
    enum Kind {
        NONE,
        VENUS,
        LISTA,
        AAVE
    }

    struct Market {
        uint256 chainId;
        Kind kind;
        address asset;
        address receipt;
        address target;
        address riskSource;
        bytes32 configuration;
        uint256 minRate;
        uint256 maxRate;
        bool supplyEnabled;
        bool retired;
    }

    struct Health {
        uint256 supply;
        uint256 liquidity;
        uint256 utilizationBps;
        bytes32 configuration;
    }
}
