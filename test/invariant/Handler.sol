// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {MandateRegistry} from "../../src/MandateRegistry.sol";
import {AnchorLog} from "../../src/AnchorLog.sol";
import {Bond} from "../../src/Bond.sol";
import {SpendMeter} from "../../src/SpendMeter.sol";
import {Receipts} from "../../src/Receipts.sol";
import {IPayment} from "@flarenetwork/flare-periphery-contracts/coston2/IPayment.sol";
import {IEVMTransaction} from "@flarenetwork/flare-periphery-contracts/coston2/IEVMTransaction.sol";
import {IReferencedPaymentNonexistence} from
    "@flarenetwork/flare-periphery-contracts/coston2/IReferencedPaymentNonexistence.sol";
import {MockProtocolsV2} from "../Rounds.sol";

/// @dev An FDC that believes everything. The handler only ever builds proofs that describe deeds it
///      really simulated, so "the FDC verified it" is true by construction; what the fuzzer explores
///      is the ORDER of calls, which is where every hole this repo has had so far was found.
contract CredulousFdc {
    function verifyEVMTransaction(IEVMTransaction.Proof calldata) external pure returns (bool) {
        return true;
    }

    function verifyPayment(IPayment.Proof calldata) external pure returns (bool) {
        return true;
    }

    function verifyReferencedPaymentNonexistence(IReferencedPaymentNonexistence.Proof calldata)
        external
        pure
        returns (bool)
    {
        return true;
    }
}

/// @title Handler — the only caller the invariant fuzzer is allowed to drive
/// @notice Every public function is one thing a participant can do. Inputs are seeds, bounded onto
///         the actors, mandates and deeds that exist; calls are allowed to revert (a refused call is
///         the protocol working). Ghost state records what SHOULD be true, and `Invariants.t.sol`
///         compares it with what the contracts say after every call.
contract Handler is Test {
    MandateRegistry public reg;
    AnchorLog public anchorLog;
    Bond public bond;
    SpendMeter public meter;
    MockProtocolsV2 public rounds;

    bytes32 constant SRC = bytes32("testFLR");
    address constant MERCHANT = address(0x2222);

    address[] public actors;

    struct Deed {
        uint256 mandateId;
        bytes32 txh;
        uint256 value;
        uint64 ts;
        bool anchored;
        uint256 episode;
    }

    uint256[] public mandates;
    Deed[] public deeds;
    uint256 txCounter = 0x1000;

    // --- ghost state ---
    uint256 public ghostPosted; // every wei that entered as bond
    uint256 public ghostStaked; // every wei that entered as an accusation stake
    uint256 public ghostWithdrawn; // every wei that left through withdraw()
    uint256 public ghostClaimed; // every wei that left through claim()
    mapping(uint256 => uint256) public ghostSlashCount; // successful slashing calls per mandate
    mapping(uint256 => uint256) public ghostBondAtFirstSlash;
    mapping(uint256 => uint256) public ghostSlashedTotal; // wei credited out of a mandate's bond
    mapping(uint256 => bool) public ghostEverDead; // a mandate that was seen dead
    mapping(uint256 => uint256) public ghostPostedTo; // per mandate: in
    mapping(uint256 => uint256) public ghostWithdrawnFrom; // per mandate: out through withdraw()
    bool public withdrewMoreThanDeposited;
    bool public unslashedDepositorShortChanged;
    bool public anchoredUnderDeadMandate;
    bool public deadMandateCameBack;
    bool public claimTwiceSucceeded;
    bool public claimPaidWrongAmount;

    bytes32[] public commitments;
    mapping(bytes32 => uint64) public ghostFirstCommit; // first time a commitment was submitted
    mapping(bytes32 => bool) public ghostConsumed;
    mapping(bytes32 => uint256) public ghostConsumeCount;
    bool public commitmentRefreshed;

    struct Pending {
        uint256 mandateId;
        uint8 kind;
        address challenger;
        bytes32 salt;
        bytes32 commitment;
        uint256 nDeeds; // how many of the mandate's deeds (ascending) the commitment covers
        uint256 deedIndex; // for single-deed kinds
    }

    Pending[] public pendings;
    uint256[] public accusationIds;

    constructor(MandateRegistry r, AnchorLog l, Bond b, SpendMeter m, MockProtocolsV2 p) {
        reg = r;
        anchorLog = l;
        bond = b;
        meter = m;
        rounds = p;
        for (uint256 i = 0; i < 4; i++) {
            address a = address(uint160(0xA11CE000 + i));
            actors.push(a);
            vm.deal(a, 1_000_000 ether);
        }
    }

    // ------------------------------------------------------------------ helpers

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _mandate(uint256 seed) internal view returns (uint256) {
        return mandates[seed % mandates.length];
    }

    function mandateCount() external view returns (uint256) {
        return mandates.length;
    }

    function commitmentCount() external view returns (uint256) {
        return commitments.length;
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function _terms() internal view returns (MandateRegistry.Terms memory) {
        return MandateRegistry.Terms({sourceId: SRC, assetKey: bytes32(0), agentRef: bytes32(0), bond: address(bond)});
    }

    function _sweepLiveness() internal {
        for (uint256 i = 0; i < mandates.length; i++) {
            uint256 id = mandates[i];
            bool live = reg.isLive(id);
            MandateRegistry.Mandate memory m = reg.get(id);
            // "dead" here means dead for good: revoked or past its window. A mandate that has not
            // started yet is not live either, and is allowed to become so.
            bool deadForGood = m.revoked || block.timestamp > m.validUntil;
            if (ghostEverDead[id] && live) deadMandateCameBack = true;
            if (deadForGood) ghostEverDead[id] = true;
        }
    }

    // ------------------------------------------------------------------ mandates

    function commitRoot(uint256 pSeed, uint256 aSeed, uint256 budget, uint64 dur) external {
        if (mandates.length >= 24) return;
        budget = bound(budget, 0, 100 ether);
        dur = uint64(bound(dur, 1 hours, 30 days));
        vm.prank(_actor(pSeed));
        uint256 id = reg.commit(
            _actor(aSeed), keccak256("root"), 0, 0, budget, uint64(block.timestamp), uint64(block.timestamp) + dur, _terms()
        );
        mandates.push(id);
    }

    /// @dev Deliberately NOT clamped to the parent's envelope: most attempts to widen must revert,
    ///      and the invariant checks that none of them ever got through.
    function commitChild(uint256 parentSeed, uint256 aSeed, uint256 budget, uint64 from, uint64 until) external {
        if (mandates.length == 0 || mandates.length >= 24) return;
        uint256 parentId = _mandate(parentSeed);
        MandateRegistry.Mandate memory p = reg.get(parentId);
        budget = bound(budget, 0, p.budget * 2 + 1);
        from = uint64(bound(from, p.validFrom > 1 days ? p.validFrom - 1 days : 0, p.validUntil));
        until = uint64(bound(until, from, uint256(p.validUntil) + 1 days));
        vm.prank(p.agent);
        try reg.commit(_actor(aSeed), keccak256("child"), 0, parentId, budget, from, until, _terms()) returns (uint256 id) {
            mandates.push(id);
        } catch {}
    }

    function acknowledge(uint256 seed) external {
        if (mandates.length == 0) return;
        uint256 id = _mandate(seed);
        vm.prank(reg.get(id).agent);
        try reg.acknowledge(id) {} catch {}
    }

    function declareExclusive(uint256 seed) external {
        if (mandates.length == 0) return;
        uint256 id = _mandate(seed);
        vm.prank(reg.get(id).agent);
        try reg.declareExclusive(id) {} catch {}
    }

    function declareEffector(uint256 seed, uint256 eSeed) external {
        if (mandates.length == 0) return;
        uint256 id = _mandate(seed);
        vm.prank(reg.get(id).principal);
        try meter.declareEffector(id, _actor(eSeed)) {} catch {}
    }

    function revoke(uint256 seed, uint256 whoSeed) external {
        if (mandates.length == 0) return;
        uint256 id = _mandate(seed);
        vm.prank(_actor(whoSeed));
        try reg.revoke(id) {} catch {}
        _sweepLiveness();
    }

    /// @dev Mostly short steps — the interesting windows (commit lead 10 min, TTL 1 h, anchor grace
    ///      1 h, response window and cooling window 24 h) are all missed by a uniformly random jump —
    ///      with an occasional long one to expire mandates and open withdrawals.
    function warp(uint32 dt, uint8 kind) external {
        bool long_ = kind % 8 == 0;
        vm.warp(block.timestamp + (long_ ? bound(dt, 1 hours, 3 days) : bound(dt, 1, 20 minutes)));
        _sweepLiveness();
    }

    /// @notice A whole honest setup in one call, so that sequences start deep instead of spending
    ///         their depth discovering that a bond needs an acknowledged mandate first.
    function scenario(uint256 pSeed, uint256 aSeed, uint256 budget, uint256 amount, bool exclusive_, bool metered_) external {
        if (mandates.length >= 24) return;
        address pr = _actor(pSeed);
        address ag = _actor(aSeed);
        vm.prank(pr);
        uint256 id = reg.commit(
            ag, keccak256("scenario"), 0, 0, bound(budget, 0, 20 ether), uint64(block.timestamp), uint64(block.timestamp + 7 days), _terms()
        );
        mandates.push(id);
        vm.prank(ag);
        if (exclusive_) reg.declareExclusive(id);
        else reg.acknowledge(id);
        if (metered_) {
            vm.prank(pr);
            meter.declareEffector(id, ag);
        }
        amount = bound(amount, 1, 50 ether);
        vm.prank(pr);
        bond.post{value: amount}(id);
        ghostPosted += amount;
        ghostPostedTo[id] += amount;
    }

    // ------------------------------------------------------------------ bond in, bond out

    function post(uint256 seed, uint256 whoSeed, uint256 amount) external {
        if (mandates.length == 0) return;
        uint256 id = _mandate(seed);
        amount = bound(amount, 0, 50 ether);
        vm.prank(_actor(whoSeed));
        try bond.post{value: amount}(id) {
            ghostPosted += amount;
            ghostPostedTo[id] += amount;
        } catch {}
    }

    function withdraw(uint256 seed, uint256 whoSeed) external {
        if (mandates.length == 0) return;
        uint256 id = _mandate(seed);
        _withdraw(id, _actor(whoSeed));
    }

    function _withdraw(uint256 id, address who) internal {
        uint256 dep = bond.depositOf(id, who);
        bool wasSlashed = bond.slashed(id);
        uint256 before = who.balance;
        vm.prank(who);
        try bond.withdraw(id, payable(who)) {
            uint256 got = who.balance - before;
            ghostWithdrawn += got;
            ghostWithdrawnFrom[id] += got;
            nWithdrawals++;
            if (got > dep) withdrewMoreThanDeposited = true;
            if (!wasSlashed && got != dep) unslashedDepositorShortChanged = true;
        } catch {}
    }

    function claim(uint256 whoSeed) external {
        address who = _actor(whoSeed);
        uint256 due = bond.owed(who);
        uint256 before = who.balance;
        vm.prank(who);
        try bond.claim() {
            uint256 got = who.balance - before;
            ghostClaimed += got;
            nClaims++;
            if (got != due || bond.owed(who) != 0) claimPaidWrongAmount = true;
            // the same balance must not be claimable again
            vm.prank(who);
            try bond.claim() {
                claimTwiceSucceeded = true;
            } catch {}
        } catch {}
    }

    // ------------------------------------------------------------------ deeds

    function _leaf(Deed memory d) internal pure returns (Receipts.Leaf memory) {
        return Receipts.Leaf({
            receiptHash: keccak256(abi.encode("receipt", d.txh)),
            kind: Receipts.KIND_EVM_TX,
            sourceId: SRC,
            destinationAddressHash: bytes32(uint256(uint160(MERCHANT))),
            amount: d.value,
            ref: d.txh,
            claimedTimestamp: d.ts,
            mandateId: d.mandateId
        });
    }

    /// @notice The agent does something in the world; with `anchorIt` it also writes it down.
    function deed(uint256 seed, uint256 value, bool anchorIt) external {
        if (mandates.length == 0 || deeds.length >= 64) return;
        uint256 id = _mandate(seed);
        value = bound(value, 0, 40 ether);
        Deed memory d = Deed(id, bytes32(txCounter++), value, uint64(block.timestamp), false, 0);
        if (anchorIt) {
            bool liveBefore = reg.isLive(id);
            vm.prank(reg.get(id).agent);
            try anchorLog.anchor(id, Receipts.hashMem(_leaf(d)), 1) returns (uint256 ep) {
                if (!liveBefore) anchoredUnderDeadMandate = true;
                d.anchored = true;
                d.episode = ep;
            } catch {}
        }
        deeds.push(d);
    }

    function note(uint256 seed, uint256 eSeed, uint256 amount) external {
        if (mandates.length == 0) return;
        vm.prank(_actor(eSeed));
        try meter.note(_mandate(seed), bound(amount, 0, 10 ether)) {} catch {}
    }

    function _proof(Deed memory d, uint64 round) internal view returns (IEVMTransaction.Proof memory p) {
        p.data.sourceId = SRC;
        p.data.votingRound = round;
        p.data.requestBody.transactionHash = d.txh;
        p.data.responseBody.timestamp = d.ts;
        p.data.responseBody.sourceAddress = reg.get(d.mandateId).agent;
        p.data.responseBody.receivingAddress = MERCHANT;
        p.data.responseBody.value = d.value;
        p.data.responseBody.status = 1;
    }

    /// @dev The first `max` deeds of a mandate, in ascending tx-hash order (which is creation order).
    function _deedsOf(uint256 id, bool anchoredOnly, uint256 max) internal view returns (uint256[] memory idx) {
        uint256 n;
        for (uint256 i = 0; i < deeds.length && n < max; i++) {
            if (deeds[i].mandateId == id && (!anchoredOnly || deeds[i].anchored)) n++;
        }
        idx = new uint256[](n);
        uint256 k;
        for (uint256 i = 0; i < deeds.length && k < n; i++) {
            if (deeds[i].mandateId == id && (!anchoredOnly || deeds[i].anchored)) idx[k++] = i;
        }
    }

    // ------------------------------------------------------------------ commit side

    function _commit(bytes32 c, address who) internal {
        uint64 before = bond.committedAt(c);
        vm.prank(who);
        bond.commitChallenge(c);
        uint64 afterTs = bond.committedAt(c);
        if (before != 0 && afterTs != before) commitmentRefreshed = true;
        if (ghostFirstCommit[c] == 0 || ghostConsumed[c]) {
            // first sighting — or a fresh life after being spent, which is a new commitment
            if (ghostFirstCommit[c] == 0) commitments.push(c);
            ghostFirstCommit[c] = afterTs;
            ghostConsumed[c] = false;
        }
    }

    function commitCumulative(uint256 seed, uint256 whoSeed, bool underReported, uint256 nSeed, bytes32 salt) external {
        if (mandates.length == 0 || pendings.length >= 48) return;
        uint256 id = _mandate(seed);
        uint256[] memory idx = _deedsOf(id, !underReported, type(uint256).max);
        if (idx.length == 0) return;
        uint256 n = bound(nSeed, 1, idx.length);
        bytes32[] memory ids = new bytes32[](n);
        for (uint256 i = 0; i < n; i++) ids[i] = deeds[idx[i]].txh;
        uint8 kind = underReported ? bond.KIND_UNDER_REPORTED() : bond.KIND_BUDGET_NATIVE();
        address who = _actor(whoSeed);
        bytes32 c = bond.commitmentFor(who, id, kind, keccak256(abi.encode(ids)), salt);
        _commit(c, who);
        pendings.push(Pending(id, kind, who, salt, c, n, 0));
    }

    function commitAccusation(uint256 deedSeed, uint256 whoSeed, bytes32 salt) external {
        if (deeds.length == 0 || pendings.length >= 48) return;
        uint256 di = deedSeed % deeds.length;
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = deeds[di].txh;
        address who = _actor(whoSeed);
        bytes32 c = bond.commitmentFor(who, deeds[di].mandateId, bond.KIND_UNANCHORED_DEED(), keccak256(abi.encode(ids)), salt);
        _commit(c, who);
        pendings.push(Pending(deeds[di].mandateId, bond.KIND_UNANCHORED_DEED(), who, salt, c, 1, di));
    }

    /// @notice The honest sequence in one call — detect, commit, wait out the lead, reveal — so the
    ///         campaign reaches verdicts often enough for the value invariants to mean something.
    ///         The atomic `commit*` / `reveal` above stay, for every dishonest timing in between.
    function honestChallenge(uint256 seed, uint256 whoSeed, bool underReported, bytes32 salt) external {
        uint256 before = pendings.length;
        this.commitCumulative(seed, whoSeed, underReported, type(uint256).max, salt);
        if (pendings.length == before) return;
        this.reveal(pendings.length - 1, true, uint64(uint256(salt)));
    }

    function honestAccusation(uint256 deedSeed, uint256 whoSeed, bytes32 salt) external {
        uint256 before = pendings.length;
        this.commitAccusation(deedSeed, whoSeed, salt);
        if (pendings.length == before) return;
        this.reveal(pendings.length - 1, true, uint64(uint256(salt)));
    }

    /// @notice An accusation filed in the last hour of the cooling window, then the principal tries
    ///         to leave. The one ordering in which collateral could walk out from under a case.
    function lateAccusationThenWithdraw(uint256 deedSeed, uint256 whoSeed, bytes32 salt) external {
        if (deeds.length == 0) return;
        uint256 id = deeds[deedSeed % deeds.length].mandateId;
        uint64 death = reg.deathTime(id);
        if (death == type(uint64).max) return;
        uint256 target = uint256(death) + 23 hours;
        if (block.timestamp < target) vm.warp(target);
        _sweepLiveness();
        this.honestAccusation(deedSeed, whoSeed, salt);
        vm.warp(block.timestamp + 2 hours);
        _withdraw(id, reg.get(id).principal);
    }

    /// @notice Anyone replays someone else's commitment bytes: must change nothing.
    function replayCommitment(uint256 cSeed, uint256 whoSeed) external {
        if (commitments.length == 0) return;
        _commit(commitments[cSeed % commitments.length], _actor(whoSeed));
    }

    // ------------------------------------------------------------------ reveal side

    function _afterReveal(Pending memory p, bool ok, uint256 bondBefore) internal {
        if (!ok) return;
        ghostConsumed[p.commitment] = true;
        ghostConsumeCount[p.commitment]++;
        _recordSlash(p.mandateId, bondBefore);
    }

    // coverage counters: an invariant that holds because nothing ever happened proves nothing
    uint256 public nSlashes;
    uint256 public nAccusations;
    uint256 public nAnswered;
    uint256 public nResolved;
    uint256 public nWithdrawals;
    uint256 public nClaims;
    uint256 public nRefusedReveals;

    function _recordSlash(uint256 id, uint256 bondBefore) internal {
        uint256 bondAfter = bond.bondOf(id);
        if (bondAfter < bondBefore) {
            nSlashes++;
            if (ghostSlashCount[id] == 0) ghostBondAtFirstSlash[id] = bondBefore;
            ghostSlashCount[id]++;
            ghostSlashedTotal[id] += bondBefore - bondAfter;
        }
        _sweepLiveness();
    }

    /// @param honestTiming false = reveal at once, whatever the lead says (must then be refused)
    function reveal(uint256 pSeed, bool honestTiming, uint64 round) external {
        if (pendings.length == 0) return;
        Pending memory p = pendings[pSeed % pendings.length];
        round = uint64(bound(round, 1, 1_000_000));
        if (honestTiming) {
            uint256 wait = bond.commitLead();
            if (p.kind == bond.KIND_UNANCHORED_DEED()) {
                // an accusation also has to wait out the anchor grace; an honest accuser commits
                // late enough that both fit inside COMMIT_TTL, which the fuzzer will sometimes miss
                uint256 graceEnd = uint256(deeds[p.deedIndex].ts) + bond.anchorGrace();
                if (graceEnd > block.timestamp + wait) wait = graceEnd - block.timestamp;
            }
            vm.warp(block.timestamp + wait);
        }
        rounds.setRoundStart(round, uint64(block.timestamp));
        uint256 bondBefore = bond.bondOf(p.mandateId);

        if (p.kind == bond.KIND_UNANCHORED_DEED()) {
            // Everything that makes an external call is evaluated BEFORE the prank: a getter in the
            // argument list would consume it (the pitfall this repo has already paid for once).
            IEVMTransaction.Proof memory pr = _proof(deeds[p.deedIndex], round);
            uint256 stake = bond.ACCUSATION_STAKE();
            vm.prank(p.challenger);
            try bond.accuseUnanchoredDeed{value: stake}(p.mandateId, pr, p.salt) returns (uint256 aid) {
                ghostStaked += stake;
                accusationIds.push(aid);
                nAccusations++;
                ghostConsumed[p.commitment] = true;
                ghostConsumeCount[p.commitment]++;
            } catch {}
            return;
        }

        bool under = p.kind == bond.KIND_UNDER_REPORTED();
        uint256[] memory idx = _deedsOf(p.mandateId, !under, p.nDeeds);
        uint256 n = idx.length;
        IEVMTransaction.Proof[] memory proofs = new IEVMTransaction.Proof[](n);
        for (uint256 i = 0; i < n; i++) proofs[i] = _proof(deeds[idx[i]], round);

        if (under) {
            vm.prank(p.challenger);
            try bond.challengeUnderReportedSpend(p.mandateId, proofs, p.salt) {
                _afterReveal(p, true, bondBefore);
            } catch {
                nRefusedReveals++;
            }
            return;
        }
        uint256[] memory eps = new uint256[](n);
        Receipts.Leaf[] memory ls = new Receipts.Leaf[](n);
        bytes32[][] memory paths = new bytes32[][](n);
        for (uint256 i = 0; i < n; i++) {
            eps[i] = deeds[idx[i]].episode;
            ls[i] = _leaf(deeds[idx[i]]);
            paths[i] = new bytes32[](0);
        }
        vm.prank(p.challenger);
        try bond.challengeBudgetOverrun(p.mandateId, eps, ls, paths, proofs, p.salt) {
            _afterReveal(p, true, bondBefore);
        } catch {}
    }

    function answer(uint256 aSeed, uint256 whoSeed) external {
        if (accusationIds.length == 0) return;
        uint256 aid = accusationIds[aSeed % accusationIds.length];
        (uint256 mid, bytes32 txh,,,,,) = bond.accusations(aid);
        for (uint256 i = 0; i < deeds.length; i++) {
            if (deeds[i].mandateId == mid && deeds[i].txh == txh && deeds[i].anchored) {
                vm.prank(_actor(whoSeed));
                try bond.answerAccusation(aid, deeds[i].episode, _leaf(deeds[i]), new bytes32[](0)) {
                    nAnswered++;
                } catch {}
                return;
            }
        }
    }

    function resolve(uint256 aSeed, uint256 whoSeed) external {
        if (accusationIds.length == 0) return;
        uint256 aid = accusationIds[aSeed % accusationIds.length];
        (uint256 mid,,,,,,) = bond.accusations(aid);
        uint256 bondBefore = bond.bondOf(mid);
        vm.prank(_actor(whoSeed));
        try bond.resolveAccusation(aid) {
            nResolved++;
            _recordSlash(mid, bondBefore);
        } catch {}
    }

    function accusationCount() external view returns (uint256) {
        return accusationIds.length;
    }
}
