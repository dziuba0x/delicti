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
    SpendMeter meter;
    MockFdcEvm2 mock;
    MockProtocolsV2 rounds;

    address principal = makeAddr("principal");
    address agent = makeAddr("agent");
    address merchant = makeAddr("merchant");
    address challenger = makeAddr("challenger");

    bytes32 constant SRC = bytes32("testFLR");
    bytes32 constant TXH = keccak256("the transaction the agent never mentioned");
    uint64 constant RESPONSE = 24 hours;
    uint64 constant COMMIT_LEAD = 10 minutes;
    bytes32 constant SALT = keccak256("the watcher's salt");

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
        meter = new SpendMeter(reg);
        rounds = new MockProtocolsV2();
        bond = new Bond(
            reg, anchorLog, IFdcVerification(address(mock)), RESPONSE, 1 hours, meter,
            COMMIT_LEAD, ProtocolsV2Interface(address(rounds)), new AgentRefs(reg, IFdcVerification(address(0))));
        vm.warp(1_800_000_000);

        vm.prank(principal);
        mandateId = reg.commit(
            agent, keccak256("may spend up to 4 FLR at merchant"), 0, 0, 4 ether,
            uint64(block.timestamp), uint64(block.timestamp + 7 days), _terms()
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

    function _terms() internal view returns (MandateRegistry.Terms memory) {
        return MandateRegistry.Terms({sourceId: bytes32("testFLR"), assetKey: bytes32(0), agentRef: bytes32(0), bond: address(bond)});
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

    /// @dev The accusation is a challenge too — it publishes the case and its accuser earns the
    ///      10% at resolution — so it goes through the same commit gate.
    function _arm(address who, uint256 mid, bytes32 txh) internal {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = txh;
        uint64 t = uint64(block.timestamp);
        vm.warp(t - bond.commitLead());
        bond.commitChallenge(bond.commitmentFor(who, mid, bond.KIND_UNANCHORED_DEED(), bond.deedsDigest(ids), SALT));
        vm.warp(t);
        rounds.setRoundStart(_proof().data.votingRound, t);
    }

    function _accuse() internal returns (uint256 id) {
        vm.warp(deedTime + GRACE + 1);
        _arm(challenger, mandateId, TXH);
        vm.prank(challenger);
        id = bond.accuseUnanchoredDeed{value: STAKE}(mandateId, _proof(), SALT);
    }

    // --- the deed nobody wrote down ---

    function test_silenceResolvesAgainstTheAgent() public {
        uint256 id = _accuse();
        vm.warp(block.timestamp + RESPONSE + 1);
        bond.resolveAccusation(id); // anyone may resolve
        assertTrue(bond.slashed(mandateId));
        assertFalse(reg.isLive(mandateId));
        // stake back + 10% of the bond, even though a stranger pressed the button
        assertEq(bond.owed(challenger), STAKE + 0.25 ether); // 1 of a budget of 4: a quarter of the bond, 10% of that
        assertEq(bond.owed(principal), 2.25 ether);
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

    // --- v0.9: two holes the invariant campaign found, both about an accusation left open ---

    function _accuseTx(address who, bytes32 txh) internal returns (uint256 id) {
        IEVMTransaction.Proof memory p = _proof();
        p.data.requestBody.transactionHash = txh;
        _arm(who, mandateId, txh);
        vm.deal(who, 1 ether);
        vm.prank(who);
        id = bond.accuseUnanchoredDeed{value: STAKE}(mandateId, p, SALT);
    }

    /// Two silent deeds, two accusers. The first resolution takes the bond; the second used to
    /// revert `AlreadySlashed` for ever, and since answering needs a leaf that by hypothesis does
    /// not exist, the second accuser's stake could never leave the contract.
    function test_secondAccusersStakeIsNotStrandedByTheFirstSlash() public {
        vm.warp(deedTime + GRACE + 1);
        address second = makeAddr("second watcher");
        uint256 a1 = _accuseTx(challenger, TXH);
        uint256 a2 = _accuseTx(second, keccak256("another silent deed"));
        vm.warp(block.timestamp + RESPONSE + 1);

        bond.resolveAccusation(a1);
        assertTrue(bond.slashed(mandateId));
        bond.resolveAccusation(a2); // must close, not revert
        // v0.9: and it is paid, because a second silent deed is a second lie — additive severity.
        // Each deed moved 1 under a budget of 4: the first verdict took 25% of the bond, the
        // second raised the total to 50%, and each accuser earns 10% of what its own verdict took.
        assertEq(bond.owed(second), STAKE + 0.25 ether, "stake back, plus 10% of the increment it proved");
        assertEq(bond.slashedAmount(mandateId), 5 ether);
        assertEq(bond.openAccusations(mandateId), 0);

        uint256 before = second.balance;
        vm.prank(second);
        bond.claim();
        assertEq(second.balance - before, STAKE + 0.25 ether);
    }

    /// The response window is as long as the cooling window, so an accusation filed late in the
    /// cooling window used to outlive the collateral: the principal withdrew, the resolution
    /// reverted `NothingToSlash`, the agent walked and the stake was stranded on top.
    function test_revert_withdrawWhileAnAccusationIsOpen() public {
        MandateRegistry.Mandate memory m = reg.get(mandateId);
        vm.warp(uint256(m.validUntil) + 23 hours); // dead, one hour of cooling window left
        _arm(challenger, mandateId, TXH);
        vm.prank(challenger);
        uint256 id = bond.accuseUnanchoredDeed{value: STAKE}(mandateId, _proof(), SALT);

        vm.warp(block.timestamp + 2 hours); // cooling window over, response window wide open
        vm.prank(principal);
        vm.expectRevert(Bond.AccusationOpen.selector);
        bond.withdraw(mandateId, payable(principal));

        vm.warp(block.timestamp + RESPONSE);
        bond.resolveAccusation(id);
        assertTrue(bond.slashed(mandateId));
        assertEq(bond.owed(challenger), STAKE + 0.25 ether); // 1 of a budget of 4: a quarter of the bond, 10% of that
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
        bond.accuseUnanchoredDeed{value: STAKE}(mandateId, _proof(), SALT);
    }

    /// An agent that never promised exclusivity cannot be asked to account for every deed:
    /// the address may be doing other, entirely legitimate things.
    function test_revert_accuseWithoutExclusivity() public {
        vm.prank(principal);
        uint256 other = reg.commit(
            agent, keccak256("non-exclusive"), 0, 0, 4 ether, uint64(block.timestamp), uint64(block.timestamp + 7 days), _terms()
        );
        vm.prank(agent);
        reg.acknowledge(other);
        vm.prank(principal);
        bond.post{value: 1 ether}(other);
        vm.warp(deedTime + GRACE + 1);
        vm.prank(challenger);
        vm.expectRevert(Bond.NotExclusive.selector);
        bond.accuseUnanchoredDeed{value: STAKE}(other, _proof(), SALT);
    }

    function test_revert_secondAccusationOnSameDeed() public {
        _accuse();
        vm.prank(challenger);
        vm.expectRevert(Bond.AlreadyAccused.selector);
        bond.accuseUnanchoredDeed{value: STAKE}(mandateId, _proof(), SALT);
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
        bond.accuseUnanchoredDeed{value: 1 wei}(mandateId, _proof(), SALT);
    }

    function test_revert_deedOutsideMandateWindow() public {
        IEVMTransaction.Proof memory p = _proof();
        p.data.responseBody.timestamp = uint64(block.timestamp - 1); // before validFrom
        vm.warp(block.timestamp + 2 hours);
        vm.prank(challenger);
        vm.expectRevert(Bond.ClaimOutsideProvenRange.selector);
        bond.accuseUnanchoredDeed{value: STAKE}(mandateId, p, SALT);
    }

    function test_revert_deedByAnotherAddress() public {
        IEVMTransaction.Proof memory p = _proof();
        p.data.responseBody.sourceAddress = makeAddr("someone else");
        vm.warp(deedTime + GRACE + 1);
        vm.prank(challenger);
        vm.expectRevert(Bond.NotAgentTx.selector);
        bond.accuseUnanchoredDeed{value: STAKE}(mandateId, p, SALT);
    }

    /// Exclusivity is the agent's own promise. Nobody else can make it for them.
    function test_revert_onlyAgentDeclaresExclusive() public {
        vm.prank(principal);
        uint256 other = reg.commit(
            agent, keccak256("x"), 0, 0, 1 ether, uint64(block.timestamp), uint64(block.timestamp + 1 days), _terms()
        );
        vm.prank(principal);
        vm.expectRevert(MandateRegistry.NotAgent.selector);
        reg.declareExclusive(other);
    }

    // --- commit–reveal (SPEC 6.7) on the accusation ---

    /// The gate sits on the accusation, not on `resolveAccusation`: the accusation is what makes the
    /// case public, and the reward follows `a.challenger`, so resolving stays open to anyone.
    function test_revert_accusationWithoutCommitment() public {
        vm.warp(deedTime + GRACE + 1);
        rounds.setRoundStart(_proof().data.votingRound, uint64(block.timestamp));
        vm.prank(challenger);
        vm.expectRevert(Bond.NoCommitment.selector);
        bond.accuseUnanchoredDeed{value: STAKE}(mandateId, _proof(), SALT);
    }

    /// A parasite watching FdcHub sees the deed's transaction hash in the attestation request and
    /// can copy the accusation wholesale. Its commitment is necessarily younger than the round.
    function test_revert_copiedAccusationWithALateCommitment() public {
        address parasite = makeAddr("mempool parasite");
        vm.deal(parasite, 10 ether);

        vm.warp(deedTime + GRACE + 1);
        _arm(challenger, mandateId, TXH); // the request has landed; the round began this second

        bytes32[] memory ids = new bytes32[](1);
        ids[0] = TXH;
        bond.commitChallenge(
            bond.commitmentFor(parasite, mandateId, bond.KIND_UNANCHORED_DEED(), bond.deedsDigest(ids), SALT)
        );
        vm.prank(parasite);
        vm.expectRevert(Bond.CommittedTooLate.selector);
        bond.accuseUnanchoredDeed{value: STAKE}(mandateId, _proof(), SALT);

        // the watcher that found it accuses, and still owns the reward when a stranger resolves
        vm.prank(challenger);
        uint256 id = bond.accuseUnanchoredDeed{value: STAKE}(mandateId, _proof(), SALT);
        vm.warp(block.timestamp + RESPONSE + 1);
        vm.prank(parasite);
        bond.resolveAccusation(id);
        assertEq(bond.owed(challenger), STAKE + 0.25 ether); // 1 of a budget of 4: a quarter of the bond, 10% of that
        assertEq(bond.owed(parasite), 0);
    }
}
