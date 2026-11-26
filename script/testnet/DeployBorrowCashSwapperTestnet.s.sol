// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Script, console } from "forge-std/Script.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { AtpRegistry } from "../../src/atp/AtpRegistry.sol";
import { IAtpBorrowExecutorV2 } from "../../src/atp/borrow/v2/IAtpBorrowExecutorV2.sol";
import { AtpBorrowRegistryV2 } from "../../src/atp/borrow/v2/AtpBorrowRegistryV2.sol";
import { AtpBorrowCashSwapper } from "../../src/atp/borrow/v2/AtpBorrowCashSwapper.sol";
import { TestnetToken } from "../../src/testnet/TestnetToken.sol";
import { TestnetBook as TB } from "./TestnetBook.sol";

interface ICashV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address);
    function feeAmountTickSpacing(uint24 fee) external view returns (int24);
}

interface ICashV3Pool {
    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint32, bool);
    function liquidity() external view returns (uint128);
}

interface ICashPositionManager {
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

/// @notice Chain 97 only: `AtpBorrowCashSwapper` for the routing v2 set recorded in
/// `deployments/testnet-97.json` (`borrowV2.executor`; ROUTING_EXECUTOR overrides it, for a rehearsal against a
/// set that is not in the manifest yet), with a PancakeSwap V3 0.01% pool of testnet USDT against each of the
/// simulated USDC / USD1 / U at 1:1 and liquidity around it. Nothing already deployed is changed, except that
/// OWNER is a USDT minter for the length of one mint.
/// DEPLOYER (the sender) creates the swapper (CREATE2), the three pools and their liquidity positions; OWNER,
/// which owns the registry and the simulated tokens, mints the pool money to DEPLOYER and allowlists the pools.
/// Idempotent: a rerun broadcasts nothing. The swapper is bound to one executor: a new routing v2 set gets a
/// new swapper (another CREATE2 address) from the same command; the pools are reused.
/// Keys: TESTNET_DEPLOYER_KEY / TESTNET_OWNER_KEY (fork: --unlocked).
contract DeployBorrowCashSwapperTestnet is Script {
    address internal constant V3_FACTORY = 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865;
    address internal constant POSITION_MANAGER = 0x427bF5b37357632377eCbEC9de3626C71A5396c1;
    uint24 internal constant POOL_FEE = 100; // 0.01%, tick spacing 1: mainnet's stable pools
    uint160 internal constant SQRT_PRICE_1_1 = 79_228_162_514_264_337_593_543_950_336; // 2^96
    /// @dev Liquidity within 0.2% of parity; a pool whose price left 0.3% is refused.
    int24 internal constant RANGE_TICKS = 20;
    int24 internal constant MAX_PRICE_TICKS = 30;
    /// @notice Each side of each pool. Around 1,000,000 a side a 50,000 swap moves the price by about 0.01%.
    uint256 internal constant POOL_SEED = 1_000_000e18;
    string internal constant SWAPPER_LABEL = "routing.cashSwapper";

    struct Out {
        AtpBorrowCashSwapper swapper;
        address executor;
        address usdt;
        address[3] tokens; // USDC, USD1, U
        address[3] pools;
    }

    function run() external returns (Out memory o) {
        require(block.chainid == 97, "cash swapper deploy: chain 97 only");
        _rememberKey("TESTNET_DEPLOYER_KEY", TB.DEPLOYER);
        _rememberKey("TESTNET_OWNER_KEY", TB.OWNER);
        _book(o);
        require(ICashPositionManager(POSITION_MANAGER).factory() == V3_FACTORY, "position manager factory");
        require(ICashV3Factory(V3_FACTORY).feeAmountTickSpacing(POOL_FEE) == 1, "0.01% tier");

        bytes memory initCode =
            abi.encodePacked(type(AtpBorrowCashSwapper).creationCode, abi.encode(o.executor));
        o.swapper = AtpBorrowCashSwapper(TB.create2Address(SWAPPER_LABEL, initCode));

        // 1. DEPLOYER: the swapper and the pools (anyone may create a pool; a pool somebody else created at
        // another price is refused below).
        vm.startBroadcast(TB.DEPLOYER);
        _create2(SWAPPER_LABEL, initCode);
        for (uint256 i; i < 3; ++i) {
            o.pools[i] = _pool(o.usdt, o.tokens[i]);
        }
        vm.stopBroadcast();

        // 2. OWNER: the pool money, minted to DEPLOYER (only what the empty pools still need).
        uint256 usdtNeeded;
        bool[3] memory empty;
        for (uint256 i; i < 3; ++i) {
            empty[i] = ICashV3Pool(o.pools[i]).liquidity() == 0;
            if (empty[i]) usdtNeeded += POOL_SEED;
        }
        vm.startBroadcast(TB.OWNER);
        _mint(o.usdt, usdtNeeded);
        for (uint256 i; i < 3; ++i) {
            if (empty[i]) _mint(o.tokens[i], POOL_SEED);
        }
        if (TestnetToken(o.usdt).isMinter(TB.OWNER)) TestnetToken(o.usdt).setMinter(TB.OWNER, false);
        vm.stopBroadcast();

        // 3. DEPLOYER: liquidity around parity.
        vm.startBroadcast(TB.DEPLOYER);
        for (uint256 i; i < 3; ++i) {
            if (empty[i]) _addLiquidity(o.usdt, o.tokens[i]);
        }
        vm.stopBroadcast();

        // 4. OWNER: allowlist.
        vm.startBroadcast(TB.OWNER);
        for (uint256 i; i < 3; ++i) {
            if (o.swapper.poolOf(o.tokens[i]) != o.pools[i]) o.swapper.setPool(o.tokens[i], o.pools[i]);
        }
        vm.stopBroadcast();

        _verify(o);
        console.log("MANIFEST cashSwapper", address(o.swapper));
        console.log("MANIFEST cashSwapper.routingExecutor", o.executor);
        string[3] memory symbols = ["USDC", "USD1", "U"];
        for (uint256 i; i < 3; ++i) {
            console.log(string.concat("MANIFEST cashSwapper.pool.", symbols[i]), o.pools[i]);
        }
        console.log("MANIFEST cashSwapper.maxPegBps", o.swapper.maxPegBps());
        console.log("MANIFEST cashSwapper.bufferBps", o.swapper.bufferBps());
    }

    /// @dev The routing v2 executor and its loan tokens, from the manifest; every address is then held
    /// against the chain (the executor's registry lists the tokens, OWNER owns them and the core registry).
    function _book(Out memory o) private view {
        string memory json = vm.readFile(string.concat(vm.projectRoot(), "/deployments/testnet-97.json"));
        require(vm.parseJsonUint(json, ".chainId") == 97, "manifest: other chain");
        o.executor = vm.envOr("ROUTING_EXECUTOR", vm.parseJsonAddress(json, ".borrowV2.executor"));
        require(o.executor.code.length != 0, "cash swapper deploy: routing executor has no code");
        AtpBorrowRegistryV2 credit = AtpBorrowRegistryV2(IAtpBorrowExecutorV2(o.executor).borrowRegistry());
        AtpRegistry registry = credit.registry();
        require(credit.executor() == o.executor, "cash swapper deploy: routing wiring");
        require(registry.owner() == TB.OWNER, "cash swapper deploy: registry owner");
        o.usdt = registry.numeraire();
        require(o.usdt == vm.parseJsonAddress(json, ".contracts.usdt"), "cash swapper deploy: USDT");
        string[3] memory symbols = ["USDC", "USD1", "U"];
        for (uint256 i; i < 3; ++i) {
            address token = vm.parseJsonAddress(json, string.concat(".borrowV2.loanTokens.", symbols[i]));
            require(
                credit.loanTokenAllowed(token) && TestnetToken(token).owner() == TB.OWNER
                    && IERC20Metadata(token).decimals() == 18
                    && keccak256(bytes(IERC20Metadata(token).symbol())) == keccak256(bytes(symbols[i])),
                string.concat("cash swapper deploy: loan token ", symbols[i])
            );
            o.tokens[i] = token;
        }
        require(TestnetToken(o.usdt).owner() == TB.OWNER, "cash swapper deploy: USDT owner");
    }

    function _pool(address usdt, address token) private returns (address pool) {
        pool = ICashV3Factory(V3_FACTORY).getPool(usdt, token, POOL_FEE);
        if (pool == address(0)) {
            (address token0, address token1) = usdt < token ? (usdt, token) : (token, usdt);
            pool = ICashPositionManager(POSITION_MANAGER)
                .createAndInitializePoolIfNecessary(token0, token1, POOL_FEE, SQRT_PRICE_1_1);
        }
        _requireParity(pool);
    }

    /// @dev Both tokens have 18 decimals: parity is tick 0. A pool that sits elsewhere (somebody created it
    /// first, or drained one side) is not something to add liquidity to or to allowlist.
    function _requireParity(address pool) private view {
        (uint160 sqrtPrice, int24 tick,,,,,) = ICashV3Pool(pool).slot0();
        require(
            sqrtPrice != 0 && tick >= -MAX_PRICE_TICKS && tick <= MAX_PRICE_TICKS,
            "cash swapper deploy: pool is not at parity"
        );
    }

    function _addLiquidity(address usdt, address token) private {
        (address token0, address token1) = usdt < token ? (usdt, token) : (token, usdt);
        _approve(token0);
        _approve(token1);
        ICashPositionManager(POSITION_MANAGER)
            .mint(
                ICashPositionManager.MintParams({
                    token0: token0,
                    token1: token1,
                    fee: POOL_FEE,
                    tickLower: -RANGE_TICKS,
                    tickUpper: RANGE_TICKS,
                    amount0Desired: POOL_SEED,
                    amount1Desired: POOL_SEED,
                    amount0Min: POOL_SEED * 9 / 10,
                    amount1Min: POOL_SEED * 9 / 10,
                    recipient: TB.DEPLOYER,
                    deadline: block.timestamp + 1 days
                })
            );
    }

    function _approve(address token) private {
        if (TestnetToken(token).allowance(TB.DEPLOYER, POSITION_MANAGER) < POOL_SEED) {
            TestnetToken(token).approve(POSITION_MANAGER, type(uint256).max);
        }
    }

    /// @dev OWNER mints to DEPLOYER what DEPLOYER is short of `amount`. OWNER is a minter of the simulated
    /// loan tokens; for USDT it lends itself the role and `run` takes it back in the same broadcast.
    function _mint(address token, uint256 amount) private {
        uint256 balance = TestnetToken(token).balanceOf(TB.DEPLOYER);
        if (balance >= amount) return;
        if (!TestnetToken(token).isMinter(TB.OWNER)) TestnetToken(token).setMinter(TB.OWNER, true);
        TestnetToken(token).mint(TB.DEPLOYER, amount - balance);
    }

    function _verify(Out memory o) private view {
        AtpBorrowCashSwapper s = o.swapper;
        require(address(s).code.length != 0, "cash swapper deploy: swapper missing");
        require(
            s.executor() == o.executor && s.usdt() == o.usdt
                && s.borrowRegistry() == IAtpBorrowExecutorV2(o.executor).borrowRegistry()
                && s.lens() == IAtpBorrowExecutorV2(o.executor).lens(),
            "cash swapper deploy: swapper wiring"
        );
        for (uint256 i; i < 3; ++i) {
            require(
                o.pools[i] == ICashV3Factory(V3_FACTORY).getPool(o.usdt, o.tokens[i], POOL_FEE)
                    && s.poolOf(o.tokens[i]) == o.pools[i] && ICashV3Pool(o.pools[i]).liquidity() != 0,
                "cash swapper deploy: pool"
            );
            _requireParity(o.pools[i]);
        }
        require(!TestnetToken(o.usdt).isMinter(TB.OWNER), "cash swapper deploy: OWNER is still a USDT minter");
    }

    function _create2(string memory label, bytes memory initCode) private returns (address expected) {
        expected = TB.create2Address(label, initCode);
        if (expected.code.length != 0) return expected;
        (bool ok, bytes memory result) = TB.CREATE2_FACTORY.call(abi.encodePacked(TB.salt(label), initCode));
        require(
            ok && result.length == 20 && address(bytes20(result)) == expected,
            string.concat("CREATE2 failed: ", label)
        );
    }

    function _rememberKey(string memory name, address expected) private {
        uint256 key = vm.envOr(name, uint256(0));
        if (key == 0) return;
        require(vm.addr(key) == expected, string.concat(name, " does not derive the expected address"));
        vm.rememberKey(key);
    }
}
