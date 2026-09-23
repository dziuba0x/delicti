// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
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
import {IPayment} from "@flarenetwork/flare-periphery-contracts/coston2/IPayment.sol";
import {ProtocolsV2Interface} from "@flarenetwork/flare-periphery-contracts/coston2/ProtocolsV2Interface.sol";
import {MockProtocolsV2} from "./Rounds.sol";

contract MockFdcPayment {
    bool public verdict = true;

    function setVerdict(bool v) external {
        verdict = v;
    }

    function verifyPayment(IPayment.Proof calldata) external view returns (bool) {
        return verdict;
    }
}

/// @title Deeds on XRPL (SPEC §6.8): who the agent is there, and how much it really paid.
contract XrplTest is Test {
    MandateRegistry reg;
    AnchorLog anchorLog;
    Vault bond;
    JudgeEvm judge;
    JudgeXrpl xjudge;
    MockFdcPayment mock;
    AgentRefs agentRefs;
    MockProtocolsV2 rounds;

    address principal = makeAddr("principal");
    address agent = makeAddr("agent");
    address challenger = makeAddr("challenger");

    bytes32 constant SRC = bytes32("testXRP");
    /// FDC standard address hash of an XRPL account: keccak256 of the r-address string.
    bytes32 constant AGENT_XRPL = keccak256("rAgentAccountOnXrpl");
    bytes32 constant MERCHANT_XRPL = keccak256("rMerchant");
    uint256 constant N = 5;
    uint256 constant EACH = 1_000_000; // 1 XRP, in drops
    uint256 constant BUDGET = 4_000_000;
    uint256 constant FEE = 12; // drops
    uint64 constant COMMIT_LEAD = 10 minutes;
    bytes32 constant SALT = keccak256("the watcher's salt");

    uint256 mandateId;
    Receipts.Leaf[] leaves;

    function setUp() public {
        reg = new MandateRegistry();
        anchorLog = new AnchorLog(reg);
        mock = new MockFdcPayment();
        rounds = new MockProtocolsV2();
        (bond, judge, xjudge) = Core.deploy(
            reg, anchorLog, IFdcVerification(address(mock)), 24 hours, 1 hours, new SpendMeter(reg),
            COMMIT_LEAD, ProtocolsV2Interface(address(rounds)), agentRefs = new AgentRefs(reg, IFdcVerification(address(mock))), 5 minutes);
        vm.warp(1_800_000_000);
        vm.deal(principal, 100 ether);

        mandateId = _mandate(AGENT_XRPL);
        vm.prank(agent);
        reg.acknowledge(mandateId);
        agentRefs.prove(mandateId, _controlProof(mandateId));
        vm.prank(principal);
        bond.post{value: 10 ether}(mandateId);

        for (uint256 i = 0; i < N; i++) {
            Receipts.Leaf memory l = Receipts.Leaf({
                receiptHash: keccak256(abi.encode("xrpl receipt", i)),
                kind: Receipts.KIND_EXTERNAL_PAYMENT,
                sourceId: SRC,
                destinationAddressHash: MERCHANT_XRPL,
                amount: EACH,
                ref: keccak256(abi.encode("invoice", i)),
                claimedTimestamp: uint64(block.timestamp + i * 60),
                mandateId: mandateId
            });
            leaves.push(l);
            vm.prank(agent);
            anchorLog.anchor(mandateId, Receipts.hashMem(l), 1);
        }
    }

    function _mandate(bytes32 agentRef) internal returns (uint256 id) {
        vm.prank(principal);
        id = reg.commit(
            agent, keccak256("may pay up to 4 XRP to rMerchant"), 0, 0, BUDGET,
            uint64(block.timestamp), uint64(block.timestamp + 1 days),
            MandateRegistry.Terms({sourceId: SRC, assetKey: bytes32(0), agentRef: agentRef, bond: address(bond)})
        );
    }

    function _payment(bytes32 txid, bytes32 from, bytes32 to, uint256 drops, bytes32 ref, uint64 ts)
        internal
        pure
        returns (IPayment.Proof memory p)
    {
        p.data.attestationType = bytes32("Payment");
        p.data.sourceId = SRC;
        p.data.votingRound = 500;
        p.data.requestBody.transactionId = txid;
        p.data.responseBody.blockTimestamp = ts;
        p.data.responseBody.sourceAddressHash = from;
        p.data.responseBody.receivingAddressHash = to;
        p.data.responseBody.intendedReceivingAddressHash = to;
        p.data.responseBody.spentAmount = int256(drops + FEE); // XRPL: what left the account includes the fee
        p.data.responseBody.intendedSpentAmount = int256(drops + FEE);
        p.data.responseBody.receivedAmount = int256(drops);
        p.data.responseBody.intendedReceivedAmount = int256(drops);
        p.data.responseBody.standardPaymentReference = ref;
        p.data.responseBody.oneToOne = true;
        p.data.responseBody.status = 0;
    }

    function _controlProof(uint256 id) internal view returns (IPayment.Proof memory) {
        return _payment(keccak256("control tx"), AGENT_XRPL, keccak256("rAnyone"), 1, agentRefs.challengeFor(id), uint64(block.timestamp));
    }

    function _proofFor(uint256 i) internal view returns (IPayment.Proof memory) {
        return _payment(bytes32(uint256(0x1000 + i)), AGENT_XRPL, MERCHANT_XRPL, EACH, leaves[i].ref, leaves[i].claimedTimestamp);
    }

    function _bundle(uint256 k)
        internal
        view
        returns (uint256[] memory idx, Receipts.Leaf[] memory ls, bytes32[][] memory paths, IPayment.Proof[] memory pr)
    {
        idx = new uint256[](k);
        ls = new Receipts.Leaf[](k);
        paths = new bytes32[][](k);
        pr = new IPayment.Proof[](k);
        for (uint256 i = 0; i < k; i++) {
            idx[i] = i;
            ls[i] = leaves[i];
            paths[i] = new bytes32[](0);
            pr[i] = _proofFor(i);
        }
    }

    function _arm(address who, uint256 mid, IPayment.Proof[] memory pr) internal {
        bytes32[] memory ids = new bytes32[](pr.length);
        for (uint256 i = 0; i < pr.length; i++) ids[i] = pr[i].data.requestBody.transactionId;
        uint64 t = uint64(block.timestamp);
        vm.warp(t - COMMIT_LEAD);
        bond.commitChallenge(bond.commitmentFor(who, mid, bond.KIND_BUDGET_PAYMENT(), bond.deedsDigest(ids), SALT));
        vm.warp(t);
        rounds.setRoundStart(500, t);
    }

    // ------------------------------------------------------------------ the salami, on XRPL

    // ------------------------------------------------------------------ v0.12: receipts keyed by transaction (x402 on XRPL)

    /// x402 on XRPL binds a payment with `InvoiceID`, which no FDC payment type returns — so the
    /// payments carry no memo, `standardPaymentReference` is zero, and the receipt names the
    /// transaction the facilitator reported instead (kind 4). The salami still convicts.
    function _x402Bundle()
        internal
        returns (uint256[] memory idx, Receipts.Leaf[] memory ls, bytes32[][] memory paths, IPayment.Proof[] memory pr)
    {
        idx = new uint256[](N);
        ls = new Receipts.Leaf[](N);
        paths = new bytes32[][](N);
        pr = new IPayment.Proof[](N);
        for (uint256 i = 0; i < N; i++) {
            bytes32 txid = bytes32(uint256(0x9000 + i));
            ls[i] = Receipts.Leaf({
                receiptHash: keccak256(abi.encode("x402-xrpl receipt", i)),
                kind: 4,
                sourceId: SRC,
                destinationAddressHash: MERCHANT_XRPL,
                amount: EACH,
                ref: txid,
                claimedTimestamp: uint64(block.timestamp + i * 60),
                mandateId: mandateId
            });
            vm.prank(agent);
            idx[i] = anchorLog.anchor(mandateId, Receipts.hashMem(ls[i]), 1);
            paths[i] = new bytes32[](0);
            pr[i] = _payment(txid, AGENT_XRPL, MERCHANT_XRPL, EACH, bytes32(0), ls[i].claimedTimestamp);
        }
    }

    /// Found by mutation testing (mewt, IF mutant on the kind check): no test pinned that a receipt
    /// of another kind — here an EVM-transaction receipt — is refused on the XRPL payment path.
    function test_revert_receiptOfAnotherKind() public {
        (uint256[] memory idx, Receipts.Leaf[] memory ls, bytes32[][] memory paths, IPayment.Proof[] memory pr) = _bundle(5);
        ls[1].kind = Receipts.KIND_EVM_TX;
        vm.prank(agent);
        idx[1] = anchorLog.anchor(mandateId, Receipts.hashMem(ls[1]), 1);
        vm.prank(challenger);
        vm.expectRevert(DelictiErrors.WrongReceiptKind.selector);
        xjudge.challengeBudgetOverrunPayment(mandateId, idx, ls, paths, pr, SALT);
    }

    function test_x402ReceiptsKeyedByTransactionConvict() public {
        (uint256[] memory idx, Receipts.Leaf[] memory ls, bytes32[][] memory paths, IPayment.Proof[] memory pr) = _x402Bundle();
        _arm(challenger, mandateId, pr);
        vm.prank(challenger);
        xjudge.challengeBudgetOverrunPayment(mandateId, idx, ls, paths, pr, SALT);
        assertTrue(bond.slashed(mandateId));
    }

    function test_revert_x402ReceiptForAnotherTransaction() public {
        (uint256[] memory idx, Receipts.Leaf[] memory ls, bytes32[][] memory paths, IPayment.Proof[] memory pr) = _x402Bundle();
        pr[4].data.requestBody.transactionId = bytes32(uint256(0x9100)); // still ascending, not the one the receipt names
        vm.prank(challenger);
        vm.expectRevert(DelictiErrors.ProofDoesNotMatchClaim.selector);
        xjudge.challengeBudgetOverrunPayment(mandateId, idx, ls, paths, pr, SALT);
    }

    /// A kind-4 receipt is not matched by memo: a proof whose reference happens to equal the
    /// receipt's `ref` but for a different transaction does not count.
    function test_revert_kind4IsNotMatchedByReference() public {
        (uint256[] memory idx, Receipts.Leaf[] memory ls, bytes32[][] memory paths, IPayment.Proof[] memory pr) = _x402Bundle();
        pr[0].data.responseBody.standardPaymentReference = ls[0].ref;
        pr[0].data.requestBody.transactionId = bytes32(uint256(0x8fff));
        vm.prank(challenger);
        vm.expectRevert(DelictiErrors.ProofDoesNotMatchClaim.selector);
        xjudge.challengeBudgetOverrunPayment(mandateId, idx, ls, paths, pr, SALT);
    }

    function test_xrplSalamiSlashes() public {
        (uint256[] memory idx, Receipts.Leaf[] memory ls, bytes32[][] memory paths, IPayment.Proof[] memory pr) = _bundle(5);
        _arm(challenger, mandateId, pr);
        vm.prank(challenger);
        xjudge.challengeBudgetOverrunPayment(mandateId, idx, ls, paths, pr, SALT);
        assertTrue(bond.slashed(mandateId));
        assertFalse(reg.isLive(mandateId));
    }

    function test_revert_fourPaymentsAreWithinBudget() public {
        (uint256[] memory idx, Receipts.Leaf[] memory ls, bytes32[][] memory paths, IPayment.Proof[] memory pr) = _bundle(4);
        _arm(challenger, mandateId, pr);
        vm.prank(challenger);
        vm.expectRevert(DelictiErrors.WithinBudget.selector);
        xjudge.challengeBudgetOverrunPayment(mandateId, idx, ls, paths, pr, SALT);
    }

    /// The fee leaves the account too, but it is not what the budget counts: four payments that
    /// deliver exactly the budget are inside it, although `spentAmount` sums to 48 drops more.
    function test_feesDoNotConvict() public {
        (uint256[] memory idx, Receipts.Leaf[] memory ls, bytes32[][] memory paths, IPayment.Proof[] memory pr) = _bundle(4);
        int256 spent;
        for (uint256 i = 0; i < 4; i++) spent += pr[i].data.responseBody.spentAmount;
        assertGt(uint256(spent), BUDGET, "the premise: with fees, the account lost more than the budget");
        _arm(challenger, mandateId, pr);
        vm.prank(challenger);
        vm.expectRevert(DelictiErrors.WithinBudget.selector);
        xjudge.challengeBudgetOverrunPayment(mandateId, idx, ls, paths, pr, SALT);
    }

    function test_revert_paymentFromAnotherAccount() public {
        (uint256[] memory idx, Receipts.Leaf[] memory ls, bytes32[][] memory paths, IPayment.Proof[] memory pr) = _bundle(5);
        pr[2].data.responseBody.sourceAddressHash = keccak256("rSomebodyElse");
        vm.prank(challenger);
        vm.expectRevert(DelictiErrors.NotAgentTx.selector);
        xjudge.challengeBudgetOverrunPayment(mandateId, idx, ls, paths, pr, SALT);
    }

    function test_revert_failedPayment() public {
        (uint256[] memory idx, Receipts.Leaf[] memory ls, bytes32[][] memory paths, IPayment.Proof[] memory pr) = _bundle(5);
        pr[1].data.responseBody.status = 2; // failed, receiver's fault: nothing was delivered
        vm.prank(challenger);
        vm.expectRevert(DelictiErrors.TxNotSuccessful.selector);
        xjudge.challengeBudgetOverrunPayment(mandateId, idx, ls, paths, pr, SALT);
    }

    function test_revert_paymentOutsideTheWindow() public {
        (uint256[] memory idx, Receipts.Leaf[] memory ls, bytes32[][] memory paths, IPayment.Proof[] memory pr) = _bundle(5);
        pr[0].data.responseBody.blockTimestamp = uint64(block.timestamp - 1);
        vm.prank(challenger);
        vm.expectRevert(DelictiErrors.ClaimOutsideProvenRange.selector);
        xjudge.challengeBudgetOverrunPayment(mandateId, idx, ls, paths, pr, SALT);
    }

    function test_revert_receiptDisagreesWithThePayment() public {
        (uint256[] memory idx, Receipts.Leaf[] memory ls, bytes32[][] memory paths, IPayment.Proof[] memory pr) = _bundle(5);
        pr[3].data.responseBody.receivedAmount = int256(EACH + 1);
        vm.prank(challenger);
        vm.expectRevert(DelictiErrors.ProofDoesNotMatchClaim.selector);
        xjudge.challengeBudgetOverrunPayment(mandateId, idx, ls, paths, pr, SALT);

        (,,, pr) = _bundle(5);
        pr[3].data.responseBody.standardPaymentReference = keccak256("some other invoice");
        vm.prank(challenger);
        vm.expectRevert(DelictiErrors.ProofDoesNotMatchClaim.selector);
        xjudge.challengeBudgetOverrunPayment(mandateId, idx, ls, paths, pr, SALT);

        (,,, pr) = _bundle(5);
        pr[3].data.responseBody.receivingAddressHash = keccak256("rSomewhereElse");
        vm.prank(challenger);
        vm.expectRevert(DelictiErrors.ProofDoesNotMatchClaim.selector);
        xjudge.challengeBudgetOverrunPayment(mandateId, idx, ls, paths, pr, SALT);
    }

    function test_revert_samePaymentTwice() public {
        (uint256[] memory idx, Receipts.Leaf[] memory ls, bytes32[][] memory paths, IPayment.Proof[] memory pr) = _bundle(5);
        pr[4] = pr[3];
        ls[4] = ls[3];
        idx[4] = idx[3];
        vm.prank(challenger);
        vm.expectRevert(DelictiErrors.DuplicateLeaf.selector);
        xjudge.challengeBudgetOverrunPayment(mandateId, idx, ls, paths, pr, SALT);
    }

    /// The leaf does not carry the transaction id, so — unlike the EVM paths — two distinct payments
    /// do not imply two distinct receipts. One receipt must not account for two payments: the agent
    /// wrote down one deed, and only what it wrote down is its claim.
    function test_revert_oneReceiptCannotAccountForTwoPayments() public {
        (uint256[] memory idx, Receipts.Leaf[] memory ls, bytes32[][] memory paths, IPayment.Proof[] memory pr) = _bundle(5);
        ls[4] = ls[3];
        idx[4] = idx[3];
        // a second, genuinely different payment with the same destination, amount and reference
        pr[4] = _payment(bytes32(uint256(0x2000)), AGENT_XRPL, MERCHANT_XRPL, EACH, leaves[3].ref, leaves[3].claimedTimestamp);
        vm.prank(challenger);
        vm.expectRevert(DelictiErrors.DuplicateLeaf.selector);
        xjudge.challengeBudgetOverrunPayment(mandateId, idx, ls, paths, pr, SALT);
    }

    function test_revert_aUtxoStyleManyToManyPayment() public {
        (uint256[] memory idx, Receipts.Leaf[] memory ls, bytes32[][] memory paths, IPayment.Proof[] memory pr) = _bundle(5);
        pr[0].data.responseBody.oneToOne = false;
        vm.prank(challenger);
        vm.expectRevert(DelictiErrors.TxNotSuccessful.selector);
        xjudge.challengeBudgetOverrunPayment(mandateId, idx, ls, paths, pr, SALT);
    }

    function test_revert_paymentOnAnotherLedger() public {
        (uint256[] memory idx, Receipts.Leaf[] memory ls, bytes32[][] memory paths, IPayment.Proof[] memory pr) = _bundle(5);
        pr[0].data.sourceId = bytes32("XRP"); // mainnet proof against a testnet mandate
        vm.prank(challenger);
        vm.expectRevert(DelictiErrors.ProofDoesNotMatchClaim.selector); // the leaf says testXRP
        xjudge.challengeBudgetOverrunPayment(mandateId, idx, ls, paths, pr, SALT);
    }

    function test_revert_mandateWithNoXrplIdentity() public {
        uint256 id = _mandate(bytes32(0));
        vm.prank(agent);
        reg.acknowledge(id);
        vm.prank(principal);
        bond.post{value: 1 ether}(id);
        (uint256[] memory idx, Receipts.Leaf[] memory ls, bytes32[][] memory paths, IPayment.Proof[] memory pr) = _bundle(5);
        vm.prank(challenger);
        vm.expectRevert(DelictiErrors.NoAgentRef.selector);
        xjudge.challengeBudgetOverrunPayment(id, idx, ls, paths, pr, SALT);
    }

    function test_revert_copiedRevealWithALateCommitment() public {
        (uint256[] memory idx, Receipts.Leaf[] memory ls, bytes32[][] memory paths, IPayment.Proof[] memory pr) = _bundle(5);
        bytes32[] memory ids = new bytes32[](5);
        for (uint256 i = 0; i < 5; i++) ids[i] = pr[i].data.requestBody.transactionId;
        rounds.setRoundStart(500, uint64(block.timestamp));
        address copier = makeAddr("copier");
        bond.commitChallenge(bond.commitmentFor(copier, mandateId, bond.KIND_BUDGET_PAYMENT(), bond.deedsDigest(ids), SALT));
        vm.prank(copier);
        vm.expectRevert(DelictiErrors.CommittedTooLate.selector);
        xjudge.challengeBudgetOverrunPayment(mandateId, idx, ls, paths, pr, SALT);
    }

    /// The good case leaves a trace too: a payment that happened exactly as the receipt says.
    function test_xrplPaymentCorroborated() public {
        CorroborationLog corr = new CorroborationLog(reg, anchorLog, IFdcVerification(address(mock)));
        IPayment.Proof memory p = _proofFor(1);
        corr.corroboratePayment(mandateId, 1, leaves[1], new bytes32[](0), p);
        assertEq(corr.valueOf(mandateId), EACH);
        // one effect, one corroboration — even through a second receipt describing the same payment
        vm.expectRevert(CorroborationLog.AlreadyCorroborated.selector);
        corr.corroboratePayment(mandateId, 1, leaves[1], new bytes32[](0), p);
    }

    // ------------------------------------------------------------------ whose account is it

    /// The principal writes `agentRef`. Until the XRPL account itself has said yes, collateral under
    /// the mandate would insure whoever happens to own that account.
    function test_revert_postBeforeTheXrplAccountConfirmed() public {
        uint256 id = _mandate(keccak256("rSomeExchangeHotWallet"));
        vm.prank(agent);
        reg.acknowledge(id); // the EVM key says yes — which shows nothing about the XRPL key
        vm.prank(principal);
        vm.expectRevert(DelictiErrors.AgentRefNotProven.selector);
        bond.post{value: 1 ether}(id);
    }

    function test_revert_controlProofFromAnotherAccount() public {
        uint256 id = _mandate(keccak256("rSomeExchangeHotWallet"));
        IPayment.Proof memory p = _controlProof(id); // built first: a getter in the argument list eats expectRevert
        vm.expectRevert(AgentRefs.NotAgentTx.selector);
        agentRefs.prove(id, p); // paid by AGENT_XRPL, not by the account named
    }

    /// The reference binds chain, registry and mandate: a confirmation given for one mandate is not
    /// a confirmation of the next one the same principal writes.
    function test_revert_controlProofReplayedForAnotherMandate() public {
        uint256 id = _mandate(AGENT_XRPL);
        IPayment.Proof memory p = _controlProof(mandateId);
        vm.expectRevert(DelictiErrors.ProofDoesNotMatchClaim.selector);
        agentRefs.prove(id, p);
        assertFalse(agentRefs.proven(id));
    }

    function test_revert_controlProofTheFdcRejects() public {
        uint256 id = _mandate(AGENT_XRPL);
        mock.setVerdict(false);
        IPayment.Proof memory p = _controlProof(id);
        vm.expectRevert(DelictiErrors.FdcProofInvalid.selector);
        agentRefs.prove(id, p);
    }
}
