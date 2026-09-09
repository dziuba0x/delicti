// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {MandateRegistry} from "../src/MandateRegistry.sol";
import {AnchorLog} from "../src/AnchorLog.sol";
import {Bond} from "../src/Bond.sol";
import {Receipts} from "../src/Receipts.sol";
import {IFdcVerification} from "@flarenetwork/flare-periphery-contracts/coston2/IFdcVerification.sol";
import {IReferencedPaymentNonexistence} from
    "@flarenetwork/flare-periphery-contracts/coston2/IReferencedPaymentNonexistence.sol";

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
    MockFdc mock;

    address principal = makeAddr("principal");
    address agent = makeAddr("agent");
    address challenger = makeAddr("challenger");
    address payable victim = payable(makeAddr("victim"));

    bytes32 constant SRC_TESTXRP = bytes32("testXRP");
    bytes32 constant DEST = keccak256("rDestinationAddress");
    bytes32 constant REF = keccak256("payment-reference-for-invoice-42");
    uint256 constant AMOUNT = 1_000_000; // 1 XRP in drops

    uint256 mandateId;
    Receipts.Leaf leaf;
    bytes32 sibling = keccak256("some other receipt in the same episode");

    function setUp() public {
        reg = new MandateRegistry();
        anchorLog = new AnchorLog(reg);
        mock = new MockFdc();
        bond = new Bond(reg, anchorLog, IFdcVerification(address(mock)));
        reg.setBond(address(bond));

        vm.warp(1_800_000_000);
        vm.prank(principal);
        mandateId = reg.commit(
            agent,
            keccak256("mandate envelope: may pay up to 5 XRP to rDestinationAddress"),
            bytes32(0),
            0,
            5_000_000,
            uint64(block.timestamp),
            uint64(block.timestamp + 1 days)
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

        // operator posts 10 ether bond
        vm.deal(principal, 100 ether);
        vm.prank(principal);
        bond.post{value: 10 ether}(mandateId);
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

    function test_contradictedDeed_slashesBond() public {
        uint256 cBefore = challenger.balance;
        uint256 pBefore = principal.balance;

        vm.prank(challenger);
        bond.challengeFalsePayment(mandateId, 0, leaf, _path(), _proof());

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
        bond.challengeFalsePayment(mandateId, 0, leaf, _path(), _proof());
    }

    function test_revert_whenProofIsAboutDifferentPayment() public {
        IReferencedPaymentNonexistence.Proof memory p = _proof();
        p.data.requestBody.amount = AMOUNT + 1; // proof about a different amount
        vm.prank(challenger);
        vm.expectRevert(Bond.ProofDoesNotMatchClaim.selector);
        bond.challengeFalsePayment(mandateId, 0, leaf, _path(), p);
    }

    function test_revert_whenClaimOutsideProvenRange() public {
        IReferencedPaymentNonexistence.Proof memory p = _proof();
        p.data.requestBody.deadlineTimestamp = leaf.claimedTimestamp - 1; // deadline before claim
        vm.prank(challenger);
        vm.expectRevert(Bond.ClaimOutsideProvenRange.selector);
        bond.challengeFalsePayment(mandateId, 0, leaf, _path(), p);
    }

    function test_revert_whenLeafNotAnchored() public {
        Receipts.Leaf memory forged = leaf;
        forged.amount = AMOUNT + 5; // not what was anchored
        IReferencedPaymentNonexistence.Proof memory p = _proof();
        p.data.requestBody.amount = AMOUNT + 5;
        vm.prank(challenger);
        vm.expectRevert(Bond.LeafNotAnchored.selector);
        bond.challengeFalsePayment(mandateId, 0, forged, _path(), p);
    }

    function test_revert_doubleSlash() public {
        vm.prank(challenger);
        bond.challengeFalsePayment(mandateId, 0, leaf, _path(), _proof());
        vm.prank(challenger);
        vm.expectRevert(Bond.AlreadySlashed.selector);
        bond.challengeFalsePayment(mandateId, 0, leaf, _path(), _proof());
    }

    function test_delegation_monotonicNarrowing() public {
        // agent delegates a child mandate to a sub-agent within limits
        address sub = makeAddr("subagent");
        vm.prank(agent);
        uint256 child = reg.commit(
            sub, keccak256("child"), keccak256("vc-chain"), mandateId, 1_000_000,
            uint64(block.timestamp), uint64(block.timestamp + 1 hours)
        );
        assertTrue(reg.isLive(child));

        // exceeding parent's budget is refused
        vm.prank(agent);
        vm.expectRevert(MandateRegistry.ExceedsParent.selector);
        reg.commit(sub, keccak256("too-big"), 0, mandateId, 6_000_000, uint64(block.timestamp), uint64(block.timestamp + 1 hours));

        // a stranger cannot delegate from a mandate they don't hold
        vm.prank(challenger);
        vm.expectRevert(MandateRegistry.NotParentAgent.selector);
        reg.commit(sub, keccak256("x"), 0, mandateId, 1, uint64(block.timestamp), uint64(block.timestamp + 1 hours));

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

    /// The immunisation attack: burn the leaf under a throwaway mandate of your own, and the
    /// same evidence can never convict anyone again. Killed by binding leaf.mandateId and by
    /// scoping consumedLeaf per mandate.
    function test_revert_leafCannotBeBurnedUnderAForeignMandate() public {
        address attacker = makeAddr("attacker");
        vm.deal(attacker, 1 ether);
        vm.startPrank(attacker);
        uint256 decoy = reg.commit(
            attacker, keccak256("decoy"), bytes32(0), 0, 1, uint64(block.timestamp), uint64(block.timestamp + 1 hours)
        );
        // root == leafHash, so the Merkle path is empty and inclusion is trivially true
        anchorLog.anchor(decoy, Receipts.hashMem(leaf), 1);
        bond.post{value: 1 wei}(decoy);
        vm.expectRevert(Bond.ProofDoesNotMatchClaim.selector);
        bond.challengeFalsePayment(decoy, 0, leaf, new bytes32[](0), _proof());
        vm.stopPrank();

        // the real challenge still lands
        vm.prank(challenger);
        bond.challengeFalsePayment(mandateId, 0, leaf, _path(), _proof());
        assertTrue(bond.slashed(mandateId));
    }

    /// A nonexistence proof scoped to a set of source addresses is a true statement about
    /// THOSE addresses. The leaf has no source address, so accepting it would convict an
    /// agent who really did pay — from a different address.
    function test_revert_sourceScopedNonexistenceProofRejected() public {
        IReferencedPaymentNonexistence.Proof memory p = _proof();
        p.data.requestBody.checkSourceAddresses = true;
        p.data.requestBody.sourceAddressesRoot = keccak256("some other payer");
        vm.prank(challenger);
        vm.expectRevert(Bond.ProofDoesNotMatchClaim.selector);
        bond.challengeFalsePayment(mandateId, 0, leaf, _path(), p);
    }

    /// One slash per mandate. Funding an already-slashed mandate buys nothing but looks like
    /// collateral to anyone reading the chain.
    function test_revert_postToSlashedMandate() public {
        vm.prank(challenger);
        bond.challengeFalsePayment(mandateId, 0, leaf, _path(), _proof());
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
                agent, keccak256("child"), bytes32(0), parent, 1, uint64(block.timestamp), uint64(block.timestamp + 1 hours)
            );
        }
        vm.stopPrank();
        assertFalse(reg.isLive(parent), "chain deeper than the guard must be dead, not immortal");
        assertEq(reg.deathTime(parent), type(uint64).max);
    }

}
