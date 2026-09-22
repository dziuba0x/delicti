// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {MandateRegistry} from "../src/MandateRegistry.sol";
import {AnchorLog} from "../src/AnchorLog.sol";
import {SpendMeter} from "../src/SpendMeter.sol";
import {AgentRefs} from "../src/AgentRefs.sol";
import {CorroborationLog} from "../src/CorroborationLog.sol";
import {BondLens} from "../src/BondLens.sol";
import {Vault} from "../src/Vault.sol";
import {JudgeEvm} from "../src/JudgeEvm.sol";
import {JudgeXrpl} from "../src/JudgeXrpl.sol";
import {IFdcVerification} from "@flarenetwork/flare-periphery-contracts/coston2/IFdcVerification.sol";
import {ProtocolsV2Interface} from "@flarenetwork/flare-periphery-contracts/coston2/ProtocolsV2Interface.sol";

/// Usage (Coston2):
///   set -a; . ./.env; set +a
///   forge script script/Deploy.s.sol --rpc-url coston2 --broadcast
///
/// v0.11 deploys the consequence layer — a Vault and its judges — and, by default, REUSES the core
/// that is already on-chain: pass REG, LOG, METER (and CORROBORATION_LOG) to keep the v0.10 registry, anchor log,
/// meter and corroboration log. Old mandates stay with the old Bond; new ones name the Vault.
/// Leave them unset to deploy a fresh core as well.
contract Deploy is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        uint64 responseWindow = uint64(vm.envOr("RESPONSE_WINDOW", uint256(24 hours)));
        uint64 anchorGrace = uint64(vm.envOr("ANCHOR_GRACE", uint256(1 hours)));
        uint64 commitLead = uint64(vm.envOr("COMMIT_LEAD", uint256(10 minutes)));
        uint64 meterGrace = uint64(vm.envOr("METER_GRACE", uint256(5 minutes)));

        vm.startBroadcast(pk);
        MandateRegistry reg = MandateRegistry(vm.envOr("REG", address(0)));
        if (address(reg) == address(0)) reg = new MandateRegistry();
        AnchorLog anchorLog = AnchorLog(vm.envOr("LOG", address(0)));
        if (address(anchorLog) == address(0)) anchorLog = new AnchorLog(reg);
        SpendMeter meter = SpendMeter(vm.envOr("METER", address(0)));
        if (address(meter) == address(0)) meter = new SpendMeter(reg);
        CorroborationLog corroborations = CorroborationLog(vm.envOr("CORROBORATION_LOG", address(0)));
        if (address(corroborations) == address(0)) {
            corroborations = new CorroborationLog(reg, anchorLog, IFdcVerification(address(0)));
        }
        require(address(anchorLog.registry()) == address(reg) && address(meter.registry()) == address(reg), "core mismatch");

        // v0.11: AgentRefs gains `proveExclusive` — a new contract, no funds, no privileges.
        AgentRefs agentRefs = new AgentRefs(reg, IFdcVerification(address(0)));

        // Judges first, each told the address the Vault is about to get; the Vault's constructor
        // then refuses any judge that names another. No setter exists at any point.
        address predicted = vm.computeCreateAddress(deployer, vm.getNonce(deployer) + 2);
        JudgeEvm judgeEvm = new JudgeEvm(
            Vault(predicted), reg, anchorLog, IFdcVerification(address(0)), meter, anchorGrace, responseWindow, meterGrace
        );
        JudgeXrpl judgeXrpl = new JudgeXrpl(Vault(predicted), reg, anchorLog, IFdcVerification(address(0)), agentRefs);
        address[] memory judges = new address[](2);
        judges[0] = address(judgeEvm);
        judges[1] = address(judgeXrpl);
        Vault vault = new Vault(reg, agentRefs, ProtocolsV2Interface(address(0)), commitLead, judges);
        require(address(vault) == predicted, "vault address prediction");
        BondLens lens = new BondLens();
        vm.stopBroadcast();

        console.log("MandateRegistry:", address(reg));
        console.log("AnchorLog:      ", address(anchorLog));
        console.log("SpendMeter:     ", address(meter));
        console.log("Corroborations: ", address(corroborations));
        console.log("AgentRefs:      ", address(agentRefs));
        console.log("JudgeEvm:       ", address(judgeEvm));
        console.log("JudgeXrpl:      ", address(judgeXrpl));
        console.log("Vault:          ", address(vault));
        console.log("BondLens:       ", address(lens));
        console.log("FdcVerification:", address(judgeEvm.fdc()));
        console.log("ProtocolsV2:    ", address(vault.protocols()));
        console.log("responseWindow: ", judgeEvm.responseWindow());
        console.log("anchorGrace:    ", judgeEvm.anchorGrace());
        console.log("commitLead:     ", vault.commitLead());
        console.log("meterGrace:     ", judgeEvm.meterGrace());
    }
}
