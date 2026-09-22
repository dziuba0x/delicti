// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {MandateRegistry} from "../src/MandateRegistry.sol";
import {AnchorLog} from "../src/AnchorLog.sol";
import {SpendMeter} from "../src/SpendMeter.sol";
import {AgentRefs} from "../src/AgentRefs.sol";
import {Vault} from "../src/Vault.sol";
import {JudgeEvm} from "../src/JudgeEvm.sol";
import {JudgeXrpl} from "../src/JudgeXrpl.sol";
import {IFdcVerification} from "@flarenetwork/flare-periphery-contracts/coston2/IFdcVerification.sol";
import {ProtocolsV2Interface} from "@flarenetwork/flare-periphery-contracts/coston2/ProtocolsV2Interface.sol";

/// @notice Deploys a Vault and its two judges the way `script/Deploy.s.sol` does: judges first, at
///         the address the Vault is about to get, so no setter ever exists. Takes exactly the
///         arguments v0.10's `Bond` constructor took, in the same order, so that every test fixture
///         keeps its numbers — the migration changes who is called, never what is asserted.
/// @dev    Internal library functions are inlined, so `address(this)` is the calling test and the
///         `new`s below consume its nonces.
library Core {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function deploy(
        MandateRegistry reg,
        AnchorLog anchorLog,
        IFdcVerification fdc,
        uint64 responseWindow,
        uint64 anchorGrace,
        SpendMeter meter,
        uint64 commitLead,
        ProtocolsV2Interface protocols,
        AgentRefs agentRefs,
        uint64 meterGrace
    ) internal returns (Vault vault, JudgeEvm judge, JudgeXrpl xjudge) {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 2);
        judge = new JudgeEvm(Vault(predicted), reg, anchorLog, fdc, meter, anchorGrace, responseWindow, meterGrace);
        xjudge = new JudgeXrpl(Vault(predicted), reg, anchorLog, fdc, agentRefs);
        address[] memory js = new address[](2);
        js[0] = address(judge);
        js[1] = address(xjudge);
        vault = new Vault(reg, agentRefs, protocols, commitLead, js);
        require(address(vault) == predicted, "Core: nonce prediction");
    }
}
