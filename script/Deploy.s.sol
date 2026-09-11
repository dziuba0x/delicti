// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {MandateRegistry} from "../src/MandateRegistry.sol";
import {AnchorLog} from "../src/AnchorLog.sol";
import {Bond} from "../src/Bond.sol";
import {IFdcVerification} from "@flarenetwork/flare-periphery-contracts/coston2/IFdcVerification.sol";

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
        Bond bond = new Bond(reg, anchorLog, IFdcVerification(address(0)), responseWindow, anchorGrace); // FDC via ContractRegistry
        // Only this Bond may revoke on a proven violation. Set once, by the deployer.
        reg.setBond(address(bond));
        vm.stopBroadcast();
        console.log("MandateRegistry:", address(reg));
        console.log("AnchorLog:      ", address(anchorLog));
        console.log("Bond:           ", address(bond));
        console.log("FdcVerification:", address(bond.fdc()));
        console.log("registry.bond:  ", reg.bond());
        console.log("responseWindow: ", bond.responseWindow());
        console.log("anchorGrace:    ", bond.anchorGrace());
    }
}
