// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test, console2 } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { AtpRegistry } from "../../../src/atp/AtpRegistry.sol";
import { AtpBorrowExecutorV2 } from "../../../src/atp/borrow/v2/AtpBorrowExecutorV2.sol";
import { AtpBorrowExecutorV2Extension } from "../../../src/atp/borrow/v2/AtpBorrowExecutorV2Extension.sol";
import { AtpBorrowRegistryV2 } from "../../../src/atp/borrow/v2/AtpBorrowRegistryV2.sol";
import { AtpBorrowLensV2 } from "../../../src/atp/borrow/v2/AtpBorrowLensV2.sol";
import { IAtpBorrowExecutorV2 as IExec } from "../../../src/atp/borrow/v2/IAtpBorrowExecutorV2.sol";
import { IAtpBorrowRegistryV2 as IReg } from "../../../src/atp/borrow/v2/IAtpBorrowRegistryV2.sol";
import { IAtpBorrowLensV2 as ILens } from "../../../src/atp/borrow/v2/IAtpBorrowLensV2.sol";
import { VenusVaultAdapter, Erc4626VaultAdapter } from "../../../src/atp/borrow/v2/VaultAdapters.sol";
import { RoutingTypes as R } from "../../../src/atp/borrow/v2/RoutingTypes.sol";
import { AtpBorrowCashSwapper } from "../../../src/atp/borrow/v2/AtpBorrowCashSwapper.sol";
import { IAtpBorrowCashSwapper as ISwapper } from "../../../src/atp/borrow/v2/IAtpBorrowCashSwapper.sol";
import { IPancakeV3Pool } from "../../../src/atp/interfaces/IPancakeV3Pool.sol";
import { DeployBorrowCashSwapperMainnet } from "../../../script/DeployBorrowCashSwapperMainnet.s.sol";

contract CashSwapperCoreStub {
    bool public globalPaused;
}

interface ICashVenus {
    function updateDelegate(address delegate, bool allowBorrows) external;
    function oracle() external view returns (address);
}

interface ICashMoolah {
    function setAuthorization(address authorized, bool newIsAuthorized) external;
    function idToMarketParams(bytes32 id) external view returns (address, address, address, address, uint256);
}

interface ICashQueue {
    function supplyQueueLength() external view returns (uint256);
    function supplyQueue(uint256 index) external view returns (bytes32);
}

/// @dev The mainnet script without its chain-id gate, broadcast and manifest anchor, so a fork test can
/// drive each step against a stand-in core.
contract DeployBorrowCashSwapperMainnetHarness is DeployBorrowCashSwapperMainnet {
    function deploy(address executor) external returns (AtpBorrowCashSwapper) {
        _checkBook();
        return _deploy(executor);
    }

    function verifyWith(address swapper, address executor, address coreRegistry) external view {
        _verify(swapper, executor, coreRegistry);
    }
}

/// @notice `AtpBorrowCashSwapper` against the live BSC venues and the real PancakeSwap V3 0.01% pools of USDT
/// with USDC / USD1 / U: the gap of routing v2 reproduced with the real flow (a position whose vault earns
/// less than its debt costs cannot be closed), closed with a top-up, the leftover cashed out; the price paid
/// at 1,000 / 10,000 / 50,000; the mainnet script's deploy, owner calls and verification. Balances come from
/// `deal`. Needs `BSC_RPC_URL` (a public endpoint is enough; pin with BSC_FORK_BLOCK); skipped without it.
contract BorrowCashSwapperForkTest is Test {
    uint256 internal constant MAX = type(uint256).max;
    address internal constant MOOLAH = 0x8F73b65B4caAf64FBA2aF91cC5D4a2A1318E5D8C;
    address internal constant COMPTROLLER = 0xfD36E2c2a6789Db23113685031d7F16329158384;
    address internal constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address internal constant USDC = 0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d;
    address internal constant USD1 = 0x8d0D000Ee44948FC98c9B98A4FA4921476f08B0d;
    address internal constant U = 0xcE24439F2D9C6a2289F741120FE202248B666666;
    address internal constant TSLAB = 0x5b1910eAaD6450E50f816082Aa078C41F10C292f;
    address internal constant V_USDT = 0xfD5840Cd36d94D7229439859C0112a4185BC0255;
    address internal constant V_USDC = 0xecA88125a5ADbe82614ffC12D0DB554E2e2867C8;
    address internal constant V_USD1 = 0x0C1DA220D301155b87318B90692Da8dc43B67340;
    address internal constant V_U = 0x3d5E269787d562b74aCC55F18Bd26C5D09Fa245E;
    address internal constant V_TSLAB = 0x97421799419Eb782628e73e7220d8E0A207469a3;
    address internal constant LISTA_VAULT_USD1 = 0xfa27f172e0b6ebcEF9c51ABf817E2cb142FbE627;
    bytes32 internal constant M_QQQB_USD1 =
        0x78f0f036e0549defcb4c6b9039a72ce14f952326ce4bba229d761c00a2749dc4;
    address internal constant REPORTER = address(0x4E9);
    address internal constant KEEPER = address(0x6EE);

    AtpRegistry internal registry;
    IExec internal lend;
    AtpBorrowRegistryV2 internal credit;
    AtpBorrowLensV2 internal lens;
    AtpBorrowCashSwapper internal swapper;
    DeployBorrowCashSwapperMainnetHarness internal script;
    address internal qqqb;
    address[3] internal tokens = [USDC, USD1, U];
    string[3] internal symbols = ["USDC", "USD1", "U"];
    bytes32[3] internal routes; // Venus TSLAB / token
    bytes32[3] internal vaults; // Venus vToken supply of the token
    bytes32 internal L_QQQB_USD1;
    bytes32 internal K_LISTA_USD1;

    function setUp() public {
        string memory rpc = vm.envOr("BSC_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        uint256 pinned = vm.envOr("BSC_FORK_BLOCK", uint256(0));
        require(pinned != 0 || !vm.envOr("CI", false), "CI fork tests need BSC_FORK_BLOCK (archive RPC)");
        if (pinned == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, pinned);
        console2.log("fork block", block.number);
        (, qqqb,,,) = ICashMoolah(MOOLAH).idToMarketParams(M_QQQB_USD1);

        // The core: this test is the registry owner (as the Safe will be) and the portfolio account.
        registry = new AtpRegistry();
        registry.setNumeraire(USDT);
        address[] memory assets = new address[](3);
        (assets[0], assets[1], assets[2]) = (USDT, TSLAB, qqqb);
        uint16[] memory weights = new uint16[](3);
        (weights[1], weights[2]) = (5_000, 5_000);
        uint256 strategy = registry.registerStrategy("fork", "cash swapper", true);
        registry.publishVersion(strategy, assets, weights, keccak256("hold"), 0);
        registry.enroll(address(this), strategy, 1);

        // Routing v2 against the live venues.
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 4);
        credit = new AtpBorrowRegistryV2(
            registry, address(new CashSwapperCoreStub()), predicted, COMPTROLLER, MOOLAH
        );
        lens = new AtpBorrowLensV2(credit);
        address extension = address(new AtpBorrowExecutorV2Extension());
        lend = IExec(address(new AtpBorrowExecutorV2(credit, lens, extension)));
        credit.setAdapter(R.VaultKind.VENUS, address(new VenusVaultAdapter(address(lend))));
        credit.setAdapter(R.VaultKind.ERC4626, address(new Erc4626VaultAdapter(address(lend))));
        address[4] memory loans = [USDT, USDC, USD1, U];
        address[4] memory loanVTokens = [V_USDT, V_USDC, V_USD1, V_U];
        for (uint256 i; i < 4; ++i) {
            credit.setLoanToken(loans[i], true);
            credit.setVenusMarket(loans[i], loanVTokens[i]);
        }
        credit.setVenusMarket(TSLAB, V_TSLAB);
        credit.setAssetTier(TSLAB, R.Tier.STOCK);
        credit.setAssetTier(qqqb, R.Tier.INDEX_LARGE_CAP);
        credit.setRateReporter(REPORTER);
        for (uint256 i; i < 3; ++i) {
            routes[i] = credit.registerRoute(R.Venue.VENUS, TSLAB, tokens[i], bytes32(0), 10_000_000e18);
            vaults[i] = credit.registerVault(R.VaultKind.VENUS, tokens[i], loanVTokens[i + 1]);
        }
        L_QQQB_USD1 = credit.registerRoute(R.Venue.LISTA, qqqb, USD1, M_QQQB_USD1, 10_000_000e18);
        K_LISTA_USD1 = credit.registerVault(R.VaultKind.ERC4626, USD1, LISTA_VAULT_USD1);
        _report();

        // The cash swapper, through the mainnet script's own steps: deploy, then the owner's calls.
        script = new DeployBorrowCashSwapperMainnetHarness();
        swapper = script.deploy(address(lend));
        DeployBorrowCashSwapperMainnet.Call[] memory calls = script.configCalls(address(swapper));
        assertEq(calls.length, 3, "three setPool calls");
        for (uint256 i; i < calls.length; ++i) {
            (bool ok,) = calls[i].target.call(calls[i].data);
            assertTrue(ok, calls[i].label);
        }
        assertEq(script.configCalls(address(swapper)).length, 0, "nothing left to configure");

        // Account-owner grants: routing v2's, plus the swapper's two.
        ICashVenus(COMPTROLLER).updateDelegate(address(lend), true);
        ICashMoolah(MOOLAH).setAuthorization(address(lend), true);
        credit.setStrategyPolicy(10_000_000e18, address(0xA11E7), true);
        deal(TSLAB, address(this), 60e18);
        deal(qqqb, address(this), 60e18);
        IERC20(TSLAB).approve(address(lend), MAX);
        IERC20(qqqb).approve(address(lend), MAX);
        IERC20(USDT).approve(address(swapper), MAX);
        for (uint256 i; i < 3; ++i) {
            IERC20(tokens[i]).approve(address(swapper), MAX);
        }
    }

    // ---- helpers ----

    /// @dev What the backend reports: rates that are not on chain and the reward programs. A 10% borrow
    /// incentive makes every pair's carry positive on paper while the base carry (vault rate - borrow rate)
    /// is negative: the case the swapper exists for.
    function _report() internal {
        uint256 n = credit.routeCount();
        IReg.RouteReport[] memory r = new IReg.RouteReport[](n);
        for (uint256 i; i < n; ++i) {
            r[i] = IReg.RouteReport(credit.routeIds(i), 0.1e18, 0);
        }
        uint256 m = credit.vaultCount();
        IReg.VaultReport[] memory v = new IReg.VaultReport[](m);
        for (uint256 i; i < m; ++i) {
            v[i] = IReg.VaultReport(credit.vaultIds(i), 0.01e18, 0);
        }
        vm.prank(REPORTER);
        credit.reportRates(r, v);
    }

    function _target(bytes32 route) internal view returns (uint256) {
        R.Health memory h = lens.health(route, address(this));
        return (h.budgetValue - h.debtValue) * 90 / 100;
    }

    /// @dev Let interest run with today's prices held (a warp is not a market move: the venues' oracles
    /// refuse prices that are too old).
    function _accrue(uint256 time) internal {
        _pinPrices();
        skip(time);
        vm.roll(block.number + time * 20 / 9); // 0.45 s blocks
        _report();
    }

    function _pinPrices() internal {
        (address loan, address collateral, address oracle,,) =
            ICashMoolah(MOOLAH).idToMarketParams(M_QQQB_USD1);
        _pin(oracle, abi.encodeWithSignature("peek(address)", loan));
        _pin(oracle, abi.encodeWithSignature("peek(address)", collateral));
        uint256 n = ICashQueue(LISTA_VAULT_USD1).supplyQueueLength();
        for (uint256 i; i < n; ++i) {
            (loan, collateral, oracle,,) =
                ICashMoolah(MOOLAH).idToMarketParams(ICashQueue(LISTA_VAULT_USD1).supplyQueue(i));
            _pin(oracle, abi.encodeWithSignature("peek(address)", loan));
            _pin(oracle, abi.encodeWithSignature("peek(address)", collateral));
        }
        address venusOracle = ICashVenus(COMPTROLLER).oracle();
        address[5] memory vTokens = [V_USDT, V_USDC, V_USD1, V_U, V_TSLAB];
        address[5] memory underlyings = [USDT, USDC, USD1, U, TSLAB];
        for (uint256 i; i < 5; ++i) {
            _pin(venusOracle, abi.encodeWithSignature("getUnderlyingPrice(address)", vTokens[i]));
            _pin(venusOracle, abi.encodeWithSignature("getPrice(address)", underlyings[i]));
        }
        vm.mockCall(venusOracle, abi.encodeWithSignature("updatePrice(address)"), "");
        vm.mockCall(venusOracle, abi.encodeWithSignature("updateAssetPrice(address)"), "");
    }

    function _pin(address target, bytes memory data) internal {
        (bool ok, bytes memory ret) = target.staticcall(data);
        if (ok) vm.mockCall(target, data, ret);
    }

    function _swapperHoldsNothing() internal view {
        address[4] memory all = [USDT, USDC, USD1, U];
        for (uint256 i; i < 4; ++i) {
            assertEq(IERC20(all[i]).balanceOf(address(swapper)), 0, "swapper holds a token");
            assertEq(IERC20(all[i]).balanceOf(address(lend)), 0, "executor holds a token");
        }
    }

    /// @dev Signed distance from parity in hundredths of a bp, printed as bps with two decimals.
    function _bps(uint256 paid, uint256 got) internal pure returns (string memory) {
        int256 x = (int256(paid) - int256(got)) * 1_000_000 / int256(got);
        uint256 abs = uint256(x < 0 ? -x : x);
        string memory cents = vm.toString(abs % 100);
        if (abs % 100 < 10) cents = string.concat("0", cents);
        return string.concat(x < 0 ? "-" : "+", vm.toString(abs / 100), ".", cents);
    }

    // ---- the gap, with the real flow, in each of the three tokens ----

    function test_fork_gap_venusNegativeCarry_cannotClose_topUpCloses_USDC() public {
        _gapAndClose(0);
    }

    function test_fork_gap_venusNegativeCarry_cannotClose_topUpCloses_USD1() public {
        _gapAndClose(1);
    }

    function test_fork_gap_venusNegativeCarry_cannotClose_topUpCloses_U() public {
        _gapAndClose(2);
    }

    /// @dev TSLAB posted on Venus, `token` borrowed and supplied back to Venus (the vToken as the vault):
    /// borrowing and supplying the same token on Venus always loses the spread, here for 180 days.
    function _gapAndClose(uint256 i) internal {
        address token = tokens[i];
        lend.executeOpen(address(this), routes[i], bytes32(0), 20e18, 0, block.timestamp);
        uint256 borrowed = _target(routes[i]);
        lend.executeOpen(address(this), routes[i], vaults[i], 0, borrowed, block.timestamp);
        assertEq(IERC20(token).balanceOf(address(this)), 0, "borrowed money never rests in the account");
        _accrue(180 days);

        // The account holds USDT (it sold assets through the core) and none of the loan token.
        deal(USDT, address(this), 100_000e18);
        (uint256 gap, uint256 cap) = swapper.shortfall(address(this), token);
        uint256 owed = lens.tokenDebt(address(this), token);
        console2.log(string.concat("== ", symbols[i], ": borrowed / debt / gap after 180 days (raw units)"));
        console2.log("  ", borrowed, owed, gap);
        assertGt(gap, borrowed / 1000, "the vault fell behind the debt");
        // Nothing in routing v2 closes it: the box is short and the account has no loan token.
        vm.expectPartialRevert(IExec.VaultShortfall.selector);
        lend.executeReduce(address(this), routes[i], vaults[i], MAX, MAX, 0, block.timestamp);
        // Not even with cash allowed: `maxCashIn` is in the loan token, and the account holds USDT.
        IERC20(token).approve(address(lend), MAX);
        vm.expectRevert();
        lend.executeReduce(address(this), routes[i], vaults[i], MAX, MAX, 100_000e18, block.timestamp);

        uint256 gasBefore = gasleft();
        (uint256 usdtIn, uint256 tokenOut) = swapper.topUp(token, MAX, cap * 1_005 / 1_000, block.timestamp);
        console2.log("  topUp gas", gasBefore - gasleft());
        console2.log(string.concat("  topUp USDT in / token out, bps vs 1:1 ", _bps(usdtIn, tokenOut)));
        console2.log("  ", usdtIn, tokenOut);
        assertEq(tokenOut, cap);
        assertEq(lens.idleOf(address(this), token), cap, "bought token sits in the account's box");
        assertEq(IERC20(USDT).balanceOf(address(this)), 100_000e18 - usdtIn);
        _swapperHoldsNothing();

        // The ordinary close, with no account cash.
        lend.executeReduce(address(this), routes[i], vaults[i], MAX, MAX, 0, block.timestamp);
        assertEq(lens.tokenDebt(address(this), token), 0, "debt closed");
        assertEq(lens.collateral(routes[i], address(this)), 0);
        assertApproxEqAbs(IERC20(TSLAB).balanceOf(address(this)), 60e18, 1e11, "collateral back");
        assertEq(lens.idleOf(address(this), token), 0);
        uint256 leftover = IERC20(token).balanceOf(address(this));
        assertApproxEqAbs(leftover, cap - gap, 1e12, "the buffer comes back as loan token");

        gasBefore = gasleft();
        (uint256 tokenIn, uint256 usdtOut) = swapper.cashOut(token, MAX, 0, block.timestamp);
        console2.log("  cashOut gas", gasBefore - gasleft());
        console2.log(string.concat("  cashOut token in / USDT out, bps vs 1:1 ", _bps(tokenIn, usdtOut)));
        assertEq(tokenIn, leftover);
        assertEq(IERC20(token).balanceOf(address(this)), 0, "the account ends in USDT only");
        assertEq(IERC20(USDT).balanceOf(address(this)), 100_000e18 - usdtIn + usdtOut);
        _swapperHoldsNothing();
        console2.log("  closing cost in USDT (raw units)", usdtIn - usdtOut);
    }

    /// @dev A Lista debt (QQQB / USD1) with its money split between Venus vUSD1 and the Lista USD1 vault:
    /// the cap reads a Lista market's debt and both kinds of vault. Whether a year leaves a gap depends on
    /// the live rates (the Lista vault can out-earn the QQQB market); both outcomes are checked.
    function test_fork_listaDebt_twoVaultKinds_capReadsBoth() public {
        lend.executeOpen(address(this), L_QQQB_USD1, bytes32(0), 5e18, 0, block.timestamp);
        uint256 borrowed = _target(L_QQQB_USD1);
        lend.executeOpen(address(this), L_QQQB_USD1, vaults[1], 0, borrowed, block.timestamp);
        lend.executeSwitchVault(address(this), vaults[1], K_LISTA_USD1, borrowed / 2, block.timestamp);
        _accrue(365 days);
        deal(USDT, address(this), 100_000e18);
        uint256 gasBefore = gasleft();
        (uint256 gap, uint256 cap) = swapper.shortfall(address(this), USD1);
        console2.log("== Lista QQQB/USD1, half in Venus vUSD1, half in the Lista USD1 vault, after 365 days");
        console2.log("  shortfall() gas (reads both vaults)", gasBefore - gasleft());
        uint256 owed = lens.tokenDebt(address(this), USD1);
        uint256 held = lens.vaultStatus(vaults[1], address(this)).assets
            + lens.vaultStatus(K_LISTA_USD1, address(this)).assets + lens.idleOf(address(this), USD1);
        console2.log("  borrowed / debt / held / gap");
        console2.log("  ", borrowed, owed);
        console2.log("  ", held, gap);
        assertEq(gap, owed > held ? owed - held : 0, "gap = debt - both vaults - idle");
        if (gap == 0) {
            vm.expectPartialRevert(ISwapper.NoShortfall.selector);
            swapper.topUp(USD1, MAX, MAX, block.timestamp);
            return;
        }
        gasBefore = gasleft();
        swapper.topUp(USD1, MAX, cap * 1_005 / 1_000, block.timestamp);
        console2.log("  topUp gas", gasBefore - gasleft());
        (gap,) = swapper.shortfall(address(this), USD1);
        assertEq(gap, 0, "covered");
        // Two vaults: empty the Lista vault into the debt first, then close on the Venus one.
        lend.executeReduce(address(this), L_QQQB_USD1, K_LISTA_USD1, borrowed / 2, 0, 0, block.timestamp);
        lend.executeReduce(address(this), L_QQQB_USD1, vaults[1], MAX, MAX, 0, block.timestamp);
        assertEq(lens.tokenDebt(address(this), USD1), 0);
        _swapperHoldsNothing();
    }

    // ---- what the real pools charge ----

    /// @dev Top-up (exact output) and cash-out (exact input) of 1,000 / 10,000 / 50,000 on each pool, each
    /// from the same pool state. The swaps are real; only the debt reading is raised so the cap admits the
    /// size (a 50,000 shortfall needs a position far above Venus' TSLAB supply cap).
    function test_fork_slippage_1k_10k_50k_onTheThreePools() public {
        uint256[3] memory sizes = [uint256(1_000e18), 10_000e18, 50_000e18];
        deal(USDT, address(this), 1_000_000e18);
        for (uint256 i; i < 3; ++i) {
            address token = tokens[i];
            IPancakeV3Pool pool = IPancakeV3Pool(swapper.poolOf(token));
            (uint160 sqrtPrice, int24 tick,,,,,) = pool.slot0();
            // USDT is token0 in all three pools: price = token per USDT.
            assertEq(pool.token0(), USDT);
            uint256 tokenPerUsdt = uint256(sqrtPrice) * uint256(sqrtPrice) / (1 << 96) * 1e18 / (1 << 96);
            console2.log(string.concat("== pool USDT/", symbols[i]), address(pool));
            console2.log("  tick", tick);
            console2.log("  token per USDT (1e18) / fee pips", tokenPerUsdt, pool.fee());
            console2.log(
                "  pool USDT / token balance (whole)",
                IERC20(USDT).balanceOf(address(pool)) / 1e18,
                IERC20(token).balanceOf(address(pool)) / 1e18
            );
            lend.executeOpen(address(this), routes[i], bytes32(0), 10e18, 0, block.timestamp);
            lend.executeOpen(address(this), routes[i], vaults[i], 0, 100e18, block.timestamp);
            deal(token, address(this), 100_000e18);
            vm.mockCall(
                address(lens),
                abi.encodeCall(ILens.tokenDebt, (address(this), token)),
                abi.encode(1_000_000e18)
            );
            for (uint256 k; k < 3; ++k) {
                uint256 snapshot = vm.snapshotState();
                (uint256 usdtIn, uint256 out) = swapper.topUp(token, sizes[k], MAX, block.timestamp);
                assertEq(out, sizes[k]);
                vm.revertToState(snapshot);
                (uint256 tokenIn, uint256 usdtOut) = swapper.cashOut(token, sizes[k], 0, block.timestamp);
                assertEq(tokenIn, sizes[k]);
                vm.revertToState(snapshot);
                console2.log(
                    string.concat(
                        "  SLIPPAGE ",
                        symbols[i],
                        " ",
                        vm.toString(sizes[k] / 1e18),
                        " | topUp pays ",
                        _bps(usdtIn, out),
                        " bps | cashOut gives ",
                        _bps(usdtOut, tokenIn),
                        " bps (vs 1:1, fee included)"
                    )
                );
                console2.log("    usdtIn / usdtOut (raw)", usdtIn, usdtOut);
                // Well inside the 0.5% bound at every size.
                assertLt(usdtIn, out + out * 50 / 10_000);
                assertLt(tokenIn, usdtOut + usdtOut * 50 / 10_000);
            }
            vm.clearMockedCalls();
        }
    }

    function test_fork_pegBound_refusesATradeTheRealPoolCannotCarry() public {
        // Selling far more USD1 than its pool holds in USDT walks the price off the peg: refused whole.
        uint256 huge = IERC20(USDT).balanceOf(swapper.poolOf(USD1)) * 3;
        deal(USD1, address(this), huge);
        vm.expectPartialRevert(ISwapper.PegExceeded.selector);
        swapper.cashOut(USD1, huge, 0, block.timestamp);
        // A size the pool carries goes through.
        (, uint256 out) = swapper.cashOut(USD1, 20_000e18, 0, block.timestamp);
        assertGt(out, 19_900e18);
        // Tightened to zero tolerance the same sale may only pass if it gets at least face value.
        swapper.setLimits(0, 100);
        try swapper.cashOut(USD1, 20_000e18, 0, block.timestamp) returns (uint256 sold, uint256 got) {
            assertGe(got + 3, sold);
        } catch (bytes memory reason) {
            assertEq(bytes4(reason), ISwapper.PegExceeded.selector);
        }
    }

    // ---- the mainnet script ----

    function test_fork_script_verify_andDriftIsCaught() public {
        vm.setEnv("ATP_SAFE", vm.toString(address(this)));
        script.verifyWith(address(swapper), address(lend), address(registry));

        // The real entry point insists on the core recorded in deployments/mainnet.json: this fork's
        // stand-in core is not it.
        vm.setEnv("ROUTING_EXECUTOR", vm.toString(address(lend)));
        vm.chainId(56);
        vm.expectRevert(bytes("core registry is not the AtpRegistry in deployments/mainnet.json"));
        script.verify(address(swapper));

        // A pool switched off; another pool of the same pair (the 0.05% one); limits moved.
        uint256 snapshot = vm.snapshotState();
        swapper.setPool(USD1, address(0));
        vm.expectRevert(bytes("pool not set: USD1"));
        script.verifyWith(address(swapper), address(lend), address(registry));
        vm.revertToState(snapshot);
        swapper.setPool(USDC, 0x4f31Fa980a675570939B737Ebdde0471a4Be40Eb);
        vm.expectRevert(bytes("pool not set: USDC"));
        script.verifyWith(address(swapper), address(lend), address(registry));
        vm.revertToState(snapshot);
        swapper.setLimits(100, 100);
        vm.expectRevert(bytes("limits are not the defaults"));
        script.verifyWith(address(swapper), address(lend), address(registry));
        vm.revertToState(snapshot);

        // Another executor, another core registry, other code at the address, an owner that is not the Safe.
        vm.expectRevert();
        script.verifyWith(address(swapper), address(0xE0E0), address(registry));
        vm.expectRevert(bytes("core registry is not the AtpRegistry in deployments/mainnet.json"));
        script.verifyWith(address(swapper), address(lend), address(0xC0DE));
        bytes memory code = address(swapper).code;
        code[code.length / 2] = bytes1(uint8(code[code.length / 2]) ^ 1);
        vm.etch(address(swapper), code);
        vm.expectRevert();
        script.verifyWith(address(swapper), address(lend), address(registry));
        vm.revertToState(snapshot);
        vm.setEnv("ATP_SAFE", vm.toString(address(lend)));
        vm.expectRevert(bytes("registry owner is not the Safe"));
        script.verifyWith(address(swapper), address(lend), address(registry));
        vm.setEnv("ATP_SAFE", "");
        vm.setEnv("ROUTING_EXECUTOR", "");
    }
}
