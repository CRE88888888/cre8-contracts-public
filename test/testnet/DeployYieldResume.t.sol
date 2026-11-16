// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import { Test } from "forge-std/Test.sol";
import { DeployTestnet } from "../../script/DeployTestnet.s.sol";
import { TestnetBook } from "../../script/testnet/TestnetBook.sol";
import { TestnetYieldBook as B } from "../../script/testnet/TestnetYieldBook.sol";
import { TestnetToken } from "../../src/testnet/TestnetToken.sol";
import { MockVenus } from "../../src/testnet/yield/MockVenus.sol";
import { AtpRegistry } from "../../src/atp/AtpRegistry.sol";
import { AtpYieldRegistry } from "../../src/atp/yield/AtpYieldRegistry.sol";
import { YieldTypes as Y } from "../../src/atp/yield/YieldTypes.sol";

contract DeployYieldHarness is DeployTestnet {
    function init(B.Spec memory spec, TestnetToken token) external pure returns (bytes memory) {
        return _yieldInit(spec, token);
    }

    function resume(
        AtpRegistry registry,
        AtpYieldRegistry yields,
        TestnetToken token,
        B.Spec memory spec,
        uint256 seed
    ) external {
        Core memory core;
        core.registry = registry;
        core.yields = yields;
        _yieldMarket(core, spec, token, seed, _yieldInit(spec, token));
    }
}

contract DeployYieldResumeTest is Test {
    DeployYieldHarness script;
    AtpRegistry registry;
    AtpYieldRegistry yields;
    TestnetToken token;
    MockVenus market;
    B.Spec spec;
    uint256 constant SEED = 1_000_000e18;

    function setUp() public {
        vm.chainId(97);
        script = new DeployYieldHarness();
        registry = new AtpRegistry();
        yields = new AtpYieldRegistry(registry, address(this));
        token = new TestnetToken("seed", "SEED", 18, address(this));
        spec = B.Spec("USDT", Y.Kind.VENUS, 500);
        bytes memory code = script.init(spec, token);
        address predicted = TestnetBook.create2Address(B.label(spec), code);
        deployCodeTo("MockVenus.sol:MockVenus", abi.encode(token, TestnetBook.OWNER, uint16(500)), predicted);
        market = MockVenus(predicted);
        token.setMinter(predicted, true);
    }

    function test_review11_resumeSeededButUnregistered_marketAccruesBeforeHealth() public {
        token.mint(TestnetBook.DEPLOYER, SEED);
        vm.startPrank(TestnetBook.DEPLOYER);
        token.approve(address(market), SEED);
        assertEq(market.mint(SEED), 0);
        market.transfer(TestnetBook.OWNER, market.balanceOf(TestnetBook.DEPLOYER));
        vm.stopPrank();
        vm.roll(block.number + 1);
        script.resume(registry, yields, token, spec, SEED);
        assertEq(yields.marketCount(), 1);
        assertEq(market.accrualBlockNumber(), block.number);
    }

    function test_review11_resumeMintedButNotDeposited_onlyMintsShortfall() public {
        token.mint(TestnetBook.DEPLOYER, SEED / 2);
        script.resume(registry, yields, token, spec, SEED);
        assertEq(token.balanceOf(TestnetBook.DEPLOYER), 0);
        assertEq(token.totalSupply(), SEED);
        assertEq(token.allowance(TestnetBook.DEPLOYER, address(market)), 0);
        assertEq(market.balanceOf(TestnetBook.DEPLOYER), 0);
        assertEq(market.balanceOf(TestnetBook.OWNER), SEED / 1e10);
    }
}
