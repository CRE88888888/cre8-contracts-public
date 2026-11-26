// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Script, console } from "forge-std/Script.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { AtpExecutor } from "../../src/atp/AtpExecutor.sol";
import { AtpRegistry } from "../../src/atp/AtpRegistry.sol";
import { AtpBorrowExecutor } from "../../src/atp/borrow/AtpBorrowExecutor.sol";
import { AtpBorrowRegistry } from "../../src/atp/borrow/AtpBorrowRegistry.sol";
import { BorrowTypes as BT } from "../../src/atp/borrow/BorrowTypes.sol";
import { IVenusComptroller } from "../../src/atp/borrow/BorrowInterfaces.sol";
import { TestnetToken } from "../../src/testnet/TestnetToken.sol";
import { MockMoolah } from "../../src/testnet/lending/MockMoolah.sol";
import { MockLendingOracle } from "../../src/testnet/lending/MockLendingOracle.sol";
import { MockVToken } from "../../src/testnet/lending/MockVToken.sol";
import { MockEarnVault } from "../../src/testnet/lending/MockEarnVault.sol";
import { TestnetBook as TB } from "./TestnetBook.sol";

/// @dev Stand-in for a CRE8 portfolio account on chain 97 (a Kernel account needs the backend's session stack).
/// Its owner signs every step; each step calls the borrow executor exactly as the account's `execute()` would.
contract BorrowDemoAccount {
    address public immutable owner;

    constructor(address owner_) {
        owner = owner_;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "demo owner only");
        _;
    }

    /// @notice One-time account-owner setup: enroll, consent to the market, grant the executor on the protocol,
    /// approve it for the collateral, USDT and the earn vault's shares.
    function prepare(AtpExecutor core, AtpBorrowExecutor lend, bytes32 creditId, uint256 maxDebt)
        external
        onlyOwner
    {
        AtpRegistry registry = core.registry();
        BT.Market memory m = lend.borrowRegistry().market(creditId);
        if (!registry.isEnrolled(address(this))) {
            uint256 strategy = registry.registerStrategy("Borrow demo", "chain 97 strategy earn (#64)", false);
            address[] memory assets = new address[](2);
            assets[0] = core.numeraire();
            assets[1] = m.collateral;
            uint16[] memory weights = new uint16[](2);
            weights[1] = 10_000;
            registry.publishVersion(strategy, assets, weights, keccak256("borrow demo"), 0);
            registry.enroll(address(this), strategy, 1);
        }
        if (m.kind == BT.Kind.VENUS) IVenusComptroller(m.core).updateDelegate(address(lend), true);
        else MockMoolah(m.core).setAuthorization(address(lend), true);
        lend.borrowRegistry().setBorrowPolicy(creditId, maxDebt, true);
        IERC20(m.collateral).approve(address(lend), type(uint256).max);
        IERC20(m.loan).approve(address(lend), type(uint256).max);
        IERC20(m.earnVault).approve(address(lend), type(uint256).max);
    }

    function postCollateral(AtpBorrowExecutor lend, bytes32 id, uint256 amount) external onlyOwner {
        lend.executeSupplyCollateral(address(this), id, amount, block.timestamp);
    }

    function borrow(AtpBorrowExecutor lend, bytes32 id, uint256 amount) external onlyOwner {
        lend.executeBorrow(address(this), id, amount, block.timestamp);
    }

    function closeFromVault(AtpBorrowExecutor lend, bytes32 id) external onlyOwner {
        lend.executeRepay(address(this), id, type(uint256).max, true, block.timestamp);
    }

    function withdrawCollateralAll(AtpBorrowExecutor lend, bytes32 id) external onlyOwner {
        lend.executeWithdrawCollateral(address(this), id, type(uint256).max, block.timestamp);
    }
}

/// @notice Chain 97 (#64): one Strategy Earn cycle with a deleverage drill, by a demo account owned by OWNER.
/// collateral -> borrow into the USDT vault -> price drop -> anyone deleverages back to target LTV -> price back
/// -> close from the vault -> collateral back -> incentives claimed into the account. Each step is its own transaction (hashes in
/// broadcast/BorrowDemoTestnet.s.sol/97/run-latest.json). Env: TESTNET_EXECUTOR, BORROW_EXECUTOR,
/// BORROW_LENDING_ORACLE, BORROW_MARKET_ID; optional BORROW_DEMO_COLLATERAL (raw, default 5e18),
/// BORROW_DEMO_AMOUNT (USDT raw, default 150e18), BORROW_DEMO_DROP_PRICE_E8 (default 70e8).
contract BorrowDemoTestnet is Script {
    function run() external {
        require(block.chainid == 97, "borrow demo: chain 97 only");
        uint256 key = vm.envOr("TESTNET_OWNER_KEY", uint256(0));
        if (key != 0) {
            require(vm.addr(key) == TB.OWNER, "TESTNET_OWNER_KEY does not derive OWNER");
            vm.rememberKey(key);
        }
        AtpExecutor core = AtpExecutor(vm.envAddress("TESTNET_EXECUTOR"));
        AtpBorrowExecutor lend = AtpBorrowExecutor(vm.envAddress("BORROW_EXECUTOR"));
        MockLendingOracle oracle = MockLendingOracle(vm.envAddress("BORROW_LENDING_ORACLE"));
        bytes32 id = vm.envBytes32("BORROW_MARKET_ID");
        uint256 collateral = vm.envOr("BORROW_DEMO_COLLATERAL", uint256(5e18));
        uint256 amount = vm.envOr("BORROW_DEMO_AMOUNT", uint256(150e18));
        uint256 dropPrice = vm.envOr("BORROW_DEMO_DROP_PRICE_E8", uint256(70e8));
        AtpBorrowRegistry credit = lend.borrowRegistry();
        BT.Market memory m = credit.market(id);
        uint256 price = oracle.prices(m.collateral);

        bytes memory code = abi.encodePacked(type(BorrowDemoAccount).creationCode, abi.encode(TB.OWNER));
        BorrowDemoAccount account = BorrowDemoAccount(TB.create2Address("borrow.demo.account.v1", code));

        vm.startBroadcast(TB.OWNER);
        if (address(account).code.length == 0) {
            (bool ok,) = TB.CREATE2_FACTORY.call(abi.encodePacked(TB.salt("borrow.demo.account.v1"), code));
            require(ok && address(account).code.length != 0, "demo account deployment failed");
        }
        _mint(m.collateral, address(account), collateral);
        // The portfolio's own cash: covers the raw-unit gap a close can leave when every step runs in one
        // simulated timestamp (on chain the vault's 4.5% outgrows the 2.5% debt between blocks).
        _mint(m.loan, address(account), 1e18);
        account.prepare(core, lend, id, 10 * amount);
        account.postCollateral(lend, id, collateral);
        account.borrow(lend, id, amount);
        oracle.setPrice(m.collateral, dropPrice);
        lend.executeDeleverage(address(account), id);
        oracle.setPrice(m.collateral, price);
        account.closeFromVault(lend, id);
        account.withdrawCollateralAll(lend, id);
        // Simulated incentives go to the portfolio account that earned them (anyone may trigger the claim).
        if (m.kind == BT.Kind.VENUS) MockVToken(m.collateralVToken).claimReward(address(account));
        else MockMoolah(m.core).claimReward(m.listaId, address(account));
        MockEarnVault(m.earnVault).claimReward(address(account));
        vm.stopBroadcast();

        require(credit.debt(id, address(account)) == 0, "debt left");
        require(credit.collateral(id, address(account)) == 0, "collateral left");
        require(IERC20(m.earnVault).balanceOf(address(account)) == 0, "vault shares left");
        require(IERC20(m.collateral).balanceOf(address(account)) >= collateral, "collateral not returned");
        console.log("BORROW_DEMO_ACCOUNT", address(account));
        console.log("BORROW_DEMO_USDT_LEFT", IERC20(m.loan).balanceOf(address(account)));
    }

    function _mint(address token, address to, uint256 amount) private {
        TestnetToken t = TestnetToken(token);
        bool was = t.isMinter(TB.OWNER);
        if (!was) t.setMinter(TB.OWNER, true);
        t.mint(to, amount);
        if (!was) t.setMinter(TB.OWNER, false);
    }
}
