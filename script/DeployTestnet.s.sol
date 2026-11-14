// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Script, console } from "forge-std/Script.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { AtpRegistry } from "../src/atp/AtpRegistry.sol";
import { AtpExecutor } from "../src/atp/AtpExecutor.sol";
import { AtpMultiPoolOracle } from "../src/atp/AtpMultiPoolOracle.sol";
import { PancakeV3TwapOracle } from "../src/atp/PancakeV3TwapOracle.sol";
import { IAggregatorV3 } from "../src/atp/interfaces/IAggregatorV3.sol";
import { IPancakeV3Pool } from "../src/atp/interfaces/IPancakeV3Pool.sol";
import { IPriceSource } from "../src/atp/interfaces/IPriceSource.sol";
import { TestnetToken, TestnetBStock, TestnetUSDT } from "../src/testnet/TestnetToken.sol";
import { TestnetPriceFeed } from "../src/testnet/TestnetPriceFeed.sol";
import { TestnetOwnedDeployer } from "../src/testnet/TestnetOwnedDeployer.sol";
import { VerifyingPaymaster } from "../src/testnet/aa/samples/VerifyingPaymaster.sol";
import { IEntryPoint } from "../src/testnet/aa/interfaces/IEntryPoint.sol";
import { TestnetAssets } from "./testnet/TestnetAssets.sol";
import { TestnetBook } from "./testnet/TestnetBook.sol";
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

/// @title DeployTestnet
/// @notice BSC TESTNET (chain 97) ONLY (cre8-contracts#30). Deploys the whole CRE8 stack against mock assets:
/// - testnet USDT (numeraire, capped faucet) and 38 mock launch assets (`TestnetAssets`);
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
/// Changing a contract's code or constructor arguments moves its address (a new deployment next to the old
/// one), which is the intended versioning.
///
/// @dev Roles (`TestnetBook`; new keys in ~/.cre8-testnet/, no Safe on testnet): DEPLOYER deploys, owns the
/// mocks and LP positions, configures, then hands the registry, router and paymaster to OWNER (the Safe's
/// stand-in), which accepts in the same run. Configuration on a rerun is sent by whoever owns the contract
/// then. OPERATOR = registry operator + USDT faucet minter; KEEPER = only feed pusher + mock minter;
/// PAYMASTER_SIGNER signs sponsorships; FEE_RECIPIENT gets the executor fee; BUNDLER_* run alto.
///
/// @dev Run: `scripts/testnet/deploy-97.sh` (fork or public chain 97, writes and checks the manifest); see
/// docs/testnet-97.zh-TW.md. Broadcasts from DEPLOYER and OWNER, so both must be available as signers
/// (`--unlocked` on a fork; two `--private-keys` on chain 97).
contract DeployTestnet is Script {
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
    uint16 internal constant SECONDARY_MAX_DEVIATION_BPS = 200;

    // ---- testnet-only parameters ----
    /// @dev Full-range liquidity per side, in USDT: 100 USDT moves a pool ~0.004%, 10,000 USDT ~0.4%.
    uint256 internal constant LIQUIDITY_PER_SIDE = 5_000_000e18;
    /// @dev Observation slots per pool. A TWAP read needs the oldest kept observation to be at least 30 minutes
    /// old; a pool writes at most one observation per block with a swap, so 600 slots serve 30 minutes while
    /// the pool trades in fewer than one block in ~7 (BSC testnet: ~0.45 s blocks), i.e. at most every 3 s.
    uint16 internal constant OBSERVATION_CARDINALITY = 600;
    /// @dev The second, tiny mint that makes a pool write its first post-initialization observation.
    uint256 internal constant POKE_LIQUIDITY = 1e18;
    uint256 internal constant FAUCET_DAILY_LIMIT = 10_000e18;
    uint8 internal constant FEED_DECIMALS = 8;
    int24 internal constant MAX_TICK = 887_272;

    // ---- tBNB float per role, topped up from DEPLOYER when below half (so a rerun sends nothing) ----
    uint256 internal constant FLOAT_OWNER = 0.01 ether;
    uint256 internal constant FLOAT_OPERATOR = 0.05 ether;
    uint256 internal constant FLOAT_KEEPER = 0.3 ether;
    uint256 internal constant FLOAT_BUNDLER_EXECUTOR = 0.1 ether;
    uint256 internal constant FLOAT_BUNDLER_UTILITY = 0.02 ether;
    /// @dev The paymaster's EntryPoint deposit pays every sponsored UserOp; the default covers ~10,000 ops of
    /// 500k gas at 0.1 gwei. `TESTNET_PAYMASTER_DEPOSIT` (wei) overrides it.
    uint256 internal constant PAYMASTER_DEPOSIT = 0.5 ether;

    struct Core {
        TestnetOwnedDeployer ownedDeployer;
        TestnetUSDT usdt;
        AtpRegistry registry;
        AtpMultiPoolOracle router;
        AtpExecutor executor;
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
        require(
            ITestnetPositionManager(POSITION_MANAGER).factory() == V3_FACTORY,
            "position manager / factory mismatch"
        );
        TestnetAssets.AssetSpec[] memory specs = TestnetAssets.specs();
        AssetOut[] memory out = new AssetOut[](specs.length);

        // 1. DEPLOYER: contracts, mocks, pools, liquidity, feeds.
        vm.startBroadcast(TestnetBook.DEPLOYER);
        _gasPolicy();
        Core memory core = _core();
        for (uint256 i; i < specs.length; ++i) {
            out[i] = _market(core, specs[i]);
        }
        vm.stopBroadcast();

        // 2. Whoever owns the registry / router now (DEPLOYER on the first run, OWNER after the hand-over).
        vm.startBroadcast(core.registry.owner());
        if (core.registry.operator() != TestnetBook.OPERATOR) {
            core.registry.setOperator(TestnetBook.OPERATOR);
        }
        vm.stopBroadcast();
        vm.startBroadcast(core.router.owner());
        for (uint256 i; i < specs.length; ++i) {
            _oracles(core, specs[i], out[i]);
        }
        vm.stopBroadcast();

        // 3. DEPLOYER: tBNB for every role, the paymaster deposit, and the ownership proposals.
        vm.startBroadcast(TestnetBook.DEPLOYER);
        _fundRoles(core);
        _handOver(core);
        vm.stopBroadcast();

        // 4. OWNER accepts.
        vm.startBroadcast(TestnetBook.OWNER);
        if (core.registry.pendingOwner() == TestnetBook.OWNER) core.registry.acceptOwnership();
        if (core.router.pendingOwner() == TestnetBook.OWNER) core.router.acceptOwnership();
        vm.stopBroadcast();

        _verify(core, specs, out);
        _report(core, specs, out);
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
                        MAX_BUY_BPS
                    )
                )
            )
        );
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
        _minter(TestnetToken(address(core.usdt)), TestnetBook.KEEPER);
        _minter(TestnetToken(address(core.usdt)), TestnetBook.OPERATOR);
    }

    // ---------------------------------------------------------------- per asset

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
                    // The testnet keeps one max age for both feeds (its pre-#25 behaviour): the deployed
                    // chain-97 stack was built that way and this script re-verifies it as is.
                    spec.maxFeedAge,
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
        }

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
        }
        // A pool writes at most one observation per second: if the mint landed in the second the pool was
        // initialized in, nothing grew and the TWAP adapter (which needs >= 2 slots) stays unavailable. A tiny
        // second mint, one block later, is the write that grows it.
        (,,, uint16 cardinality,,,) = IPancakeV3Pool(pool).slot0();
        if (cardinality < 2) _mintFullRange(spec, token, usdt, edge, POKE_LIQUIDITY);
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
        (AtpExecutor.VenueKind kind,) = core.executor.venues(V3_UNIVERSAL_ROUTER);
        require(kind == AtpExecutor.VenueKind.PANCAKE_UR, "UR venue");
        require(core.usdt.decimals() == 18 && core.usdt.dailyLimit() == FAUCET_DAILY_LIMIT, "USDT");
        require(
            core.usdt.isMinter(TestnetBook.OPERATOR) && core.usdt.isMinter(TestnetBook.KEEPER), "USDT minters"
        );
        require(core.usdtUsdFeed.keeper() == TestnetBook.KEEPER, "USDT/USD keeper");
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
            if (spec.uiMultiplier != 0) {
                require(
                    TestnetBStock(address(token)).uiMultiplier() == spec.uiMultiplier,
                    string.concat(spec.symbol, ": uiMultiplier")
                );
            }
            IPancakeV3Pool pool = IPancakeV3Pool(out[i].pool);
            require(pool.fee() == spec.fee && pool.liquidity() > 0, string.concat(spec.symbol, ": pool"));
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
                require(
                    TestnetPriceFeed(out[i].feed).keeper() == TestnetBook.KEEPER,
                    string.concat(spec.symbol, ": keeper")
                );
            } else {
                require(address(source) == address(0), string.concat(spec.symbol, ": unexpected secondary"));
            }
        }
    }

    /// @dev `MANIFEST <key> <address>` lines are what `scripts/testnet/deploy-97.sh` turns into the manifest.
    function _report(Core memory core, TestnetAssets.AssetSpec[] memory specs, AssetOut[] memory out)
        internal
        pure
    {
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
