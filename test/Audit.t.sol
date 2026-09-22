// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {StructuringFixture} from "./Structuring.t.sol";
import {MandateRegistry} from "../src/MandateRegistry.sol";
import {AnchorLog} from "../src/AnchorLog.sol";
import {Vault} from "../src/Vault.sol";
import {JudgeEvm} from "../src/JudgeEvm.sol";
import {JudgeXrpl} from "../src/JudgeXrpl.sol";
import {DelictiErrors} from "../src/DelictiErrors.sol";
import {Core} from "./Core.sol";
import {AgentRefs} from "../src/AgentRefs.sol";
import {SpendMeter} from "../src/SpendMeter.sol";
import {CorroborationLog} from "../src/CorroborationLog.sol";
import {Receipts} from "../src/Receipts.sol";
import {IFdcVerification} from "@flarenetwork/flare-periphery-contracts/coston2/IFdcVerification.sol";
import {IEVMTransaction} from "@flarenetwork/flare-periphery-contracts/coston2/IEVMTransaction.sol";
import {ProtocolsV2Interface} from "@flarenetwork/flare-periphery-contracts/coston2/ProtocolsV2Interface.sol";
import {MockProtocolsV2} from "./Rounds.sol";

contract MockFdcAudit {
    function verifyEVMTransaction(IEVMTransaction.Proof calldata) external pure returns (bool) {
        return true;
    }
}

/// @title Audit of v0.9 — two openings the invariant campaign could not see, and their fixes
/// @notice Both were reachable from outside the contracts: one needed a colluding effector, the
///         other nothing but gas. Neither was a Solidity bug; both were missing bindings — one in
///         time (a tally read at the wrong moment), one in scope (a per-mandate key behind a
///         per-agent counter). v0.10 fixes both; these are the regressions.
contract AuditMeterTest is Test {
    MandateRegistry reg;
    AnchorLog anchorLog;
    Vault bond;
    JudgeEvm judge;
    JudgeXrpl xjudge;
    SpendMeter meter;
    MockFdcAudit mock;
    MockProtocolsV2 rounds;

    address principal = makeAddr("principal");
    address agent = makeAddr("agent");
    address effector = makeAddr("effector");
    address merchant = makeAddr("merchant");
    address challenger = makeAddr("challenger");

    bytes32 constant SRC = bytes32("testFLR");
    uint256 constant EACH = 1 ether;
    uint256 constant BUDGET = 4 ether;
    uint64 constant COMMIT_LEAD = 10 minutes;
    bytes32 constant SALT = keccak256("the watcher's salt");

    uint256 mandateId;

    function setUp() public {
        reg = new MandateRegistry();
        anchorLog = new AnchorLog(reg);
        mock = new MockFdcAudit();
        meter = new SpendMeter(reg);
        rounds = new MockProtocolsV2();
        (bond, judge, xjudge) = Core.deploy(
            reg, anchorLog, IFdcVerification(address(mock)), 24 hours, 1 hours, meter,
            COMMIT_LEAD, ProtocolsV2Interface(address(rounds)), new AgentRefs(reg, IFdcVerification(address(0)))
        , 5 minutes);
        vm.warp(1_800_000_000);
        vm.prank(principal);
        mandateId = reg.commit(
            agent, keccak256("metered, exclusive"), 0, 0, BUDGET,
            uint64(block.timestamp), uint64(block.timestamp + 7 days),
            MandateRegistry.Terms({sourceId: SRC, assetKey: bytes32(0), agentRef: bytes32(0), bond: address(bond)})
        );
        vm.prank(agent);
        reg.declareExclusive(mandateId);
        vm.prank(principal);
        meter.declareEffector(mandateId, effector);
        vm.deal(principal, 100 ether);
        vm.prank(principal);
        bond.post{value: 10 ether}(mandateId);
    }

    function _proof(uint256 i) internal view returns (IEVMTransaction.Proof memory p) {
        p.data.attestationType = bytes32("EVMTransaction");
        p.data.sourceId = SRC;
        p.data.requestBody.transactionHash = bytes32(uint256(0x1000 + i));
        p.data.responseBody.blockNumber = uint64(100 + i);
        p.data.responseBody.timestamp = uint64(block.timestamp + i);
        p.data.responseBody.sourceAddress = agent;
        p.data.responseBody.receivingAddress = merchant;
        p.data.responseBody.value = EACH;
        p.data.responseBody.status = 1;
    }

    function _bundle(uint256 k) internal view returns (IEVMTransaction.Proof[] memory ps) {
        ps = new IEVMTransaction.Proof[](k);
        for (uint256 i = 0; i < k; i++) ps[i] = _proof(i);
    }

    function _arm(address who, IEVMTransaction.Proof[] memory ps) internal {
        bytes32[] memory ids = new bytes32[](ps.length);
        for (uint256 i = 0; i < ps.length; i++) ids[i] = ps[i].data.requestBody.transactionHash;
        uint64 t = uint64(block.timestamp);
        vm.warp(t - COMMIT_LEAD);
        vm.prank(who);
        bond.commitChallenge(bond.commitmentFor(who, mandateId, bond.KIND_UNDER_REPORTED(), bond.deedsDigest(ids), SALT));
        vm.warp(t);
        rounds.setRoundStart(0, t);
    }

    /// @notice REGRESSION (v0.9 opening, fixed in v0.10) — the effector can no longer destroy the
    ///         case against itself once the case is public.
    /// @dev    The attack: §6.5 convicted on `proven > meter.spent(mandateId)` read at REVEAL time,
    ///         while `note()` stays open to the effector for as long as the mandate lives and takes
    ///         any amount. The challenger is forced to publish the case first — `requestAttestation`
    ///         carries the deeds' transaction hashes in the clear and the reveal cannot land until
    ///         the round finalises and `commitLead` has passed (§6.7), so the effector had a
    ///         quarter of an hour to "catch up" its tally to the truth and the challenge then died
    ///         on `TallyAgrees`. Commit–reveal protects who OWNS a reward, not whether there is one.
    ///         The verdict now reads `spentAt(lastDeed + meterGrace)`, a fact nothing written later
    ///         can change.
    function test_effectorCannotCatchUpTheTallyOnceTheCaseIsPublic() public {
        IEVMTransaction.Proof[] memory ps = _bundle(5);

        // the effector records two of five settlements and stays silent about three
        vm.startPrank(effector);
        meter.note(mandateId, EACH);
        meter.note(mandateId, EACH);
        vm.stopPrank();
        assertEq(meter.spent(mandateId), 2 * EACH);

        // a watcher detects it, commits and requests its attestations — the case is now public.
        // The earliest possible reveal is a round's finality plus commitLead after that.
        vm.warp(block.timestamp + 15 minutes);
        _arm(challenger, ps);

        // the effector notes the missing three, which under v0.9 was enough to erase the case
        vm.prank(effector);
        meter.note(mandateId, 3 * EACH);
        assertEq(meter.spent(mandateId), 5 * EACH, "the tally NOW agrees with the world");

        vm.prank(challenger);
        judge.challengeUnderReportedSpend(mandateId, ps, SALT);

        assertTrue(bond.slashed(mandateId), "the tally at the time of the deeds is what is judged");
        assertLt(bond.bondOf(mandateId), 10 ether);
    }

    /// @notice The limit this fix keeps, stated rather than hidden: an effector that is merely late
    ///         — inside `meterGrace` of the deed — is not a liar, and is not convicted.
    function test_effectorMayBeLateWithinTheGrace() public {
        IEVMTransaction.Proof[] memory ps = _bundle(5);
        vm.startPrank(effector);
        meter.note(mandateId, EACH);
        meter.note(mandateId, EACH);
        vm.stopPrank();

        vm.warp(block.timestamp + 2 minutes); // inside the 5-minute grace
        vm.prank(effector);
        meter.note(mandateId, 3 * EACH);

        vm.warp(block.timestamp + 15 minutes);
        _arm(challenger, ps);
        vm.prank(challenger);
        vm.expectRevert(DelictiErrors.TallyAgrees.selector);
        judge.challengeUnderReportedSpend(mandateId, ps, SALT);
    }

    /// @notice The control: a tally that stayed silent is convicted, as in v0.9.
    function test_controlUntouchedTallyStillConvicts() public {
        IEVMTransaction.Proof[] memory ps = _bundle(5);
        vm.startPrank(effector);
        meter.note(mandateId, EACH);
        meter.note(mandateId, EACH);
        vm.stopPrank();
        vm.warp(block.timestamp + 15 minutes);
        _arm(challenger, ps);
        vm.prank(challenger);
        judge.challengeUnderReportedSpend(mandateId, ps, SALT);
        assertTrue(bond.slashed(mandateId));
    }

    /// @notice The history the fix reads is append-only and per second, and answers before its
    ///         first entry with zero.
    function test_tallyHistoryIsAppendOnlyAndReadableAtAnyMoment() public {
        uint64 t0 = uint64(block.timestamp);
        vm.prank(effector);
        meter.note(mandateId, EACH);
        vm.warp(t0 + 100);
        vm.prank(effector);
        meter.note(mandateId, EACH);
        assertEq(meter.spentAt(mandateId, t0 - 1), 0, "nothing was recorded before the first note");
        assertEq(meter.spentAt(mandateId, t0), EACH);
        assertEq(meter.spentAt(mandateId, t0 + 99), EACH);
        assertEq(meter.spentAt(mandateId, t0 + 100), 2 * EACH);
        assertEq(meter.checkpointCount(mandateId), 2);
    }

    /// @notice Several settlements inside one block are one moment, not several.
    function test_notesInTheSameSecondCollapseToOneCheckpoint() public {
        vm.startPrank(effector);
        meter.note(mandateId, EACH);
        meter.note(mandateId, EACH);
        vm.stopPrank();
        assertEq(meter.checkpointCount(mandateId), 1);
        (uint64 at, uint256 total) = meter.checkpoint(mandateId, 0);
        assertEq(at, uint64(block.timestamp));
        assertEq(total, 2 * EACH);
    }
}

/// @notice Inherits the salami fixture (abstract: it re-runs nothing).
contract AuditCorroborationTest is StructuringFixture {
    /// @notice REGRESSION (v0.9 opening, fixed in v0.10) — one deed, counted once per agent.
    /// @dev    `CorroborationLog.deedRecorded` and `corroborated` are keyed per MANDATE, but
    ///         `countOfAgent` is keyed per AGENT and crosses them. Anyone may commit a mandate
    ///         naming any agent, and the agent may acknowledge its own; the same FDC proof verifies
    ///         under every one of them, so a second mandate over the same window and source turns
    ///         one real deed into two entries in the agent's public record — at the price of an
    ///         anchor and a call. §11 tells a score to weigh corroboration by VALUE, and
    ///         `valueOf` is per mandate, so an indexer summing `valueOf` over an agent's mandates
    ///         inherits the same multiple.
    ///         SPEC §10 admits that the log "cannot tell a deed from a wash" — a wash costs a real
    ///         transaction on the source chain. This costs none: it is the SAME transaction.
    function test_oneDeedIsCountedOncePerAgentAcrossMandates() public {
        CorroborationLog corr = new CorroborationLog(reg, anchorLog, IFdcVerification(address(mock)));

        // the real deed, corroborated under the mandate it was done for
        corr.corroborateEvm(mandateId, 0, leaves[0], new bytes32[](0), _evmProof(0));
        assertEq(corr.countOfAgent(agent), 1);

        // a second mandate for the same agent, same source, same window — free to create
        vm.prank(principal);
        uint256 second = reg.commit(
            agent, keccak256("a mandate whose only purpose is to be counted"), 0, 0, BUDGET,
            uint64(block.timestamp), uint64(block.timestamp + 1 days), _terms()
        );
        vm.prank(agent);
        reg.acknowledge(second);

        // the same deed, re-anchored under it: one leaf, one call, no new transaction anywhere
        Receipts.Leaf memory again = leaves[0];
        again.mandateId = second;
        bytes32 h = Receipts.hashMem(again);
        vm.prank(agent);
        anchorLog.anchor(second, h, 1);

        vm.expectRevert(CorroborationLog.AlreadyCorroborated.selector);
        corr.corroborateEvm(second, 0, again, new bytes32[](0), _evmProof(0));

        assertEq(corr.countOfAgent(agent), 1, "one deed, one entry in the agent's record");
        assertEq(corr.countOf(second), 0);
        assertTrue(corr.deedRecordedForAgent(agent, leaves[0].ref));
    }
}
