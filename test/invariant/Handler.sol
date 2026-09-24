// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {MandateRegistry} from "../../src/MandateRegistry.sol";
import {AnchorLog} from "../../src/AnchorLog.sol";
import {Vault} from "../../src/Vault.sol";
import {JudgeEvm} from "../../src/JudgeEvm.sol";
import {JudgeXrpl} from "../../src/JudgeXrpl.sol";
import {DelictiErrors} from "../../src/DelictiErrors.sol";
import {Core} from "../Core.sol";
import {SpendMeter} from "../../src/SpendMeter.sol";
import {Receipts} from "../../src/Receipts.sol";
import {IPayment} from "@flarenetwork/flare-periphery-contracts/coston2/IPayment.sol";
import {IEVMTransaction} from "@flarenetwork/flare-periphery-contracts/coston2/IEVMTransaction.sol";
import {IBalanceDecreasingTransaction} from
    "@flarenetwork/flare-periphery-contracts/coston2/IBalanceDecreasingTransaction.sol";
import {AgentRefs} from "../../src/AgentRefs.sol";
import {Kinds} from "../../src/Kinds.sol";
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

    function verifyBalanceDecreasingTransaction(IBalanceDecreasingTransaction.Proof calldata)
        external
        pure
        returns (bool)
    {
        return true;
    }
}

/// @dev FdcHub stand-in: takes the fee, keeps it. Etched with `FlareRegistryStub` at Flare's
///      ContractRegistry address so `Vault.requestAttestation` has somewhere to forward to.
contract FdcHubStub {
    function requestAttestation(bytes calldata) external payable {}
}

contract FlareRegistryStub {
    address public hub; // storage slot 0, set by the test with vm.store

    function getContractAddressByName(string calldata name) external view returns (address) {
        return keccak256(bytes(name)) == keccak256("FdcHub") ? hub : address(0);
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
    Vault public bond;
    JudgeEvm public judge;
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

    constructor(MandateRegistry r, AnchorLog l, Vault b, JudgeEvm j, SpendMeter m, MockProtocolsV2 p, JudgeXrpl x, AgentRefs refs) {
        xjudge = x;
        agentRefs = refs;
        reg = r;
        judge = j;
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

    /// v0.12: an outsider naming whom its deposit compensates — another actor, possibly the principal.
    function postFor(uint256 seed, uint256 whoSeed, uint256 benSeed, uint256 amount) external {
        if (mandates.length == 0) return;
        uint256 id = _mandate(seed);
        amount = bound(amount, 1, 50 ether);
        vm.prank(_actor(whoSeed));
        try bond.postFor{value: amount}(id, _actor(benSeed)) {
            ghostPosted += amount;
            ghostPostedTo[id] += amount;
        } catch {}
    }

    /// v0.12: anyone may credit a deposit's accrued remainder to its beneficiary.
    function settle(uint256 seed, uint256 whoSeed) external {
        if (mandates.length == 0) return;
        bond.settle(_mandate(seed), _actor(whoSeed));
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
                uint256 graceEnd = uint256(deeds[p.deedIndex].ts) + judge.anchorGrace();
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
            try judge.accuseUnanchoredDeed{value: stake}(p.mandateId, pr, p.salt) returns (uint256 aid) {
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
            try judge.challengeUnderReportedSpend(p.mandateId, proofs, p.salt) {
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
        try judge.challengeBudgetOverrun(p.mandateId, eps, ls, paths, proofs, p.salt) {
            _afterReveal(p, true, bondBefore);
        } catch {}
    }

    function answer(uint256 aSeed, uint256 whoSeed) external {
        if (accusationIds.length == 0) return;
        uint256 aid = accusationIds[aSeed % accusationIds.length];
        (uint256 mid, bytes32 txh,,,,,) = judge.accusations(aid);
        for (uint256 i = 0; i < deeds.length; i++) {
            if (deeds[i].mandateId == mid && deeds[i].txh == txh && deeds[i].anchored) {
                vm.prank(_actor(whoSeed));
                try judge.answerAccusation(aid, deeds[i].episode, _leaf(deeds[i]), new bytes32[](0)) {
                    nAnswered++;
                } catch {}
                return;
            }
        }
    }

    function resolve(uint256 aSeed, uint256 whoSeed) external {
        if (accusationIds.length == 0) return;
        uint256 aid = accusationIds[aSeed % accusationIds.length];
        (uint256 mid,,,,,,) = judge.accusations(aid);
        uint256 bondBefore = bond.bondOf(mid);
        vm.prank(_actor(whoSeed));
        try judge.resolveAccusation(aid) {
            nResolved++;
            _recordSlash(mid, bondBefore);
        } catch {}
    }

    function accusationCount() external view returns (uint256) {
        return accusationIds.length;
    }

    // ------------------------------------------------------------------ XRPL: §6.10 on a docket
    //
    // v0.12 put two judges behind one Vault. Until now the campaign only ever drove JudgeEvm, so
    // every value invariant held over a Vault that one judge had touched. This track drives
    // JudgeXrpl's docket — filings that only record, filings that cross, filings that repeat or
    // straddle what is already filed — on the SAME Vault, interleaved with everything above.

    JudgeXrpl public xjudge;
    AgentRefs public agentRefs;
    bytes32 constant XSRC = bytes32("testXRP");

    struct XTx {
        uint256 mandateId;
        bytes32 txid;
        int256 spent; // negative = XRP came in
        uint64 ts;
    }

    XTx[] public xtxs;
    uint256 xCounter = 0x5000;
    uint256[] public xMandates;

    uint256 public nFilings; // filings that landed (recording or crossing)
    uint256 public nOutflowVerdicts; // crossings that took something
    bool public docketCountedOutOfWindow;
    bool public refilingChangedTheDocket;


    function xrplTxCount() external view returns (uint256) {
        return xtxs.length;
    }

    function xMandateCount() external view returns (uint256) {
        return xMandates.length;
    }

    function _xref(address agent) internal pure returns (bytes32) {
        return keccak256(abi.encode("xrpl account of", agent));
    }

    /// An outflow mandate, acknowledged, made exclusive with the XRPL key, bonded by the principal.
    function xrplScenario(uint256 pSeed, uint256 aSeed, uint256 budget, uint256 amount, uint64 dur) external {
        if (mandates.length >= 24) return;
        address pr = _actor(pSeed);
        address ag = _actor(aSeed);
        vm.prank(pr);
        uint256 id = reg.commit(
            ag, keccak256("outflow"), 0, 0, bound(budget, 0, 50_000_000), uint64(block.timestamp),
            uint64(block.timestamp + bound(dur, 1 hours, 30 days)),
            MandateRegistry.Terms({sourceId: XSRC, assetKey: Kinds.XRP_OUTFLOW_KEY, agentRef: _xref(ag), bond: address(bond)})
        );
        mandates.push(id);
        xMandates.push(id);
        vm.prank(ag);
        reg.acknowledge(id);
        IPayment.Proof memory st;
        st.data.sourceId = XSRC;
        st.data.requestBody.transactionId = keccak256(abi.encode("statement", id));
        st.data.responseBody.sourceAddressHash = _xref(ag);
        st.data.responseBody.standardPaymentReference = agentRefs.exclusiveFor(id);
        agentRefs.proveExclusive(id, st);
        amount = bound(amount, 1, 50 ether);
        vm.prank(pr);
        bond.post{value: amount}(id);
        ghostPosted += amount;
        ghostPostedTo[id] += amount;
    }

    /// Something moves the account's balance: a payment, a fee, an offer eaten, or XRP coming in.
    /// Sometimes a little outside the window, which the docket must never count.
    function xrplMove(uint256 seed, int256 spent, int32 skew) external {
        if (xMandates.length == 0 || xtxs.length >= 96) return;
        uint256 id = xMandates[seed % xMandates.length];
        spent = bound(spent, -5_000_000, 20_000_000);
        int256 ts = int256(block.timestamp) + int256(bound(int256(skew), -2 hours, 2 hours));
        xtxs.push(XTx(id, bytes32(xCounter++), spent, uint64(uint256(ts))));
    }

    function _bdt(XTx memory t, uint64 round) internal view returns (IBalanceDecreasingTransaction.Proof memory p) {
        bytes32 ref = reg.get(t.mandateId).agentRef;
        p.data.attestationType = bytes32("BalanceDecreasingTransaction"); // the stipend key needs it
        p.data.sourceId = XSRC;
        p.data.votingRound = round;
        p.data.requestBody.transactionId = t.txid;
        p.data.requestBody.sourceAddressIndicator = ref;
        p.data.responseBody.blockTimestamp = t.ts;
        p.data.responseBody.sourceAddressHash = ref;
        p.data.responseBody.spentAmount = t.spent;
    }

    /// @notice File a run of the mandate's moves (ascending, from `startSeed`, `nSeed` of them —
    ///         overlapping earlier filings is the point). With `committed` the filer commits first
    ///         and waits out the lead, as an honest crossing filer does; without, only a filing that
    ///         stays below the budget can land.
    function fileOutflow(uint256 seed, uint256 whoSeed, uint256 startSeed, uint256 nSeed, bool committed, bytes32 salt)
        external
    {
        if (xMandates.length == 0) return;
        uint256 id = xMandates[seed % xMandates.length];
        uint256 total;
        for (uint256 i = 0; i < xtxs.length; i++) if (xtxs[i].mandateId == id) total++;
        if (total == 0) return;
        uint256 start = startSeed % total;
        uint256 n = bound(nSeed, 1, total - start);
        XTx[] memory run = new XTx[](n);
        uint256 k;
        uint256 j;
        for (uint256 i = 0; i < xtxs.length && k < n; i++) {
            if (xtxs[i].mandateId != id) continue;
            if (j++ >= start) run[k++] = xtxs[i];
        }
        address who = _actor(whoSeed);
        if (committed) {
            bytes32[] memory ids = new bytes32[](n);
            for (uint256 i = 0; i < n; i++) ids[i] = run[i].txid;
            bytes32 c = bond.commitmentFor(who, id, Kinds.XRP_OUTFLOW, keccak256(abi.encode(ids)), salt);
            _commit(c, who);
            vm.warp(block.timestamp + bond.commitLead());
            _sweepLiveness();
        }
        uint64 round = uint64(bound(uint256(salt), 1, 1_000_000));
        rounds.setRoundStart(round, uint64(block.timestamp));
        IBalanceDecreasingTransaction.Proof[] memory proofs = new IBalanceDecreasingTransaction.Proof[](n);
        for (uint256 i = 0; i < n; i++) proofs[i] = _bdt(run[i], round);

        uint256 docketBefore = xjudge.docket(id);
        uint256 expectAdded;
        for (uint256 i = 0; i < n; i++) {
            if (!xjudge.filed(id, run[i].txid) && run[i].spent > 0) expectAdded += uint256(run[i].spent);
        }
        uint256 bondBefore = bond.bondOf(id);
        vm.prank(who);
        try xjudge.fileXrpOutflow(id, proofs, salt) {
            nFilings++;
            if (xjudge.docket(id) != docketBefore + expectAdded) refilingChangedTheDocket = true;
            uint256 slashesBefore = nSlashes;
            _recordSlash(id, bondBefore);
            if (nSlashes > slashesBefore) nOutflowVerdicts++;
            if (committed) {
                // the committed filing may have been a mere recording; spent or not, the ghost follows the Vault
                bytes32[] memory ids = new bytes32[](n);
                for (uint256 i = 0; i < n; i++) ids[i] = run[i].txid;
                bytes32 c = bond.commitmentFor(who, id, Kinds.XRP_OUTFLOW, keccak256(abi.encode(ids)), salt);
                if (bond.committedAt(c) == 0 && !ghostConsumed[c]) {
                    ghostConsumed[c] = true;
                    ghostConsumeCount[c]++;
                }
            }
        } catch {}
        _checkWindow(id, run);
    }

    function _checkWindow(uint256 id, XTx[] memory run) internal {
        MandateRegistry.Mandate memory m = reg.get(id);
        for (uint256 i = 0; i < run.length; i++) {
            if (xjudge.filed(id, run[i].txid) && (run[i].ts < m.validFrom || run[i].ts > m.validUntil)) {
                docketCountedOutOfWindow = true;
            }
        }
    }

    /// @notice The honest watcher in one call: everything the account did, committed and filed —
    ///         so crossings happen often enough for the Vault invariants to see XRPL verdicts.
    function honestOutflow(uint256 seed, uint256 whoSeed, bytes32 salt) external {
        this.fileOutflow(seed, whoSeed, 0, type(uint256).max, true, salt);
    }

    // ------------------------------------------------------------------ EVM: §6.11 ERC-20 docket
    //
    // The token outflow docket, keyed per event. Moves are transactions sent by a facilitator with
    // one to three Transfer logs out of the agent; filings list all of a transaction's logs or a
    // subset (the FDC allows it), overlap earlier filings, and cross the budget committed or not.

    address constant TOKEN = address(0x5DC0);

    struct TEv {
        uint256 mandateId;
        bytes32 txh;
        uint32 logIndex;
        uint256 value;
        uint64 ts;
    }

    TEv[] public tevs;
    uint256[] public tMandates;
    uint256 tCounter = 0x9000;
    uint32 logCounter;
    uint256 public nTokenFilings;
    uint256 public nTokenVerdicts;
    bool public tokenDocketDrifted;

    function tokenEventCount() external view returns (uint256) {
        return tevs.length;
    }

    function tMandateCount() external view returns (uint256) {
        return tMandates.length;
    }

    function tokenScenario(uint256 pSeed, uint256 aSeed, uint256 budget, uint256 amount) external {
        if (mandates.length >= 24) return;
        address pr = _actor(pSeed);
        address ag = _actor(aSeed);
        vm.prank(pr);
        uint256 id = reg.commit(
            ag, keccak256("usdc"), 0, 0, bound(budget, 0, 50_000_000), uint64(block.timestamp), uint64(block.timestamp + 7 days),
            MandateRegistry.Terms({sourceId: SRC, assetKey: bytes32(uint256(uint160(TOKEN))), agentRef: bytes32(0), bond: address(bond)})
        );
        mandates.push(id);
        tMandates.push(id);
        vm.prank(ag);
        reg.declareExclusive(id);
        amount = bound(amount, 1, 50 ether);
        vm.prank(pr);
        bond.post{value: amount}(id);
        ghostPosted += amount;
        ghostPostedTo[id] += amount;
    }

    function tokenMove(uint256 seed, uint256 v, uint8 nLogs) external {
        if (tMandates.length == 0 || tevs.length >= 120) return;
        uint256 id = tMandates[seed % tMandates.length];
        bytes32 txh = bytes32(tCounter++);
        uint256 k = bound(nLogs, 1, 3);
        for (uint256 j = 0; j < k; j++) {
            tevs.push(TEv(id, txh, logCounter++, bound(v, 0, 2_000_000), uint64(block.timestamp)));
        }
    }

    function _tokenProof(uint256 id, bytes32 txh, uint256 mask, uint64 round) internal view returns (IEVMTransaction.Proof memory p) {
        // collect the listed logs of this transaction (bit j of mask = list the j-th log)
        IEVMTransaction.Event[] memory tmp = new IEVMTransaction.Event[](3);
        uint256 n;
        uint256 j;
        uint64 ts;
        for (uint256 i = 0; i < tevs.length; i++) {
            if (tevs[i].txh != txh) continue;
            ts = tevs[i].ts;
            if ((mask >> j++) & 1 == 0) continue;
            IEVMTransaction.Event memory e;
            e.logIndex = tevs[i].logIndex;
            e.emitterAddress = TOKEN;
            e.topics = new bytes32[](3);
            e.topics[0] = keccak256("Transfer(address,address,uint256)");
            e.topics[1] = bytes32(uint256(uint160(reg.get(id).agent)));
            e.topics[2] = bytes32(uint256(uint160(MERCHANT)));
            e.data = abi.encode(tevs[i].value);
            tmp[n++] = e;
        }
        IEVMTransaction.Event[] memory evs = new IEVMTransaction.Event[](n);
        for (uint256 i = 0; i < n; i++) evs[i] = tmp[i];
        p.data.attestationType = bytes32("EVMTransaction");
        p.data.sourceId = SRC;
        p.data.votingRound = round;
        p.data.requestBody.transactionHash = txh;
        p.data.requestBody.requiredConfirmations = 1;
        p.data.requestBody.listEvents = true;
        p.data.responseBody.timestamp = ts;
        p.data.responseBody.status = 1;
        p.data.responseBody.events = evs;
    }

    /// File a run of the mandate's transactions, each with all or some of its logs listed.
    function fileTokens(uint256 seed, uint256 whoSeed, uint256 startSeed, uint256 nSeed, uint256 mask, bool committed, bytes32 salt)
        external
    {
        if (tMandates.length == 0) return;
        uint256 id = tMandates[seed % tMandates.length];
        // distinct transactions of this mandate, in creation (= ascending hash) order
        bytes32[] memory txs = new bytes32[](tevs.length);
        uint256 total;
        for (uint256 i = 0; i < tevs.length; i++) {
            if (tevs[i].mandateId != id) continue;
            if (total == 0 || txs[total - 1] != tevs[i].txh) txs[total++] = tevs[i].txh;
        }
        if (total == 0) return;
        uint256 start = startSeed % total;
        uint256 n = bound(nSeed, 1, total - start);
        bytes32[] memory ids = new bytes32[](n);
        for (uint256 i = 0; i < n; i++) ids[i] = txs[start + i];
        address who = _actor(whoSeed);
        if (committed) {
            _commit(bond.commitmentFor(who, id, Kinds.ERC20_OUTFLOW, keccak256(abi.encode(ids)), salt), who);
            vm.warp(block.timestamp + bond.commitLead());
            _sweepLiveness();
        }
        uint64 round = uint64(bound(uint256(salt), 1, 1_000_000));
        rounds.setRoundStart(round, uint64(block.timestamp));
        IEVMTransaction.Proof[] memory proofs = new IEVMTransaction.Proof[](n);
        for (uint256 i = 0; i < n; i++) {
            proofs[i] = _tokenProof(id, ids[i], committed ? 7 : uint256(keccak256(abi.encode(mask, i))) | 1, round);
        }
        uint256 bondBefore = bond.bondOf(id);
        vm.prank(who);
        try judge.fileErc20Outflow(id, proofs, salt) {
            nTokenFilings++;
            uint256 slashesBefore = nSlashes;
            _recordSlash(id, bondBefore);
            if (nSlashes > slashesBefore) nTokenVerdicts++;
            if (committed) {
                bytes32 c = bond.commitmentFor(who, id, Kinds.ERC20_OUTFLOW, keccak256(abi.encode(ids)), salt);
                if (bond.committedAt(c) == 0 && !ghostConsumed[c]) {
                    ghostConsumed[c] = true;
                    ghostConsumeCount[c]++;
                }
            }
        } catch {}
    }

    // ------------------------------------------------------------------ XRPL: §6.8 receipted payments
    //
    // The last path to the Vault the campaign did not drive. Receipted XRP payments, kind 3 (named
    // by memo) and kind 4 (named by transaction id), anchored or not, judged two ways over the same
    // mandate: the one-shot `challengeBudgetOverrunPayment` and the `fileBudgetPayments` docket,
    // both kind 6, nested. Filings overlap, repeat, and cross committed or not.

    struct PDeed {
        uint256 mandateId;
        bytes32 txid;
        uint256 amount;
        uint64 ts;
        bool kind4;
        bool anchored;
        uint256 episode;
    }

    PDeed[] public pdeeds;
    uint256[] public pMandates;
    uint256 pCounter = 0xD000;
    uint256 public nPaymentFilings;
    uint256 public nPaymentVerdicts;
    uint256 public nOneShotVerdicts;
    bool public paymentDocketDrifted;

    function pDeedCount() external view returns (uint256) {
        return pdeeds.length;
    }

    function pMandateCount() external view returns (uint256) {
        return pMandates.length;
    }

    function payScenario(uint256 pSeed, uint256 aSeed, uint256 budget, uint256 amount) external {
        if (mandates.length >= 24) return;
        address pr = _actor(pSeed);
        address ag = _actor(aSeed);
        vm.prank(pr);
        uint256 id = reg.commit(
            ag, keccak256("xrp payments"), 0, 0, bound(budget, 0, 30_000_000), uint64(block.timestamp), uint64(block.timestamp + 7 days),
            MandateRegistry.Terms({sourceId: XSRC, assetKey: bytes32(0), agentRef: _xref(ag), bond: address(bond)})
        );
        mandates.push(id);
        pMandates.push(id);
        vm.prank(ag);
        reg.acknowledge(id);
        IPayment.Proof memory st; // the XRPL account accepts the mandate with a memo (§6.8)
        st.data.sourceId = XSRC;
        st.data.requestBody.transactionId = keccak256(abi.encode("acceptance", id));
        st.data.responseBody.sourceAddressHash = _xref(ag);
        st.data.responseBody.standardPaymentReference = agentRefs.challengeFor(id);
        agentRefs.prove(id, st);
        amount = bound(amount, 1, 50 ether);
        vm.prank(pr);
        bond.post{value: amount}(id);
        ghostPosted += amount;
        ghostPostedTo[id] += amount;
    }

    function _pleaf(PDeed memory d) internal pure returns (Receipts.Leaf memory) {
        return Receipts.Leaf({
            receiptHash: keccak256(abi.encode("xrpl receipt", d.txid)),
            kind: d.kind4 ? Receipts.KIND_EXTERNAL_TX : Receipts.KIND_EXTERNAL_PAYMENT,
            sourceId: XSRC,
            destinationAddressHash: keccak256("rMerchant"),
            amount: d.amount,
            // kind 4 names the payment by its transaction id; kind 3 by the memo reference, which
            // this simulation derives from the id so each receipt names exactly one payment
            ref: d.kind4 ? d.txid : keccak256(abi.encode("memo", d.txid)),
            claimedTimestamp: d.ts,
            mandateId: d.mandateId
        });
    }

    /// The agent pays on XRPL and (with `anchorIt`) writes the receipt down.
    function payDeed(uint256 seed, uint256 amount, bool kind4, bool anchorIt) external {
        if (pMandates.length == 0 || pdeeds.length >= 80) return;
        uint256 id = pMandates[seed % pMandates.length];
        PDeed memory d = PDeed(id, bytes32(pCounter++), bound(amount, 1, 12_000_000), uint64(block.timestamp), kind4, false, 0);
        if (anchorIt) {
            vm.prank(reg.get(id).agent);
            try anchorLog.anchor(id, Receipts.hashMem(_pleaf(d)), 1) returns (uint256 ep) {
                d.anchored = true;
                d.episode = ep;
            } catch {}
        }
        pdeeds.push(d);
    }

    function _payment(PDeed memory d, uint64 round) internal view returns (IPayment.Proof memory p) {
        p.data.attestationType = bytes32("Payment");
        p.data.sourceId = XSRC;
        p.data.votingRound = round;
        p.data.requestBody.transactionId = d.txid;
        p.data.responseBody.blockTimestamp = d.ts;
        p.data.responseBody.sourceAddressHash = reg.get(d.mandateId).agentRef;
        p.data.responseBody.receivingAddressHash = keccak256("rMerchant");
        p.data.responseBody.receivedAmount = int256(d.amount);
        p.data.responseBody.spentAmount = int256(d.amount + 12);
        p.data.responseBody.standardPaymentReference = d.kind4 ? bytes32(0) : keccak256(abi.encode("memo", d.txid));
        p.data.responseBody.oneToOne = true;
    }

    /// Anchored deeds of a mandate, in creation (= ascending id) order, from `start`, `n` of them.
    function _prun(uint256 id, uint256 start, uint256 n) internal view returns (PDeed[] memory run) {
        uint256 total;
        for (uint256 i = 0; i < pdeeds.length; i++) if (pdeeds[i].mandateId == id && pdeeds[i].anchored) total++;
        if (total == 0) return new PDeed[](0);
        start = start % total;
        n = n > total - start ? total - start : n;
        run = new PDeed[](n);
        uint256 j;
        uint256 k;
        for (uint256 i = 0; i < pdeeds.length && k < n; i++) {
            if (pdeeds[i].mandateId != id || !pdeeds[i].anchored) continue;
            if (j++ >= start) run[k++] = pdeeds[i];
        }
    }

    function _pArgs(PDeed[] memory run, uint64 round)
        internal
        view
        returns (uint256[] memory eps, Receipts.Leaf[] memory ls, bytes32[][] memory paths, IPayment.Proof[] memory prs, bytes32[] memory ids)
    {
        uint256 n = run.length;
        eps = new uint256[](n);
        ls = new Receipts.Leaf[](n);
        paths = new bytes32[][](n);
        prs = new IPayment.Proof[](n);
        ids = new bytes32[](n);
        for (uint256 i = 0; i < n; i++) {
            eps[i] = run[i].episode;
            ls[i] = _pleaf(run[i]);
            paths[i] = new bytes32[](0);
            prs[i] = _payment(run[i], round);
            ids[i] = run[i].txid;
        }
    }

    function _pCommit(uint256 id, address who, bytes32[] memory ids, bytes32 salt) internal {
        _commit(bond.commitmentFor(who, id, Kinds.BUDGET_PAYMENT, keccak256(abi.encode(ids)), salt), who);
        vm.warp(block.timestamp + bond.commitLead());
        _sweepLiveness();
    }

    function _pSpent(uint256 id, address who, bytes32[] memory ids, bytes32 salt) internal {
        bytes32 c = bond.commitmentFor(who, id, Kinds.BUDGET_PAYMENT, keccak256(abi.encode(ids)), salt);
        if (bond.committedAt(c) == 0 && ghostFirstCommit[c] != 0 && !ghostConsumed[c]) {
            ghostConsumed[c] = true;
            ghostConsumeCount[c]++;
        }
    }

    /// The docket path: a run of anchored receipted payments, committed or not.
    function filePayments(uint256 seed, uint256 whoSeed, uint256 startSeed, uint256 nSeed, bool committed, bytes32 salt) external {
        if (pMandates.length == 0) return;
        uint256 id = pMandates[seed % pMandates.length];
        PDeed[] memory run = _prun(id, startSeed, bound(nSeed, 1, 16));
        if (run.length == 0) return;
        uint64 round = uint64(bound(uint256(salt), 1, 1_000_000));
        (uint256[] memory eps, Receipts.Leaf[] memory ls, bytes32[][] memory paths, IPayment.Proof[] memory prs, bytes32[] memory ids) =
            _pArgs(run, round);
        address who = _actor(whoSeed);
        if (committed) _pCommit(id, who, ids, salt);
        rounds.setRoundStart(round, uint64(block.timestamp));
        uint256 expect = xjudge.paymentDocket(id);
        for (uint256 i = 0; i < run.length; i++) if (!xjudge.paymentFiled(id, run[i].txid)) expect += run[i].amount;
        uint256 bondBefore = bond.bondOf(id);
        vm.prank(who);
        try xjudge.fileBudgetPayments(id, eps, ls, paths, prs, salt) {
            nPaymentFilings++;
            if (xjudge.paymentDocket(id) != expect) paymentDocketDrifted = true;
            uint256 before = nSlashes;
            _recordSlash(id, bondBefore);
            if (nSlashes > before) nPaymentVerdicts++;
            if (committed) _pSpent(id, who, ids, salt);
        } catch {}
    }

    /// The one-shot path over the same deeds: everything anchored, committed, in one challenge.
    function oneShotPayments(uint256 seed, uint256 whoSeed, bytes32 salt) external {
        if (pMandates.length == 0) return;
        uint256 id = pMandates[seed % pMandates.length];
        PDeed[] memory run = _prun(id, 0, 16);
        if (run.length == 0) return;
        uint64 round = uint64(bound(uint256(salt), 1, 1_000_000));
        (uint256[] memory eps, Receipts.Leaf[] memory ls, bytes32[][] memory paths, IPayment.Proof[] memory prs, bytes32[] memory ids) =
            _pArgs(run, round);
        address who = _actor(whoSeed);
        _pCommit(id, who, ids, salt);
        rounds.setRoundStart(round, uint64(block.timestamp));
        uint256 bondBefore = bond.bondOf(id);
        vm.prank(who);
        try xjudge.challengeBudgetOverrunPayment(id, eps, ls, paths, prs, salt) {
            uint256 before = nSlashes;
            _recordSlash(id, bondBefore);
            if (nSlashes > before) nOneShotVerdicts++;
            _pSpent(id, who, ids, salt);
        } catch {}
    }

    /// The honest docket keeper in one call: every anchored payment, committed.
    function honestPaymentDocket(uint256 seed, uint256 whoSeed, bytes32 salt) external {
        this.filePayments(seed, whoSeed, 0, 16, true, salt);
    }

    // ------------------------------------------------------------------ the watch pool (v0.14/v0.15)

    uint256 public ghostWatchFunded;
    uint256 public ghostWatchRefunded;
    bool public refundExceededFunding;
    uint256 public nRefunds;
    mapping(uint256 => uint256) public ghostFundedTo;

    function watchTerms(uint256 seed, uint256 rate, uint256 minV) external {
        if (mandates.length == 0) return;
        uint256 id = _mandate(seed);
        vm.prank(reg.get(id).principal);
        try bond.setWatchTerms(id, bound(rate, 0, 1 ether), bound(minV, 0, 3_000_000)) {} catch {}
    }

    /// The principal funds (allowed); the agent or an outsider tries (refused since v0.15).
    function fundWatch(uint256 seed, uint256 whoSeed, uint256 amount) external {
        if (mandates.length == 0) return;
        uint256 id = _mandate(seed);
        amount = bound(amount, 0, 5 ether);
        MandateRegistry.Mandate memory m = reg.get(id);
        address who = whoSeed % 3 == 0 ? m.principal : whoSeed % 3 == 1 ? m.agent : _actor(whoSeed / 3);
        vm.prank(who);
        try bond.fundWatch{value: amount}(id) {
            ghostWatchFunded += amount;
            ghostFundedTo[id] += amount;
            if (who != m.principal) refundExceededFunding = true; // nobody else may fund
        } catch {}
    }

    function refundWatch(uint256 seed, uint256 whoSeed) external {
        if (mandates.length == 0) return;
        uint256 id = _mandate(seed);
        MandateRegistry.Mandate memory m = reg.get(id);
        address who = whoSeed % 2 == 0 ? m.principal : m.agent;
        uint256 before = who.balance;
        vm.prank(who);
        try bond.refundWatch(id, payable(who)) {
            uint256 got = who.balance - before;
            ghostWatchRefunded += got;
            nRefunds++;
            if (got > ghostFundedTo[id] || who != m.principal) refundExceededFunding = true;
        } catch {}
    }

    // ------------------------------------------------------------------ paying for attestations (v0.15)
    //
    // Stipends go to whoever paid for a deed's attestation through `Vault.requestAttestation`, keyed
    // by (type, source, request body). These build the exact request bytes the verifier would, so
    // the key the Vault records is the key the judge rebuilds from the handler's proofs.

    mapping(bytes32 => address) public ghostRequester;

    function _request(bytes32 aType, bytes32 source, bytes memory body, address who) internal {
        bytes memory req = abi.encodePacked(aType, source, bytes32(uint256(0xC0DE)), body);
        vm.deal(who, who.balance + 1);
        vm.prank(who);
        bytes32 key = bond.requestAttestation{value: 1}(req);
        if (ghostRequester[key] == address(0)) ghostRequester[key] = who;
    }

    /// Someone pays for the attestation of a token move, an XRPL move, or an XRPL payment.
    function requestFor(uint256 which, uint256 seed, uint256 whoSeed) external {
        address who = _actor(whoSeed);
        uint256 k = which % 3;
        if (k == 0 && tevs.length != 0) {
            TEv memory t = tevs[seed % tevs.length];
            IEVMTransaction.RequestBody memory b;
            b.transactionHash = t.txh;
            b.requiredConfirmations = 1;
            b.listEvents = true;
            _request(bytes32("EVMTransaction"), SRC, abi.encode(b), who);
        } else if (k == 1 && xtxs.length != 0) {
            XTx memory t = xtxs[seed % xtxs.length];
            IBalanceDecreasingTransaction.RequestBody memory b =
                IBalanceDecreasingTransaction.RequestBody({transactionId: t.txid, sourceAddressIndicator: reg.get(t.mandateId).agentRef});
            _request(bytes32("BalanceDecreasingTransaction"), XSRC, abi.encode(b), who);
        } else if (k == 2 && pdeeds.length != 0) {
            PDeed memory d = pdeeds[seed % pdeeds.length];
            IPayment.RequestBody memory b = IPayment.RequestBody({transactionId: d.txid, inUtxo: 0, utxo: 0});
            _request(bytes32("Payment"), XSRC, abi.encode(b), who);
        }
    }

    /// The paid watcher in one call: the principal offers terms and funds a pool, a watcher pays for
    /// every attestation of a mandate's moves through the Vault, and files them all.
    function paidWatch(uint256 seed, uint256 whoSeed, bool xrpl, bytes32 salt) external {
        uint256 id;
        if (xrpl) {
            if (xMandates.length == 0) return;
            id = xMandates[seed % xMandates.length];
        } else {
            if (tMandates.length == 0) return;
            id = tMandates[seed % tMandates.length];
        }
        MandateRegistry.Mandate memory m = reg.get(id);
        vm.startPrank(m.principal);
        try bond.setWatchTerms(id, 0.01 ether, 0) {} catch {}
        try bond.fundWatch{value: 1 ether}(id) {
            ghostWatchFunded += 1 ether;
            ghostFundedTo[id] += 1 ether;
        } catch {}
        vm.stopPrank();
        address who = _actor(whoSeed);
        if (xrpl) {
            for (uint256 i = 0; i < xtxs.length; i++) {
                if (xtxs[i].mandateId != id) continue;
                IBalanceDecreasingTransaction.RequestBody memory b =
                    IBalanceDecreasingTransaction.RequestBody({transactionId: xtxs[i].txid, sourceAddressIndicator: m.agentRef});
                _request(bytes32("BalanceDecreasingTransaction"), XSRC, abi.encode(b), who);
            }
            this.fileOutflow(seed, whoSeed, 0, type(uint256).max, true, salt);
        } else {
            bytes32 last;
            for (uint256 i = 0; i < tevs.length; i++) {
                if (tevs[i].mandateId != id || tevs[i].txh == last) continue;
                last = tevs[i].txh;
                IEVMTransaction.RequestBody memory b;
                b.transactionHash = tevs[i].txh;
                b.requiredConfirmations = 1;
                b.listEvents = true;
                _request(bytes32("EVMTransaction"), SRC, abi.encode(b), who);
            }
            this.fileTokens(seed, whoSeed, 0, type(uint256).max, 7, true, salt);
        }
    }
}
