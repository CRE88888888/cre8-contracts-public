// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Script, console } from "forge-std/Script.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { AtpExecutor } from "../../src/atp/AtpExecutor.sol";
import { AtpRegistry } from "../../src/atp/AtpRegistry.sol";
import { IAtpBorrowExecutorV2 } from "../../src/atp/borrow/v2/IAtpBorrowExecutorV2.sol";
import { AtpBorrowRegistryV2 } from "../../src/atp/borrow/v2/AtpBorrowRegistryV2.sol";
import { AtpBorrowLensV2 } from "../../src/atp/borrow/v2/AtpBorrowLensV2.sol";
import { RoutingTypes as R } from "../../src/atp/borrow/v2/RoutingTypes.sol";
import { IVenusComptroller, IMoolahCore } from "../../src/atp/borrow/BorrowInterfaces.sol";
import { TestnetToken } from "../../src/testnet/TestnetToken.sol";
import { MockRewardEarnVault } from "../../src/testnet/lending/MockRewardEarnVault.sol";
import { TestnetBook as TB } from "./TestnetBook.sol";

interface IMoolahAuthorize {
    function setAuthorization(address authorized, bool newIsAuthorized) external;
}

/// @dev Stand-in for a CRE8 portfolio account on chain 97 (a Kernel account needs the backend's session stack).
/// `execute` forwards exactly what the account's own `execute()` would send, so every step below is the call
/// the backend will make. It answers ERC-1271 for hashes its owner approved.
contract RoutingDemoAccount {
    address public immutable owner;
    mapping(bytes32 => bool) public signed;

    constructor(address owner_) {
        owner = owner_;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "demo owner only");
        _;
    }

    function execute(address target, bytes calldata data) external onlyOwner returns (bytes memory result) {
        bool ok;
        (ok, result) = target.call(data);
        if (!ok) {
            assembly {
                revert(add(result, 0x20), mload(result))
            }
        }
    }

    function sign(bytes32 hash) external onlyOwner {
        signed[hash] = true;
    }

    function isValidSignature(bytes32 hash, bytes calldata) external view returns (bytes4) {
        return signed[hash] ? bytes4(0x1626ba7e) : bytes4(0xffffffff);
    }
}

/// @notice Chain 97: one routing v2 rehearsal by a demo account owned by OWNER, each step its own transaction.
/// QQQB: open on Lista borrowing USDC into the USDC earn vault -> partial repay -> migrate to the Lista USD1
/// market (other loan token, one call) -> switch the deposit to Venus vUSD1 -> (local fork only: the owner
/// tightens the route's lines -> anyone deleverages -> lines back) -> close. NVDAB: open on Venus borrowing
/// USDT into Aave -> migrate to Lista (same token) -> close. Then rewards: claim to the box, collect into the
/// account, sweep to the owner's recipient.
/// The deleverage drill changes the lines of a route every account on the chain shares, so it only runs
/// against a local Anvil fork; on the public chain the script skips it and never touches a shared setting.
/// Env: TESTNET_EXECUTOR, ROUTING_EXECUTOR; optional ROUTING_DEMO_COLLATERAL (raw, default 5e18).
contract RoutingDemoTestnet is Script {
    uint256 internal constant MAX = type(uint256).max;

    struct Ctx {
        AtpExecutor core;
        IAtpBorrowExecutorV2 lend;
        AtpBorrowRegistryV2 credit;
        AtpBorrowLensV2 lens;
        RoutingDemoAccount account;
        address usdt;
        address usdc;
        address usd1;
        address qqq;
        address nvda;
        address reward;
        uint256 amount;
    }

    function run() external {
        require(block.chainid == 97, "routing demo: chain 97 only");
        uint256 key = vm.envOr("TESTNET_OWNER_KEY", uint256(0));
        if (key != 0) {
            require(vm.addr(key) == TB.OWNER, "TESTNET_OWNER_KEY does not derive OWNER");
            vm.rememberKey(key);
        }
        Ctx memory c;
        c.core = AtpExecutor(vm.envAddress("TESTNET_EXECUTOR"));
        c.lend = IAtpBorrowExecutorV2(vm.envAddress("ROUTING_EXECUTOR"));
        c.credit = AtpBorrowRegistryV2(c.lend.borrowRegistry());
        c.lens = AtpBorrowLensV2(c.lend.lens());
        c.amount = vm.envOr("ROUTING_DEMO_COLLATERAL", uint256(5e18));
        c.usdt = c.core.numeraire();
        _tokens(c);
        bool fork = _isLocalFork();

        bytes memory code = abi.encodePacked(type(RoutingDemoAccount).creationCode, abi.encode(TB.OWNER));
        c.account = RoutingDemoAccount(TB.create2Address("routing.demo.account.v1", code));
        address a = address(c.account);

        vm.startBroadcast(TB.OWNER);
        if (a.code.length == 0) {
            (bool ok,) = TB.CREATE2_FACTORY.call(abi.encodePacked(TB.salt("routing.demo.account.v1"), code));
            require(ok && a.code.length != 0, "demo account deployment failed");
        }
        _mint(c.qqq, a, c.amount);
        _mint(c.nvda, a, c.amount);
        _prepare(c);

        // ---- QQQB ----
        bytes32 qqqUsdc = _listaRoute(c, c.qqq, c.usdc);
        bytes32 qqqUsd1 = _listaRoute(c, c.qqq, c.usd1);
        bytes32 vaultUsdc = _vault(c, R.VaultKind.ERC4626, c.usdc);
        bytes32 vaultUsd1 = _vault(c, R.VaultKind.ERC4626, c.usd1);
        bytes32 venusUsd1 = _vault(c, R.VaultKind.VENUS, c.usd1);
        _call(c, abi.encodeCall(c.lend.executeOpen, (a, qqqUsdc, bytes32(0), c.amount, 0, MAX)));
        uint256 borrow = c.lens.health(qqqUsdc, a).budgetValue * 95 / 100;
        _call(c, abi.encodeCall(c.lend.executeOpen, (a, qqqUsdc, vaultUsdc, 0, borrow, MAX)));
        _call(c, abi.encodeCall(c.lend.executeReduce, (a, qqqUsdc, vaultUsdc, borrow / 4, 0, 0, MAX)));
        // Every step of a script runs in one simulated timestamp, so the vault has earned nothing yet and
        // share rounding leaves it a raw unit short of the debt: the account's own USDC covers that unit.
        _mint(c.usdc, a, 1e18);
        _call(
            c,
            abi.encodeCall(
                c.lend.executeMigrate, (a, qqqUsdc, vaultUsdc, qqqUsd1, vaultUsd1, borrow * 3 / 4, 1e18, MAX)
            )
        );
        _call(c, abi.encodeCall(c.lend.executeSwitchVault, (a, vaultUsd1, venusUsd1, MAX, MAX)));
        // Deleverage drill, on a local fork only. The owner tightens this route's lines under the open
        // position (target 10%, deleverage 20%; the position sits near 25%), anyone repays from the box back
        // to the target, and the owner puts the lines back. The route is the one every account uses: on the
        // public chain anyone could deleverage a real position on it between those transactions, so there
        // the step is skipped (neither the lines nor the shared lending oracle are ever moved).
        uint256 repaid;
        if (fork) {
            c.credit.setLtvConfig(qqqUsd1, 0.1e18, 0.2e18);
            repaid = c.lend.executeDeleverage(a, qqqUsd1, venusUsd1, MAX);
            c.credit.setLtvConfig(qqqUsd1, 0, 0);
        }
        // Close: the box's vUSD1 first, a little of the account's own USD1 for share rounding.
        _mint(c.usd1, a, 1e18);
        _call(c, abi.encodeCall(c.lend.executeReduce, (a, qqqUsd1, venusUsd1, MAX, MAX, 1e18, MAX)));

        // ---- NVDAB ----
        bytes32 nvdaVenus = c.credit.routeIdOf(R.Venue.VENUS, c.nvda, c.usdt, bytes32(0));
        bytes32 nvdaLista = _listaRoute(c, c.nvda, c.usdt);
        bytes32 aaveUsdt = _vault(c, R.VaultKind.AAVE, c.usdt);
        bytes32 vaultUsdt = _vault(c, R.VaultKind.ERC4626, c.usdt);
        _call(c, abi.encodeCall(c.lend.executeOpen, (a, nvdaVenus, bytes32(0), c.amount, 0, MAX)));
        uint256 borrowT = c.lens.health(nvdaVenus, a).budgetValue * 95 / 100;
        _call(c, abi.encodeCall(c.lend.executeOpen, (a, nvdaVenus, aaveUsdt, 0, borrowT, MAX)));
        _mint(c.usdt, a, 1e18);
        _call(
            c,
            abi.encodeCall(
                c.lend.executeMigrate, (a, nvdaVenus, aaveUsdt, nvdaLista, vaultUsdt, borrowT, 1e18, MAX)
            )
        );
        _call(c, abi.encodeCall(c.lend.executeReduce, (a, nvdaLista, vaultUsdt, MAX, MAX, 1e18, MAX)));

        // ---- rewards ----
        // The vault pays its simulated incentive to the box (the depositor); anyone moves it into the account;
        // on exit the account sends it to the recipient its owner set.
        address box = c.lend.boxOf(a);
        _mint(c.reward, box, 1e18);
        // Explicit gas: the simulation runs every step in one timestamp, where nothing has accrued yet and the
        // claim returns early; on chain it mints.
        MockRewardEarnVault(c.credit.vault(vaultUsdc).target).claimReward{ gas: 300_000 }(box);
        uint256 collected = c.lend.collectRewards(a, c.reward);
        _call(c, abi.encodeCall(IERC20.approve, (address(c.lend), MAX)), c.reward);
        _call(c, abi.encodeCall(c.lend.executeSweepRewards, (a, c.reward, MAX, MAX)));
        vm.stopBroadcast();

        require(c.credit.accountRoutes(a).length == 0, "routes left");
        require(c.lens.tokenDebt(a, c.usdt) == 0 && c.lens.tokenDebt(a, c.usd1) == 0, "debt left");
        // Venus pays collateral back in whole vTokens (1e-8 of a token times the exchange rate): up to about
        // 1e10 raw units of the supplied amount stay behind as rounding.
        require(IERC20(c.qqq).balanceOf(a) + 1e11 >= c.amount, "QQQB collateral not back");
        require(IERC20(c.nvda).balanceOf(a) + 1e11 >= c.amount, "NVDAB collateral not back");
        require(IERC20(c.reward).balanceOf(TB.OWNER) >= collected && collected >= 1e18, "rewards");
        console.log("ROUTING_DEMO_ACCOUNT", a);
        console.log("ROUTING_DEMO_BOX", box);
        console.log(
            fork ? "ROUTING_DEMO_DELEVERAGE_REPAID" : "ROUTING_DEMO_DELEVERAGE_SKIPPED_NOT_A_FORK", repaid
        );
        console.log("ROUTING_DEMO_REWARD_COLLECTED", collected);
    }

    /// @dev One-time account-owner setup: enroll, grant the executor on both venues, consent, approvals.
    function _prepare(Ctx memory c) private {
        AtpRegistry registry = c.core.registry();
        address a = address(c.account);
        if (!registry.isEnrolled(a)) {
            address[] memory assets = new address[](3);
            assets[0] = c.usdt;
            assets[1] = c.qqq;
            assets[2] = c.nvda;
            uint16[] memory weights = new uint16[](3);
            weights[1] = 5_000;
            weights[2] = 5_000;
            bytes memory out = c.account
                .execute(
                    address(registry),
                    abi.encodeCall(registry.registerStrategy, ("Routing demo", "chain 97 routing v2", false))
                );
            uint256 strategy = abi.decode(out, (uint256));
            c.account
                .execute(
                    address(registry),
                    abi.encodeCall(
                        registry.publishVersion, (strategy, assets, weights, keccak256("routing demo"), 0)
                    )
                );
            c.account.execute(address(registry), abi.encodeCall(registry.enroll, (a, strategy, 1)));
        }
        c.account
            .execute(
                c.credit.venusComptroller(),
                abi.encodeCall(IVenusComptroller.updateDelegate, (address(c.lend), true))
            );
        c.account
            .execute(
                c.credit.moolah(), abi.encodeCall(IMoolahAuthorize.setAuthorization, (address(c.lend), true))
            );
        c.account
            .execute(
                address(c.credit), abi.encodeCall(c.credit.setStrategyPolicy, (1_000_000e18, TB.OWNER, true))
            );
        address[5] memory tokens = [c.qqq, c.nvda, c.usdt, c.usdc, c.usd1];
        for (uint256 i; i < tokens.length; ++i) {
            c.account.execute(tokens[i], abi.encodeCall(IERC20.approve, (address(c.lend), MAX)));
        }
    }

    /// @dev Whether the RPC is a local Anvil node (a fork of chain 97). A public node rejects the method.
    function _isLocalFork() private returns (bool) {
        try vm.rpc("anvil_nodeInfo", "[]") returns (bytes memory) {
            return true;
        } catch {
            return false;
        }
    }

    function _call(Ctx memory c, bytes memory data) private {
        c.account.execute(address(c.lend), data);
    }

    function _call(Ctx memory c, bytes memory data, address target) private {
        c.account.execute(target, data);
    }

    function _tokens(Ctx memory c) private view {
        uint256 n = c.credit.routeCount();
        for (uint256 i; i < n; ++i) {
            R.Route memory r = c.credit.route(c.credit.routeIds(i));
            bytes32 collateral = keccak256(bytes(IERC20Metadata(r.collateral).symbol()));
            bytes32 loan = keccak256(bytes(IERC20Metadata(r.loan).symbol()));
            if (collateral == keccak256("QQQB")) c.qqq = r.collateral;
            if (collateral == keccak256("NVDAB")) c.nvda = r.collateral;
            if (loan == keccak256("USDC")) c.usdc = r.loan;
            if (loan == keccak256("USD1")) c.usd1 = r.loan;
        }
        n = c.credit.vaultCount();
        for (uint256 i; i < n && c.reward == address(0); ++i) {
            R.Vault memory v = c.credit.vault(c.credit.vaultIds(i));
            if (v.kind == R.VaultKind.ERC4626) {
                c.reward = address(MockRewardEarnVault(v.target).rewardToken());
            }
        }
        require(
            c.qqq != address(0) && c.nvda != address(0) && c.usdc != address(0) && c.usd1 != address(0)
                && c.reward != address(0),
            "routing demo: tokens"
        );
    }

    function _listaRoute(Ctx memory c, address collateral, address loan) private view returns (bytes32) {
        uint256 n = c.credit.routeCount();
        for (uint256 i; i < n; ++i) {
            bytes32 id = c.credit.routeIds(i);
            R.Route memory r = c.credit.route(id);
            if (r.venue == R.Venue.LISTA && r.collateral == collateral && r.loan == loan) return id;
        }
        revert("routing demo: no Lista route");
    }

    function _vault(Ctx memory c, R.VaultKind kind, address token) private view returns (bytes32) {
        uint256 n = c.credit.vaultCount();
        for (uint256 i; i < n; ++i) {
            bytes32 id = c.credit.vaultIds(i);
            R.Vault memory v = c.credit.vault(id);
            if (v.kind == kind && v.token == token) return id;
        }
        revert("routing demo: no vault");
    }

    function _mint(address token, address to, uint256 amount) private {
        TestnetToken t = TestnetToken(token);
        bool was = t.isMinter(TB.OWNER);
        if (!was) t.setMinter(TB.OWNER, true);
        t.mint(to, amount);
        if (!was) t.setMinter(TB.OWNER, false);
    }
}
