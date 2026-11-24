// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Script, console } from "forge-std/Script.sol";
import { ListaProofProbeHost } from "./ListaProofProbe.sol";

interface IKernelMetaFactory {
    function deployWithFactory(address factory, bytes calldata createData, bytes32 salt)
        external
        payable
        returns (address);
}

interface IKernelFactory {
    function getAddress(bytes calldata data, bytes32 salt) external view returns (address);
}

/// @notice BSC mainnet (56) only, two transactions from a throwaway key, no funds involved: a Kernel v3.3
/// account owned by that key (same version, factory and ECDSA validator as CRE8 portfolio accounts, created
/// through the canonical ZeroDev factories already on chain) and `ListaProofProbeHost` (the real
/// `StrategyBox` bound to that account, plus seven call-form probes). Then `probe.sh` asks Lista's
/// reward-proof API which of these addresses it accepts a signature from.
/// Env: PROBE_OWNER = the throwaway address; it must be the broadcaster (`--private-key` of that key).
/// Rerunning is safe: whatever already exists is reused.
///
/// Not broadcast yet. Order once approved (send through the official dataseed RPC; publicnode refuses sends):
///   1. PROBE_OWNER=<throwaway> forge script script/mainnet-verify/DeployListaProofProbe.s.sol \
///        --rpc-url https://bsc-dataseed.bnbchain.org --broadcast --slow --private-key "$(cat <key file>)"
///      (2 transactions, about 5.0M gas: 181k for the account, 4.82M for the host.)
///   2. PROBE_KEY_FILE=<key file> PROBE_HOST=<printed PROBE_HOST> python3 script/mainnet-verify/probe.py
///      (no transaction: eth_call checks, then the API queries.)
///   3. PROBE_KEY_FILE=<key file> ETH_RPC_URL=https://bsc-dataseed.bnbchain.org \
///        script/mainnet-verify/sweep.sh <address the user names>   (1 transfer returning the leftover BNB.)
contract DeployListaProofProbe is Script {
    address internal constant KERNEL_META_FACTORY = 0xd703aaE79538628d27099B8c4f621bE4CCd142d5;
    address internal constant KERNEL_FACTORY_V33 = 0x2577507b78c2008Ff367261CB6285d44ba5eF2E9;
    address internal constant KERNEL_IMPL_V33 = 0xd6CEDDe84be40893d153Be9d467CD6aD37875b28;
    address internal constant ECDSA_VALIDATOR = 0x845ADb2C711129d4f3966735eD98a9F09fC4cE57;
    bytes32 internal constant ACCOUNT_SALT = keccak256("cre8-atp:lista-proof-probe");
    bytes32 internal constant HOST_SALT = keccak256("cre8-atp:lista-proof-probe:host");
    bytes internal constant REWARD_PROOF_SUFFIX = "\nThank you for your support of listaDAO.";

    function run() external returns (address account, ListaProofProbeHost host) {
        require(block.chainid == 56, "lista proof probe: BSC mainnet (56) only");
        address owner = vm.envAddress("PROBE_OWNER");
        require(
            KERNEL_META_FACTORY.code.length != 0 && KERNEL_FACTORY_V33.code.length != 0
                && KERNEL_IMPL_V33.code.length != 0 && ECDSA_VALIDATOR.code.length != 0,
            "Kernel v3.3 infrastructure missing"
        );
        // Kernel v3.3 `initialize(rootValidator, hook, validatorData, hookData, initConfig)`: the ECDSA
        // validator as root with the owner as its data, no hook, nothing else installed (the ZeroDev SDK's
        // account without plugins).
        bytes memory init = abi.encodeWithSignature(
            "initialize(bytes21,address,bytes,bytes,bytes[])",
            bytes21(abi.encodePacked(bytes1(0x01), ECDSA_VALIDATOR)),
            address(0),
            abi.encodePacked(owner),
            bytes(""),
            new bytes[](0)
        );
        account = IKernelFactory(KERNEL_FACTORY_V33).getAddress(init, ACCOUNT_SALT);
        bytes memory hostCode = abi.encodePacked(
            type(ListaProofProbeHost).creationCode, abi.encode(account, REWARD_PROOF_SUFFIX)
        );
        host = ListaProofProbeHost(
            address(
                uint160(
                    uint256(
                        keccak256(
                            abi.encodePacked(bytes1(0xff), CREATE2_FACTORY, HOST_SALT, keccak256(hostCode))
                        )
                    )
                )
            )
        );

        vm.startBroadcast();
        require(msg.sender == owner, "broadcaster must be PROBE_OWNER");
        if (account.code.length == 0) {
            address created = IKernelMetaFactory(KERNEL_META_FACTORY)
                .deployWithFactory(KERNEL_FACTORY_V33, init, ACCOUNT_SALT);
            require(created == account, "unexpected account address");
        }
        if (address(host).code.length == 0) {
            (bool ok,) = CREATE2_FACTORY.call(abi.encodePacked(HOST_SALT, hostCode));
            require(ok && address(host).code.length != 0, "host deployment failed");
        }
        vm.stopBroadcast();

        require(host.account() == account, "host account");
        console.log("PROBE_OWNER  ", owner);
        console.log("PROBE_ACCOUNT", account);
        console.log("PROBE_HOST   ", address(host));
        console.log("PROBE_BOX    ", host.box());
        for (uint256 i; i < 7; ++i) {
            console.log(string.concat("PROBE_FORM_", vm.toString(i)), host.probes(i));
        }
    }
}
