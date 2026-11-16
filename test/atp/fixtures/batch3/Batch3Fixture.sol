// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { AtpExecutor } from "../../../../src/atp/AtpExecutor.sol";
import { AtpRegistry } from "../../../../src/atp/AtpRegistry.sol";
import { AtpMultiPoolOracle } from "../../../../src/atp/AtpMultiPoolOracle.sol";
import { PancakeV3TwapOracle, TickMathLite } from "../../../../src/atp/PancakeV3TwapOracle.sol";
import { IPancakeV3Pool } from "../../../../src/atp/interfaces/IPancakeV3Pool.sol";
import { TestnetToken } from "../../../../src/testnet/TestnetToken.sol";
import { MockPermit2, MockUniversalRouter } from "../../AtpExecutor.t.sol";
import { PancakeV3PoolCode } from "./PancakeV3PoolCode.sol";

interface LocalV3Pool is IPancakeV3Pool {
    function initialize(uint160 sqrtPriceX96) external;
    function increaseObservationCardinalityNext(uint16 next) external;
    function mint(address recipient, int24 lower, int24 upper, uint128 amount, bytes calldata data)
        external
        returns (uint256 amount0, uint256 amount1);
    function swap(address recipient, bool zeroForOne, int256 amount, uint160 limit, bytes calldata data)
        external
        returns (int256 amount0, int256 amount1);
}

/// @dev Only supplies the official pool constructor's parameters. No factory or chain state is imported.
contract LocalPoolDeployer {
    address private token0;
    address private token1;

    function parameters() external view returns (address, address, address, uint24, int24) {
        return (address(this), token0, token1, 500, 10);
    }

    function deploy(bytes memory code, address a, address b) external returns (LocalV3Pool pool) {
        (token0, token1) = a < b ? (a, b) : (b, a);
        address deployed;
        assembly {
            deployed := create(0, add(code, 32), mload(code))
        }
        require(deployed != address(0), "local pool deployment failed");
        pool = LocalV3Pool(deployed);
    }
}

/// @dev Test-only LP/market actor AND ERC20_APPROVE venue. Swaps consume real input and return the actual
/// pool output. There is no amountOut/minimum in its calldata, no mint-on-swap, and no oracle override.
contract LocalPoolVenue {
    LocalV3Pool public immutable pool;

    constructor(LocalV3Pool pool_) {
        pool = pool_;
    }

    function addLiquidity(uint128 amount) external {
        pool.mint(address(this), -887_270, 887_270, amount, "");
    }

    function swap(address tokenIn, uint256 amountIn) external returns (uint256 received) {
        require(tokenIn == pool.token0() || tokenIn == pool.token1(), "wrong pool token");
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        bool zeroForOne = tokenIn == pool.token0();
        (int256 a, int256 b) = pool.swap(
            msg.sender,
            zeroForOne,
            int256(amountIn),
            zeroForOne ? 4_295_128_740 : 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_341,
            ""
        );
        require(uint256(zeroForOne ? a : b) == amountIn, "local swap partially filled");
        received = uint256(-(zeroForOne ? b : a));
    }

    /// @dev Market movement writes the pool's own tick cumulatives. No synthetic observation setters.
    function moveToTick(int24 targetTick) external {
        (uint160 current,,,,,,) = pool.slot0();
        uint160 target = TickMathLite.getSqrtPriceAtTick(targetTick);
        if (target == current) return;
        pool.swap(address(this), target < current, int256(1e30), target, "");
    }

    function pancakeV3MintCallback(uint256 amount0, uint256 amount1, bytes calldata) external {
        require(msg.sender == address(pool), "unexpected mint callback");
        if (amount0 != 0) IERC20(pool.token0()).transfer(msg.sender, amount0);
        if (amount1 != 0) IERC20(pool.token1()).transfer(msg.sender, amount1);
    }

    function pancakeV3SwapCallback(int256 amount0, int256 amount1, bytes calldata) external {
        require(msg.sender == address(pool), "unexpected swap callback");
        if (amount0 > 0) IERC20(pool.token0()).transfer(msg.sender, uint256(amount0));
        if (amount1 > 0) IERC20(pool.token1()).transfer(msg.sender, uint256(amount1));
    }
}

/// @notice Reusable offline chain-97 fixture for CT-1 / BE-4: real V3 observations, production oracle and
/// executor, TestnetToken transfer logs, 10 bps fee and 0.30 USDT minimum. All state lives in Foundry's EVM.
abstract contract Batch3Fixture is Test {
    address internal constant OPERATOR = address(0x0FE7);
    address internal constant FEE_RECIPIENT = address(0xFEE);
    address internal constant SECOND = address(0xBEEF);
    uint32 internal constant WINDOW = 30 minutes;
    uint16 internal constant FEE_BPS = 10;
    uint256 internal constant BPS = 10_000;

    TestnetToken internal usdt;
    TestnetToken internal asset;
    LocalV3Pool internal pool;
    LocalPoolVenue internal venue;
    PancakeV3TwapOracle internal pairOracle;
    AtpMultiPoolOracle internal oracle;
    AtpRegistry internal registry;
    AtpExecutor internal executor;
    uint256 internal strategy;

    function setUp() public virtual {
        vm.chainId(97);
        vm.warp(100 days + 17 hours + 37 minutes); // deliberately not a UTC-day boundary
        usdt = new TestnetToken("Local USDT", "USDT", 18, address(this));
        asset = new TestnetToken("Local asset", "ASSET", 18, address(this));
        pool = _newPool(asset, usdt);
        venue = new LocalPoolVenue(pool);
        usdt.mint(address(venue), 1e32);
        asset.mint(address(venue), 1e32);
        venue.addLiquidity(1_000_000e18);
        oracle = new AtpMultiPoolOracle(address(usdt));
        pairOracle = oracle.setOracle(address(asset), address(pool), WINDOW, 50, 1 hours);
        registry = new AtpRegistry();
        registry.setOperator(OPERATOR);
        registry.setDefaultFeeBps(FEE_BPS);
        address permit = 0x31c2F6fcFf4F8759b3Bd5Bf0e1084A055615c768;
        vm.etch(permit, address(new MockPermit2()).code);
        executor = new AtpExecutor(
            registry, new MockUniversalRouter(), oracle, permit, FEE_RECIPIENT, address(usdt), 10_000, 0.3e18
        );
        executor.setVenue(address(venue), AtpExecutor.VenueKind.ERC20_APPROVE, address(venue));
        address[] memory assets = new address[](2);
        assets[0] = address(usdt);
        assets[1] = address(asset);
        uint16[] memory weights = new uint16[](2);
        weights[0] = 5_000;
        weights[1] = 5_000;
        strategy = registry.registerStrategy("batch3", "local regression", true);
        // P11: publish one day before this fixture, then restore its exact pool-history clock.
        uint256 enrollmentTime = vm.getBlockTimestamp();
        vm.warp(enrollmentTime - 1 days);
        registry.publishVersion(strategy, assets, weights, keccak256("batch3 schema3"), 0);
        vm.warp(enrollmentTime);
        registry.enroll(address(this), strategy, 1);
        vm.etch(SECOND, hex"00");
        vm.prank(SECOND);
        registry.approveEnrollment(strategy, 1);
        vm.prank(OPERATOR);
        registry.enroll(SECOND, strategy, 1);
        for (uint256 i; i < 2; ++i) {
            address account = i == 0 ? address(this) : SECOND;
            usdt.mint(account, 1_000e18);
            asset.mint(account, 1_000e18);
            vm.startPrank(account);
            usdt.approve(address(executor), type(uint256).max);
            asset.approve(address(executor), type(uint256).max);
            vm.stopPrank();
        }
    }

    function _newPool(TestnetToken a, TestnetToken b) internal returns (LocalV3Pool created) {
        return _newPoolAtTick(a, b, 0);
    }

    function _newPoolAtTick(TestnetToken a, TestnetToken b, int24 tick)
        internal
        returns (LocalV3Pool created)
    {
        bytes memory code = new PancakeV3PoolCode().creationCode();
        // Pin the upstream creation code, including its original solc metadata (see README.md).
        assertEq(sha256(code), 0x034ffaf7180fa30ebc95543ff0496c2ca5e1b3621c7aeb000285b9812662c6c6);
        created = new LocalPoolDeployer().deploy(code, address(a), address(b));
        created.initialize(TickMathLite.getSqrtPriceAtTick(tick));
        created.increaseObservationCardinalityNext(128);
    }

    function _advance(uint256 seconds_) internal {
        vm.warp(vm.getBlockTimestamp() + seconds_);
        vm.roll(vm.getBlockNumber() + 1);
    }

    function _warm() internal {
        _advance(WINDOW);
        venue.addLiquidity(1); // real in-range mint writes an observation even at the same tick
    }

    function _movePrice(int24 priceTick) internal {
        venue.moveToTick(pool.token0() == address(asset) ? priceTick : -priceTick);
    }

    function _minGross(address tokenIn, address tokenOut, uint256 amountIn) internal view returns (uint256) {
        (, uint256 floor) = oracle.previewSwap(tokenIn, tokenOut, amountIn);
        return Math.mulDiv(floor, BPS, BPS - FEE_BPS, Math.Rounding.Ceil);
    }

    function _step(bool buy, uint256 amountIn) internal view returns (AtpExecutor.SwapStep memory step) {
        address tokenIn = buy ? address(usdt) : address(asset);
        address tokenOut = buy ? address(asset) : address(usdt);
        step = AtpExecutor.SwapStep(
            tokenIn,
            tokenOut,
            amountIn,
            _minGross(tokenIn, tokenOut, amountIn),
            address(venue),
            abi.encodeCall(LocalPoolVenue.swap, (tokenIn, amountIn))
        );
    }

    function _one(AtpExecutor.SwapStep memory step)
        internal
        pure
        returns (AtpExecutor.SwapStep[] memory steps)
    {
        steps = new AtpExecutor.SwapStep[](1);
        steps[0] = step;
    }

    function _run(address account, AtpExecutor.SwapStep[] memory steps) internal {
        vm.prank(account);
        executor.executeRebalance(account, steps, block.timestamp);
    }

    /// @dev Independent execution quote: replay the real pool swap from an EVM snapshot, then restore it.
    /// The venue does not receive the executor's amountOutMin, so this cannot make a failing bound pass.
    function _realOutput(bool buy, uint256 amountIn) internal returns (uint256 gross) {
        uint256 snapshot = vm.snapshotState();
        TestnetToken tokenIn = buy ? usdt : asset;
        tokenIn.approve(address(venue), amountIn);
        gross = venue.swap(address(tokenIn), amountIn);
        assertTrue(vm.revertToState(snapshot));
    }

    function _assertClean() internal view {
        assertEq(usdt.balanceOf(address(executor)), 0);
        assertEq(asset.balanceOf(address(executor)), 0);
        assertEq(usdt.allowance(address(executor), address(venue)), 0);
        assertEq(asset.allowance(address(executor), address(venue)), 0);
    }
}
