// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { console } from "forge-std/Script.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { AtpRegistry } from "../src/atp/AtpRegistry.sol";
import { AtpExecutor } from "../src/atp/AtpExecutor.sol";
import { AtpMultiPoolOracle } from "../src/atp/AtpMultiPoolOracle.sol";
import { PancakeV3TwapOracle } from "../src/atp/PancakeV3TwapOracle.sol";
import { IAggregatorV3 } from "../src/atp/interfaces/IAggregatorV3.sol";
import { IPancakeV3Pool } from "../src/atp/interfaces/IPancakeV3Pool.sol";
import { IPriceSource } from "../src/atp/interfaces/IPriceSource.sol";
import { PushFeedPriceSource } from "../src/atp/PushFeedPriceSource.sol";
import { TestnetToken, TestnetBStock, TestnetUSDT } from "../src/testnet/TestnetToken.sol";
import { TestnetPriceFeed } from "../src/testnet/TestnetPriceFeed.sol";
import { TestnetOwnedDeployer } from "../src/testnet/TestnetOwnedDeployer.sol";
import { VerifyingPaymaster } from "../src/testnet/aa/samples/VerifyingPaymaster.sol";
import { IEntryPoint } from "../src/testnet/aa/interfaces/IEntryPoint.sol";
import { TestnetAssets } from "./testnet/TestnetAssets.sol";
import { TestnetBook } from "./testnet/TestnetBook.sol";
import { TestnetYieldBook as YieldBook } from "./testnet/TestnetYieldBook.sol";
import { AtpYieldRegistry } from "../src/atp/yield/AtpYieldRegistry.sol";
import { YieldTypes as Y } from "../src/atp/yield/YieldTypes.sol";
import { YieldReader } from "../src/atp/yield/YieldReader.sol";
import { YieldView } from "../src/atp/yield/YieldView.sol";
import { YieldViewPin } from "./testnet/DeployYieldView.s.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { MockVenus } from "../src/testnet/yield/MockVenus.sol";
import { MockLista } from "../src/testnet/yield/MockLista.sol";
import { MockAavePool, MockAToken } from "../src/testnet/yield/MockAavePool.sol";
import { GasPolicyInitCode } from "./testnet/GasPolicyInitCode.sol";

interface ITestnetV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address);
    function feeAmountTickSpacing(uint24 fee) external view returns (int24);
}

interface ITestnetPositionManager {
    struct MintParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }

    function factory() external view returns (address);
    function createAndInitializePoolIfNecessary(
        address token0,
        address token1,
        uint24 fee,
        uint160 sqrtPriceX96
    ) external payable returns (address pool);
    function mint(MintParams calldata params)
        external
        payable
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);
}

interface IObservationCardinality {
    function increaseObservationCardinalityNext(uint16 observationCardinalityNext) external;
}

/// @dev The position manager's ERC721 (enumerable) side, to hand the LP NFTs over.
interface ITestnetPositionNft {
    function balanceOf(address owner) external view returns (uint256);
    function tokenOfOwnerByIndex(address owner, uint256 index) external view returns (uint256);
    function transferFrom(address from, address to, uint256 tokenId) external;
}

/// @title DeployTestnet
/// @notice BSC TESTNET (chain 97) ONLY (cre8-contracts#30). Deploys the whole CRE8 stack against mock assets:
/// - testnet USDT (numeraire, capped faucet) and 92 mock assets (`TestnetAssets`: the 38 launch assets and,
///   testnet only, the other showcase-fund tokens and crypto of cre8-contracts#39);
/// - one Pancake V3 pool per asset against USDT, full-range liquidity, observation room for the 30-minute TWAP;
/// - the registry, oracle router and executor with `DeployAtpMainnet`'s parameters;
/// - mock USD push feeds as the secondary source of the same 11 assets as mainnet;
/// - ZeroDev's GasPolicy (missing on 97) and our own `VerifyingPaymaster` (eth-infinitism v0.7.0) with an
///   EntryPoint deposit, so sessions run gasless without a paid paymaster service;
/// - tBNB for every role, sent from the deployer (the only address the user funds).
///
/// @dev Idempotent by construction: every contract is deployed with CREATE2, so each address is a pure function
/// of (deployer, salt, init code). A rerun finds the code and only does what is still missing; a complete
/// deployment reruns with no transaction. A local chain 97 fork therefore predicts the public addresses exactly.
/// A run deploys at most `TESTNET_MARKETS_PER_RUN` unfinished markets and then prints `PENDING_MARKETS <n>`
/// instead of funding, handing over and verifying; `deploy-97.sh` reruns until nothing is pending.
/// Changing a contract's code or constructor arguments moves its address (a new deployment next to the old
/// one), which is the intended versioning.
///
/// @dev Roles (`TestnetBook`; new keys in ~/.cre8-testnet/, no Safe on testnet): DEPLOYER deploys, owns the
/// mocks and LP positions while it builds the markets, configures, then hands the registry, router and paymaster
/// to OWNER (the Safe's stand-in), which accepts in the same run. Once no pool needs a mint any more it also
/// hands over what it built (cre8-contracts#47): USDT, every mock token and every feed to OWNER, its own minter
/// role revoked, every LP NFT to OWNER; DEPLOYER keeps nothing. Configuration on a rerun is sent by whoever owns
/// the contract then. OPERATOR = registry operator + USDT faucet (capped `claimFor` / `welcomeFor`, no `mint`);
/// KEEPER = only feed pusher + mock-asset minter, with a USDT stock minted once at the hand-over (no USDT
/// minter); PAYMASTER_SIGNER signs sponsorships; FEE_RECIPIENT gets the executor fee; BUNDLER_* run alto.
///
/// @dev Run: `scripts/testnet/deploy-97.sh` (fork or public chain 97, writes and checks the manifest); see
/// docs/testnet-97.zh-TW.md. Broadcasts from DEPLOYER and OWNER, so both must be available as signers
/// (`--unlocked` on a fork; on chain 97 the keys come from the environment, `TESTNET_DEPLOYER_KEY` and
/// `TESTNET_OWNER_KEY`, never from command-line arguments another process could read with `ps`; #47).
contract DeployTestnet is YieldViewPin {
    // ---- chain 97 pins (sources in docs/testnet-97.zh-TW.md) ----
    address internal constant V3_FACTORY = 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865;
    address internal constant POSITION_MANAGER = 0x427bF5b37357632377eCbEC9de3626C71A5396c1;
    address internal constant V3_UNIVERSAL_ROUTER = 0x9A082015c919AD0E47861e5Db9A1c7070E81A2C7;
    address internal constant PERMIT2 = 0x31c2F6fcFf4F8759b3Bd5Bf0e1084A055615c768;
    address internal constant ENTRY_POINT_V07 = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;
    /// @dev ZeroDev GasPolicy used by `@zerodev/permissions` (`toGasPolicy`); see `GasPolicyInitCode`.
    address internal constant GAS_POLICY = 0xaeFC5AbC67FfD258abD0A3E54f65E70326F84b23;
    /// @dev keccak256 of GasPolicy's runtime code on BSC mainnet, read 2026-11-14.
    bytes32 internal constant GAS_POLICY_CODEHASH =
        0x906572ca775c1eebe7f038c0ca621fb6e53232916733659dbbe60ab8630550be;

    // ---- the same parameters as DeployAtpMainnet ----
    uint32 internal constant TWAP_WINDOW = 30 minutes;
    uint32 internal constant MAX_ORACLE_AGE = 1 hours;
    uint16 internal constant MAX_BUY_BPS = 10_000;
    /// @notice Minimum fee per swap batch (cre8-contracts#33): 0.30 USDT (mock USDT has 18 decimals); settable by the owner.
    uint256 internal constant MIN_BATCH_FEE = 0.3e18;
    /// @notice Proportional swap fee, the parameter table's 0.1% of max(0.1%, 0.30 USDT) (cre8-contracts#47).
    /// Testnet only: `DeployAtpMainnet` leaves the default at 0.
    uint16 internal constant DEFAULT_FEE_BPS = 10;
    uint16 internal constant SECONDARY_MAX_DEVIATION_BPS = 200;

    // ---- testnet-only parameters ----
    /// @dev USDT/USD has its own max age (cre8-contracts#25), like mainnet's `USDT_USD_MAX_AGE`, but sized to the
    /// testnet keeper (the mock feed has no Chainlink heartbeat): the keeper pushes it with every price step.
    uint32 internal constant USDT_USD_MAX_AGE = 1 hours;
    /// @dev Full-range liquidity per side, in USDT: 100 USDT moves a pool ~0.004%, 10,000 USDT ~0.4%.
    uint256 internal constant LIQUIDITY_PER_SIDE = 5_000_000e18;
    /// @dev Observation slots per pool. A TWAP read needs the oldest kept observation to be at least 30 minutes
    /// old; a pool writes at most one observation per block with a swap, so 600 slots serve 30 minutes while
    /// the pool trades in fewer than one block in ~7 (BSC testnet: ~0.45 s blocks), i.e. at most every 3 s.
    uint16 internal constant OBSERVATION_CARDINALITY = 600;
    /// @dev The second, tiny mint that makes a pool write its first post-initialization observation.
    uint256 internal constant POKE_LIQUIDITY = 1e18;
    /// @dev Per recipient per 24 hours, the parameter table's daily claim (cre8-contracts#47).
    uint256 internal constant FAUCET_DAILY_LIMIT = 1_000e18;
    /// @dev KEEPER's USDT stock, minted once at the hand-over (KEEPER is no USDT minter, cre8-contracts#47):
    /// `PokePoolsTestnet` keeps 20 pokes of 1,000 USDT for each of the 92 pools (1.84M); the rest is headroom.
    uint256 internal constant KEEPER_USDT_STOCK = 2_000_000e18;
    /// @dev A pool's price may sit at most this far from its spec price (cre8-contracts#47): anyone can create
    /// the pool first, at any price, from the public CREATE2 addresses.
    uint256 internal constant MAX_POOL_PRICE_DEVIATION_BPS = 100;
    /// @dev Unfinished markets one run deploys (cre8-contracts#39): ~22M gas and ~12 transactions each. forge
    /// simulates the whole `run()` as one call, and on a fresh fork an earlier 134-market draft ran out of gas
    /// there after ~56 markets in one run; 40 keeps a run near the ~500 transactions / ~0.85B gas of the 38-asset deployment.
    /// `TESTNET_MARKETS_PER_RUN` overrides it.
    uint256 internal constant MARKETS_PER_RUN = 40;
    uint8 internal constant FEED_DECIMALS = 8;
    int24 internal constant MAX_TICK = 887_272;

    // ---- tBNB float per role, topped up from DEPLOYER when below half (so a rerun sends nothing) ----
    uint256 internal constant FLOAT_OWNER = 0.01 ether;
    uint256 internal constant FLOAT_OPERATOR = 0.05 ether;
    uint256 internal constant FLOAT_KEEPER = 0.3 ether;
    uint256 internal constant FLOAT_BUNDLER_EXECUTOR = 0.1 ether;
    uint256 internal constant FLOAT_BUNDLER_UTILITY = 0.02 ether;
    /// @dev The paymaster's EntryPoint deposit pays every sponsored UserOp; at 0.1 gwei the default covers about
    /// 4,000 rebalance UserOps of the size measured on the fork (1,257,325 gas for three buys; docs/testnet-97
    /// §3, the parameter table's figure). `TESTNET_PAYMASTER_DEPOSIT` (wei) overrides it.
    uint256 internal constant PAYMASTER_DEPOSIT = 0.5 ether;

    /// @dev Set when this run creates a pool or mints into one; the market hand-over then waits for a rerun.
    bool internal _poolsTouched;

    struct Core {
        TestnetOwnedDeployer ownedDeployer;
        TestnetUSDT usdt;
        AtpRegistry registry;
        AtpMultiPoolOracle router;
        AtpExecutor executor;
        AtpYieldRegistry yields;
        TestnetPriceFeed usdtUsdFeed;
        VerifyingPaymaster paymaster;
    }

    struct AssetOut {
        address token;
        address pool;
        address oracle;
        address feed;
        address source;
    }

    function run() external {
        require(block.chainid == 97, "DeployTestnet: BSC testnet (97) only");
        _verifyYieldView(address(YieldView));
        rememberKey("TESTNET_DEPLOYER_KEY", TestnetBook.DEPLOYER);
        rememberKey("TESTNET_OWNER_KEY", TestnetBook.OWNER);
        require(
            ITestnetPositionManager(POSITION_MANAGER).factory() == V3_FACTORY,
            "position manager / factory mismatch"
        );
        TestnetAssets.AssetSpec[] memory specs = TestnetAssets.specs();
        AssetOut[] memory out = new AssetOut[](specs.length);
        uint256 perRun = vm.envOr("TESTNET_MARKETS_PER_RUN", MARKETS_PER_RUN);
        require(perRun > 0, "TESTNET_MARKETS_PER_RUN must be > 0");

        // 1. DEPLOYER: contracts, mocks, pools, liquidity, feeds - for at most `perRun` unfinished markets.
        vm.startBroadcast(TestnetBook.DEPLOYER);
        _gasPolicy();
        Core memory core = _core();
        uint256 started;
        uint256 pending;
        for (uint256 i; i < specs.length; ++i) {
            if (!_marketDone(core, specs[i])) {
                if (started == perRun) {
                    ++pending;
                    continue;
                }
                ++started;
            }
            out[i] = _market(core, specs[i]);
        }
        vm.stopBroadcast();

        // 2. Whoever owns the registry / router now (DEPLOYER on the first run, OWNER after the hand-over).
        vm.startBroadcast(core.registry.owner());
        if (core.registry.operator() != TestnetBook.OPERATOR) {
            core.registry.setOperator(TestnetBook.OPERATOR);
        }
        if (core.registry.defaultSwapFeeBps() != DEFAULT_FEE_BPS) {
            core.registry.setDefaultFeeBps(DEFAULT_FEE_BPS);
        }
        if (core.registry.numeraire() == address(0)) core.registry.setNumeraire(address(core.usdt));
        vm.stopBroadcast();
        vm.startBroadcast(core.router.owner());
        for (uint256 i; i < specs.length; ++i) {
            if (out[i].token != address(0)) _oracles(core, specs[i], out[i]);
        }
        vm.stopBroadcast();

        // Markets left for the next run: no funding, hand-over, verification or manifest until all are done.
        // `scripts/testnet/deploy-97.sh` reruns while it sees this line.
        if (pending != 0) {
            console.log("PENDING_MARKETS", pending);
            return;
        }

        // Yield markets are a separate bounded phase, before the mock tokens' ownership hand-over.
        uint256 pendingYield = _yieldMarkets(core);
        if (pendingYield != 0) {
            console.log("PENDING_YIELD_MARKETS", pendingYield);
            return;
        }

        // 3. DEPLOYER: tBNB for every role, the paymaster deposit, and the ownership proposals. What DEPLOYER
        // built (tokens, feeds, LP NFTs) goes too, but only in a run that minted into no pool: a pool that still
        // needs its observation poke needs DEPLOYER's mint. Such a run prints PENDING_HANDOVER and deploy-97.sh
        // reruns; the run that hands over has read every pool from chain, so none can be left thin.
        vm.startBroadcast(TestnetBook.DEPLOYER);
        _fundRoles(core);
        _handOver(core);
        if (!_poolsTouched) _handOverMarkets(core, specs, out);
        vm.stopBroadcast();

        // 4. OWNER accepts.
        vm.startBroadcast(TestnetBook.OWNER);
        if (core.registry.pendingOwner() == TestnetBook.OWNER) core.registry.acceptOwnership();
        if (core.router.pendingOwner() == TestnetBook.OWNER) core.router.acceptOwnership();
        vm.stopBroadcast();

        if (_poolsTouched) {
            console.log("PENDING_HANDOVER");
            return;
        }

        _verify(core, specs, out);
        _report(core, specs, out);
    }

    /// @notice Loads a signer from the environment variable `name` (cre8-contracts#47: keys never travel as
    /// command-line arguments), after checking it derives `expected`. Unset (fork mode, `--unlocked`): nothing.
    function rememberKey(string memory name, address expected) public {
        uint256 key = vm.envOr(name, uint256(0));
        if (key == 0) return;
        require(vm.addr(key) == expected, string.concat(name, " does not derive the expected address"));
        vm.rememberKey(key);
    }

    // ---------------------------------------------------------------- GasPolicy

    /// @dev ZeroDev deployed GasPolicy through the deterministic deployer with salt 0 (Ethereum tx
    /// 0x40a559cd…cac26); replaying the same init code there reproduces the same address on chain 97.
    function _gasPolicy() internal {
        if (GAS_POLICY.code.length == 0) {
            (bool ok,) = CREATE2_FACTORY.call(abi.encodePacked(bytes32(0), GasPolicyInitCode.INIT_CODE));
            require(ok, "GasPolicy deployment failed");
            console.log("deploy              NEW   gasPolicy", GAS_POLICY);
        }
        require(
            GAS_POLICY.codehash == GAS_POLICY_CODEHASH, "code at GasPolicy address is not ZeroDev's GasPolicy"
        );
    }

    // ---------------------------------------------------------------- core

    function _core() internal returns (Core memory core) {
        address deployer = TestnetBook.DEPLOYER;
        core.ownedDeployer =
            TestnetOwnedDeployer(_create2("ownedDeployer", type(TestnetOwnedDeployer).creationCode));
        core.usdt = TestnetUSDT(
            _create2(
                "USDT",
                abi.encodePacked(type(TestnetUSDT).creationCode, abi.encode(deployer, FAUCET_DAILY_LIMIT))
            )
        );
        core.usdtUsdFeed = TestnetPriceFeed(
            _create2(
                "feed.USDT/USD",
                abi.encodePacked(
                    type(TestnetPriceFeed).creationCode,
                    abi.encode(
                        FEED_DECIMALS, "USDT / USD (testnet)", deployer, TestnetBook.KEEPER, int256(1e8)
                    )
                )
            )
        );
        core.registry = AtpRegistry(_owned(core.ownedDeployer, "registry", type(AtpRegistry).creationCode));
        core.router = AtpMultiPoolOracle(
            _owned(
                core.ownedDeployer,
                "router",
                abi.encodePacked(type(AtpMultiPoolOracle).creationCode, abi.encode(address(core.usdt)))
            )
        );
        core.executor = AtpExecutor(
            _create2(
                "executor",
                abi.encodePacked(
                    type(AtpExecutor).creationCode,
                    abi.encode(
                        address(core.registry),
                        V3_UNIVERSAL_ROUTER,
                        address(core.router),
                        PERMIT2,
                        TestnetBook.FEE_RECIPIENT,
                        address(core.usdt),
                        MAX_BUY_BPS,
                        MIN_BATCH_FEE
                    )
                )
            )
        );
        core.yields = core.executor.yieldRegistry();
        core.paymaster = VerifyingPaymaster(
            payable(_owned(
                    core.ownedDeployer,
                    "paymaster",
                    abi.encodePacked(
                        type(VerifyingPaymaster).creationCode,
                        abi.encode(ENTRY_POINT_V07, TestnetBook.PAYMASTER_SIGNER)
                    )
                ))
        );
        if (!core.usdt.isFaucet(TestnetBook.OPERATOR)) core.usdt.setFaucet(TestnetBook.OPERATOR, true);
    }

    // ---------------------------------------------------------------- yield markets (#40/#41/#42)

    function _yieldInit(YieldBook.Spec memory spec, TestnetToken token) internal pure returns (bytes memory) {
        bytes memory args = abi.encode(token, TestnetBook.OWNER, spec.aprBps);
        if (spec.kind == Y.Kind.VENUS) return abi.encodePacked(type(MockVenus).creationCode, args);
        if (spec.kind == Y.Kind.LISTA) return abi.encodePacked(type(MockLista).creationCode, args);
        return abi.encodePacked(type(MockAavePool).creationCode, args);
    }

    function _yieldMarkets(Core memory core) internal returns (uint256 pending) {
        YieldBook.Spec[] memory specs = YieldBook.specs();
        uint256 perRun = vm.envOr("TESTNET_YIELD_MARKETS_PER_RUN", uint256(8));
        require(perRun > 0, "TESTNET_YIELD_MARKETS_PER_RUN must be > 0");
        uint256 started;
        for (uint256 i; i < specs.length; ++i) {
            (address asset, uint256 seed) = YieldBook.asset(specs[i], address(core.usdt));
            bytes memory initCode = _yieldInit(specs[i], TestnetToken(asset));
            address target = TestnetBook.create2Address(YieldBook.label(specs[i]), initCode);
            address receipt = target;
            if (specs[i].kind == Y.Kind.AAVE && target.code.length != 0) {
                receipt = MockAavePool(target).receipt();
            }
            bool done = target.code.length != 0
                && core.yields.receiptMarket(receipt) == YieldBook.id(specs[i], asset);
            if (!done) {
                if (started == perRun) {
                    ++pending;
                    continue;
                }
                ++started;
            }
            _yieldMarket(core, specs[i], TestnetToken(asset), seed, initCode);
        }
    }

    function _yieldMarket(
        Core memory core,
        YieldBook.Spec memory spec,
        TestnetToken token,
        uint256 seed,
        bytes memory initCode
    ) internal {
        vm.startBroadcast(TestnetBook.DEPLOYER);
        address target = _create2(YieldBook.label(spec), initCode);
        vm.stopBroadcast();
        address receipt = spec.kind == Y.Kind.AAVE ? MockAavePool(target).receipt() : target;
        // Accrual may mint test interest ONLY into the simulated market, never to an arbitrary receiver.
        vm.startBroadcast(token.owner());
        address interestMinter = spec.kind == Y.Kind.AAVE ? receipt : target;
        if (!token.isMinter(interestMinter)) token.setMinter(interestMinter, true);
        bool seedNeeded = IERC20(receipt).totalSupply() == 0;
        if (seedNeeded) {
            uint256 balance = token.balanceOf(TestnetBook.DEPLOYER);
            if (balance < seed) token.mint(TestnetBook.DEPLOYER, seed - balance);
        }
        vm.stopBroadcast();
        if (seedNeeded) {
            vm.startBroadcast(TestnetBook.DEPLOYER);
            token.approve(target, seed);
            if (spec.kind == Y.Kind.VENUS) {
                require(MockVenus(target).mint(seed) == 0, "mock Venus seed error");
                IERC20(receipt).transfer(TestnetBook.OWNER, IERC20(receipt).balanceOf(TestnetBook.DEPLOYER));
            } else if (spec.kind == Y.Kind.LISTA) {
                MockLista(target).deposit(seed, TestnetBook.OWNER);
            } else {
                MockAavePool(target).supply(address(token), seed, TestnetBook.OWNER, 0);
            }
            token.approve(target, 0);
            vm.stopBroadcast();
        }
        bytes32 id = YieldBook.id(spec, address(token));
        if (core.yields.receiptMarket(receipt) == bytes32(0)) {
            // A resumed seeded market must accrue in a broadcast transaction before health is read.
            vm.startBroadcast(TestnetBook.DEPLOYER);
            if (spec.kind == Y.Kind.VENUS) {
                require(MockVenus(target).accrueInterest() == 0, "mock Venus accrue error");
            } else if (spec.kind == Y.Kind.LISTA) {
                MockLista(target).accrue();
            } else {
                MockAToken(receipt).accrue();
            }
            vm.stopBroadcast();
            uint256 initialRate = spec.kind == Y.Kind.VENUS
                ? MockVenus(target).exchangeRateStored()
                : spec.kind == Y.Kind.LISTA ? MockLista(target).convertToAssets(1e18) : uint256(1e18);
            Y.Market memory m = Y.Market(
                97,
                spec.kind,
                address(token),
                receipt,
                target,
                target,
                bytes32(0),
                initialRate / 2,
                initialRate * 2,
                true,
                false
            );
            m.configuration = YieldReader.health(m).configuration;
            vm.startBroadcast(core.registry.owner());
            core.yields.registerMarket(id, m);
            vm.stopBroadcast();
        }
        Y.Market memory stored = core.yields.market(id);
        require(
            stored.asset == address(token) && stored.receipt == receipt && stored.target == target
                && stored.kind == spec.kind && stored.supplyEnabled && !stored.retired,
            "yield market pin mismatch"
        );
    }

    function _reportYield(Core memory core) internal view {
        YieldBook.Spec[] memory specs = YieldBook.specs();
        for (uint256 i; i < specs.length; ++i) {
            (address asset, uint256 seed) = YieldBook.asset(specs[i], address(core.usdt));
            bytes32 id = YieldBook.id(specs[i], asset);
            Y.Market memory m = core.yields.market(id);
            console.log(
                string.concat(
                    "YIELD_MARKET ",
                    vm.toString(id),
                    " ",
                    YieldBook.protocol(specs[i].kind),
                    " ",
                    specs[i].symbol,
                    " ",
                    vm.toString(specs[i].aprBps),
                    " ",
                    vm.toString(m.target),
                    " ",
                    vm.toString(m.receipt),
                    " ",
                    vm.toString(asset),
                    " ",
                    vm.toString(seed)
                )
            );
        }
    }

    // ---------------------------------------------------------------- per asset

    /// @dev Whether every per-asset step of `_market` and `_oracles` is already on chain, read before this run
    /// sends anything. Only unfinished markets count against `TESTNET_MARKETS_PER_RUN`; a finished one still runs
    /// through `_market` / `_oracles`, which then send nothing.
    function _marketDone(Core memory core, TestnetAssets.AssetSpec memory spec) internal view returns (bool) {
        address token = TestnetBook.tokenAddress(spec, TestnetBook.DEPLOYER);
        if (token.code.length == 0 || !TestnetToken(token).isMinter(TestnetBook.KEEPER)) return false;
        address usdt = address(core.usdt);
        (address token0, address token1) = token < usdt ? (token, usdt) : (usdt, token);
        address pool = ITestnetV3Factory(V3_FACTORY).getPool(token0, token1, spec.fee);
        if (pool == address(0) || IPancakeV3Pool(pool).liquidity() == 0) return false;
        // `observationCardinality < 2` (the first mint landed in the pool's initialization second) does not count:
        // `_pool` still pokes such a pool on every run, and deploy-97.sh reruns until none is left. Counting it
        // would let last run's thin pools take this run's places and stall the progress check.
        (,,,, uint16 cardinalityNext,,) = IPancakeV3Pool(pool).slot0();
        if (cardinalityNext < OBSERVATION_CARDINALITY) return false;
        if (address(core.router.oracleOf(token)) == address(0)) return false;
        if (!spec.hasFeed) return true;
        (IPriceSource source,) = core.router.secondaryOf(token);
        return address(source) != address(0);
    }

    function _market(Core memory core, TestnetAssets.AssetSpec memory spec)
        internal
        returns (AssetOut memory out)
    {
        out.token = _create2(
            TestnetBook.tokenLabel(spec), TestnetBook.tokenInitCode(spec, TestnetBook.DEPLOYER)
        );
        _minter(TestnetToken(out.token), TestnetBook.KEEPER);
        out.pool = _pool(core, spec, out.token);
        if (spec.hasFeed) {
            out.feed = _create2(
                string.concat("feed.", spec.symbol, "/USD"),
                abi.encodePacked(
                    type(TestnetPriceFeed).creationCode,
                    abi.encode(
                        FEED_DECIMALS,
                        string.concat(spec.symbol, " / USD (testnet)"),
                        TestnetBook.DEPLOYER,
                        TestnetBook.KEEPER,
                        int256(spec.priceE18 / 1e10)
                    )
                )
            );
        }
    }

    function _oracles(Core memory core, TestnetAssets.AssetSpec memory spec, AssetOut memory out) internal {
        PancakeV3TwapOracle oracle = core.router.oracleOf(out.token);
        if (address(oracle) == address(0)) {
            oracle =
                core.router.setOracle(out.token, out.pool, TWAP_WINDOW, spec.maxSlippageBps, MAX_ORACLE_AGE);
        }
        require(address(oracle.pool()) == out.pool, string.concat(spec.symbol, ": oracle on another pool"));
        out.oracle = address(oracle);
        if (!spec.hasFeed) return;
        (IPriceSource source,) = core.router.secondaryOf(out.token);
        if (address(source) == address(0)) {
            source = core.router
                .setSecondary(
                    out.token,
                    IAggregatorV3(out.feed),
                    IAggregatorV3(address(core.usdtUsdFeed)),
                    spec.maxFeedAge,
                    USDT_USD_MAX_AGE,
                    SECONDARY_MAX_DEVIATION_BPS
                );
        }
        out.source = address(source);
    }

    /// @dev Creates and initializes the pool at the spec price, seeds full-range liquidity once and grows the
    /// observation buffer. Each part is skipped when already done.
    function _pool(Core memory core, TestnetAssets.AssetSpec memory spec, address token)
        internal
        returns (address pool)
    {
        address usdt = address(core.usdt);
        (address token0, address token1) = token < usdt ? (token, usdt) : (usdt, token);
        pool = ITestnetV3Factory(V3_FACTORY).getPool(token0, token1, spec.fee);
        if (pool == address(0)) {
            pool = ITestnetPositionManager(POSITION_MANAGER)
                .createAndInitializePoolIfNecessary(
                    token0, token1, spec.fee, sqrtPriceX96(spec.priceE18, spec.decimals, token < usdt)
                );
            console.log(string.concat("pool                NEW   ", spec.symbol), pool);
            _poolsTouched = true;
        }
        // Someone may have created the pool first at another price; never add liquidity to it then.
        _requirePoolPrice(spec, pool, token < usdt);

        // Room first: the pool only grows its observation buffer to `cardinalityNext` on its next observation
        // write, and the first liquidity mint below is that write (an in-range mint writes an observation).
        (,,,, uint16 cardinalityNext,,) = IPancakeV3Pool(pool).slot0();
        if (cardinalityNext < OBSERVATION_CARDINALITY) {
            IObservationCardinality(pool).increaseObservationCardinalityNext(OBSERVATION_CARDINALITY);
        }

        int24 spacing = ITestnetV3Factory(V3_FACTORY).feeAmountTickSpacing(spec.fee);
        int24 edge = MAX_TICK / spacing * spacing;
        if (IPancakeV3Pool(pool).liquidity() == 0) {
            _mintFullRange(spec, token, usdt, edge, LIQUIDITY_PER_SIDE);
            _poolsTouched = true;
        }
        // A pool writes at most one observation per second: if the mint landed in the second the pool was
        // initialized in, nothing grew and the TWAP adapter (which needs >= 2 slots) stays unavailable. A tiny
        // second mint, one block later, is the write that grows it.
        (,,, uint16 cardinality,,,) = IPancakeV3Pool(pool).slot0();
        if (cardinality < 2) {
            _mintFullRange(spec, token, usdt, edge, POKE_LIQUIDITY);
            _poolsTouched = true;
        }
    }

    /// @notice Whether a pool's `actual` sqrtPriceX96 is within `MAX_POOL_PRICE_DEVIATION_BPS` of the `expected`
    /// one, compared as prices (squares): (actual / expected)^2 in [1 - 1%, 1 + 1%].
    function poolPriceWithinBounds(uint160 actual, uint160 expected) public pure returns (bool) {
        if (expected == 0) return false;
        uint256 ratioE9 = Math.mulDiv(actual, 1e9, expected); // sqrt of the price ratio, 1e9 = 1x
        uint256 ratioE18 = ratioE9 * ratioE9;
        return ratioE18 >= (10_000 - MAX_POOL_PRICE_DEVIATION_BPS) * 1e14
            && ratioE18 <= (10_000 + MAX_POOL_PRICE_DEVIATION_BPS) * 1e14;
    }

    function _requirePoolPrice(TestnetAssets.AssetSpec memory spec, address pool, bool assetIsToken0)
        internal
        view
    {
        (uint160 sqrtPrice,,,,,,) = IPancakeV3Pool(pool).slot0();
        require(
            poolPriceWithinBounds(sqrtPrice, sqrtPriceX96(spec.priceE18, spec.decimals, assetIsToken0)),
            string.concat(spec.symbol, ": pool price is more than 1% off the spec price; not using this pool")
        );
    }

    /// @dev Full-range position for DEPLOYER worth `usdtAmount` per side at the spec price.
    function _mintFullRange(
        TestnetAssets.AssetSpec memory spec,
        address token,
        address usdt,
        int24 edge,
        uint256 usdtAmount
    ) internal {
        (address token0, address token1) = token < usdt ? (token, usdt) : (usdt, token);
        uint256 assetAmount = Math.mulDiv(usdtAmount, 10 ** spec.decimals, spec.priceE18);
        _fund(TestnetToken(usdt), usdtAmount);
        _fund(TestnetToken(token), assetAmount);
        ITestnetPositionManager(POSITION_MANAGER)
            .mint(
                ITestnetPositionManager.MintParams({
                    token0: token0,
                    token1: token1,
                    fee: spec.fee,
                    tickLower: -edge,
                    tickUpper: edge,
                    amount0Desired: token0 == usdt ? usdtAmount : assetAmount,
                    amount1Desired: token0 == usdt ? assetAmount : usdtAmount,
                    amount0Min: 0,
                    amount1Min: 0,
                    recipient: TestnetBook.DEPLOYER,
                    deadline: block.timestamp + 1 hours
                })
            );
    }

    /// @notice Pool price for `priceE18` USDT (18 decimals) per whole asset (`decimals`), as a V3 sqrtPriceX96.
    /// Raw units throughout: a bStock's `uiMultiplier` never enters a price.
    function sqrtPriceX96(uint256 priceE18, uint8 decimals, bool assetIsToken0)
        public
        pure
        returns (uint160)
    {
        // token1 per token0 in raw units: USDT-raw per asset-raw = priceE18 / 10^decimals, or its inverse.
        uint256 ratioX192 = assetIsToken0
            ? Math.mulDiv(priceE18, 1 << 192, 10 ** decimals)
            : Math.mulDiv(10 ** decimals, 1 << 192, priceE18);
        return uint160(Math.sqrt(ratioX192));
    }

    // ---------------------------------------------------------------- funding and hand-over

    function _fundRoles(Core memory core) internal {
        address[5] memory roles = [
            TestnetBook.OWNER,
            TestnetBook.OPERATOR,
            TestnetBook.KEEPER,
            TestnetBook.BUNDLER_EXECUTOR,
            TestnetBook.BUNDLER_UTILITY
        ];
        uint256[5] memory targets =
            [FLOAT_OWNER, FLOAT_OPERATOR, FLOAT_KEEPER, FLOAT_BUNDLER_EXECUTOR, FLOAT_BUNDLER_UTILITY];
        uint256 depositTarget = vm.envOr("TESTNET_PAYMASTER_DEPOSIT", PAYMASTER_DEPOSIT);
        uint256 deposit = core.paymaster.getDeposit();

        // Everything this step sends, checked up front so a short deployer fails with the amount to add instead
        // of halfway through the transfers.
        uint256 needed = deposit < depositTarget / 2 ? depositTarget - deposit : 0;
        for (uint256 i; i < roles.length; ++i) {
            needed += _shortfall(roles[i], targets[i]);
        }
        uint256 available = TestnetBook.DEPLOYER.balance;
        if (available < needed) {
            revert(
                string.concat(
                    "deployer needs ",
                    vm.toString(needed - available),
                    " more wei of tBNB for role floats + paymaster deposit (needs ",
                    vm.toString(needed),
                    ", has ",
                    vm.toString(available),
                    ")"
                )
            );
        }

        for (uint256 i; i < roles.length; ++i) {
            uint256 amount = _shortfall(roles[i], targets[i]);
            if (amount == 0) continue;
            (bool ok,) = payable(roles[i]).call{ value: amount }("");
            require(ok, "tBNB transfer failed");
            console.log("fund                TOPUP", roles[i], amount);
        }
        if (deposit < depositTarget / 2) {
            core.paymaster.deposit{ value: depositTarget - deposit }();
            console.log("paymaster deposit   TOPUP (wei)", depositTarget - deposit);
        }
    }

    /// @dev What a role is topped up by: nothing while it holds at least half its float (so a rerun sends
    /// nothing), otherwise back to the full float.
    function _shortfall(address role, uint256 target) internal view returns (uint256) {
        uint256 balance = role.balance;
        return balance >= target / 2 ? 0 : target - balance;
    }

    function _handOver(Core memory core) internal {
        address owner = TestnetBook.OWNER;
        if (core.registry.owner() == TestnetBook.DEPLOYER && core.registry.pendingOwner() != owner) {
            core.registry.transferOwnership(owner);
        }
        if (core.router.owner() == TestnetBook.DEPLOYER && core.router.pendingOwner() != owner) {
            core.router.transferOwnership(owner);
        }
        // OpenZeppelin `Ownable`: one step.
        if (core.paymaster.owner() == TestnetBook.DEPLOYER) core.paymaster.transferOwnership(owner);
    }

    /// @dev DEPLOYER gives up everything it built (cre8-contracts#47): KEEPER's USDT stock first (the last mint
    /// DEPLOYER makes), then on USDT and every mock its minter role and the ownership, the ownership of every feed,
    /// and every LP NFT it holds. Each part is skipped when already done, so a rerun sends nothing.
    function _handOverMarkets(Core memory core, TestnetAssets.AssetSpec[] memory specs, AssetOut[] memory out)
        internal
    {
        address deployer = TestnetBook.DEPLOYER;
        if (core.usdt.isMinter(deployer) && core.usdt.balanceOf(TestnetBook.KEEPER) < KEEPER_USDT_STOCK / 2) {
            core.usdt.mint(TestnetBook.KEEPER, KEEPER_USDT_STOCK - core.usdt.balanceOf(TestnetBook.KEEPER));
        }
        _handOverToken(TestnetToken(address(core.usdt)));
        _handOverFeed(address(core.usdtUsdFeed));
        for (uint256 i; i < specs.length; ++i) {
            _handOverToken(TestnetToken(out[i].token));
            if (out[i].feed != address(0)) _handOverFeed(out[i].feed);
        }
        ITestnetPositionNft nft = ITestnetPositionNft(POSITION_MANAGER);
        for (uint256 held = nft.balanceOf(deployer); held > 0; --held) {
            nft.transferFrom(deployer, TestnetBook.OWNER, nft.tokenOfOwnerByIndex(deployer, held - 1));
        }
    }

    function _handOverToken(TestnetToken token) internal {
        if (token.owner() != TestnetBook.DEPLOYER) return;
        if (token.isMinter(TestnetBook.DEPLOYER)) token.setMinter(TestnetBook.DEPLOYER, false);
        token.transferOwnership(TestnetBook.OWNER);
    }

    function _handOverFeed(address feed) internal {
        if (TestnetPriceFeed(feed).owner() == TestnetBook.DEPLOYER) {
            TestnetPriceFeed(feed).transferOwnership(TestnetBook.OWNER);
        }
    }

    // ---------------------------------------------------------------- helpers

    /// @dev CREATE2 through the deterministic deployer; reuses whatever already sits at the address.
    function _create2(string memory label, bytes memory initCode) internal returns (address deployed) {
        deployed = TestnetBook.create2Address(label, initCode);
        if (deployed.code.length != 0) return deployed;
        (bool ok,) = CREATE2_FACTORY.call(abi.encodePacked(TestnetBook.salt(label), initCode));
        require(ok && deployed.code.length != 0, string.concat(label, ": CREATE2 failed"));
        console.log(string.concat("deploy              NEW   ", label), deployed);
    }

    /// @dev CREATE2 through `TestnetOwnedDeployer` for a contract that makes `msg.sender` its owner. The factory
    /// proposes DEPLOYER (two-step registry / router) or hands it over outright (OpenZeppelin `Ownable`);
    /// DEPLOYER accepts the two-step ones here.
    function _owned(TestnetOwnedDeployer ownedDeployer, string memory label, bytes memory initCode)
        internal
        returns (address deployed)
    {
        bytes32 salt = TestnetBook.salt(label);
        deployed = ownedDeployer.predict(TestnetBook.DEPLOYER, salt, keccak256(initCode));
        if (deployed.code.length == 0) {
            require(
                ownedDeployer.deploy(salt, initCode) == deployed, string.concat(label, ": address mismatch")
            );
            console.log(string.concat("deploy              NEW   ", label), deployed);
        }
        // Also finishes a hand-over an interrupted earlier run left pending.
        (bool ok, bytes memory ret) = deployed.staticcall(abi.encodeWithSignature("pendingOwner()"));
        if (ok && ret.length == 32 && abi.decode(ret, (address)) == TestnetBook.DEPLOYER) {
            AtpRegistry(deployed).acceptOwnership(); // same ABI on the router
        }
    }

    function _minter(TestnetToken token, address minter) internal {
        if (!token.isMinter(minter)) token.setMinter(minter, true);
    }

    function _fund(TestnetToken token, uint256 amount) internal {
        uint256 balance = token.balanceOf(TestnetBook.DEPLOYER);
        if (balance < amount) token.mint(TestnetBook.DEPLOYER, amount - balance);
        if (token.allowance(TestnetBook.DEPLOYER, POSITION_MANAGER) < amount) {
            token.approve(POSITION_MANAGER, type(uint256).max);
        }
    }

    // ---------------------------------------------------------------- verification

    function _verify(Core memory core, TestnetAssets.AssetSpec[] memory specs, AssetOut[] memory out)
        internal
        view
    {
        require(
            core.registry.owner() == TestnetBook.OWNER && core.registry.pendingOwner() == address(0),
            "registry owner"
        );
        require(core.registry.operator() == TestnetBook.OPERATOR, "registry operator");
        require(
            address(core.executor.yieldRegistry()) == address(core.yields)
                && core.yields.marketCount() == YieldBook.COUNT
                && core.yields.reader() == expectedYieldView(),
            "yield registry pins"
        );
        require(
            core.router.owner() == TestnetBook.OWNER && core.router.pendingOwner() == address(0),
            "router owner"
        );
        require(core.router.numeraire() == address(core.usdt), "router numeraire");
        require(address(core.executor.registry()) == address(core.registry), "executor registry");
        require(address(core.executor.oracle()) == address(core.router), "executor oracle");
        require(address(core.executor.universalRouter()) == V3_UNIVERSAL_ROUTER, "executor UR");
        require(address(core.executor.permit2()) == PERMIT2, "executor permit2");
        require(core.executor.numeraire() == address(core.usdt), "executor numeraire");
        require(core.executor.feeRecipient() == TestnetBook.FEE_RECIPIENT, "executor fee recipient");
        require(core.executor.maxBuyBps() == MAX_BUY_BPS && !core.executor.globalPaused(), "executor guards");
        require(core.executor.minBatchFee() == MIN_BATCH_FEE, "executor minBatchFee");
        require(core.registry.defaultSwapFeeBps() == DEFAULT_FEE_BPS, "registry default fee");
        require(core.registry.numeraire() == address(core.usdt), "registry numeraire");
        (AtpExecutor.VenueKind kind,) = core.executor.venues(V3_UNIVERSAL_ROUTER);
        require(kind == AtpExecutor.VenueKind.PANCAKE_UR, "UR venue");
        require(core.usdt.decimals() == 18 && core.usdt.dailyLimit() == FAUCET_DAILY_LIMIT, "USDT");
        require(core.usdt.isFaucet(TestnetBook.OPERATOR), "USDT faucet");
        require(
            !core.usdt.isMinter(TestnetBook.OPERATOR) && !core.usdt.isMinter(TestnetBook.KEEPER)
                && !core.usdt.isMinter(TestnetBook.DEPLOYER) && core.usdt.owner() == TestnetBook.OWNER,
            "USDT: no minter left but whom OWNER appoints"
        );
        require(core.usdt.balanceOf(TestnetBook.KEEPER) >= KEEPER_USDT_STOCK / 2, "keeper USDT stock");
        require(
            core.usdtUsdFeed.keeper() == TestnetBook.KEEPER && core.usdtUsdFeed.owner() == TestnetBook.OWNER,
            "USDT/USD keeper / owner"
        );
        require(ITestnetPositionNft(POSITION_MANAGER).balanceOf(TestnetBook.DEPLOYER) == 0, "LP NFTs left");
        require(GAS_POLICY.codehash == GAS_POLICY_CODEHASH, "GasPolicy");
        require(
            address(core.paymaster.entryPoint()) == ENTRY_POINT_V07
                && core.paymaster.verifyingSigner() == TestnetBook.PAYMASTER_SIGNER
                && core.paymaster.owner() == TestnetBook.OWNER && core.paymaster.getDeposit() > 0,
            "paymaster"
        );

        for (uint256 i; i < specs.length; ++i) {
            TestnetAssets.AssetSpec memory spec = specs[i];
            TestnetToken token = TestnetToken(out[i].token);
            require(
                token.decimals() == spec.decimals
                    && keccak256(bytes(token.symbol())) == keccak256(bytes(spec.symbol)),
                string.concat(spec.symbol, ": token")
            );
            require(token.isMinter(TestnetBook.KEEPER), string.concat(spec.symbol, ": keeper minter"));
            require(
                token.owner() == TestnetBook.OWNER && !token.isMinter(TestnetBook.DEPLOYER),
                string.concat(spec.symbol, ": owner / deployer minter")
            );
            if (spec.uiMultiplier != 0) {
                require(
                    TestnetBStock(address(token)).uiMultiplier() == spec.uiMultiplier,
                    string.concat(spec.symbol, ": uiMultiplier")
                );
            }
            IPancakeV3Pool pool = IPancakeV3Pool(out[i].pool);
            require(pool.fee() == spec.fee && pool.liquidity() > 0, string.concat(spec.symbol, ": pool"));
            _requirePoolPrice(spec, address(pool), address(token) < address(core.usdt));
            // `observationCardinality >= 2` is checked on chain by deploy-97.sh: the simulation runs every
            // transaction at one timestamp, so a new pool never writes the observation that grows it here.
            (,,,, uint16 cardinalityNext,,) = pool.slot0();
            require(cardinalityNext >= OBSERVATION_CARDINALITY, string.concat(spec.symbol, ": cardinality"));
            PancakeV3TwapOracle oracle = core.router.oracleOf(address(token));
            require(
                address(oracle) == out[i].oracle && oracle.maxSlippageBps() == spec.maxSlippageBps
                    && oracle.twapWindow() == TWAP_WINDOW && oracle.maxOracleAge() == MAX_ORACLE_AGE,
                string.concat(spec.symbol, ": oracle")
            );
            (IPriceSource source, uint16 deviation) = core.router.secondaryOf(address(token));
            if (spec.hasFeed) {
                require(
                    address(source) == out[i].source && deviation == SECONDARY_MAX_DEVIATION_BPS,
                    string.concat(spec.symbol, ": secondary")
                );
                PushFeedPriceSource push = PushFeedPriceSource(address(source));
                require(
                    address(push.assetFeed()) == out[i].feed
                        && address(push.numeraireFeed()) == address(core.usdtUsdFeed)
                        && push.maxAge() == spec.maxFeedAge && push.numeraireMaxAge() == USDT_USD_MAX_AGE,
                    string.concat(spec.symbol, ": secondary feeds / max ages")
                );
                require(
                    TestnetPriceFeed(out[i].feed).keeper() == TestnetBook.KEEPER
                        && TestnetPriceFeed(out[i].feed).owner() == TestnetBook.OWNER,
                    string.concat(spec.symbol, ": keeper / owner")
                );
            } else {
                require(address(source) == address(0), string.concat(spec.symbol, ": unexpected secondary"));
            }
        }
    }

    /// @dev `MANIFEST <key> <address>` lines are what `scripts/testnet/deploy-97.sh` turns into the manifest.
    function _report(Core memory core, TestnetAssets.AssetSpec[] memory specs, AssetOut[] memory out)
        internal
        view
    {
        _verifyYieldView(core.yields.reader());
        console.log("");
        _line("role.deployer", TestnetBook.DEPLOYER);
        _line("role.owner", TestnetBook.OWNER);
        _line("role.operator", TestnetBook.OPERATOR);
        _line("role.keeper", TestnetBook.KEEPER);
        _line("role.paymasterSigner", TestnetBook.PAYMASTER_SIGNER);
        _line("role.feeRecipient", TestnetBook.FEE_RECIPIENT);
        _line("role.bundlerExecutor", TestnetBook.BUNDLER_EXECUTOR);
        _line("role.bundlerUtility", TestnetBook.BUNDLER_UTILITY);
        _line("ownedDeployer", address(core.ownedDeployer));
        _line("registry", address(core.registry));
        _line("router", address(core.router));
        _line("executor", address(core.executor));
        _line("yieldRegistry", address(core.yields));
        _line("yieldView", core.yields.reader());
        _reportYield(core);
        _line("usdt", address(core.usdt));
        _line("feed.USDT/USD", address(core.usdtUsdFeed));
        _line("paymaster", address(core.paymaster));
        _line("gasPolicy", GAS_POLICY);
        _line("entryPoint", ENTRY_POINT_V07);
        _line("v3Factory", V3_FACTORY);
        _line("positionManager", POSITION_MANAGER);
        _line("universalRouter", V3_UNIVERSAL_ROUTER);
        _line("permit2", PERMIT2);
        for (uint256 i; i < specs.length; ++i) {
            string memory s = specs[i].symbol;
            _line(string.concat("asset.", s, ".token"), out[i].token);
            _line(string.concat("asset.", s, ".pool"), out[i].pool);
            _line(string.concat("asset.", s, ".oracle"), out[i].oracle);
            if (out[i].feed != address(0)) {
                _line(string.concat("asset.", s, ".feed"), out[i].feed);
                _line(string.concat("asset.", s, ".secondary"), out[i].source);
            }
        }
    }

    function _line(string memory key, address value) internal pure {
        console.log(string.concat("MANIFEST ", key, " ", vm.toString(value)));
    }
}
