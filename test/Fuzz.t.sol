// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {MandateRegistry} from "../src/MandateRegistry.sol";
import {AnchorLog} from "../src/AnchorLog.sol";
import {Bond} from "../src/Bond.sol";
import {AgentRefs} from "../src/AgentRefs.sol";
import {SpendMeter} from "../src/SpendMeter.sol";
import {Receipts} from "../src/Receipts.sol";
import {IFdcVerification} from "@flarenetwork/flare-periphery-contracts/coston2/IFdcVerification.sol";
import {IEVMTransaction} from "@flarenetwork/flare-periphery-contracts/coston2/IEVMTransaction.sol";
import {ProtocolsV2Interface} from "@flarenetwork/flare-periphery-contracts/coston2/ProtocolsV2Interface.sol";
import {MockProtocolsV2} from "./Rounds.sol";
import {CredulousFdc} from "./invariant/Handler.sol";

/// @title Stateless properties — "for every input", where the unit tests say "for this input"
contract FuzzTest is Test {
    MandateRegistry reg;
    AnchorLog anchorLog;
    Bond bond;
    MockProtocolsV2 rounds;

    address principal = makeAddr("principal");
    address agent = makeAddr("agent");
    address watcher = makeAddr("watcher");
    bytes32 constant SRC = bytes32("testFLR");
    uint64 constant LEAD = 10 minutes;
    uint64 constant T0 = 1_800_000_000;

    function setUp() public {
        vm.warp(T0);
        reg = new MandateRegistry();
        anchorLog = new AnchorLog(reg);
        rounds = new MockProtocolsV2();
        bond = new Bond(
            reg, anchorLog, IFdcVerification(address(new CredulousFdc())), 24 hours, 1 hours,
            new SpendMeter(reg), LEAD, ProtocolsV2Interface(address(rounds)), new AgentRefs(reg, IFdcVerification(address(0))), 5 minutes);
    }

    function _terms(bytes32 src, bytes32 asset) internal view returns (MandateRegistry.Terms memory) {
        return MandateRegistry.Terms({sourceId: src, assetKey: asset, agentRef: bytes32(0), bond: address(bond)});
    }

    /// A child is accepted IF AND ONLY IF it sits inside its parent on every axis. The unit tests
    /// check three refusals; this checks that there is no fourth way in, and no honest child refused.
    function testFuzz_childAcceptedIffItOnlyNarrows(
        uint256 pBudget, uint64 pFrom, uint64 pLen, uint256 cBudget, uint64 cFrom, uint64 cUntil, bool sameSrc, bool sameAsset, bool aimInside
    ) public {
        pFrom = uint64(bound(pFrom, 0, T0 + 365 days));
        pLen = uint64(bound(pLen, 1, 365 days));
        uint64 pUntil = pFrom + pLen;
        vm.assume(pUntil > T0);
        vm.prank(principal);
        uint256 parent = reg.commit(agent, "p", 0, 0, pBudget, pFrom, pUntil, _terms(SRC, bytes32(0)));

        if (aimInside) {
            // uniformly random children almost never land inside the parent, and a property that is
            // only ever tested on refusals is half a property
            cBudget = bound(cBudget, 0, pBudget);
            cFrom = uint64(bound(cFrom, pFrom, pUntil));
            cUntil = uint64(bound(cUntil, cFrom, pUntil));
        } else {
            cFrom = uint64(bound(cFrom, 0, T0 + 800 days));
            cUntil = uint64(bound(cUntil, 0, T0 + 800 days));
        }
        bool windowOk = cUntil > cFrom && cUntil > T0;
        bool narrows = cBudget <= pBudget && cFrom >= pFrom && cUntil <= pUntil;
        bool unitOk = sameSrc && sameAsset;

        MandateRegistry.Terms memory t = _terms(sameSrc ? SRC : bytes32("XRP"), sameAsset ? bytes32(0) : bytes32(uint256(1)));
        vm.prank(agent);
        try reg.commit(makeAddr("sub"), "c", 0, parent, cBudget, cFrom, cUntil, t) returns (uint256) {
            assertTrue(windowOk && narrows && unitOk, "a child that widens its parent was accepted");
        } catch {
            assertFalse(windowOk && narrows && unitOk, "a child that only narrows was refused");
        }
    }

    /// The commit gate opens IF AND ONLY IF  at + lead <= roundStart <= at + TTL  and  roundStart <= now.
    function testFuzz_revealAcceptedIffCommittedInsideTheWindow(uint32 roundAfterCommit, uint32 nowAfterRound, bool future) public {
        // one deed, 2 units, over a budget of 1: the case itself always stands
        vm.prank(principal);
        uint256 id = reg.commit(agent, "m", 0, 0, 1, T0, T0 + 30 days, _terms(SRC, bytes32(0)));
        vm.prank(agent);
        reg.acknowledge(id);
        vm.deal(principal, 1 ether);
        vm.prank(principal);
        bond.post{value: 1 ether}(id);

        Receipts.Leaf[] memory ls = new Receipts.Leaf[](1);
        ls[0] = Receipts.Leaf(keccak256("r"), Receipts.KIND_EVM_TX, SRC, bytes32(uint256(0x2222)), 2, bytes32(uint256(7)), T0, id);
        vm.prank(agent);
        anchorLog.anchor(id, Receipts.hashMem(ls[0]), 1);

        IEVMTransaction.Proof[] memory pr = new IEVMTransaction.Proof[](1);
        pr[0].data.sourceId = SRC;
        pr[0].data.votingRound = 1000;
        pr[0].data.requestBody.transactionHash = bytes32(uint256(7));
        pr[0].data.responseBody.timestamp = T0;
        pr[0].data.responseBody.sourceAddress = agent;
        pr[0].data.responseBody.receivingAddress = address(0x2222);
        pr[0].data.responseBody.value = 2;
        pr[0].data.responseBody.status = 1;

        bytes32[] memory ids = new bytes32[](1);
        ids[0] = bytes32(uint256(7));
        uint64 at = T0 + 100;
        vm.warp(at);
        bond.commitChallenge(bond.commitmentFor(watcher, id, bond.KIND_BUDGET_NATIVE(), bond.deedsDigest(ids), "salt"));

        uint64 rs = at + uint64(bound(roundAfterCommit, 0, 3 hours));
        uint64 nowTs = future ? rs - uint64(bound(nowAfterRound, 1, 90)) : rs + uint64(bound(nowAfterRound, 0, 1 days));
        vm.assume(nowTs >= at);
        rounds.setRoundStart(1000, rs);
        vm.warp(nowTs);

        bool expected = rs >= at + LEAD && rs <= at + bond.COMMIT_TTL() && rs <= nowTs;
        uint256[] memory eps = new uint256[](1);
        bytes32[][] memory paths = new bytes32[][](1);
        vm.prank(watcher);
        try bond.challengeBudgetOverrun(id, eps, ls, paths, pr, "salt") {
            assertTrue(expected, "the gate opened outside its window");
        } catch {
            assertFalse(expected, "the gate stayed shut inside its window");
        }
    }
}
