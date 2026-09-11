// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {MandateRegistry} from "../src/MandateRegistry.sol";
import {AnchorLog} from "../src/AnchorLog.sol";
import {Bond} from "../src/Bond.sol";
import {Receipts} from "../src/Receipts.sol";
import {IFdcVerification} from "@flarenetwork/flare-periphery-contracts/coston2/IFdcVerification.sol";
import {IEVMTransaction} from "@flarenetwork/flare-periphery-contracts/coston2/IEVMTransaction.sol";

contract MockFdcEvm2 {
    bool public verdict = true;

    function setVerdict(bool v) external {
        verdict = v;
    }

    function verifyEVMTransaction(IEVMTransaction.Proof calldata) external view returns (bool) {
        return verdict;
    }
}

/// The deed nobody wrote down. Every other challenge reaches only agents that anchored their
/// own breach; this one reaches the ones that stayed quiet.
contract UnanchoredTest is Test {
    MandateRegistry reg;
    AnchorLog anchorLog;
    Bond bond;
    MockFdcEvm2 mock;

    address principal = makeAddr("principal");
    address agent = makeAddr("agent");
    address merchant = makeAddr("merchant");
    address challenger = makeAddr("challenger");

    bytes32 constant SRC = bytes32("testFLR");
    bytes32 constant TXH = keccak256("the transaction the agent never mentioned");
    uint64 constant RESPONSE = 24 hours;

    uint256 mandateId;
    uint64 deedTime;
    // Cached: reading these off the contract inside an argument list is a separate call, and it
    // eats the vm.prank / vm.expectRevert cheatcode that was meant for the call after it.
    uint256 STAKE;
    uint64 GRACE;

    function setUp() public {
        reg = new MandateRegistry();
        anchorLog = new AnchorLog(reg);
        mock = new MockFdcEvm2();
        bond = new Bond(reg, anchorLog, IFdcVerification(address(mock)), RESPONSE, 1 hours);
        reg.setBond(address(bond));
        vm.warp(1_800_000_000);

        vm.prank(principal);
        mandateId = reg.commit(
            agent, keccak256("may spend up to 4 FLR at merchant"), 0, 0, 4 ether,
            uint64(block.timestamp), uint64(block.timestamp + 7 days)
        );
        vm.prank(agent);
        reg.declareExclusive(mandateId);

        vm.deal(principal, 100 ether);
        vm.prank(principal);
        bond.post{value: 10 ether}(mandateId);
        vm.deal(challenger, 10 ether);

        STAKE = bond.ACCUSATION_STAKE();
        GRACE = bond.anchorGrace();
        deedTime = uint64(block.timestamp + 60);
    }

    function _proof() internal view returns (IEVMTransaction.Proof memory p) {
        p.data.attestationType = bytes32("EVMTransaction");
        p.data.sourceId = SRC;
        p.data.requestBody.transactionHash = TXH;
        p.data.requestBody.requiredConfirmations = 1;
        p.data.responseBody.blockNumber = 100;
        p.data.responseBody.timestamp = deedTime;
        p.data.responseBody.sourceAddress = agent;
        p.data.responseBody.receivingAddress = merchant;
        p.data.responseBody.value = 1 ether;
        p.data.responseBody.status = 1;
    }

    function _leaf() internal view returns (Receipts.Leaf memory l) {
        l = Receipts.Leaf({
            receiptHash: keccak256("flario receipt for the deed"),
            kind: Receipts.KIND_EVM_TX,
            sourceId: SRC,
            destinationAddressHash: bytes32(uint256(uint160(merchant))),
            amount: 1 ether,
            ref: TXH,
            claimedTimestamp: deedTime,
            mandateId: mandateId
        });
    }

    function _accuse() internal returns (uint256 id) {
        vm.warp(deedTime + GRACE + 1);
        vm.prank(challenger);
        id = bond.accuseUnanchoredDeed{value: STAKE}(mandateId, _proof());
    }

    // --- the deed nobody wrote down ---

    function test_silenceResolvesAgainstTheAgent() public {
        uint256 id = _accuse();
        vm.warp(block.timestamp + RESPONSE + 1);
        bond.resolveAccusation(id); // anyone may resolve
        assertTrue(bond.slashed(mandateId));
        assertFalse(reg.isLive(mandateId));
        // stake back + 10% of the bond, even though a stranger pressed the button
        assertEq(bond.owed(challenger), STAKE + 1 ether);
        assertEq(bond.owed(principal), 9 ether);
    }

    function test_answeringWithTheReceiptClosesIt() public {
        // the agent did anchor it, in time
        vm.warp(deedTime + 10 minutes);
        bytes32 lh = Receipts.hashMem(_leaf());
        vm.prank(agent);
        anchorLog.anchor(mandateId, lh, 1);

        uint256 id = _accuse();
        bond.answerAccusation(id, 0, _leaf(), new bytes32[](0));
        assertFalse(bond.slashed(mandateId));
        // a false accusation costs the accuser its stake
        assertEq(bond.owed(principal), STAKE);
        assertEq(bond.owed(challenger), 0);

        vm.warp(block.timestamp + RESPONSE + 1);
        vm.expectRevert(Bond.AccusationClosed.selector);
        bond.resolveAccusation(id);
    }

    /// Anchoring after the accusation is a cover story, not a receipt.
    function test_revert_retroactiveAnchorIsNoDefence() public {
        uint256 id = _accuse();
        bytes32 lh = Receipts.hashMem(_leaf());
        vm.prank(agent);
        anchorLog.anchor(mandateId, lh, 1); // now, well past the grace
        vm.expectRevert(Bond.AnchoredTooLate.selector);
        bond.answerAccusation(id, 0, _leaf(), new bytes32[](0));
    }

    /// The agent gets to be slower than the chain — only silence past the grace counts.
    function test_revert_accuseWithinGrace() public {
        vm.warp(deedTime + 10 minutes);
        vm.prank(challenger);
        vm.expectRevert(Bond.DeedWithinGrace.selector);
        bond.accuseUnanchoredDeed{value: STAKE}(mandateId, _proof());
    }

    /// An agent that never promised exclusivity cannot be asked to account for every deed:
    /// the address may be doing other, entirely legitimate things.
    function test_revert_accuseWithoutExclusivity() public {
        vm.prank(principal);
        uint256 other = reg.commit(
            agent, keccak256("non-exclusive"), 0, 0, 4 ether, uint64(block.timestamp), uint64(block.timestamp + 7 days)
        );
        vm.prank(principal);
        bond.post{value: 1 ether}(other);
        vm.warp(deedTime + GRACE + 1);
        vm.prank(challenger);
        vm.expectRevert(Bond.NotExclusive.selector);
        bond.accuseUnanchoredDeed{value: STAKE}(other, _proof());
    }

    function test_revert_secondAccusationOnSameDeed() public {
        _accuse();
        vm.prank(challenger);
        vm.expectRevert(Bond.AlreadyAccused.selector);
        bond.accuseUnanchoredDeed{value: STAKE}(mandateId, _proof());
    }

    function test_revert_resolveBeforeWindowCloses() public {
        uint256 id = _accuse();
        vm.warp(block.timestamp + RESPONSE - 1);
        vm.expectRevert(Bond.ResponseWindowOpen.selector);
        bond.resolveAccusation(id);
    }

    function test_revert_wrongStake() public {
        vm.warp(deedTime + GRACE + 1);
        vm.prank(challenger);
        vm.expectRevert(Bond.BadStake.selector);
        bond.accuseUnanchoredDeed{value: 1 wei}(mandateId, _proof());
    }

    function test_revert_deedOutsideMandateWindow() public {
        IEVMTransaction.Proof memory p = _proof();
        p.data.responseBody.timestamp = uint64(block.timestamp - 1); // before validFrom
        vm.warp(block.timestamp + 2 hours);
        vm.prank(challenger);
        vm.expectRevert(Bond.ClaimOutsideProvenRange.selector);
        bond.accuseUnanchoredDeed{value: STAKE}(mandateId, p);
    }

    function test_revert_deedByAnotherAddress() public {
        IEVMTransaction.Proof memory p = _proof();
        p.data.responseBody.sourceAddress = makeAddr("someone else");
        vm.warp(deedTime + GRACE + 1);
        vm.prank(challenger);
        vm.expectRevert(Bond.NotAgentTx.selector);
        bond.accuseUnanchoredDeed{value: STAKE}(mandateId, p);
    }

    /// Exclusivity is the agent's own promise. Nobody else can make it for them.
    function test_revert_onlyAgentDeclaresExclusive() public {
        vm.prank(principal);
        uint256 other = reg.commit(
            agent, keccak256("x"), 0, 0, 1 ether, uint64(block.timestamp), uint64(block.timestamp + 1 days)
        );
        vm.prank(principal);
        vm.expectRevert(MandateRegistry.NotAgent.selector);
        reg.declareExclusive(other);
    }
}
