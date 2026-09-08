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
            standardPaymentReference: REF,
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
        uint256 vBefore = victim.balance;

        vm.prank(challenger);
        bond.challengeFalsePayment(mandateId, 0, leaf, _path(), _proof(), victim);

        assertEq(bond.bondOf(mandateId), 0);
        assertTrue(bond.slashed(mandateId));
        assertEq(challenger.balance - cBefore, 1 ether); // 10%
        assertEq(victim.balance - vBefore, 9 ether);
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
        bond.challengeFalsePayment(mandateId, 0, leaf, _path(), _proof(), victim);
    }

    function test_revert_whenProofIsAboutDifferentPayment() public {
        IReferencedPaymentNonexistence.Proof memory p = _proof();
        p.data.requestBody.amount = AMOUNT + 1; // proof about a different amount
        vm.prank(challenger);
        vm.expectRevert(Bond.ProofDoesNotMatchClaim.selector);
        bond.challengeFalsePayment(mandateId, 0, leaf, _path(), p, victim);
    }

    function test_revert_whenClaimOutsideProvenRange() public {
        IReferencedPaymentNonexistence.Proof memory p = _proof();
        p.data.requestBody.deadlineTimestamp = leaf.claimedTimestamp - 1; // deadline before claim
        vm.prank(challenger);
        vm.expectRevert(Bond.ClaimOutsideProvenRange.selector);
        bond.challengeFalsePayment(mandateId, 0, leaf, _path(), p, victim);
    }

    function test_revert_whenLeafNotAnchored() public {
        Receipts.Leaf memory forged = leaf;
        forged.amount = AMOUNT + 5; // not what was anchored
        IReferencedPaymentNonexistence.Proof memory p = _proof();
        p.data.requestBody.amount = AMOUNT + 5;
        vm.prank(challenger);
        vm.expectRevert(Bond.LeafNotAnchored.selector);
        bond.challengeFalsePayment(mandateId, 0, forged, _path(), p, victim);
    }

    function test_revert_doubleSlash() public {
        vm.prank(challenger);
        bond.challengeFalsePayment(mandateId, 0, leaf, _path(), _proof(), victim);
        vm.prank(challenger);
        vm.expectRevert(Bond.AlreadySlashed.selector);
        bond.challengeFalsePayment(mandateId, 0, leaf, _path(), _proof(), victim);
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
}
