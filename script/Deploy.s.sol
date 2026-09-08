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
        Bond bond = new Bond(reg, anchorLog, IFdcVerification(address(0))); // resolve via ContractRegistry
        vm.stopBroadcast();
        console.log("MandateRegistry:", address(reg));
        console.log("AnchorLog:      ", address(anchorLog));
        console.log("Bond:           ", address(bond));
        console.log("FdcVerification:", address(bond.fdc()));
    }
}
