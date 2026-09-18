// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {MandateRegistry} from "../src/MandateRegistry.sol";
import {AnchorLog} from "../src/AnchorLog.sol";
import {Bond} from "../src/Bond.sol";
import {SpendMeter} from "../src/SpendMeter.sol";
import {Receipts} from "../src/Receipts.sol";
import {IFdcVerification} from "@flarenetwork/flare-periphery-contracts/coston2/IFdcVerification.sol";
import {IReferencedPaymentNonexistence} from
    "@flarenetwork/flare-periphery-contracts/coston2/IReferencedPaymentNonexistence.sol";
import {ProtocolsV2Interface} from "@flarenetwork/flare-periphery-contracts/coston2/ProtocolsV2Interface.sol";
import {MockProtocolsV2} from "./Rounds.sol";

/// @dev Stand-in for Flare's FdcVerification: returns a configurable verdict.
///      On Coston2 the real one checks the proof against the Relay Merkle root.
contract MockFdc {
    bool public verdict = true;

    function setVerdict(bool v) external {
        verdict = v;
    }

    function verifyReferencedPaymentNonexistence(IReferencedPaymentNonexistence.Proof calldata)
        external
        view
        returns (bool)
    {
        return verdict;
    }
}

contract BondTest is Test {
    MandateRegistry reg;
    AnchorLog anchorLog;
    Bond bond;
    SpendMeter meter;
    MockFdc mock;
    MockProtocolsV2 rounds;

    address principal = makeAddr("principal");
    address agent = makeAddr("agent");
    address challenger = makeAddr("challenger");
    address payable victim = payable(makeAddr("victim"));

    bytes32 constant SRC_TESTXRP = bytes32("testXRP");
    bytes32 constant DEST = keccak256("rDestinationAddress");
    bytes32 constant REF = keccak256("payment-reference-for-invoice-42");
    uint256 constant AMOUNT = 1_000_000; // 1 XRP in drops

    uint64 constant COMMIT_LEAD = 10 minutes;
    bytes32 constant SALT = keccak256("the watcher's salt");

    uint256 mandateId;
    Receipts.Leaf leaf;
    bytes32 sibling = keccak256("some other receipt in the same episode");

    function setUp() public {
        reg = new MandateRegistry();
        anchorLog = new AnchorLog(reg);
        mock = new MockFdc();
        meter = new SpendMeter(reg);
        rounds = new MockProtocolsV2();
        bond = new Bond(
            reg, anchorLog, IFdcVerification(address(mock)), 24 hours, 1 hours, meter,
            COMMIT_LEAD, ProtocolsV2Interface(address(rounds))
        );

        vm.warp(1_800_000_000);
        vm.prank(principal);
        mandateId = reg.commit(
            agent,
            keccak256("mandate envelope: may pay up to 5 XRP to rDestinationAddress"),
            bytes32(0),
            0,
            5_000_000,
            uint64(block.timestamp),
            uint64(block.timestamp + 1 days), _terms()
        );

        // agent's receipt (witness 1): "I paid 1 XRP with reference REF at T"
        leaf = Receipts.Leaf({
            receiptHash: keccak256("flario x402_receipt / kya-os jws bytes"),
            kind: Receipts.KIND_EXTERNAL_PAYMENT,
            sourceId: SRC_TESTXRP,
            destinationAddressHash: DEST,
            amount: AMOUNT,
            ref: REF,
            claimedTimestamp: uint64(block.timestamp + 100),
            mandateId: mandateId
        });

        // anchor a 2-leaf episode
        bytes32 lh = Receipts.hashMem(leaf);
        bytes32 root = lh < sibling ? keccak256(abi.encodePacked(lh, sibling)) : keccak256(abi.encodePacked(sibling, lh));
        vm.prank(agent);
        anchorLog.anchor(mandateId, root, 2);

        vm.prank(agent);
        reg.acknowledge(mandateId);
        // operator posts 10 ether bond
        vm.deal(principal, 100 ether);
        vm.prank(principal);
        bond.post{value: 10 ether}(mandateId);
    }


    function _terms() internal view returns (MandateRegistry.Terms memory) {
        return MandateRegistry.Terms({sourceId: SRC_TESTXRP, assetKey: bytes32(0), agentRef: bytes32(0), bond: address(bond)});
    }

    function _proof() internal view returns (IReferencedPaymentNonexistence.Proof memory p) {
        p.data.attestationType = bytes32("ReferencedPaymentNonexistence");
        p.data.sourceId = SRC_TESTXRP;
        p.data.votingRound = 123;
        p.data.requestBody = IReferencedPaymentNonexistence.RequestBody({
            minimalBlockNumber: 1000,
            deadlineBlockNumber: 2000,
            deadlineTimestamp: uint64(block.timestamp + 600),
            destinationAddressHash: DEST,
            amount: AMOUNT,
            standardPaymentReference: REF,
            checkSourceAddresses: false,
            sourceAddressesRoot: bytes32(0)
        });
        p.data.responseBody = IReferencedPaymentNonexistence.ResponseBody({
            minimalBlockTimestamp: uint64(block.timestamp),
            firstOverflowBlockNumber: 2001,
            firstOverflowBlockTimestamp: uint64(block.timestamp + 604)
        });
    }

    function _path() internal view returns (bytes32[] memory p) {
        p = new bytes32[](1);
        p[0] = sibling;
    }

    function _digest() internal view returns (bytes32) {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = Receipts.hashMem(leaf);
        return bond.deedsDigest(ids);
    }

    /// @dev Put `who`'s commitment `age` seconds in the past and start the evidence round NOW.
    ///      Both halves matter. A commitment has to be older than the round it is revealed against,
    ///      and a finalised round cannot have begun in the future — a harness that set the round
    ///      start ahead of `block.timestamp` would be testing a chain that cannot exist, and would
    ///      sail straight past `ClockDrift`. Time is left exactly where it was found, so proofs
    ///      built from `block.timestamp` stay valid.
    ///      Anyone may submit the commitment; only the address named inside it can spend it.
    function _armAged(address who, bytes32 digest, uint8 kind, uint64 age, uint64 round) internal {
        uint64 t = uint64(block.timestamp);
        vm.warp(t - age);
        bond.commitChallenge(bond.commitmentFor(who, mandateId, kind, digest, SALT));
        vm.warp(t);
        rounds.setRoundStart(round, t);
    }

    function _arm(address who) internal {
        _armAged(who, _digest(), bond.KIND_FALSE_PAYMENT(), COMMIT_LEAD, _proof().data.votingRound);
    }

    function test_contradictedDeed_slashesBond() public {
        uint256 cBefore = challenger.balance;
        uint256 pBefore = principal.balance;

        _arm(challenger);
        vm.prank(challenger);
        bond.challengeFalsePayment(mandateId, 0, leaf, _path(), _proof(), SALT);

        assertEq(bond.bondOf(mandateId), 0);
        assertTrue(bond.slashed(mandateId));
        // credited, not pushed: both sides pull
        assertEq(bond.owed(challenger), 1 ether); // 10%
        assertEq(bond.owed(principal), 9 ether);  // the harmed party, not a calldata address
        vm.prank(challenger);
        bond.claim();
        vm.prank(principal);
        bond.claim();
        assertEq(challenger.balance - cBefore, 1 ether);
        assertEq(principal.balance - pBefore, 9 ether);
        assertFalse(reg.isLive(mandateId), "mandate revoked by bond");
        // anchoring under a revoked mandate is now refused
        vm.prank(agent);
        vm.expectRevert(AnchorLog.MandateNotLive.selector);
        anchorLog.anchor(mandateId, bytes32(uint256(1)), 1);
    }

    function test_revert_whenFdcSaysProofInvalid() public {
        mock.setVerdict(false);
        vm.prank(challenger);
        vm.expectRevert(Bond.FdcProofInvalid.selector);
        bond.challengeFalsePayment(mandateId, 0, leaf, _path(), _proof(), SALT);
    }

    function test_revert_whenProofIsAboutDifferentPayment() public {
        IReferencedPaymentNonexistence.Proof memory p = _proof();
        p.data.requestBody.amount = AMOUNT + 1; // proof about a different amount
        _arm(challenger);
        vm.prank(challenger);
        vm.expectRevert(Bond.ProofDoesNotMatchClaim.selector);
        bond.challengeFalsePayment(mandateId, 0, leaf, _path(), p, SALT);
    }

    function test_revert_whenClaimOutsideProvenRange() public {
        IReferencedPaymentNonexistence.Proof memory p = _proof();
        p.data.requestBody.deadlineTimestamp = leaf.claimedTimestamp - 1; // deadline before claim
        _arm(challenger);
        vm.prank(challenger);
        vm.expectRevert(Bond.ClaimOutsideProvenRange.selector);
        bond.challengeFalsePayment(mandateId, 0, leaf, _path(), p, SALT);
    }

    function test_revert_whenLeafNotAnchored() public {
        Receipts.Leaf memory forged = leaf;
        forged.amount = AMOUNT + 5; // not what was anchored
        IReferencedPaymentNonexistence.Proof memory p = _proof();
        p.data.requestBody.amount = AMOUNT + 5;
        vm.prank(challenger);
        vm.expectRevert(Bond.LeafNotAnchored.selector);
        bond.challengeFalsePayment(mandateId, 0, forged, _path(), p, SALT);
    }

    function test_revert_doubleSlash() public {
        _arm(challenger);
        vm.prank(challenger);
        bond.challengeFalsePayment(mandateId, 0, leaf, _path(), _proof(), SALT);
        vm.prank(challenger);
        vm.expectRevert(Bond.AlreadySlashed.selector);
        bond.challengeFalsePayment(mandateId, 0, leaf, _path(), _proof(), SALT);
    }

    function test_delegation_monotonicNarrowing() public {
        // agent delegates a child mandate to a sub-agent within limits
        address sub = makeAddr("subagent");
        vm.prank(agent);
        uint256 child = reg.commit(
            sub, keccak256("child"), keccak256("vc-chain"), mandateId, 1_000_000,
            uint64(block.timestamp), uint64(block.timestamp + 1 hours), _terms()
        );
        assertTrue(reg.isLive(child));

        // exceeding parent's budget is refused
        vm.prank(agent);
        vm.expectRevert(MandateRegistry.ExceedsParent.selector);
        reg.commit(sub, keccak256("too-big"), 0, mandateId, 6_000_000, uint64(block.timestamp), uint64(block.timestamp + 1 hours), _terms());

        // a stranger cannot delegate from a mandate they don't hold
        vm.prank(challenger);
        vm.expectRevert(MandateRegistry.NotParentAgent.selector);
        reg.commit(sub, keccak256("x"), 0, mandateId, 1, uint64(block.timestamp), uint64(block.timestamp + 1 hours), _terms());

        // revoking the parent kills the child
        vm.prank(principal);
        reg.revoke(mandateId);
        assertFalse(reg.isLive(child));
    }

    // ---------------------------------------------------------------------
    // v0.5 hardening — one regression test per hole that was actually open.
    // ---------------------------------------------------------------------

    /// The bond must survive the mandate long enough for a challenge to be built.
    /// Before this, `revoke(); withdraw();` in one transaction emptied it — and the
    /// challenger's own FDC request announces the challenge minutes in advance.
    function test_revert_revokeAndWithdrawInSameTransaction() public {
        vm.startPrank(principal);
        reg.revoke(mandateId);
        vm.expectRevert(Bond.CoolingWindow.selector);
        bond.withdraw(mandateId, payable(principal));
        vm.stopPrank();

        // still slashable during the window
        vm.warp(block.timestamp + 23 hours);
        vm.prank(principal);
        vm.expectRevert(Bond.CoolingWindow.selector);
        bond.withdraw(mandateId, payable(principal));

        vm.warp(block.timestamp + 2 hours);
        uint256 before = principal.balance;
        vm.prank(principal);
        bond.withdraw(mandateId, payable(principal));
        assertEq(principal.balance - before, 10 ether);
    }

    /// Expiry gets the same window as revocation, measured from the mandate's death.
    function test_revert_withdrawRightAfterExpiry() public {
        vm.warp(block.timestamp + 1 days + 1);
        assertFalse(reg.isLive(mandateId));
        vm.prank(principal);
        vm.expectRevert(Bond.CoolingWindow.selector);
        bond.withdraw(mandateId, payable(principal));
    }

    /// revokeByBond was permissionless. That is not untidiness: a revoked mandate cannot
    /// anchor, so anyone could silence any agent's evidence layer for one transaction.
    function test_revert_revokeByBondFromStranger() public {
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(MandateRegistry.NotBond.selector);
        reg.revokeByBond(mandateId);
        assertTrue(reg.isLive(mandateId));
    }

    // ---------------------------------------------------------------------
    // v0.9 — what the budget is made of, and who agreed to it.
    // ---------------------------------------------------------------------

    function _commitAs(address who, address agent_, uint256 parent, MandateRegistry.Terms memory t)
        internal
        returns (uint256)
    {
        vm.prank(who);
        return reg.commit(agent_, keccak256("m"), 0, parent, 1_000, uint64(block.timestamp), uint64(block.timestamp + 1 hours), t);
    }

    function test_revert_mandateWithoutASource() public {
        MandateRegistry.Terms memory t = _terms();
        t.sourceId = bytes32(0);
        vm.prank(principal);
        vm.expectRevert(MandateRegistry.NoSource.selector);
        reg.commit(agent, keccak256("m"), 0, 0, 1, uint64(block.timestamp), uint64(block.timestamp + 1 hours), t);
    }

    /// Narrowing attenuates a quantity. A child in another asset or on another chain is not a
    /// smaller share of its parent's budget, it is a different budget.
    function test_revert_childCannotChangeAssetOrSource() public {
        MandateRegistry.Terms memory t = _terms();
        t.assetKey = bytes32(uint256(uint160(makeAddr("some token"))));
        vm.prank(agent);
        vm.expectRevert(MandateRegistry.ChangesParentAsset.selector);
        reg.commit(makeAddr("sub"), keccak256("m"), 0, mandateId, 1, uint64(block.timestamp), uint64(block.timestamp + 1 hours), t);

        t = _terms();
        t.sourceId = bytes32("XRP"); // mainnet instead of testnet: still another chain
        vm.prank(agent);
        vm.expectRevert(MandateRegistry.ChangesParentAsset.selector);
        reg.commit(makeAddr("sub"), keccak256("m"), 0, mandateId, 1, uint64(block.timestamp), uint64(block.timestamp + 1 hours), t);
    }

    /// The child may name its own sub-agent's identity and its own consequence contract; both are
    /// about the child, not about what the parent's budget is made of.
    function test_childKeepsAssetButNamesItsOwnAgentRef() public {
        MandateRegistry.Terms memory t = _terms();
        t.agentRef = keccak256("rSubAgentAddress");
        uint256 child = _commitAs(agent, makeAddr("sub"), mandateId, t);
        MandateRegistry.Mandate memory m = reg.get(child);
        assertEq(m.sourceId, SRC_TESTXRP);
        assertEq(m.assetKey, bytes32(0));
        assertEq(m.agentRef, keccak256("rSubAgentAddress"));
    }

    /// A principal writes the agent's address unilaterally. Until the agent says yes, the mandate is
    /// a claim about an address — and collateral under it would insure a stranger's ordinary life.
    function test_revert_postUnderUnacknowledgedMandate() public {
        uint256 id = _commitAs(principal, makeAddr("a busy stranger"), 0, _terms());
        vm.prank(principal);
        vm.expectRevert(Bond.NotAcknowledged.selector);
        bond.post{value: 1 ether}(id);
    }

    function test_revert_onlyTheAgentAcknowledges() public {
        uint256 id = _commitAs(principal, agent, 0, _terms());
        vm.prank(principal);
        vm.expectRevert(MandateRegistry.NotAgent.selector);
        reg.acknowledge(id);
        vm.prank(agent);
        reg.acknowledge(id);
        assertTrue(reg.acknowledged(id));
    }

    /// Collateral posted to a Bond the mandate does not name could never be slashed: `revokeByBond`
    /// would revert every time. It would only look like a bond.
    function test_revert_postToABondTheMandateDoesNotName() public {
        MandateRegistry.Terms memory t = _terms();
        t.bond = makeAddr("some other consequence contract");
        uint256 id = _commitAs(principal, agent, 0, t);
        vm.prank(agent);
        reg.acknowledge(id);
        vm.prank(principal);
        vm.expectRevert(Bond.NotThisBond.selector);
        bond.post{value: 1 ether}(id);
    }

    /// The registry has no deployer and no global Bond: a consequence contract can revoke exactly
    /// the mandates that named it, which is no more than their principals could do anyway.
    function test_consequenceContractRevokesOnlyMandatesThatNamedIt() public {
        address other = makeAddr("bond v2");
        MandateRegistry.Terms memory t = _terms();
        t.bond = other;
        uint256 id = _commitAs(principal, agent, 0, t);

        vm.prank(other);
        vm.expectRevert(MandateRegistry.NotBond.selector);
        reg.revokeByBond(mandateId); // named `bond`, not `other`

        vm.prank(address(bond));
        vm.expectRevert(MandateRegistry.NotBond.selector);
        reg.revokeByBond(id); // and the other way round

        vm.prank(other);
        reg.revokeByBond(id);
        assertFalse(reg.isLive(id));
        assertTrue(reg.isLive(mandateId));
    }

    /// A mandate that names no consequence contract can be revoked by no contract at all.
    function test_revert_revokeByBondWhenMandateNamesNone() public {
        MandateRegistry.Terms memory t = _terms();
        t.bond = address(0);
        uint256 id = _commitAs(principal, agent, 0, t);
        vm.prank(address(0));
        vm.expectRevert(MandateRegistry.NotBond.selector);
        reg.revokeByBond(id);
    }

    /// The false-payment path proves a payment in the source's native asset did not arrive. Against
    /// a mandate whose budget is some token, that is a true statement about the wrong thing.
    function test_revert_falsePaymentAgainstATokenMandate() public {
        MandateRegistry.Terms memory t = _terms();
        t.assetKey = bytes32(uint256(uint160(makeAddr("token"))));
        uint256 id = _commitAs(principal, agent, 0, t);
        Receipts.Leaf memory l = leaf;
        l.mandateId = id;
        vm.prank(agent);
        anchorLog.anchor(id, Receipts.hashMem(l), 1);
        vm.prank(agent);
        reg.acknowledge(id);
        vm.prank(principal);
        bond.post{value: 1 ether}(id);
        vm.prank(challenger);
        vm.expectRevert(Bond.WrongAsset.selector);
        bond.challengeFalsePayment(id, 0, l, new bytes32[](0), _proof(), SALT);
    }

    /// ...and a receipt naming another chain than the mandate's is not a deed under the mandate.
    function test_revert_falsePaymentOnAnotherSource() public {
        MandateRegistry.Terms memory t = _terms();
        t.sourceId = bytes32("testBTC");
        uint256 id = _commitAs(principal, agent, 0, t);
        Receipts.Leaf memory l = leaf; // says testXRP
        l.mandateId = id;
        vm.prank(agent);
        anchorLog.anchor(id, Receipts.hashMem(l), 1);
        vm.prank(agent);
        reg.acknowledge(id);
        vm.prank(principal);
        bond.post{value: 1 ether}(id);
        vm.prank(challenger);
        vm.expectRevert(Bond.WrongSource.selector);
        bond.challengeFalsePayment(id, 0, l, new bytes32[](0), _proof(), SALT);
    }

    /// The immunisation attack: burn the leaf under a throwaway mandate of your own, and the
    /// same evidence can never convict anyone again. Killed by binding leaf.mandateId and by
    /// scoping consumedLeaf per mandate.
    function test_revert_leafCannotBeBurnedUnderAForeignMandate() public {
        address attacker = makeAddr("attacker");
        vm.deal(attacker, 1 ether);
        vm.startPrank(attacker);
        uint256 decoy = reg.commit(
            attacker, keccak256("decoy"), bytes32(0), 0, 1, uint64(block.timestamp), uint64(block.timestamp + 1 hours), _terms()
        );
        // root == leafHash, so the Merkle path is empty and inclusion is trivially true
        anchorLog.anchor(decoy, Receipts.hashMem(leaf), 1);
        reg.acknowledge(decoy);
        bond.post{value: 1 wei}(decoy);
        vm.expectRevert(Bond.ProofDoesNotMatchClaim.selector);
        bond.challengeFalsePayment(decoy, 0, leaf, new bytes32[](0), _proof(), SALT);
        vm.stopPrank();

        // the real challenge still lands
        _arm(challenger);
        vm.prank(challenger);
        bond.challengeFalsePayment(mandateId, 0, leaf, _path(), _proof(), SALT);
        assertTrue(bond.slashed(mandateId));
    }

    /// A nonexistence proof scoped to a set of source addresses is a true statement about
    /// THOSE addresses. The leaf has no source address, so accepting it would convict an
    /// agent who really did pay — from a different address.
    function test_revert_sourceScopedNonexistenceProofRejected() public {
        IReferencedPaymentNonexistence.Proof memory p = _proof();
        p.data.requestBody.checkSourceAddresses = true;
        p.data.requestBody.sourceAddressesRoot = keccak256("some other payer");
        _arm(challenger);
        vm.prank(challenger);
        vm.expectRevert(Bond.ProofDoesNotMatchClaim.selector);
        bond.challengeFalsePayment(mandateId, 0, leaf, _path(), p, SALT);
    }

    /// One slash per mandate. Funding an already-slashed mandate buys nothing but looks like
    /// collateral to anyone reading the chain.
    function test_revert_postToSlashedMandate() public {
        _arm(challenger);
        vm.prank(challenger);
        bond.challengeFalsePayment(mandateId, 0, leaf, _path(), _proof(), SALT);
        vm.deal(address(this), 1 ether);
        vm.expectRevert(Bond.BondSlashed.selector);
        bond.post{value: 1 ether}(mandateId);
    }

    /// isLive walked at most 64 ancestors and then answered "alive". 65 self-delegations
    /// therefore produced a mandate its own root could not kill. Now it fails closed.
    function test_deepDelegationChainFailsClosed() public {
        uint256 parent = mandateId;
        vm.startPrank(agent);
        for (uint256 i = 0; i < 65; i++) {
            parent = reg.commit(
                agent, keccak256("child"), bytes32(0), parent, 1, uint64(block.timestamp), uint64(block.timestamp + 1 hours), _terms()
        );
        }
        vm.stopPrank();
        assertFalse(reg.isLive(parent), "chain deeper than the guard must be dead, not immortal");
        assertEq(reg.deathTime(parent), type(uint64).max);
    }

    // ---------------------------------------------------------------------
    // v0.8 — commit–reveal on the challenge (SPEC 6.7).
    //
    // The reward has to belong to whoever DETECTED the violation, not to whoever pressed the
    // button. Every test below is a statement about one thing: the distance between when the
    // commitment was made and when the voting round that produced the evidence began.
    // ---------------------------------------------------------------------

    function _commitmentOf(address who) internal view returns (bytes32) {
        return bond.commitmentFor(who, mandateId, bond.KIND_FALSE_PAYMENT(), _digest(), SALT);
    }

    /// No commitment at all: the old, snipeable path is simply gone.
    function test_revert_challengeWithoutAnyCommitment() public {
        rounds.setRoundStart(_proof().data.votingRound, uint64(block.timestamp));
        vm.prank(challenger);
        vm.expectRevert(Bond.NoCommitment.selector);
        bond.challengeFalsePayment(mandateId, 0, leaf, _path(), _proof(), SALT);
    }

    /// Committing after the evidence round started is exactly what a copier can do, and it fails.
    function test_revert_commitmentMadeAfterTheRoundBegan() public {
        // the round that produced this proof began a second before the commitment
        rounds.setRoundStart(_proof().data.votingRound, uint64(block.timestamp) - 1);
        bond.commitChallenge(_commitmentOf(challenger));
        vm.prank(challenger);
        vm.expectRevert(Bond.CommittedTooLate.selector);
        bond.challengeFalsePayment(mandateId, 0, leaf, _path(), _proof(), SALT);
    }

    /// One second short of `commitLead` is short.
    /// @dev These boundaries are four tests rather than two on purpose: re-arming inside one test
    ///      would be a no-op, because `commitChallenge` keeps the EARLIEST submission of a given
    ///      commitment and the salt is fixed. That is the anti-grief property, asserted separately
    ///      in `test_replayingACommitmentCannotAgeIt`.
    function test_revert_commitmentOneSecondTooYoung() public {
        _armAged(challenger, _digest(), bond.KIND_FALSE_PAYMENT(), COMMIT_LEAD - 1, _proof().data.votingRound);
        vm.prank(challenger);
        vm.expectRevert(Bond.CommittedTooLate.selector);
        bond.challengeFalsePayment(mandateId, 0, leaf, _path(), _proof(), SALT);
    }

    /// Exactly `commitLead` is enough: the window is inclusive at the near end.
    function test_commitmentExactlyAtTheLeadStands() public {
        _arm(challenger);
        vm.prank(challenger);
        bond.challengeFalsePayment(mandateId, 0, leaf, _path(), _proof(), SALT);
        assertTrue(bond.slashed(mandateId));
    }

    /// The other end of the window, and the one that decides whether the gate means anything.
    /// A commitment older than COMMIT_TTL is a free option someone parked there in advance; it is
    /// refused, so pre-committing to every deed on the chain costs rent instead of one SSTORE.
    function test_revert_commitmentOlderThanTheTtl() public {
        _armAged(challenger, _digest(), bond.KIND_FALSE_PAYMENT(), bond.COMMIT_TTL() + 1, _proof().data.votingRound);
        vm.prank(challenger);
        vm.expectRevert(Bond.CommitmentStale.selector);
        bond.challengeFalsePayment(mandateId, 0, leaf, _path(), _proof(), SALT);
    }

    /// Exactly COMMIT_TTL still stands: the window is [commitLead, COMMIT_TTL], inclusive at both
    /// ends, so a challenger who sat on a find for an hour is not punished for a second of drift.
    function test_commitmentExactlyAtTheTtlStands() public {
        _armAged(challenger, _digest(), bond.KIND_FALSE_PAYMENT(), bond.COMMIT_TTL(), _proof().data.votingRound);
        vm.prank(challenger);
        bond.challengeFalsePayment(mandateId, 0, leaf, _path(), _proof(), SALT);
        assertTrue(bond.slashed(mandateId));
    }

    /// A squatter's commitment, parked long before anyone found anything, is worthless by the time
    /// there is a reveal worth copying. This is the attack the TTL exists for: the deed set on the
    /// single-deed paths is one public hash, so guessing it needs no detection at all.
    function test_revert_preSquattedCommitmentHasExpiredByTheTimeItIsUseful() public {
        address squatter = makeAddr("commitment squatter");
        // three days before anybody challenges anything, the squatter commits to this leaf
        _armAged(squatter, _digest(), bond.KIND_FALSE_PAYMENT(), 3 days, _proof().data.votingRound);
        vm.prank(squatter);
        vm.expectRevert(Bond.CommitmentStale.selector);
        bond.challengeFalsePayment(mandateId, 0, leaf, _path(), _proof(), SALT);
    }

    /// THE attack this release exists for. The challenger has committed in time and is about to
    /// reveal; a parasite lifts the whole calldata out of the mempool — proofs included — and
    /// sends it from its own address with its own, newly made commitment. Refused.
    function test_revert_copiedCalldataWithALateCommitment() public {
        address parasite = makeAddr("mempool parasite");
        _arm(challenger); // the evidence round began now; the FDC request is public

        bond.commitChallenge(_commitmentOf(parasite)); // the best a copier can do: commit now
        vm.prank(parasite);
        vm.expectRevert(Bond.CommittedTooLate.selector);
        bond.challengeFalsePayment(mandateId, 0, leaf, _path(), _proof(), SALT);

        // and the watcher who actually did the work still gets paid
        vm.prank(challenger);
        bond.challengeFalsePayment(mandateId, 0, leaf, _path(), _proof(), SALT);
        assertEq(bond.owed(challenger), 1 ether);
        assertEq(bond.owed(parasite), 0);
    }

    /// The variant the round rule alone does NOT stop, and the reason `commitLead` exists: the
    /// parasite requests its own attestation a round later, so its fresh commitment honestly
    /// predates THAT round's start. It has to buy `commitLead` worth of rounds to get there — by
    /// which time the honest challenger, whose proof was ready first, has long since revealed.
    function test_laterRoundBuysOnlyCommitLeadWorthOfRounds() public {
        address parasite = makeAddr("mempool parasite");
        uint64 base = _proof().data.votingRound;
        uint64 dur = rounds.votingEpochDurationSeconds();
        _arm(challenger);
        bond.commitChallenge(_commitmentOf(parasite)); // learns of the case as the round opens

        IReferencedPaymentNonexistence.Proof memory later = _proof();

        // one round later is not enough — nor is anything short of commitLead
        later.data.votingRound = base + 1;
        vm.warp(block.timestamp + dur); // that round has now begun, so ClockDrift is not what bites
        vm.prank(parasite);
        vm.expectRevert(Bond.CommittedTooLate.selector);
        bond.challengeFalsePayment(mandateId, 0, leaf, _path(), later, SALT);

        // the residual, stated rather than hidden: far enough out, the copier is just a slower
        // watcher. COMMIT_LEAD is sized so "far enough" exceeds the FDC latency spread, and
        // COMMIT_TTL caps how far out it can still be.
        uint64 rounds_ = COMMIT_LEAD / dur + 1; // 600 / 90 + 1 = 7 rounds = 630 s >= 600 s
        later.data.votingRound = base + rounds_;
        vm.warp(block.timestamp + uint256(rounds_) * dur);
        vm.prank(parasite);
        bond.challengeFalsePayment(mandateId, 0, leaf, _path(), later, SALT);
        assertEq(bond.owed(parasite), 1 ether);
    }

    /// A voting round cannot have begun in the future. If Flare ever lengthens the voting epoch,
    /// `roundStartTs` — which multiplies an old round number by the CURRENT epoch length — lands
    /// years ahead, and every commitment, including one made in this block, would clear the lead
    /// test. The gate would stop existing with nothing reverting to say so. It fails closed.
    function test_revert_clockDriftCannotOpenTheGate() public {
        address parasite = makeAddr("mempool parasite");
        uint64 base = _proof().data.votingRound;
        bond.commitChallenge(_commitmentOf(parasite)); // committed this very second

        // Flare doubles the epoch: this round's computed start jumps far into the future
        rounds.setRoundStart(base, uint64(block.timestamp) + 1);
        vm.prank(parasite);
        vm.expectRevert(Bond.ClockDrift.selector);
        bond.challengeFalsePayment(mandateId, 0, leaf, _path(), _proof(), SALT);
    }

    /// `msg.sender` is inside the preimage, so a commitment is not transferable.
    function test_revert_revealingSomeoneElsesCommitment() public {
        _arm(challenger);
        vm.prank(makeAddr("thief"));
        vm.expectRevert(Bond.NoCommitment.selector);
        bond.challengeFalsePayment(mandateId, 0, leaf, _path(), _proof(), SALT);
    }

    /// A commitment for a cheap challenge type cannot be spent on an expensive one.
    function test_revert_commitmentForAnotherKind() public {
        _armAged(challenger, _digest(), bond.KIND_UNANCHORED_DEED(), COMMIT_LEAD, _proof().data.votingRound);
        vm.prank(challenger);
        vm.expectRevert(Bond.NoCommitment.selector);
        bond.challengeFalsePayment(mandateId, 0, leaf, _path(), _proof(), SALT);
    }

    /// Nor on another mandate, nor against a deed it did not name.
    function test_revert_commitmentForAnotherMandateOrDeed() public {
        bytes32[] memory otherIds = new bytes32[](1);
        otherIds[0] = keccak256("some other receipt entirely");
        uint64 t = uint64(block.timestamp);
        vm.warp(t - COMMIT_LEAD);
        bond.commitChallenge(bond.commitmentFor(challenger, mandateId + 1, bond.KIND_FALSE_PAYMENT(), _digest(), SALT));
        bond.commitChallenge(
            bond.commitmentFor(challenger, mandateId, bond.KIND_FALSE_PAYMENT(), bond.deedsDigest(otherIds), SALT)
        );
        vm.warp(t);
        rounds.setRoundStart(_proof().data.votingRound, t);

        vm.prank(challenger);
        vm.expectRevert(Bond.NoCommitment.selector);
        bond.challengeFalsePayment(mandateId, 0, leaf, _path(), _proof(), SALT);
    }

    /// Spent on reveal. The slot is the single-use token, not a standing licence.
    function test_commitmentIsSpentOnReveal() public {
        bytes32 c = _commitmentOf(challenger);
        _arm(challenger);
        assertEq(bond.committedAt(c), uint64(block.timestamp) - COMMIT_LEAD);
        vm.prank(challenger);
        bond.challengeFalsePayment(mandateId, 0, leaf, _path(), _proof(), SALT);
        assertEq(bond.committedAt(c), 0, "commitment must not survive its reveal");
    }

    /// Commitments travel in public calldata. If a second submission could refresh the stored
    /// timestamp, a parasite unable to steal a challenge could still grief it into `CommittedTooLate`
    /// by replaying the victim's own commitment bytes just before the reveal. It cannot: the
    /// earliest submission is the one that counts, and replaying it is a no-op.
    function test_replayingACommitmentCannotAgeIt() public {
        bytes32 c = _commitmentOf(challenger);
        _arm(challenger);
        uint64 first = bond.committedAt(c);

        vm.prank(makeAddr("griefer"));
        bond.commitChallenge(c); // the round has begun; the reveal is imminent
        assertEq(bond.committedAt(c), first, "a replay must not move the commitment forward");

        vm.prank(challenger);
        bond.challengeFalsePayment(mandateId, 0, leaf, _path(), _proof(), SALT);
        assertTrue(bond.slashed(mandateId));
    }

    /// `_one` builds its array in memory, `deedsDigest` takes calldata. The two must agree byte for
    /// byte or every single-deed commitment made off-chain would miss its slot.
    function test_singleDeedDigestMatchesTheArrayHelper() public view {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = Receipts.hashMem(leaf);
        assertEq(bond.deedsDigest(ids), _digest());
        assertEq(bond.deedsDigest(ids), keccak256(abi.encode(ids)));
    }

    /// The clock is read off Flare, never hardcoded.
    function test_roundStartTsTracksTheLiveClock() public view {
        uint64 first = rounds.firstVotingRoundStartTs();
        uint64 dur = rounds.votingEpochDurationSeconds();
        assertEq(bond.roundStartTs(0), first);
        assertEq(bond.roundStartTs(1234), first + 1234 * dur);
        assertEq(address(bond.protocols()), address(rounds));
    }
}
