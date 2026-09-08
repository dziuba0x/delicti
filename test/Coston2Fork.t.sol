// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {MandateRegistry} from "../src/MandateRegistry.sol";
import {AnchorLog} from "../src/AnchorLog.sol";
import {Bond} from "../src/Bond.sol";
import {IFdcVerification} from "@flarenetwork/flare-periphery-contracts/coston2/IFdcVerification.sol";

/// @dev Runs only with `forge test --fork-url coston2`. Proves the live wiring:
///      Bond resolves Flare's real FdcVerification through the ContractRegistry.
contract Coston2ForkTest is Test {
    function test_resolvesRealFdcVerification() public {
        if (block.chainid != 114) return; // Coston2 only
        MandateRegistry reg = new MandateRegistry();
        AnchorLog anchorLog = new AnchorLog(reg);
        Bond bond = new Bond(reg, anchorLog, IFdcVerification(address(0)));
        IFdcVerification fdc = bond.fdc();
        assertTrue(address(fdc) != address(0), "FdcVerification resolved");
        assertTrue(address(fdc).code.length > 0, "has code");
        assertTrue(address(fdc.relay()) != address(0), "relay resolved");
        emit log_named_address("FdcVerification (Coston2)", address(fdc));
        emit log_named_address("Relay (Coston2)", address(fdc.relay()));
        emit log_named_uint("fdcProtocolId", fdc.fdcProtocolId());
    }
}
