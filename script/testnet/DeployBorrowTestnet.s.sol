// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Script, console } from "forge-std/Script.sol";
import { AtpExecutor } from "../../src/atp/AtpExecutor.sol";
import { AtpRegistry } from "../../src/atp/AtpRegistry.sol";
import { AtpBorrowExecutor } from "../../src/atp/borrow/AtpBorrowExecutor.sol";
import { AtpBorrowRegistry } from "../../src/atp/borrow/AtpBorrowRegistry.sol";
import { BorrowTypes as BT } from "../../src/atp/borrow/BorrowTypes.sol";
import { MoolahParams } from "../../src/atp/yield/YieldInterfaces.sol";
import { AtpYieldRegistry } from "../../src/atp/yield/AtpYieldRegistry.sol";
import { YieldTypes as Y } from "../../src/atp/yield/YieldTypes.sol";
import { YieldView } from "../../src/atp/yield/YieldView.sol";
import { TestnetToken } from "../../src/testnet/TestnetToken.sol";
import { MockLendingOracle } from "../../src/testnet/lending/MockLendingOracle.sol";
import { MockVenusComptroller } from "../../src/testnet/lending/MockVenusComptroller.sol";
import { MockVToken } from "../../src/testnet/lending/MockVToken.sol";
import { MockMoolah } from "../../src/testnet/lending/MockMoolah.sol";
import { MockEarnVault } from "../../src/testnet/lending/MockEarnVault.sol";
import { TestnetBook as TB } from "./TestnetBook.sol";
import { TestnetBorrowBook as BB } from "./TestnetBorrowBook.sol";

/// @notice Chain 97 only (#64): deploys Strategy Earn next to the existing core, then configures it.
/// DEPLOYER (or OWNER, see BORROW_DEPLOY_SENDER) deploys every contract through CREATE2 (addresses depend only
/// on init code); OWNER, which owns the
/// registries, USDT and the mock assets, sets prices, lists markets, sets the simulated rates and incentives,
/// seeds liquidity, admits the earn vault (supply disabled for `AtpExecutor`: strategy only) and the markets.
/// Idempotent: a rerun broadcasts nothing. Keys: TESTNET_DEPLOYER_KEY / TESTNET_OWNER_KEY (fork: --unlocked).
/// Env: TESTNET_EXECUTOR (manifest contracts.executor) and TOKEN_<SYMBOL> per `TestnetBorrowBook` asset
/// (manifest .assets.<SYMBOL>.token). Link YieldView: --libraries src/atp/yield/YieldView.sol:YieldView:<yieldView>.
/// New USDT minters (simulated interest / incentives only, like the yield mocks): the earn vault, every vToken
/// and Moolah.
contract DeployBorrowTestnet is Script {
    uint8 internal constant BORROW_ACTION = 2;

    struct Out {
        AtpExecutor core;
        address usdt;
        MockLendingOracle oracle;
        MockVenusComptroller comptroller;
        MockVToken vUsdt;
        MockMoolah moolah;
        MockEarnVault vault;
        AtpBorrowExecutor lend;
        address[] vCollateral;
    }

    function run() external returns (Out memory o) {
        require(block.chainid == 97, "borrow deploy: chain 97 only");
        _rememberKey("TESTNET_DEPLOYER_KEY", TB.DEPLOYER);
        _rememberKey("TESTNET_OWNER_KEY", TB.OWNER);
        o.core = AtpExecutor(vm.envAddress("TESTNET_EXECUTOR"));
        o.usdt = o.core.numeraire();
        AtpRegistry registry = o.core.registry();
        require(registry.owner() == TB.OWNER, "borrow deploy: registry owner");
        BB.Spec[] memory specs = BB.specs();

        // 1. Contracts. CREATE2 through the deterministic deployer: the address depends only on salt and init code,
        // so any testnet role may pay for it. BORROW_DEPLOY_SENDER=OWNER when DEPLOYER is short of tBNB.
        address sender = vm.envOr("BORROW_DEPLOY_SENDER", TB.DEPLOYER);
        require(sender == TB.DEPLOYER || sender == TB.OWNER, "borrow deploy: sender");
        vm.startBroadcast(sender);
        o.oracle = MockLendingOracle(
            _create2(
                "borrow.oracle", abi.encodePacked(type(MockLendingOracle).creationCode, abi.encode(TB.OWNER))
            )
        );
        o.comptroller = MockVenusComptroller(
            _create2(
                "borrow.venus.comptroller",
                abi.encodePacked(
                    type(MockVenusComptroller).creationCode, abi.encode(TB.OWNER, address(o.oracle))
                )
            )
        );
        o.vUsdt = MockVToken(_vToken(o.usdt, "USDT", o.comptroller, BB.BORROW_APR_BPS));
        o.vCollateral = new address[](specs.length);
        for (uint256 i; i < specs.length; ++i) {
            if (specs[i].kind != BT.Kind.VENUS) continue;
            o.vCollateral[i] = _vToken(_token(specs[i].symbol), specs[i].symbol, o.comptroller, 0);
        }
        o.moolah = MockMoolah(
            _create2(
                "borrow.lista.moolah", abi.encodePacked(type(MockMoolah).creationCode, abi.encode(TB.OWNER))
            )
        );
        o.vault = MockEarnVault(
            _create2(
                "borrow.earnVault",
                abi.encodePacked(
                    type(MockEarnVault).creationCode, abi.encode(o.usdt, TB.OWNER, BB.VAULT_APR_BPS)
                )
            )
        );
        o.lend = AtpBorrowExecutor(
            _create2(
                "borrow.executor",
                abi.encodePacked(type(AtpBorrowExecutor).creationCode, abi.encode(registry, address(o.core)))
            )
        );
        vm.stopBroadcast();
        AtpBorrowRegistry credit = o.lend.borrowRegistry();
        require(credit.executor() == address(o.lend) && credit.numeraire() == o.usdt, "borrow deploy: pins");

        // 2. OWNER: earn vault, prices, protocol markets, incentives, liquidity, CRE8 admission.
        vm.startBroadcast(TB.OWNER);
        _minter(o.usdt, address(o.vault));
        if (o.vault.incentiveAprBps() != BB.VAULT_INCENTIVE_BPS) {
            o.vault.setIncentiveAprBps(BB.VAULT_INCENTIVE_BPS);
        }
        if (o.vault.totalSupply() == 0) {
            _mintUsdt(o.usdt, BB.VAULT_SEED);
            TestnetToken(o.usdt).approve(address(o.vault), BB.VAULT_SEED);
            o.vault.deposit(BB.VAULT_SEED, TB.OWNER);
        }
        _admitVault(o.core.yieldRegistry(), o.usdt, address(o.vault));
        _price(o.oracle, o.usdt, 1e8);
        if (!_listed(o.comptroller, address(o.vUsdt))) o.comptroller.supportMarket(address(o.vUsdt));
        if (o.vUsdt.totalSupply() == 0) {
            _mintUsdt(o.usdt, BB.VENUS_SEED);
            TestnetToken(o.usdt).approve(address(o.vUsdt), BB.VENUS_SEED);
            require(o.vUsdt.mint(BB.VENUS_SEED) == 0, "seed vUSDT");
        }
        if (o.moolah.rewardToken() != o.usdt) o.moolah.setRewardToken(o.usdt);
        _minter(o.usdt, address(o.moolah));
        for (uint256 i; i < specs.length; ++i) {
            address token = _token(specs[i].symbol);
            _price(o.oracle, token, BB.priceE8(specs[i].symbol));
            BT.Market memory m;
            if (specs[i].kind == BT.Kind.VENUS) {
                MockVToken v = MockVToken(o.vCollateral[i]);
                if (!_listed(o.comptroller, address(v))) o.comptroller.supportMarket(address(v));
                (, uint256 factor,) = o.comptroller.markets(address(v));
                if (factor != specs[i].factor) {
                    o.comptroller.setCollateralFactor(address(v), specs[i].factor);
                }
                // Collateral-only, like Venus' bStock markets.
                if (!o.comptroller.actionPaused(address(v), BORROW_ACTION)) {
                    o.comptroller.setActionPaused(address(v), BORROW_ACTION, true);
                }
                if (v.supplyIncentiveAprBps() != specs[i].collateralIncentiveBps) {
                    v.setIncentives(o.usdt, specs[i].collateralIncentiveBps, 0);
                }
                _minter(o.usdt, address(v));
                m.kind = BT.Kind.VENUS;
                m.core = address(o.comptroller);
                m.collateralVToken = address(v);
                m.loanVToken = address(o.vUsdt);
            } else {
                MoolahParams memory p =
                    MoolahParams(o.usdt, token, address(o.oracle), address(o.moolah), specs[i].factor);
                bytes32 listaId = o.moolah.marketId(p);
                if (o.moolah.market(listaId).lastUpdate == 0) o.moolah.createMarket(p, BB.BORROW_APR_BPS);
                if (o.moolah.collateralIncentiveAprBps(listaId) != specs[i].collateralIncentiveBps) {
                    o.moolah
                        .setIncentives(
                            listaId, specs[i].collateralIncentiveBps, BB.LISTA_BORROW_INCENTIVE_BPS
                        );
                }
                if (o.moolah.market(listaId).totalSupplyAssets == 0) {
                    _mintUsdt(o.usdt, BB.LISTA_SEED);
                    TestnetToken(o.usdt).approve(address(o.moolah), BB.LISTA_SEED);
                    o.moolah.supply(p, BB.LISTA_SEED, 0, TB.OWNER, "");
                }
                m.kind = BT.Kind.LISTA;
                m.core = address(o.moolah);
                m.listaId = listaId;
            }
            m.tier = specs[i].tier;
            m.collateral = token;
            m.loan = o.usdt;
            m.vaultMarketId = BB.vaultMarketId();
            m.borrowCap = BB.BORROW_CAP;
            m.borrowEnabled = true;
            bytes32 id = BB.id(specs[i], token);
            if (!_registered(credit, id)) credit.registerMarket(id, m);
            console.log(string.concat("MANIFEST ", BB.label(specs[i]), " ", vm.toString(id)));
        }
        _revokeOwnerMinter(o.usdt);
        vm.stopBroadcast();

        console.log("MANIFEST borrowExecutor", address(o.lend));
        console.log("MANIFEST borrowRegistry", address(credit));
        console.log("MANIFEST earnVault", address(o.vault));
        console.log(string.concat("MANIFEST earnVaultMarketId ", vm.toString(BB.vaultMarketId())));
        console.log("MANIFEST lendingOracle", address(o.oracle));
        console.log("MANIFEST venusComptroller", address(o.comptroller));
        console.log("MANIFEST vUSDT", address(o.vUsdt));
        for (uint256 i; i < specs.length; ++i) {
            if (o.vCollateral[i] != address(0)) {
                console.log(string.concat("MANIFEST v", specs[i].symbol), o.vCollateral[i]);
            }
        }
        console.log("MANIFEST listaMoolah", address(o.moolah));
    }

    /// @dev Admit the earn vault in the existing yield registry so its utilization / rate / identity checks are
    /// reused; supply there stays disabled so `AtpExecutor` idle-cash deposits never mix into the strategy vault.
    function _admitVault(AtpYieldRegistry yields, address usdt, address vault) private {
        bytes32 id = BB.vaultMarketId();
        try yields.market(id) returns (Y.Market memory) {
            return;
        } catch { }
        Y.Market memory m =
            Y.Market(97, Y.Kind.LISTA, usdt, vault, vault, vault, bytes32(0), 0.5e18, 2e18, false, false);
        m.configuration = YieldView.health(m).configuration;
        yields.registerMarket(id, m);
    }

    function _token(string memory symbol) private view returns (address token) {
        token = vm.envAddress(string.concat("TOKEN_", symbol));
        require(token.code.length != 0, string.concat("borrow deploy: no token ", symbol));
    }

    function _vToken(address token, string memory symbol, MockVenusComptroller comptroller, uint16 apr)
        private
        returns (address)
    {
        return _create2(
            string.concat("borrow.venus.v", symbol),
            abi.encodePacked(
                type(MockVToken).creationCode, abi.encode(token, address(comptroller), TB.OWNER, apr, symbol)
            )
        );
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

    function _price(MockLendingOracle oracle, address asset, uint256 priceE8) private {
        if (oracle.prices(asset) != priceE8) oracle.setPrice(asset, priceE8);
    }

    function _listed(MockVenusComptroller comptroller, address v) private view returns (bool listed) {
        (listed,,) = comptroller.markets(v);
    }

    function _registered(AtpBorrowRegistry credit, bytes32 id) private view returns (bool) {
        try credit.market(id) returns (BT.Market memory) {
            return true;
        } catch {
            return false;
        }
    }

    function _minter(address usdt, address minter) private {
        if (!TestnetToken(usdt).isMinter(minter)) TestnetToken(usdt).setMinter(minter, true);
    }

    /// @dev OWNER owns USDT after the #47 hand-over but is no minter; it lends itself the minter role for the
    /// seeds and `_revokeOwnerMinter` takes it back in the same run, so no OWNER minter is left behind.
    function _mintUsdt(address usdt, uint256 amount) private {
        _minter(usdt, TB.OWNER);
        TestnetToken(usdt).mint(TB.OWNER, amount);
    }

    function _revokeOwnerMinter(address usdt) private {
        if (TestnetToken(usdt).isMinter(TB.OWNER)) TestnetToken(usdt).setMinter(TB.OWNER, false);
    }

    function _rememberKey(string memory name, address expected) private {
        uint256 key = vm.envOr(name, uint256(0));
        if (key == 0) return;
        require(vm.addr(key) == expected, string.concat(name, " does not derive the expected address"));
        vm.rememberKey(key);
    }
}
