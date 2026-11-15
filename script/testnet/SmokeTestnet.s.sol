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
/// warm-up: the assets go in groups of 15 (16-asset versions with USDT; 7 groups for the 92 assets of
/// cre8-contracts#39); per group a fresh contract account claims testnet USDT from the faucet and enrolls in the
/// group's strategy, and for every asset it buys 100 USDT worth through the executor and the Pancake Universal
/// Router and sells everything back. The executor enforces the oracle floor (and, since #24,
/// `amountOutMin`) on every step; this script also prints each fill against its floor. On a public chain it
/// spends real tBNB, so it is meant for the local fork unless a run on 97 is explicitly wanted.
/// @dev `TESTNET_EXECUTOR` locates everything else: registry, router and USDT from the executor, the tokens
/// from `TestnetBook` (CREATE2 addresses of DEPLOYER).
contract SmokeTestnet is Script {
    uint256 internal constant TRADE_USDT = 100e18;
    /// @dev Per group account: 15 buys of 100 USDT stay under the 100%-of-value daily buy cap.
    uint256 internal constant CLAIM_USDT = 2_000e18;
    uint256 internal constant ASSETS_PER_VERSION = 15; // + USDT = MAX_VERSION_ASSETS (16)
    uint256 internal constant BPS = 10_000;
    bytes1 internal constant V3_SWAP_EXACT_IN = 0x00;

    struct Env {
        AtpExecutor executor;
        AtpRegistry registry;
        AtpMultiPoolOracle router;
        TestnetUSDT usdt;
        SmokeAccount account;
    }

    function run() external {
        require(block.chainid == 97, "SmokeTestnet: chain 97 only");
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
        uint256 strategyId;
        uint256 claimed;
        uint256 left;
        for (uint256 i; i < specs.length; ++i) {
            if (i % ASSETS_PER_VERSION == 0) {
                if (address(env.account) != address(0)) left += env.usdt.balanceOf(address(env.account));
                // A fresh account per group: the executor caps an account's buys at `maxBuyBps` (100%) of its
                // value per 24 hours, so one account cannot buy 100 USDT of every asset.
                env.account = new SmokeAccount(msg.sender);
                _call(env, address(env.usdt), abi.encodeCall(TestnetUSDT.claim, (CLAIM_USDT)));
                claimed += CLAIM_USDT;
                _approve(env, address(env.usdt));
                strategyId = _strategy(env, tokens, i);
                _call(
                    env,
                    address(env.registry),
                    abi.encodeCall(AtpRegistry.enroll, (address(env.account), strategyId))
                );
                console.log(
                    string.concat("SMOKE group ", vm.toString(i / ASSETS_PER_VERSION + 1), " account"),
                    address(env.account)
                );
            }
            _approve(env, tokens[i]);
            _roundTrip(env, specs[i], tokens[i], strategyId);
        }
        vm.stopBroadcast();
        left += env.usdt.balanceOf(address(env.account));

        console.log("");
        console.log("SMOKE assets round-tripped", specs.length);
        console.log("SMOKE USDT claimed / left (wei)", claimed, left);
        console.log("SMOKE round-trip cost over all assets (USDT wei)", claimed - left);
    }

    function _roundTrip(
        Env memory env,
        TestnetAssets.AssetSpec memory spec,
        address token,
        uint256 strategyId
    ) internal {
        uint16 feeBps = env.registry.effectiveFeeBps(strategyId);
        IERC20 asset = IERC20(token);

        (uint256 buyQuote, uint256 buyFloor) = env.router.previewSwap(address(env.usdt), token, TRADE_USDT);
        uint256 before = asset.balanceOf(address(env.account));
        _swap(
            env,
            address(env.usdt),
            token,
            spec.fee,
            TRADE_USDT,
            _minGross(buyFloor, feeBps, spec.maxSlippageBps)
        );
        uint256 bought = asset.balanceOf(address(env.account)) - before;
        require(bought >= buyFloor, string.concat(spec.symbol, ": buy below floor"));

        (uint256 sellQuote, uint256 sellFloor) = env.router.previewSwap(token, address(env.usdt), bought);
        before = env.usdt.balanceOf(address(env.account));
        _swap(
            env, token, address(env.usdt), spec.fee, bought, _minGross(sellFloor, feeBps, spec.maxSlippageBps)
        );
        uint256 sold = env.usdt.balanceOf(address(env.account)) - before;
        require(sold >= sellFloor, string.concat(spec.symbol, ": sale below floor"));
        require(asset.balanceOf(address(env.account)) == 0, string.concat(spec.symbol, ": not fully sold"));

        console.log(
            string.concat(
                "SMOKE ",
                spec.symbol,
                " buy 100 USDT -> ",
                vm.toString(bought),
                " (quote ",
                vm.toString(buyQuote),
                ", floor ",
                vm.toString(buyFloor),
                "); sell -> ",
                vm.toString(sold),
                " USDT wei (quote ",
                vm.toString(sellQuote),
                ", floor ",
                vm.toString(sellFloor),
                ")"
            )
        );
    }

    function _swap(
        Env memory env,
        address tokenIn,
        address tokenOut,
        uint24 fee,
        uint256 amountIn,
        uint256 minOut
    ) internal {
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(
            address(env.executor), amountIn, minOut, abi.encodePacked(tokenIn, fee, tokenOut), true
        );
        AtpExecutor.SwapStep[] memory steps = new AtpExecutor.SwapStep[](1);
        steps[0] = AtpExecutor.SwapStep({
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            amountIn: amountIn,
            amountOutMin: minOut,
            venue: address(env.executor.universalRouter()),
            data: abi.encode(abi.encodePacked(V3_SWAP_EXACT_IN), inputs)
        });
        _call(
            env,
            address(env.executor),
            abi.encodeCall(AtpExecutor.executeRebalance, (address(env.account), steps, block.timestamp + 600))
        );
    }

    /// @dev One strategy per group of 15 assets (+ USDT), equal weights with the remainder on USDT.
    function _strategy(Env memory env, address[] memory tokens, uint256 from) internal returns (uint256 id) {
        uint256 count = Math.min(ASSETS_PER_VERSION, tokens.length - from);
        address[] memory assets = new address[](count + 1);
        uint16[] memory weights = new uint16[](count + 1);
        uint256 each = BPS / (count + 1);
        assets[0] = address(env.usdt);
        weights[0] = uint16(BPS - each * count);
        for (uint256 k; k < count; ++k) {
            assets[k + 1] = tokens[from + k];
            weights[k + 1] = uint16(each);
        }
        id = env.registry
            .registerStrategy(
                string.concat("testnet smoke ", vm.toString(from / ASSETS_PER_VERSION + 1)),
                "cre8-contracts#30",
                false
            );
        env.registry.publishVersion(id, assets, weights, keccak256("smoke"), 0);
    }

    function _approve(Env memory env, address token) internal {
        _call(env, token, abi.encodeCall(IERC20.approve, (address(env.executor), type(uint256).max)));
    }

    function _call(Env memory env, address target, bytes memory data) internal {
        env.account.execute(target, data);
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
