// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {MandateRegistry} from "../src/MandateRegistry.sol";
import {AnchorLog} from "../src/AnchorLog.sol";
import {Bond} from "../src/Bond.sol";
import {AgentRefs} from "../src/AgentRefs.sol";
import {SpendMeter} from "../src/SpendMeter.sol";
import {IFdcVerification} from "@flarenetwork/flare-periphery-contracts/coston2/IFdcVerification.sol";
import {ProtocolsV2Interface} from "@flarenetwork/flare-periphery-contracts/coston2/ProtocolsV2Interface.sol";

/// @dev Runs only with `forge test --fork-url coston2`. Proves the live wiring: Bond resolves
///      Flare's real FdcVerification AND the real voting-round clock through the ContractRegistry.
///      The clock matters as much as the verifier now — commit–reveal is enforced against it, and a
///      wrong or stale source of round timings would silently let late commitments through.
contract Coston2ForkTest is Test {
    function test_resolvesRealFdcVerification() public {
        if (block.chainid != 114) return; // Coston2 only
        MandateRegistry reg = new MandateRegistry();
        AnchorLog anchorLog = new AnchorLog(reg);
        Bond bond = new Bond(
            reg, anchorLog, IFdcVerification(address(0)), 24 hours, 1 hours, new SpendMeter(reg),
            10 minutes, ProtocolsV2Interface(address(0)), new AgentRefs(reg, IFdcVerification(address(0))));
        IFdcVerification fdc = bond.fdc();
        assertTrue(address(fdc) != address(0), "FdcVerification resolved");
        assertTrue(address(fdc).code.length > 0, "has code");
        assertTrue(address(fdc.relay()) != address(0), "relay resolved");
        emit log_named_address("FdcVerification (Coston2)", address(fdc));
        emit log_named_address("Relay (Coston2)", address(fdc.relay()));
        emit log_named_uint("fdcProtocolId", fdc.fdcProtocolId());

        // the voting-round clock, read live
        ProtocolsV2Interface p = bond.protocols();
        assertTrue(address(p) != address(0), "ProtocolsV2 resolved");
        uint64 first = p.firstVotingRoundStartTs();
        uint64 dur = p.votingEpochDurationSeconds();
        assertTrue(first > 0 && dur > 0, "round clock is live");
        assertEq(bond.roundStartTs(0), first);
        // the round containing "now" must have started at or before now, and the next one after
        uint64 current = uint64((block.timestamp - first) / dur);
        assertLe(bond.roundStartTs(current), block.timestamp);
        assertGt(bond.roundStartTs(current + 1), block.timestamp);
        emit log_named_address("ProtocolsV2 (Coston2)", address(p));
        emit log_named_uint("firstVotingRoundStartTs", first);
        emit log_named_uint("votingEpochDurationSeconds", dur);
        emit log_named_uint("currentVotingRound", current);
    }
}
