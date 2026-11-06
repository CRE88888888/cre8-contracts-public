// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Script, console } from "forge-std/Script.sol";
import { AtpRegistry } from "../src/atp/AtpRegistry.sol";
import { AtpExecutor } from "../src/atp/AtpExecutor.sol";
import { PancakeV3TwapOracle } from "../src/atp/PancakeV3TwapOracle.sol";
import { IUniversalRouter } from "../src/atp/interfaces/IUniversalRouter.sol";
import { IOracleFloor } from "../src/atp/interfaces/IOracleFloor.sol";

/// @dev Minimal PancakeSwap V3 factory: `getPool` is the only call this script makes to it.
interface IV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool);
}

/// @title DeployAtp
/// @notice Deploys the three ATP contracts against BSC mainnet (chain 56) addresses. The pool is
/// resolved at runtime through the PancakeSwap V3 factory, so a fork of any block height that has the
/// WBNB/USDT 0.05% pool deploys identically.
contract DeployAtp is Script {
    // ---- BSC mainnet (chain 56) pins ----
    address internal constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address internal constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address internal constant V3_FACTORY = 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865;
    address internal constant V3_UNIVERSAL_ROUTER = 0x1A0A18AC4BECDDbd6389559687d1A73d8927E416;
    address internal constant PERMIT2 = 0x31c2F6fcFf4F8759b3Bd5Bf0e1084A055615c768;

    uint24 internal constant PREFERRED_FEE = 500;
    uint24 internal constant FALLBACK_FEE = 2500;

    // ---- oracle config (matches the fork suite) ----
    uint32 internal constant TWAP_WINDOW = 30 minutes;
    uint16 internal constant MAX_SLIPPAGE_BPS = 100;
    uint32 internal constant MAX_ORACLE_AGE = 3600;

    function run() external {
        vm.startBroadcast();

        // 1. Registry (owner = deployer)
        AtpRegistry registry = new AtpRegistry();

        // 2. Oracle: resolve the WBNB/USDT pool through the factory, fall back to 0.25% if 0.05% is absent.
        address pool = IV3Factory(V3_FACTORY).getPool(WBNB, USDT, PREFERRED_FEE);
        uint24 usedFee = PREFERRED_FEE;
        if (pool == address(0)) {
            pool = IV3Factory(V3_FACTORY).getPool(WBNB, USDT, FALLBACK_FEE);
            usedFee = FALLBACK_FEE;
        }
        require(pool != address(0), "no WBNB/USDT pool at 500 or 2500");

        PancakeV3TwapOracle oracle =
            new PancakeV3TwapOracle(pool, WBNB, USDT, TWAP_WINDOW, MAX_SLIPPAGE_BPS, MAX_ORACLE_AGE);

        // 3. Executor (fee recipient = deployer for the fork; point it at a treasury before mainnet).
        AtpExecutor executor = new AtpExecutor(
            registry, IUniversalRouter(V3_UNIVERSAL_ROUTER), IOracleFloor(address(oracle)), PERMIT2, msg.sender
        );

        vm.stopBroadcast();

        console.log("registry", address(registry));
        console.log("oracle", address(oracle));
        console.log("executor", address(executor));
        console.log("pool", pool);
        console.log("poolFee", usedFee);
        console.log("router", V3_UNIVERSAL_ROUTER);
        console.log("permit2", PERMIT2);
    }
}
