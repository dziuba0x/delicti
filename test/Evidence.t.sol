// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {StructuringFixture} from "./Structuring.t.sol";
import {Vault} from "../src/Vault.sol";
import {JudgeEvm} from "../src/JudgeEvm.sol";
import {JudgeXrpl} from "../src/JudgeXrpl.sol";
import {DelictiErrors} from "../src/DelictiErrors.sol";
import {Core} from "./Core.sol";
import {AnchorLog} from "../src/AnchorLog.sol";
import {CorroborationLog} from "../src/CorroborationLog.sol";
import {Deeds} from "../src/Deeds.sol";
import {Receipts} from "../src/Receipts.sol";
import {IFdcVerification} from "@flarenetwork/flare-periphery-contracts/coston2/IFdcVerification.sol";
import {IEVMTransaction} from "@flarenetwork/flare-periphery-contracts/coston2/IEVMTransaction.sol";

/// @title v0.9 — what a score can count without an archive node and without touching the core
/// @notice Inherits the salami fixture: five anchored 1-ether deeds, budget 4, bond 10 ether.
contract EvidenceTest is StructuringFixture {
    CorroborationLog corr;

    event DeedCorroborated(
        uint256 indexed mandateId, address indexed agent, bytes32 indexed deedId, bytes32 leafHash,
        uint256 episodeIndex, uint256 value, uint64 deedTime, uint64 votingRound, address by
    );
    event DeedJudged(uint256 indexed mandateId, uint8 indexed kind, bytes32 indexed deedId, uint256 value);
    event Anchored(
        uint256 indexed mandateId, uint256 indexed index, bytes32 root, uint64 receiptCount, address indexed by,
        uint64 anchoredAt, string leavesURI
    );

    function _corr() internal {
        corr = new CorroborationLog(reg, anchorLog, IFdcVerification(address(mock)));
    }

    // ------------------------------------------------------------------ corroboration: the good case leaves a trace

    function test_agreementIsRecorded() public {
        _corr();
        IEVMTransaction.Proof memory p = _evmProof(2);
        vm.expectEmit(true, true, true, true);
        emit DeedCorroborated(mandateId, agent, leaves[2].ref, hashes[2], 2, EACH, leaves[2].claimedTimestamp, 0, address(this));
        corr.corroborateEvm(mandateId, 2, leaves[2], new bytes32[](0), p);
        assertEq(corr.countOf(mandateId), 1);
        assertEq(corr.valueOf(mandateId), EACH);
        assertEq(corr.countOfAgent(agent), 1);
        assertFalse(bond.slashed(mandateId), "recording agreement has no consequence");
    }

    function test_revert_sameDeedCorroboratedTwice() public {
        _corr();
        IEVMTransaction.Proof memory p = _evmProof(0);
        corr.corroborateEvm(mandateId, 0, leaves[0], new bytes32[](0), p);
        vm.expectRevert(CorroborationLog.AlreadyCorroborated.selector);
        corr.corroborateEvm(mandateId, 0, leaves[0], new bytes32[](0), p);
    }

    /// The definition of "agree" is the Bond's own: a proof that would not count in a challenge does
    /// not count here either.
    function test_revert_disagreementIsNotCorroboration() public {
        _corr();
        IEVMTransaction.Proof memory p = _evmProof(1);
        p.data.responseBody.value = EACH + 1;
        vm.expectRevert(Deeds.ProofDoesNotMatchClaim.selector);
        corr.corroborateEvm(mandateId, 1, leaves[1], new bytes32[](0), p);

        p = _evmProof(1);
        p.data.responseBody.sourceAddress = makeAddr("someone else");
        vm.expectRevert(Deeds.NotAgentTx.selector);
        corr.corroborateEvm(mandateId, 1, leaves[1], new bytes32[](0), p);

        p = _evmProof(1);
        vm.expectRevert(Deeds.LeafNotAnchored.selector);
        corr.corroborateEvm(mandateId, 0, leaves[1], new bytes32[](0), p); // wrong episode
    }

    /// A flattering record an outsider can write into is still not the agent's record.
    function test_revert_corroborationUnderAnUnacknowledgedMandate() public {
        _corr();
        vm.prank(principal);
        uint256 id = reg.commit(agent, keccak256("never accepted"), 0, 0, BUDGET, uint64(block.timestamp), uint64(block.timestamp + 1 days), _terms());
        Receipts.Leaf memory l = leaves[0];
        l.mandateId = id;
        vm.prank(principal); // principals may anchor
        anchorLog.anchor(id, Receipts.hashMem(l), 1);
        IEVMTransaction.Proof memory p = _evmProof(0);
        vm.expectRevert(CorroborationLog.NotAcknowledged.selector);
        corr.corroborateEvm(id, 0, l, new bytes32[](0), p);
    }

    // ------------------------------------------------------------------ contradiction: which deeds, by value

    function test_verdictNamesEveryDeedItSummed() public {
        (uint256[] memory idx, Receipts.Leaf[] memory ls, bytes32[][] memory paths, IEVMTransaction.Proof[] memory pr) = _bundle(5);
        _arm(bond.KIND_BUDGET_NATIVE(), challenger, pr);
        for (uint256 i = 0; i < 5; i++) {
            vm.expectEmit(true, true, true, true, address(judge)); // v0.11: the judge that summed the deeds emits them
            emit DeedJudged(mandateId, 2, leaves[i].ref, EACH);
        }
        vm.prank(challenger);
        judge.challengeBudgetOverrun(mandateId, idx, ls, paths, pr, SALT);
        assertEq(bond.verdictsAgainst(agent), 1);
        assertEq(bond.takenFrom(agent), 2.5 ether);
    }

    // ------------------------------------------------------------------ coverage: leaves somebody can fetch

    function test_anchorPublishesWhereTheLeavesAre() public {
        vm.expectEmit(true, true, true, true, address(anchorLog));
        emit Anchored(mandateId, 5, keccak256("root"), 3, agent, uint64(block.timestamp), "ipfs://bafy-episode-5");
        vm.prank(agent);
        anchorLog.anchor(mandateId, keccak256("root"), 3, "ipfs://bafy-episode-5");
        assertEq(anchorLog.receiptCountOf(mandateId), 5 + 3);
    }

    // ------------------------------------------------------------------ a record that is complete or provably not

    /// A contract cannot read events, and an agent asked for its record will show the mandates that
    /// went well. The list is appended at acknowledgement — by the agent, never by an outsider.
    function test_agentsMandatesAreEnumerable_andOnlyAcknowledgedOnes() public {
        assertEq(reg.mandateCountOf(agent), 1);
        assertEq(reg.mandateOf(agent, 0), mandateId);

        vm.prank(makeAddr("spammer"));
        reg.commit(agent, keccak256("spam"), 0, 0, 1, uint64(block.timestamp), uint64(block.timestamp + 1 days), _terms());
        assertEq(reg.mandateCountOf(agent), 1, "an outsider cannot append to an agent's record");

        vm.prank(principal);
        uint256 id = reg.commit(agent, keccak256("second"), 0, 0, 1, uint64(block.timestamp), uint64(block.timestamp + 1 days), _terms());
        vm.prank(agent);
        reg.declareExclusive(id); // implies acknowledgement
        vm.prank(agent);
        reg.acknowledge(id); // idempotent: not listed twice
        assertEq(reg.mandateCountOf(agent), 2);
        assertEq(reg.mandateOf(agent, 1), id);
    }
}
