// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {MandateRegistry} from "../src/MandateRegistry.sol";
import {AnchorLog} from "../src/AnchorLog.sol";
import {Bond} from "../src/Bond.sol";
import {SpendMeter} from "../src/SpendMeter.sol";
import {AgentRefs} from "../src/AgentRefs.sol";
import {CorroborationLog} from "../src/CorroborationLog.sol";
import {BondLens} from "../src/BondLens.sol";
import {IFdcVerification} from "@flarenetwork/flare-periphery-contracts/coston2/IFdcVerification.sol";
import {ProtocolsV2Interface} from "@flarenetwork/flare-periphery-contracts/coston2/ProtocolsV2Interface.sol";

/// Usage (Coston2):
///   forge script script/Deploy.s.sol --rpc-url coston2 --broadcast --private-key $PK
contract Deploy is Script {
    function run() external {
        vm.startBroadcast();
        MandateRegistry reg = new MandateRegistry();
        AnchorLog anchorLog = new AnchorLog(reg);
        // 24 h in production; RESPONSE_WINDOW lets a testnet deployment show the full loop in one sitting.
        uint64 responseWindow = uint64(vm.envOr("RESPONSE_WINDOW", uint256(24 hours)));
        uint64 anchorGrace = uint64(vm.envOr("ANCHOR_GRACE", uint256(1 hours)));
        // How much older than its evidence round a challenge commitment must be. 10 min in
        // production (see Bond.commitLead); COMMIT_LEAD lets a demo run finish in one sitting.
        uint64 commitLead = uint64(vm.envOr("COMMIT_LEAD", uint256(10 minutes)));
        // How late an effector's tally may still be honest (SPEC §6.5). Production: 5 minutes.
        uint64 meterGrace = uint64(vm.envOr("METER_GRACE", uint256(5 minutes)));
        SpendMeter meter = new SpendMeter(reg);
        AgentRefs agentRefs = new AgentRefs(reg, IFdcVerification(address(0)));
        // FDC and the voting-round clock both resolved via ContractRegistry.
        Bond bond = new Bond(
            reg,
            anchorLog,
            IFdcVerification(address(0)),
            responseWindow,
            anchorGrace,
            meter,
            commitLead,
            ProtocolsV2Interface(address(0)),
            agentRefs,
            meterGrace
        );
        // Stateless companions: no funds, no privileges, replaceable by anyone at any time.
        CorroborationLog corroborations = new CorroborationLog(reg, anchorLog, IFdcVerification(address(0)));
        BondLens lens = new BondLens();
        // No wiring step: since v0.9 each mandate names its own consequence contract
        // (`Terms.bond`), so the registry has no deployer privilege and nothing to set.
        vm.stopBroadcast();
        console.log("MandateRegistry:", address(reg));
        console.log("AnchorLog:      ", address(anchorLog));
        console.log("SpendMeter:     ", address(meter));
        console.log("Bond:           ", address(bond));
        console.log("AgentRefs:      ", address(agentRefs));
        console.log("Corroborations: ", address(corroborations));
        console.log("BondLens:       ", address(lens));
        console.log("FdcVerification:", address(bond.fdc()));
        console.log("responseWindow: ", bond.responseWindow());
        console.log("anchorGrace:    ", bond.anchorGrace());
        console.log("commitLead:     ", bond.commitLead());
        console.log("meterGrace:     ", bond.meterGrace());
        console.log("ProtocolsV2:    ", address(bond.protocols()));
    }
}
