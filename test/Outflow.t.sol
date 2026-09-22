// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {MandateRegistry} from "../src/MandateRegistry.sol";
import {AnchorLog} from "../src/AnchorLog.sol";
import {AgentRefs} from "../src/AgentRefs.sol";
import {SpendMeter} from "../src/SpendMeter.sol";
import {Vault, IJudge} from "../src/Vault.sol";
import {JudgeEvm} from "../src/JudgeEvm.sol";
import {JudgeXrpl} from "../src/JudgeXrpl.sol";
import {DelictiErrors} from "../src/DelictiErrors.sol";
import {Receipts} from "../src/Receipts.sol";
import {Core} from "./Core.sol";
import {MockProtocolsV2} from "./Rounds.sol";
import {IFdcVerification} from "@flarenetwork/flare-periphery-contracts/coston2/IFdcVerification.sol";
import {IPayment} from "@flarenetwork/flare-periphery-contracts/coston2/IPayment.sol";
import {IBalanceDecreasingTransaction} from
    "@flarenetwork/flare-periphery-contracts/coston2/IBalanceDecreasingTransaction.sol";
import {IReferencedPaymentNonexistence} from
    "@flarenetwork/flare-periphery-contracts/coston2/IReferencedPaymentNonexistence.sol";
import {ProtocolsV2Interface} from "@flarenetwork/flare-periphery-contracts/coston2/ProtocolsV2Interface.sol";

contract MockFdcXrpl {
    bool public verdict = true;

    function setVerdict(bool v) external {
        verdict = v;
    }

    function verifyPayment(IPayment.Proof calldata) external view returns (bool) {
        return verdict;
    }

    function verifyBalanceDecreasingTransaction(IBalanceDecreasingTransaction.Proof calldata) external view returns (bool) {
        return verdict;
    }

    function verifyReferencedPaymentNonexistence(IReferencedPaymentNonexistence.Proof calldata) external view returns (bool) {
        return verdict;
    }
}

/// @title §6.10 — gross XRP outflow, judged with no receipt at all (v0.11)
contract OutflowTest is Test {
    MandateRegistry reg;
    AnchorLog anchorLog;
    Vault bond;
    JudgeEvm judge;
    JudgeXrpl xjudge;
    AgentRefs agentRefs;
    MockFdcXrpl mock;
    MockProtocolsV2 rounds;

    address principal = makeAddr("principal");
    address agent = makeAddr("agent");
    address challenger = makeAddr("challenger");
    address copier = makeAddr("copier");

    bytes32 constant SRC = bytes32("testXRP");
    bytes32 constant OUTFLOW = bytes32("XRP/outflow");
    bytes32 constant AGENT_XRPL = keccak256("rAgentAccountOnXrpl");
    uint256 constant EACH = 1_000_000; // 1 XRP in drops
    uint256 constant FEE = 12;
    uint256 constant BUDGET = 4_000_000;
    uint64 constant COMMIT_LEAD = 10 minutes;
    bytes32 constant SALT = keccak256("outflow watcher");

    uint256 mandateId;

    function setUp() public {
        vm.warp(1_800_000_000);
        reg = new MandateRegistry();
        anchorLog = new AnchorLog(reg);
        mock = new MockFdcXrpl();
        rounds = new MockProtocolsV2();
        agentRefs = new AgentRefs(reg, IFdcVerification(address(mock)));
        (bond, judge, xjudge) = Core.deploy(
            reg, anchorLog, IFdcVerification(address(mock)), 24 hours, 1 hours, new SpendMeter(reg),
            COMMIT_LEAD, ProtocolsV2Interface(address(rounds)), agentRefs, 5 minutes);
        vm.deal(principal, 100 ether);

        mandateId = _mandate(OUTFLOW);
        vm.prank(agent);
        reg.acknowledge(mandateId);
        agentRefs.proveExclusive(mandateId, _statement(mandateId, agentRefs.exclusiveFor(mandateId)));
        vm.prank(principal);
        bond.post{value: 10 ether}(mandateId);
    }

    // ------------------------------------------------------------------ helpers

    function _mandate(bytes32 assetKey) internal returns (uint256 id) {
        vm.prank(principal);
        id = reg.commit(
            agent, keccak256("may move up to 4 XRP out of its account"), 0, 0, BUDGET,
            uint64(block.timestamp), uint64(block.timestamp + 1 days),
            MandateRegistry.Terms({sourceId: SRC, assetKey: assetKey, agentRef: AGENT_XRPL, bond: address(bond)})
        );
    }

    /// A payment from the agent's account carrying `ref` — how the XRPL key makes a statement.
    function _statement(uint256, bytes32 ref) internal view returns (IPayment.Proof memory p) {
        p.data.attestationType = bytes32("Payment");
        p.data.sourceId = SRC;
        p.data.requestBody.transactionId = keccak256("statement tx");
        p.data.responseBody.blockTimestamp = uint64(block.timestamp);
        p.data.responseBody.sourceAddressHash = AGENT_XRPL;
        p.data.responseBody.receivingAddressHash = keccak256("rAnyone");
        p.data.responseBody.receivedAmount = 1000;
        p.data.responseBody.standardPaymentReference = ref;
        p.data.responseBody.oneToOne = true;
    }

    /// One attested decrease (or increase, if `spent` < 0) of the agent's balance.
    function _bdt(uint256 i, int256 spent, uint64 ts) internal pure returns (IBalanceDecreasingTransaction.Proof memory p) {
        p.data.attestationType = bytes32("BalanceDecreasingTransaction");
        p.data.sourceId = SRC;
        p.data.votingRound = 500;
        p.data.requestBody.transactionId = bytes32(uint256(0x1000 + i));
        p.data.requestBody.sourceAddressIndicator = AGENT_XRPL;
        p.data.responseBody.blockTimestamp = ts;
        p.data.responseBody.sourceAddressHash = AGENT_XRPL;
        p.data.responseBody.spentAmount = spent;
    }

    /// k payments of 1 XRP, each paying the fee: what the agent's own transactions look like.
    function _salami(uint256 k) internal view returns (IBalanceDecreasingTransaction.Proof[] memory pr) {
        pr = new IBalanceDecreasingTransaction.Proof[](k);
        for (uint256 i = 0; i < k; i++) {
            pr[i] = _bdt(i, int256(EACH + FEE), uint64(block.timestamp + i * 60));
        }
    }

    function _arm(address who, IBalanceDecreasingTransaction.Proof[] memory pr) internal {
        bytes32[] memory ids = new bytes32[](pr.length);
        for (uint256 i = 0; i < pr.length; i++) ids[i] = pr[i].data.requestBody.transactionId;
        uint64 t = uint64(block.timestamp);
        vm.warp(t - COMMIT_LEAD);
        bond.commitChallenge(bond.commitmentFor(who, mandateId, bond.KIND_XRP_OUTFLOW(), bond.deedsDigest(ids), SALT));
        vm.warp(t);
        rounds.setRoundStart(500, t);
    }

    function _challenge(address who, IBalanceDecreasingTransaction.Proof[] memory pr) internal {
        vm.prank(who);
        xjudge.challengeXrpOutflow(mandateId, pr, SALT);
    }

    // ------------------------------------------------------------------ the verdicts

    /// Five 1-XRP payments under a 4-XRP outflow budget. Fees count: the overrun is 1 XRP + 60 drops.
    function test_outflowSalamiSlashes() public {
        IBalanceDecreasingTransaction.Proof[] memory pr = _salami(5);
        _arm(challenger, pr);
        _challenge(challenger, pr);
        assertTrue(bond.slashed(mandateId));
        assertFalse(reg.isLive(mandateId));
        uint256 severity = 5 * (EACH + FEE) - BUDGET;
        assertEq(bond.severityOf(mandateId), severity);
        assertEq(bond.slashedAmount(mandateId), (10 ether * severity) / BUDGET);
    }

    /// Four payments that deliver EXACTLY the budget: under §6.8 they are inside it (fees are not
    /// counted); under this measure they are 48 drops over, and that is a verdict (the floor).
    function test_feesAreOutflow() public {
        IBalanceDecreasingTransaction.Proof[] memory pr = _salami(4);
        _arm(challenger, pr);
        _challenge(challenger, pr);
        assertEq(bond.severityOf(mandateId), 4 * FEE);
        assertEq(bond.slashedAmount(mandateId), 1 ether, "a 48-drop overrun costs the 10% floor");
    }

    /// The deed the agent never signed: its resting offer, consumed by someone else's OfferCreate.
    /// What arrives is an ordinary BDT proof for the TAKER's transaction id with the agent as the
    /// account asked about, and no fee (the taker paid it) — measured exactly so on 2026-09-20.
    function test_offerTakenInSomeoneElsesTransactionCounts() public {
        IBalanceDecreasingTransaction.Proof[] memory pr = new IBalanceDecreasingTransaction.Proof[](3);
        pr[0] = _bdt(0, int256(EACH + FEE), uint64(block.timestamp)); // own payment, 1 XRP
        pr[1] = _bdt(1, int256(EACH + FEE), uint64(block.timestamp + 60)); // own payment, 1 XRP
        pr[2] = _bdt(2, int256(5 * EACH), uint64(block.timestamp + 120)); // offer eaten by the taker: 5 XRP, no fee
        _arm(challenger, pr);
        _challenge(challenger, pr);
        assertEq(bond.severityOf(mandateId), 7 * EACH + 2 * FEE - BUDGET);
    }

    /// XRP that came back does not un-spend what left. Four outflows of 1 XRP + fee, and one
    /// transaction in which the account RECEIVED 3 XRP: gross outflow is still 48 drops over.
    function test_inflowsAreIgnored() public {
        IBalanceDecreasingTransaction.Proof[] memory pr = _salami(5);
        pr[4].data.responseBody.spentAmount = -3_000_000;
        _arm(challenger, pr);
        _challenge(challenger, pr);
        assertEq(bond.severityOf(mandateId), 4 * FEE);
    }

    /// Nested: a later, larger case takes the difference, never the sum.
    function test_largerCaseTakesTheDifference() public {
        IBalanceDecreasingTransaction.Proof[] memory five = _salami(5);
        _arm(challenger, five);
        _challenge(challenger, five);
        uint256 first = bond.slashedAmount(mandateId);

        vm.warp(block.timestamp + 2 hours);
        IBalanceDecreasingTransaction.Proof[] memory six = _salami(6);
        _arm(challenger, six);
        _challenge(challenger, six);
        uint256 severity = 6 * (EACH + FEE) - BUDGET;
        assertEq(bond.severityOf(mandateId), severity, "high-water mark, not a sum");
        assertEq(bond.slashedAmount(mandateId), (10 ether * severity) / BUDGET);
        assertGt(bond.slashedAmount(mandateId), first);
    }

    // ------------------------------------------------------------------ refusals

    function test_revert_withinBudget() public {
        IBalanceDecreasingTransaction.Proof[] memory pr = _salami(3);
        _arm(challenger, pr);
        vm.expectRevert(DelictiErrors.WithinBudget.selector);
        _challenge(challenger, pr);
    }

    function test_revert_noExclusivityFromTheXrplKey() public {
        uint256 id = _mandate(OUTFLOW);
        vm.prank(agent);
        reg.acknowledge(id);
        // plain control proof: the account confirmed the mandate but promised nothing about its outflow
        agentRefs.prove(id, _statement(id, agentRefs.challengeFor(id)));
        vm.prank(principal);
        bond.post{value: 1 ether}(id);
        // the EVM key promising exclusivity does not count either
        vm.prank(agent);
        reg.declareExclusive(id);
        vm.prank(challenger);
        vm.expectRevert(DelictiErrors.NotExclusiveOnXrpl.selector);
        xjudge.challengeXrpOutflow(id, _salami(5), SALT);
    }

    function test_revert_proofForAnotherAccount() public {
        IBalanceDecreasingTransaction.Proof[] memory pr = _salami(5);
        pr[2].data.requestBody.sourceAddressIndicator = keccak256("rSomebodyElse");
        vm.prank(challenger);
        vm.expectRevert(DelictiErrors.NotAgentTx.selector);
        xjudge.challengeXrpOutflow(mandateId, pr, SALT);

        pr = _salami(5);
        pr[2].data.responseBody.sourceAddressHash = keccak256("rSomebodyElse");
        vm.prank(challenger);
        vm.expectRevert(DelictiErrors.NotAgentTx.selector);
        xjudge.challengeXrpOutflow(mandateId, pr, SALT);
    }

    function test_revert_unorderedTxids() public {
        IBalanceDecreasingTransaction.Proof[] memory pr = _salami(5);
        (pr[1], pr[2]) = (pr[2], pr[1]);
        vm.prank(challenger);
        vm.expectRevert(DelictiErrors.UnorderedTxs.selector);
        xjudge.challengeXrpOutflow(mandateId, pr, SALT);

        pr = _salami(5);
        pr[3] = pr[2]; // the same transaction twice
        vm.prank(challenger);
        vm.expectRevert(DelictiErrors.UnorderedTxs.selector);
        xjudge.challengeXrpOutflow(mandateId, pr, SALT);
    }

    function test_revert_outsideTheWindow() public {
        IBalanceDecreasingTransaction.Proof[] memory pr = _salami(5);
        pr[0].data.responseBody.blockTimestamp = uint64(block.timestamp - 1);
        vm.prank(challenger);
        vm.expectRevert(DelictiErrors.ClaimOutsideProvenRange.selector);
        xjudge.challengeXrpOutflow(mandateId, pr, SALT);
    }

    function test_revert_wrongSourceOrInvalidProof() public {
        IBalanceDecreasingTransaction.Proof[] memory pr = _salami(5);
        pr[1].data.sourceId = bytes32("XRP");
        vm.prank(challenger);
        vm.expectRevert(DelictiErrors.WrongSource.selector);
        xjudge.challengeXrpOutflow(mandateId, pr, SALT);

        mock.setVerdict(false);
        vm.prank(challenger);
        vm.expectRevert(DelictiErrors.FdcProofInvalid.selector);
        xjudge.challengeXrpOutflow(mandateId, _salami(5), SALT);
    }

    /// The measure is the mandate's, not the challenger's: a delivered-amount mandate (§6.8) cannot
    /// be judged on outflow, and an outflow mandate cannot be judged on delivered payments.
    function test_revert_measureIsTheMandates() public {
        uint256 delivered = _mandate(bytes32(0));
        vm.prank(agent);
        reg.acknowledge(delivered);
        agentRefs.proveExclusive(delivered, _statement(delivered, agentRefs.exclusiveFor(delivered)));
        vm.prank(principal);
        bond.post{value: 1 ether}(delivered);
        vm.prank(challenger);
        vm.expectRevert(DelictiErrors.WrongAsset.selector);
        xjudge.challengeXrpOutflow(delivered, _salami(5), SALT);

        vm.prank(challenger);
        vm.expectRevert(DelictiErrors.WrongAsset.selector);
        xjudge.challengeBudgetOverrunPayment(
            mandateId, new uint256[](1), new Receipts.Leaf[](1), new bytes32[][](1), new IPayment.Proof[](1), SALT
        );
    }

    /// The copier sees the watcher's BDT requests land in FdcHub, commits, requests its own proofs of
    /// the same transactions, and reveals: its commitment is younger than the round by less than the lead.
    function test_revert_copierCommittedTooLate() public {
        IBalanceDecreasingTransaction.Proof[] memory pr = _salami(5);
        bytes32[] memory ids = new bytes32[](5);
        for (uint256 i = 0; i < 5; i++) ids[i] = pr[i].data.requestBody.transactionId;
        uint64 t = uint64(block.timestamp);
        vm.warp(t - 1 minutes);
        bond.commitChallenge(bond.commitmentFor(copier, mandateId, bond.KIND_XRP_OUTFLOW(), bond.deedsDigest(ids), SALT));
        vm.warp(t);
        rounds.setRoundStart(500, t);
        vm.prank(copier);
        vm.expectRevert(DelictiErrors.CommittedTooLate.selector);
        xjudge.challengeXrpOutflow(mandateId, pr, SALT);
    }

    /// A commitment for the §6.8 kind cannot be spent on §6.10, though the deed ids are the same.
    function test_revert_commitmentOfAnotherKind() public {
        IBalanceDecreasingTransaction.Proof[] memory pr = _salami(5);
        bytes32[] memory ids = new bytes32[](5);
        for (uint256 i = 0; i < 5; i++) ids[i] = pr[i].data.requestBody.transactionId;
        uint64 t = uint64(block.timestamp);
        vm.warp(t - COMMIT_LEAD);
        bond.commitChallenge(bond.commitmentFor(challenger, mandateId, bond.KIND_BUDGET_PAYMENT(), bond.deedsDigest(ids), SALT));
        vm.warp(t);
        rounds.setRoundStart(500, t);
        vm.prank(challenger);
        vm.expectRevert(DelictiErrors.NoCommitment.selector);
        xjudge.challengeXrpOutflow(mandateId, pr, SALT);
    }

    // ------------------------------------------------------------------ the XRPL key's statements

    function test_exclusivityImpliesControl_andIsSticky() public view {
        assertTrue(agentRefs.proven(mandateId));
        assertTrue(agentRefs.exclusive(mandateId));
    }

    function test_revert_exclusivityWithTheWrongMemo() public {
        uint256 id = _mandate(OUTFLOW);
        // (proofs built before expectRevert: a getter in the argument list would eat it)
        IPayment.Proof memory control = _statement(id, agentRefs.challengeFor(id));
        IPayment.Proof memory foreign = _statement(id, agentRefs.exclusiveFor(mandateId));
        // the control reference is not a promise of exclusivity
        vm.expectRevert(AgentRefs.ProofDoesNotMatchClaim.selector);
        agentRefs.proveExclusive(id, control);
        // nor is another mandate's exclusivity reference
        vm.expectRevert(AgentRefs.ProofDoesNotMatchClaim.selector);
        agentRefs.proveExclusive(id, foreign);
        assertFalse(agentRefs.exclusive(id));
    }

    function test_revert_exclusivityFromAnotherAccount() public {
        uint256 id = _mandate(OUTFLOW);
        IPayment.Proof memory p = _statement(id, agentRefs.exclusiveFor(id));
        p.data.responseBody.sourceAddressHash = keccak256("rSomebodyElse");
        vm.expectRevert(AgentRefs.NotAgentTx.selector);
        agentRefs.proveExclusive(id, p);
    }

    // ------------------------------------------------------------------ §6.1 still reaches an outflow mandate

    function test_falsePaymentOnAnOutflowMandate() public {
        Receipts.Leaf memory l = Receipts.Leaf({
            receiptHash: keccak256("receipt"),
            kind: Receipts.KIND_EXTERNAL_PAYMENT,
            sourceId: SRC,
            destinationAddressHash: keccak256("rMerchant"),
            amount: 2 * EACH,
            ref: keccak256("invoice"),
            claimedTimestamp: uint64(block.timestamp),
            mandateId: mandateId
        });
        vm.prank(agent);
        anchorLog.anchor(mandateId, Receipts.hashMem(l), 1);

        IReferencedPaymentNonexistence.Proof memory p;
        p.data.attestationType = bytes32("ReferencedPaymentNonexistence");
        p.data.sourceId = SRC;
        p.data.votingRound = 500;
        p.data.requestBody.destinationAddressHash = l.destinationAddressHash;
        p.data.requestBody.amount = l.amount;
        p.data.requestBody.standardPaymentReference = l.ref;
        p.data.requestBody.deadlineTimestamp = uint64(block.timestamp + 1 hours);
        p.data.responseBody.minimalBlockTimestamp = uint64(block.timestamp - 1 hours);
        p.data.responseBody.firstOverflowBlockTimestamp = uint64(block.timestamp + 2 hours);

        bytes32[] memory ids = new bytes32[](1);
        ids[0] = Receipts.hashMem(l);
        uint64 t = uint64(block.timestamp);
        vm.warp(t - COMMIT_LEAD);
        bond.commitChallenge(bond.commitmentFor(challenger, mandateId, bond.KIND_FALSE_PAYMENT(), bond.deedsDigest(ids), SALT));
        vm.warp(t);
        rounds.setRoundStart(500, t);
        vm.prank(challenger);
        judge.challengeFalsePayment(mandateId, 0, l, new bytes32[](0), p, SALT);
        assertTrue(bond.slashed(mandateId));
    }

    // ------------------------------------------------------------------ the verifier's horizon

    function test_fullyEnforceableReadsTheWindow() public {
        assertTrue(xjudge.fullyEnforceable(mandateId), "a one-day window fits");
        vm.prank(principal);
        uint256 long = reg.commit(
            agent, bytes32(0), 0, 0, BUDGET, uint64(block.timestamp), uint64(block.timestamp + 30 days),
            MandateRegistry.Terms({sourceId: SRC, assetKey: OUTFLOW, agentRef: AGENT_XRPL, bond: address(bond)})
        );
        assertFalse(xjudge.fullyEnforceable(long), "a 30-day window outlives the verifier's memory");
    }
}

/// @notice A judge that names some other vault.
contract StrayJudge {
    address public vault;

    constructor(address v) {
        vault = v;
    }
}

/// @title The Vault's gate: only the judges it was built with, and only judges that name it.
contract VaultGateTest is Test {
    MandateRegistry reg;
    AnchorLog anchorLog;
    Vault vault;
    JudgeEvm judge;
    JudgeXrpl xjudge;
    AgentRefs agentRefs;

    function setUp() public {
        reg = new MandateRegistry();
        anchorLog = new AnchorLog(reg);
        agentRefs = new AgentRefs(reg, IFdcVerification(address(0)));
        (vault, judge, xjudge) = Core.deploy(
            reg, anchorLog, IFdcVerification(address(0)), 24 hours, 1 hours, new SpendMeter(reg),
            10 minutes, ProtocolsV2Interface(address(new MockProtocolsV2())), agentRefs, 5 minutes);
    }

    function test_judgesAreTheOnesItWasBuiltWith() public view {
        address[] memory js = vault.judges();
        assertEq(js.length, 2);
        assertEq(js[0], address(judge));
        assertEq(js[1], address(xjudge));
        assertTrue(vault.isJudge(address(judge)) && vault.isJudge(address(xjudge)));
        assertEq(address(judge.vault()), address(vault));
        assertEq(address(xjudge.vault()), address(vault));
    }

    function test_revert_judgeOfAnotherVault() public {
        address[] memory js = new address[](2);
        js[0] = address(judge); // names `vault`, not the one being built
        js[1] = address(new StrayJudge(address(0xBEEF)));
        vm.expectRevert(DelictiErrors.JudgeOfAnotherVault.selector);
        new Vault(reg, agentRefs, ProtocolsV2Interface(address(0)), 10 minutes, js);
    }

    function test_revert_noJudges() public {
        vm.expectRevert(DelictiErrors.NoJudges.selector);
        new Vault(reg, agentRefs, ProtocolsV2Interface(address(0)), 10 minutes, new address[](0));
    }

    function test_revert_notAJudge() public {
        vm.expectRevert(DelictiErrors.NotJudge.selector);
        vault.verdict(2, 1, 1, 1, address(this), 1, bytes32(0), bytes32(0), true);
        vm.expectRevert(DelictiErrors.NotJudge.selector);
        vault.consumeCommitment(address(this), 2, 1, bytes32(0), bytes32(0), 0);
        vm.deal(address(this), 1 ether);
        vm.expectRevert(DelictiErrors.NotJudge.selector);
        vault.openAccusation{value: 0.1 ether}(1);
        vm.expectRevert(DelictiErrors.NotJudge.selector);
        vault.closeAccusation(1, address(this));
    }
}
