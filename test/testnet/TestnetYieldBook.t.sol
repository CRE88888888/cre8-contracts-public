// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import { Test } from "forge-std/Test.sol";
import { TestnetYieldBook as B } from "../../script/testnet/TestnetYieldBook.sol";
import { YieldTypes as Y } from "../../src/atp/yield/YieldTypes.sol";
import { TestnetAssets } from "../../script/testnet/TestnetAssets.sol";
import { TestnetToken } from "../../src/testnet/TestnetToken.sol";
import { MockVenus } from "../../src/testnet/yield/MockVenus.sol";
import { MockLista } from "../../src/testnet/yield/MockLista.sol";
import { MockAavePool, MockAToken } from "../../src/testnet/yield/MockAavePool.sol";

contract TestnetYieldBookTest is Test {
    function setUp() public {
        vm.chainId(97);
    }

    function test_everyMarketRow_mintsAndRedeemsUsingItsActualDecimals() public {
        B.Spec[] memory markets = B.specs();
        TestnetAssets.AssetSpec[] memory assets = TestnetAssets.specs();
        for (uint256 i; i < markets.length; ++i) {
            uint8 decimals = 18;
            bool found = keccak256(bytes(markets[i].symbol)) == keccak256("USDT");
            for (uint256 j; j < assets.length; ++j) {
                if (keccak256(bytes(assets[j].symbol)) == keccak256(bytes(markets[i].symbol))) {
                    decimals = assets[j].decimals;
                    found = true;
                    break;
                }
            }
            assertTrue(found, markets[i].symbol);
            TestnetToken token =
                new TestnetToken(markets[i].symbol, markets[i].symbol, decimals, address(this));
            uint256 amount = 1_000 * 10 ** decimals;
            token.mint(address(this), amount);
            if (markets[i].kind == Y.Kind.VENUS) {
                MockVenus market = new MockVenus(token, address(this), markets[i].aprBps);
                token.setMinter(address(market), true);
                token.approve(address(market), amount);
                assertEq(market.mint(amount), 0);
                assertEq(market.balanceOf(address(this)), 1_000e8, markets[i].symbol);
                assertEq(market.redeem(1_000e8), 0);
            } else if (markets[i].kind == Y.Kind.LISTA) {
                MockLista market = new MockLista(token, address(this), markets[i].aprBps);
                token.setMinter(address(market), true);
                token.approve(address(market), amount);
                uint256 shares = market.deposit(amount, address(this));
                assertEq(shares, 1_000e18, markets[i].symbol);
                assertEq(market.redeem(shares, address(this), address(this)), amount);
            } else {
                MockAavePool pool = new MockAavePool(token, address(this), markets[i].aprBps);
                token.setMinter(pool.receipt(), true);
                token.approve(address(pool), amount);
                pool.supply(address(token), amount, address(this), 0);
                assertEq(MockAToken(pool.receipt()).decimals(), decimals);
                assertEq(MockAToken(pool.receipt()).balanceOf(address(this)), amount);
                assertEq(pool.withdraw(address(token), type(uint256).max, address(this)), amount);
            }
            assertEq(token.balanceOf(address(this)), amount, markets[i].symbol);
        }
    }

    function test_exactC3Rows_noMissingAssets_orDuplicateMarkets() public pure {
        B.Spec[] memory s = B.specs();
        assertEq(s.length, 30);
        uint256[4] memory counts;
        string memory rows;
        address[] memory tokens = new address[](s.length);
        for (uint256 i; i < s.length; ++i) {
            (address token, uint256 seed) = B.asset(s[i], address(0x1234));
            assertTrue(token != address(0));
            assertGt(seed, 0);
            assertGt(s[i].aprBps, 0);
            tokens[i] = token;
            counts[uint256(s[i].kind)]++;
            rows = string.concat(rows, s[i].symbol, "/", B.protocol(s[i].kind), " ");
            for (uint256 j; j < i; ++j) {
                assertTrue(B.id(s[i], token) != B.id(s[j], tokens[j]));
            }
        }
        assertEq(counts[1], 21);
        assertEq(counts[2], 4);
        assertEq(counts[3], 5);
        assertEq(
            rows,
            "USDT/Venus USDT/Lista USDT/Aave WBNB/Venus WBNB/Lista WBNB/Aave BTCB/Venus BTCB/Lista BTCB/Aave ETH/Venus ETH/Aave USDC/Venus USDC/Lista USDC/Aave XRP/Venus DOGE/Venus LTC/Venus SOL/Venus LINK/Venus ADA/Venus TRX/Venus DAI/Venus UNI/Venus BCH/Venus AAVE/Venus DOT/Venus FIL/Venus NVDAB/Venus TSLAB/Venus SPCXB/Venus "
        );
    }
}
