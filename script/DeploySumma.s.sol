// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {MandateRegistry} from "../src/MandateRegistry.sol";
import {AgentRefs} from "../src/AgentRefs.sol";
import {Vault} from "../src/Vault.sol";
import {JudgeSumma} from "../src/JudgeSumma.sol";
import {IFdcVerification} from "@flarenetwork/flare-periphery-contracts/coston2/IFdcVerification.sol";
import {FtsoV2Interface} from "@flarenetwork/flare-periphery-contracts/coston2/FtsoV2Interface.sol";
import {ProtocolsV2Interface} from "@flarenetwork/flare-periphery-contracts/coston2/ProtocolsV2Interface.sol";

/// @notice SUMMA (amendment v1.1) on an existing v0.15 deployment: JudgeSumma first, at the address
///         the Vault is about to get, then VaultSumma = the unchanged v0.15 Vault bytecode with
///         `judges = [JudgeSumma]`. Registry and AgentRefs are reused, so umbrellas and rail
///         mandates live in the same registry. FDC, FtsoV2 and the round clock resolve through
///         Flare's ContractRegistry (no overrides).
///
///   REG=… REFS=… USDT0=0x9Eea… PRIVATE_KEY=… forge script script/DeploySumma.s.sol --rpc-url coston2 --broadcast
contract DeploySumma is Script {
    bytes21 constant XRP_USD = bytes21(0x015852502f55534400000000000000000000000000);
    bytes21 constant USDT_USD = bytes21(0x01555344542f555344000000000000000000000000);
    bytes21 constant USDC_USD = bytes21(0x01555344432f555344000000000000000000000000);
    bytes21 constant FLR_USD = bytes21(0x01464c522f55534400000000000000000000000000);

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        MandateRegistry reg = MandateRegistry(vm.envAddress("REG"));
        AgentRefs refs = AgentRefs(vm.envAddress("REFS"));
        uint64 commitLead = uint64(vm.envOr("COMMIT_LEAD", uint256(10 minutes)));
        address usdt0 = vm.envAddress("USDT0"); // on Coston2: MockUSDT0 (EIP-3009, public mint)
        address wflr = vm.envOr("WFLR", address(0));
        bool testnet = vm.envOr("TESTNET", true);

        // The price map is code: written here, once, and never again (amendment S.5).
        uint256 n = wflr == address(0) ? 2 : 3;
        JudgeSumma.PriceRow[] memory map = new JudgeSumma.PriceRow[](n);
        map[0] = JudgeSumma.PriceRow(testnet ? bytes32("testXRP") : bytes32("XRP"), bytes32("XRP/outflow"), XRP_USD, 6);
        map[1] = JudgeSumma.PriceRow(testnet ? bytes32("testFLR") : bytes32("FLR"), bytes32(uint256(uint160(usdt0))), USDT_USD, 6);
        if (wflr != address(0)) {
            map[2] = JudgeSumma.PriceRow(testnet ? bytes32("testFLR") : bytes32("FLR"), bytes32(uint256(uint160(wflr))), FLR_USD, 18);
        }

        vm.startBroadcast(pk);
        address predicted = vm.computeCreateAddress(deployer, vm.getNonce(deployer) + 1);
        JudgeSumma summa = new JudgeSumma(
            Vault(predicted), reg, refs, IFdcVerification(address(0)), FtsoV2Interface(address(0)), map
        );
        address[] memory judges = new address[](1);
        judges[0] = address(summa);
        Vault vault = new Vault(reg, refs, ProtocolsV2Interface(address(0)), commitLead, judges);
        vm.stopBroadcast();
        require(address(vault) == predicted, "DeploySumma: nonce prediction");

        console.log("JudgeSumma: ", address(summa));
        console.log("VaultSumma: ", address(vault));
        console.log("commitLead: ", vault.commitLead());
    }
}
