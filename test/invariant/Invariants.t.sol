// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {MandateRegistry} from "../../src/MandateRegistry.sol";
import {AnchorLog} from "../../src/AnchorLog.sol";
import {Vault} from "../../src/Vault.sol";
import {JudgeEvm} from "../../src/JudgeEvm.sol";
import {JudgeXrpl} from "../../src/JudgeXrpl.sol";
import {DelictiErrors} from "../../src/DelictiErrors.sol";
import {Core} from "../Core.sol";
import {AgentRefs} from "../../src/AgentRefs.sol";
import {SpendMeter} from "../../src/SpendMeter.sol";
import {IFdcVerification} from "@flarenetwork/flare-periphery-contracts/coston2/IFdcVerification.sol";
import {ProtocolsV2Interface} from "@flarenetwork/flare-periphery-contracts/coston2/ProtocolsV2Interface.sol";
import {MockProtocolsV2} from "../Rounds.sol";
import {Handler, CredulousFdc} from "./Handler.sol";

/// @title Invariants — properties that must hold after ANY sequence of calls
/// @notice The unit tests say "this attack, which we thought of, fails". These say "no sequence of
///         the things participants can do — commit, delegate, post, act, anchor, stay silent,
///         commit to a challenge, replay someone else's commitment, reveal early, reveal late,
///         accuse, answer, resolve, revoke, withdraw, claim, wait — ever breaks the books".
contract Invariants is Test {
    MandateRegistry reg;
    AnchorLog anchorLog;
    Vault bond;
    JudgeEvm judge;
    JudgeXrpl xjudge;
    SpendMeter meter;
    MockProtocolsV2 rounds;
    Handler h;

    function setUp() public {
        vm.warp(1_800_000_000);
        reg = new MandateRegistry();
        anchorLog = new AnchorLog(reg);
        meter = new SpendMeter(reg);
        rounds = new MockProtocolsV2();
        (bond, judge, xjudge) = Core.deploy(
            reg,
            anchorLog,
            IFdcVerification(address(new CredulousFdc())),
            24 hours,
            1 hours,
            meter,
            10 minutes,
            ProtocolsV2Interface(address(rounds)), new AgentRefs(reg, IFdcVerification(address(0))), 5 minutes);
        h = new Handler(reg, anchorLog, bond, judge, meter, rounds);
        targetContract(address(h));
    }

    /// The handler itself is code and can be wrong in the boring direction: every call refused,
    /// every invariant vacuously true. This drives it down the honest paths once and insists that
    /// verdicts, accusations, answers, withdrawals and claims all actually happen.
    function test_handlerReachesEveryDeepState() public {
        h.scenario(0, 1, 2 ether, 10 ether, true, true); // mandate 1: exclusive, metered, bonded
        h.deed(0, 1 ether, true);
        h.deed(0, 1 ether, true);
        h.deed(0, 1 ether, true); // 3 > budget 2
        h.honestChallenge(0, 2, false, keccak256("s1"));
        assertEq(h.nSlashes(), 1, "overrun flow did not slash");

        h.scenario(0, 1, 5 ether, 10 ether, true, true); // mandate 2
        h.deed(1, 1 ether, false); // silent deed
        h.deed(1, 1 ether, true); // written down
        h.honestAccusation(3, 2, keccak256("s2"));
        h.honestAccusation(4, 3, keccak256("s3"));
        assertEq(h.nAccusations(), 2, "accusation flow did not accuse");
        h.answer(1, 0);
        assertEq(h.nAnswered(), 1, "the anchored deed was not answerable");
        h.warp(2 days, 0);
        h.resolve(0, 0);
        assertEq(h.nResolved(), 1);
        assertEq(h.nSlashes(), 2, "silence did not slash");

        h.scenario(0, 1, 5 ether, 10 ether, true, true); // mandate 3: the tally that lied
        h.deed(2, 1 ether, false);
        h.honestChallenge(2, 2, true, keccak256("s4"));
        assertEq(h.nSlashes(), 3, "under-reported flow did not slash");

        h.scenario(0, 1, 5 ether, 10 ether, false, false); // mandate 4: left alone, then withdrawn
        h.warp(3 days, 0);
        h.warp(3 days, 0);
        h.warp(3 days, 0);
        h.withdraw(3, 0);
        assertEq(h.nWithdrawals(), 1, "withdrawal flow did not withdraw");
        for (uint256 i = 0; i < 4; i++) h.claim(i);
        assertGt(h.nClaims(), 0, "nobody could claim");
    }

    // ---------------------------------------------------------------- value

    /// Every wei the Bond holds is accounted for by exactly one of: a live bond, a credit waiting
    /// to be pulled, or the stake of an accusation still open. Nothing else, and nothing missing.
    function invariant_bondIsExactlyBackedByItsBooks() public view {
        uint256 books;
        for (uint256 i = 0; i < h.mandateCount(); i++) books += bond.bondOf(h.mandates(i)) + bond.unsettled(h.mandates(i));
        for (uint256 i = 0; i < h.actorCount(); i++) books += bond.owed(h.actors(i));
        for (uint256 i = 0; i < h.accusationCount(); i++) {
            (,,,,, bool closed,) = judge.accusations(h.accusationIds(i));
            if (!closed) books += bond.ACCUSATION_STAKE();
        }
        assertEq(address(bond).balance, books, "balance != bonds + credits + unsettled remainders + open stakes");
    }

    /// What has left can never exceed what came in.
    function invariant_neverPaysOutMoreThanCameIn() public view {
        assertLe(h.ghostClaimed() + h.ghostWithdrawn(), h.ghostPosted() + h.ghostStaked());
    }

    /// claim() pays exactly what was owed, zeroes it, and cannot be repeated on the same balance.
    function invariant_claimConservesValueAndIsNotRepeatable() public view {
        assertFalse(h.claimPaidWrongAmount(), "claim paid something other than owed[msg.sender]");
        assertFalse(h.claimTwiceSucceeded(), "the same credit was claimed twice");
    }

    // ---------------------------------------------------------------- commitments

    /// A live commitment keeps the timestamp of its FIRST submission, whoever replays it; a spent
    /// one is gone. It is spent at most once per life.
    function invariant_commitmentKeepsItsFirstTimestampAndIsSpentOnce() public view {
        assertFalse(h.commitmentRefreshed(), "a replay moved a commitment's timestamp");
        for (uint256 i = 0; i < h.commitmentCount(); i++) {
            bytes32 c = h.commitments(i);
            if (h.ghostConsumed(c)) {
                assertEq(bond.committedAt(c), 0, "a spent commitment is still on the books");
            } else {
                assertEq(bond.committedAt(c), h.ghostFirstCommit(c), "a live commitment lost its first timestamp");
            }
        }
    }

    // ---------------------------------------------------------------- consequence

    /// v0.9 replaced "a mandate is slashed at most once" — which, combined with a proportional
    /// penalty, would have let a trivial self-inflicted verdict shield the rest of the bond — with a
    /// bound on the total: verdicts never take more than the bond as it stood at the first one, and
    /// per mandate every wei is in exactly one place: still bonded, taken by verdicts, or withdrawn.
    function invariant_verdictsNeverTakeMoreThanTheBondTheyWereMeasuredOn() public view {
        for (uint256 i = 0; i < h.mandateCount(); i++) {
            uint256 id = h.mandates(i);
            assertLe(bond.slashedAmount(id), bond.slashBase(id), "verdicts took more than the base");
            assertEq(h.ghostSlashedTotal(id), bond.slashedAmount(id), "the Bond's own tally of verdicts is wrong");
            assertEq(
                h.ghostPostedTo(id),
                bond.bondOf(id) + bond.slashedAmount(id) + h.ghostWithdrawnFrom(id),
                "per mandate: posted != bonded + taken + withdrawn"
            );
            if (!bond.slashed(id)) assertEq(bond.bondOf(id), bond.totalDeposits(id), "an unslashed bond is not 1:1 with its deposits");
        }
    }

    /// A depositor never takes out more than it put in, and takes out exactly that if no verdict
    /// ever touched the mandate — whoever else posted, withdrew, or was slashed elsewhere.
    function invariant_depositorsGetTheirOwnMoneyBackAndNoMore() public view {
        assertFalse(h.withdrewMoreThanDeposited(), "a depositor withdrew more than it posted");
        assertFalse(h.unslashedDepositorShortChanged(), "a depositor under an unslashed mandate did not get its deposit back");
    }

    /// A slashed mandate is dead, and a dead mandate never anchored anything.
    function invariant_deadMandatesStayDeadAndSilent() public view {
        assertFalse(h.anchoredUnderDeadMandate(), "a dead mandate anchored an episode");
        assertFalse(h.deadMandateCameBack(), "a mandate that was dead for good became live again");
        for (uint256 i = 0; i < h.mandateCount(); i++) {
            uint256 id = h.mandates(i);
            if (bond.slashed(id)) assertFalse(reg.isLive(id), "slashed but still live");
        }
    }

    // ---------------------------------------------------------------- the delegation tree

    /// Liveness is transitive (a live child has a live parent, all the way up), and a child is
    /// never wider than its parent in budget, window, or unit — in any order of commits.
    function invariant_treeOnlyNarrowsAndDiesFromTheRoot() public view {
        for (uint256 i = 0; i < h.mandateCount(); i++) {
            uint256 id = h.mandates(i);
            MandateRegistry.Mandate memory m = reg.get(id);
            if (m.parentId == 0) continue;
            MandateRegistry.Mandate memory p = reg.get(m.parentId);
            assertLe(m.budget, p.budget, "child budget exceeds parent's");
            assertGe(m.validFrom, p.validFrom, "child starts before parent");
            assertLe(m.validUntil, p.validUntil, "child outlives parent");
            assertEq(m.sourceId, p.sourceId, "child changed the source");
            assertEq(m.assetKey, p.assetKey, "child changed the asset");
            assertEq(m.principal, p.agent, "child not committed by the parent's agent");
            if (reg.isLive(id)) assertTrue(reg.isLive(m.parentId), "live child under a dead parent");
            assertLe(reg.deathTime(id), reg.deathTime(m.parentId), "child's authority outlives its parent's");
        }
    }

    /// Not a property: a report. `forge test --match-test invariant_coverageReport -vv` prints how
    /// often the deep states were actually reached in the last run of the campaign.
    function invariant_coverageReport() public view {
        console.log("mandates", h.mandateCount());
        console.log("slashes", h.nSlashes());
        console.log("accusations", h.nAccusations());
        console.log("answered", h.nAnswered());
        console.log("resolved", h.nResolved());
        console.log("withdrawals", h.nWithdrawals());
        console.log("claims", h.nClaims());
    }

    // ---------------------------------------------------------------- liveness of the books

    /// An open accusation always has something behind it: either the bond is still there, or the
    /// mandate was slashed by another path. It can never have been quietly withdrawn from under it.
    function invariant_openAccusationIsNeverLeftWithoutCollateral() public view {
        for (uint256 i = 0; i < h.accusationCount(); i++) {
            (uint256 mid,,,,, bool closed,) = judge.accusations(h.accusationIds(i));
            if (closed) continue;
            assertTrue(bond.bondOf(mid) > 0 || bond.slashed(mid), "bond withdrawn from under an open accusation");
        }
    }

    /// An accusation whose window has closed can always be closed by someone. If it cannot, the
    /// accuser's stake is stranded in the contract for ever.
    function invariant_everyExpiredAccusationCanBeClosed() public {
        for (uint256 i = 0; i < h.accusationCount(); i++) {
            uint256 aid = h.accusationIds(i);
            (,,, uint64 deadline,, bool closed,) = judge.accusations(aid);
            if (closed || block.timestamp <= deadline) continue;
            uint256 snap = vm.snapshotState();
            try judge.resolveAccusation(aid) {}
            catch (bytes memory err) {
                revert(string.concat("expired accusation cannot be resolved: ", vm.toString(err)));
            }
            vm.revertToState(snap);
        }
    }
}
