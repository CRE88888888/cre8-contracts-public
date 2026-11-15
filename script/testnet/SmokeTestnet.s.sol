// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Script, console } from "forge-std/Script.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { AtpRegistry } from "../../src/atp/AtpRegistry.sol";
import { AtpExecutor } from "../../src/atp/AtpExecutor.sol";
import { AtpMultiPoolOracle } from "../../src/atp/AtpMultiPoolOracle.sol";
import { TestnetUSDT } from "../../src/testnet/TestnetToken.sol";
import { TestnetAssets } from "./TestnetAssets.sol";
import { TestnetBook } from "./TestnetBook.sol";

/// @dev A minimal smart account for the smoke run: the executor requires `msg.sender == account` and code there.
contract SmokeAccount {
    address public immutable owner;

    constructor(address owner_) {
        owner = owner_;
    }

    function execute(address target, bytes calldata data) external returns (bytes memory ret) {
        require(msg.sender == owner, "owner");
        bool ok;
        (ok, ret) = target.call(data);
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
    }
}

/// @title SmokeTestnet
/// @notice Chain 97 acceptance run for cre8-contracts#30, after `DeployTestnet` and the 30-minute TWAP
/// warm-up. Since cre8-contracts#45 (no asset-count ceiling) it uses one strategy whose version holds USDT and
/// all 92 assets of cre8-contracts#39: one fresh contract account gets the faucet's welcome grant (sent by
/// OPERATOR, the faucet; cre8-contracts#47 removed the self-service claim), enrolls,
/// buys 100 USDT worth of every asset through the executor and the Pancake Universal Router, sells everything
/// back and withdraws its USDT. Buys and sales go in batches of `SMOKE_STEPS_PER_BATCH` steps (default 16), the
/// way the backend splits a large rebalance. The executor enforces the oracle floor (and, since #24,
/// `amountOutMin`) on every step; this script also prints each fill against its floor, and `SMOKE_TX <label>
/// <index>` for the transactions whose gas `fork-e2e.sh` reports (index into the broadcast's transactions). On a
/// public chain it spends real tBNB, so it is meant for the local fork unless a run on 97 is explicitly wanted.
/// Broadcasts from the run's sender and from OPERATOR (`fork-e2e.sh` impersonates both).
/// @dev `TESTNET_EXECUTOR` locates everything else: registry, router and USDT from the executor, the tokens
/// from `TestnetBook` (CREATE2 addresses of DEPLOYER).
contract SmokeTestnet is Script {
    uint256 internal constant TRADE_USDT = 100e18;
    /// @dev The faucet's welcome grant (`TestnetUSDT.WELCOME_AMOUNT`). 92 buys of 100 USDT (9,200) stay under the
    /// executor's buy cap, 100% of the account value per 24 hours (about 10,000 less fees and pool fees).
    uint256 internal constant CLAIM_USDT = 10_000e18;
    uint256 internal constant DEFAULT_STEPS_PER_BATCH = 16;
    uint256 internal constant BPS = 10_000;
    bytes1 internal constant V3_SWAP_EXACT_IN = 0x00;

    struct Env {
        AtpExecutor executor;
        AtpRegistry registry;
        AtpMultiPoolOracle router;
        TestnetUSDT usdt;
        SmokeAccount account;
        uint256 strategyId;
        uint16 feeBps;
        /// @dev Transactions broadcast so far; the next one has this index.
        uint256 txCount;
    }

    function run() external {
        require(block.chainid == 97, "SmokeTestnet: chain 97 only");
        uint256 perBatch = vm.envOr("SMOKE_STEPS_PER_BATCH", DEFAULT_STEPS_PER_BATCH);
        require(perBatch != 0, "SmokeTestnet: SMOKE_STEPS_PER_BATCH = 0");
        Env memory env;
        env.executor = AtpExecutor(vm.envAddress("TESTNET_EXECUTOR"));
        env.registry = env.executor.registry();
        env.router = AtpMultiPoolOracle(address(env.executor.oracle()));
        env.usdt = TestnetUSDT(env.executor.numeraire());
        TestnetAssets.AssetSpec[] memory specs = TestnetAssets.specs();
        address[] memory tokens = new address[](specs.length);
        for (uint256 i; i < specs.length; ++i) {
            tokens[i] = TestnetBook.tokenAddress(specs[i], TestnetBook.DEPLOYER);
            require(tokens[i].code.length != 0, string.concat(specs[i].symbol, ": token not deployed"));
        }

        vm.startBroadcast();
        env.account = new SmokeAccount(msg.sender);
        ++env.txCount;
        vm.stopBroadcast();
        require(env.usdt.WELCOME_AMOUNT() == CLAIM_USDT, "SmokeTestnet: welcome amount");
        vm.startBroadcast(TestnetBook.OPERATOR);
        env.usdt.welcomeFor(address(env.account));
        ++env.txCount;
        vm.stopBroadcast();
        vm.startBroadcast();
        _approve(env, address(env.usdt));
        _strategy(env, tokens);
        _call(
            env,
            address(env.registry),
            abi.encodeCall(AtpRegistry.enroll, (address(env.account), env.strategyId))
        );
        console.log("SMOKE account", address(env.account));
        console.log("SMOKE version assets (incl. USDT) / steps per batch", tokens.length + 1, perBatch);
        for (uint256 i; i < tokens.length; ++i) {
            _approve(env, tokens[i]);
        }

        uint256[] memory bought = new uint256[](tokens.length);
        for (uint256 from; from < tokens.length; from += perBatch) {
            _batch(env, specs, tokens, from, Math.min(from + perBatch, tokens.length), true, bought);
        }
        for (uint256 from; from < tokens.length; from += perBatch) {
            _batch(env, specs, tokens, from, Math.min(from + perBatch, tokens.length), false, bought);
        }
        uint256 left = env.usdt.balanceOf(address(env.account));
        // Exit: the owner moves the USDT out of its own account (never through the executor).
        _call(env, address(env.usdt), abi.encodeCall(IERC20.transfer, (msg.sender, left)));
        _mark(env, "exit_withdrawUsdt");
        vm.stopBroadcast();

        for (uint256 i; i < tokens.length; ++i) {
            require(
                IERC20(tokens[i]).balanceOf(address(env.account)) == 0,
                string.concat(specs[i].symbol, ": not fully sold")
            );
        }
        console.log("");
        console.log("SMOKE assets round-tripped", specs.length);
        console.log("SMOKE USDT claimed / left (wei)", CLAIM_USDT, left);
        console.log("SMOKE round-trip cost over all assets (USDT wei)", CLAIM_USDT - left);
    }

    /// @dev One `executeRebalance` over tokens[from, to): buys of `TRADE_USDT` each (`buy`), or sales of exactly
    /// what the buys returned. Every fill is checked against its floor and printed.
    function _batch(
        Env memory env,
        TestnetAssets.AssetSpec[] memory specs,
        address[] memory tokens,
        uint256 from,
        uint256 to,
        bool buy,
        uint256[] memory bought
    ) internal {
        uint256 count = to - from;
        AtpExecutor.SwapStep[] memory steps = new AtpExecutor.SwapStep[](count);
        uint256[] memory floors = new uint256[](count);
        uint256[] memory before = new uint256[](count);
        for (uint256 k; k < count; ++k) {
            uint256 i = from + k;
            (address tokenIn, address tokenOut) =
                buy ? (address(env.usdt), tokens[i]) : (tokens[i], address(env.usdt));
            uint256 amountIn = buy ? TRADE_USDT : bought[i];
            (, floors[k]) = env.router.previewSwap(tokenIn, tokenOut, amountIn);
            steps[k] = _step(
                env,
                tokenIn,
                tokenOut,
                specs[i].fee,
                amountIn,
                _minGross(floors[k], env.feeBps, specs[i].maxSlippageBps)
            );
            before[k] = buy ? IERC20(tokens[i]).balanceOf(address(env.account)) : 0;
        }
        uint256 usdtBefore = env.usdt.balanceOf(address(env.account));
        _call(
            env,
            address(env.executor),
            abi.encodeCall(AtpExecutor.executeRebalance, (address(env.account), steps, block.timestamp + 600))
        );
        string memory label = string.concat(
            buy ? "buy" : "sell",
            "_assets_",
            vm.toString(from + 1),
            "-",
            vm.toString(to),
            "_steps_",
            vm.toString(count)
        );
        _mark(env, label);

        if (buy) {
            for (uint256 k; k < count; ++k) {
                uint256 i = from + k;
                bought[i] = IERC20(tokens[i]).balanceOf(address(env.account)) - before[k];
                require(bought[i] >= floors[k], string.concat(specs[i].symbol, ": buy below floor"));
                console.log(
                    string.concat("SMOKE ", specs[i].symbol, " buy 100 USDT -> ", vm.toString(bought[i])),
                    string.concat("(floor ", vm.toString(floors[k]), ")")
                );
            }
        } else {
            // Every sale pays USDT, so per asset only the executor's own per-step check (gross >= amountOutMin
            // >= floor grossed up over the fee) applies; here the batch total is checked against the floor sum.
            uint256 received = env.usdt.balanceOf(address(env.account)) - usdtBefore;
            uint256 floorSum;
            for (uint256 k; k < count; ++k) {
                floorSum += floors[k];
            }
            require(received >= floorSum, string.concat(label, ": sales below floor"));
            console.log(
                string.concat("SMOKE ", label, " USDT received / floor sum (wei)"), received, floorSum
            );
        }
    }

    function _step(
        Env memory env,
        address tokenIn,
        address tokenOut,
        uint24 fee,
        uint256 amountIn,
        uint256 minOut
    ) internal view returns (AtpExecutor.SwapStep memory) {
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(
            address(env.executor), amountIn, minOut, abi.encodePacked(tokenIn, fee, tokenOut), true
        );
        return AtpExecutor.SwapStep({
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            amountIn: amountIn,
            amountOutMin: minOut,
            venue: address(env.executor.universalRouter()),
            data: abi.encode(abi.encodePacked(V3_SWAP_EXACT_IN), inputs)
        });
    }

    /// @dev One strategy over USDT + every asset (93 with the 92 of #39), equal weights with the remainder on USDT.
    function _strategy(Env memory env, address[] memory tokens) internal {
        uint256 count = tokens.length;
        address[] memory assets = new address[](count + 1);
        uint16[] memory weights = new uint16[](count + 1);
        uint256 each = BPS / (count + 1);
        assets[0] = address(env.usdt);
        weights[0] = uint16(BPS - each * count);
        for (uint256 k; k < count; ++k) {
            assets[k + 1] = tokens[k];
            weights[k + 1] = uint16(each);
        }
        env.strategyId = env.registry.registerStrategy("testnet smoke", "cre8-contracts#30, #45", false);
        ++env.txCount;
        env.registry.publishVersion(env.strategyId, assets, weights, keccak256("smoke"), 0);
        ++env.txCount;
        _mark(env, "publishVersion");
        env.feeBps = env.registry.effectiveFeeBps(env.strategyId);
    }

    function _approve(Env memory env, address token) internal {
        _call(env, token, abi.encodeCall(IERC20.approve, (address(env.executor), type(uint256).max)));
    }

    function _call(Env memory env, address target, bytes memory data) internal {
        env.account.execute(target, data);
        ++env.txCount;
    }

    /// @dev Labels the transaction just broadcast for `fork-e2e.sh`, which reads its gas from the receipts.
    function _mark(Env memory env, string memory label) internal pure {
        console.log(string.concat("SMOKE_TX ", label), env.txCount - 1);
    }

    /// @dev The executor's `minGross` plus a cushion of a sixth of the asset's slippage budget (tier B 300 bps ->
    /// 50 bps, A 100 -> 16, S 50 -> 8). The floor is read here, during forge's simulation, but enforced when the
    /// transaction lands a few blocks later; the 5-minute mean moves a little in between (the preceding trade
    /// shifted the pool), and a step whose `amountOutMin` ends up a hair under the new floor reverts `BelowFloor`.
    /// The cushion has to stay well inside the budget: the floor sits `maxSlippageBps` under the quote, so a flat
    /// 50 bps on a 50 bps stablecoin floor would ask for more than the quote itself (`V3TooLittleReceived`).
    function _minGross(uint256 floor, uint16 feeBps, uint16 maxSlippageBps) internal pure returns (uint256) {
        return Math.mulDiv(
            Math.mulDiv(floor, BPS, BPS - feeBps, Math.Rounding.Ceil),
            BPS + maxSlippageBps / 6,
            BPS,
            Math.Rounding.Ceil
        );
    }
}
