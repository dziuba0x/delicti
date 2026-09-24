// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IFdcVerification} from "@flarenetwork/flare-periphery-contracts/coston2/IFdcVerification.sol";
import {IPayment} from "@flarenetwork/flare-periphery-contracts/coston2/IPayment.sol";
import {IBalanceDecreasingTransaction} from
    "@flarenetwork/flare-periphery-contracts/coston2/IBalanceDecreasingTransaction.sol";
import {ContractRegistry} from "@flarenetwork/flare-periphery-contracts/coston2/ContractRegistry.sol";
import {MandateRegistry} from "./MandateRegistry.sol";
import {AnchorLog} from "./AnchorLog.sol";
import {AgentRefs} from "./AgentRefs.sol";
import {Receipts} from "./Receipts.sol";
import {Merkle} from "./Merkle.sol";
import {Deeds} from "./Deeds.sol";
import {Kinds} from "./Kinds.sol";
import {Vault} from "./Vault.sol";
import {DelictiErrors} from "./DelictiErrors.sol";

/// @title JudgeXrpl — the challenges over deeds done on XRPL
/// @notice §6.8 budget overrun over `Payment`s the agent wrote receipts for (moved from `Bond`
///         unchanged), and §6.10, new in v0.11: budget overrun over the account's GROSS XRP OUTFLOW,
///         proven by `BalanceDecreasingTransaction` with no receipt at all. No funds, no state.
contract JudgeXrpl is DelictiErrors {
    Vault public immutable vault;
    MandateRegistry public immutable registry;
    AnchorLog public immutable log;
    AgentRefs public immutable agentRefs;
    IFdcVerification private immutable _fdcOverride; // 0 => resolve via ContractRegistry

    /// @notice How far back the FDC's XRP verifier can still attest a transaction, conservatively.
    /// @dev    Observed 2026-09-20: the verifier indexes ~15 days back and `XRPPayment` declares a
    ///         lowest-used-timestamp limit of 14 days. A cumulative challenge needs EVERY deed it
    ///         sums to still be provable when it is brought, so over a mandate window longer than
    ///         this the early deeds age out and an overrun made late in the window may be
    ///         unprovable. Not enforced — refusing long mandates would make them immune, which is
    ///         worse — but readable, so a depositor can see it before posting (`fullyEnforceable`).
    ///         SPEC §10.
    uint64 public constant PROOF_HORIZON = 14 days;

    event DeedJudged(uint256 indexed mandateId, uint8 indexed kind, bytes32 indexed deedId, uint256 value);
    event BudgetOverrunProven(
        uint256 indexed mandateId, uint256 spent, uint256 budget, uint256 deeds, address indexed challenger, uint256 slashedAmount
    );
    event XrpOutflowProven(
        uint256 indexed mandateId, uint256 outflow, uint256 budget, uint256 deeds, address indexed challenger, uint256 slashedAmount
    );

    constructor(Vault vault_, MandateRegistry _registry, AnchorLog _log, IFdcVerification fdcOverride, AgentRefs agentRefs_) {
        vault = vault_;
        registry = _registry;
        log = _log;
        _fdcOverride = fdcOverride;
        agentRefs = agentRefs_;
    }

    function fdc() public view returns (IFdcVerification) {
        if (address(_fdcOverride) != address(0)) return _fdcOverride;
        return ContractRegistry.getFdcVerification();
    }

    /// @notice Whether the mandate's whole window fits inside the verifier's memory. Since v0.12 a
    ///         longer window is still enforceable through the docket — but only if every deed is
    ///         filed within `PROOF_HORIZON` of happening. `false` means: somebody has to keep filing.
    function fullyEnforceable(uint256 mandateId) external view returns (bool) {
        MandateRegistry.Mandate memory m = registry.get(mandateId);
        return m.validUntil - m.validFrom <= PROOF_HORIZON;
    }

    // -----------------------------------------------------------------------------------
    // §6.8 Budget overrun over receipted Payments
    // -----------------------------------------------------------------------------------

    /// @notice STRUCTURING on XRPL. N anchored kind-3 leaves, each with a positive FDC `Payment`
    ///         attestation from the mandate's account; `Σ receivedAmount > budget`. Commitment kind 6.
    function challengeBudgetOverrunPayment(
        uint256 mandateId,
        uint256[] calldata episodeIndices,
        Receipts.Leaf[] calldata leaves,
        bytes32[][] calldata merkleProofs,
        IPayment.Proof[] calldata fdcProofs,
        bytes32 salt
    ) external {
        if (vault.bondOf(mandateId) == 0) revert NothingToSlash();
        uint256 n = leaves.length;
        if (n == 0 || episodeIndices.length != n || merkleProofs.length != n || fdcProofs.length != n) {
            revert LengthMismatch();
        }
        MandateRegistry.Mandate memory m = registry.get(mandateId);
        if (m.agentRef == bytes32(0)) revert NoAgentRef();
        if (m.assetKey != bytes32(0)) revert WrongAsset(); // delivered XRP only; outflow is §6.10

        uint256 spent;
        bytes32[] memory ids = new bytes32[](n);
        bytes32[] memory leafHashes = new bytes32[](n);
        uint64 minRound = type(uint64).max;
        for (uint256 i = 0; i < n; i++) {
            Receipts.Leaf calldata leaf = leaves[i];
            leafHashes[i] = _witnessOne(mandateId, episodeIndices[i], leaf, merkleProofs[i], leafHashes, i);

            IPayment.Proof calldata pr = fdcProofs[i];
            bytes32 txid = pr.data.requestBody.transactionId;
            if (i != 0 && txid <= ids[i - 1]) revert UnorderedTxs();
            ids[i] = txid;
            if (pr.data.votingRound < minRound) minRound = pr.data.votingRound;
            uint256 v = Deeds.payment(fdc(), pr, leaf, m);
            spent += v;
            emit DeedJudged(mandateId, Kinds.BUDGET_PAYMENT, txid, v);
        }
        vault.consumeCommitment(msg.sender, Kinds.BUDGET_PAYMENT, mandateId, keccak256(abi.encode(ids)), salt, minRound);
        if (spent <= m.budget) revert WithinBudget();

        uint256 taken = vault.verdict(
            Kinds.BUDGET_PAYMENT, mandateId, m.budget, spent - m.budget, msg.sender, n, fdcProofs[0].data.attestationType, m.sourceId, true
        );
        emit BudgetOverrunProven(mandateId, spent, m.budget, n, msg.sender, taken);
    }

    // -----------------------------------------------------------------------------------
    // §6.8 on a docket (v0.12+). The same case as `challengeBudgetOverrunPayment`, filed the way
    // §6.10 is: each receipted payment once, while the verifier can still prove it, counted for ever
    // after. Below the budget a filing only records; the crossing filing is the committed conviction.
    // Nested with every other budget kind, so it and the one-shot path can never double-count.
    // -----------------------------------------------------------------------------------

    mapping(uint256 => uint256) public paymentDocket;
    /// @notice mandateId => payment transaction id => on the docket
    mapping(uint256 => mapping(bytes32 => bool)) public paymentFiled;
    /// @notice mandateId => receipt leaf hash => on the docket (one receipt accounts for one payment)
    mapping(uint256 => mapping(bytes32 => bool)) public receiptFiled;

    event PaymentsFiled(uint256 indexed mandateId, address indexed filer, uint256 added, uint256 docketTotal, uint256 newDeeds);

    function fileBudgetPayments(
        uint256 mandateId,
        uint256[] calldata episodeIndices,
        Receipts.Leaf[] calldata leaves,
        bytes32[][] calldata merkleProofs,
        IPayment.Proof[] calldata fdcProofs,
        bytes32 salt
    ) external {
        if (vault.bondOf(mandateId) == 0) revert NothingToSlash();
        uint256 n = leaves.length;
        if (n == 0 || episodeIndices.length != n || merkleProofs.length != n || fdcProofs.length != n) {
            revert LengthMismatch();
        }
        MandateRegistry.Mandate memory m = registry.get(mandateId);
        if (m.agentRef == bytes32(0)) revert NoAgentRef();
        if (m.assetKey != bytes32(0)) revert WrongAsset();

        uint256 added;
        uint256 fresh;
        uint256 paid; // new deeds that moved at least the watch pool's minimum (§8.4)
        uint256 minV = vault.stipendMinValue(mandateId);
        uint64 minRound = type(uint64).max;
        bytes32[] memory ids = new bytes32[](n);
        for (uint256 i = 0; i < n; i++) {
            bytes32 txid = fdcProofs[i].data.requestBody.transactionId;
            if (i != 0 && txid <= ids[i - 1]) revert UnorderedTxs();
            ids[i] = txid;
            if (paymentFiled[mandateId][txid]) continue; // already counted: skipped, not refused
            uint256 v = _filePayment(mandateId, episodeIndices[i], leaves[i], merkleProofs[i], fdcProofs[i], m);
            added += v;
            fresh++;
            if (v != 0 && v >= minV) paid++;
            if (fdcProofs[i].data.votingRound < minRound) minRound = fdcProofs[i].data.votingRound;
        }
        if (fresh == 0) revert NothingNew();
        uint256 before = paymentDocket[mandateId];
        uint256 total = before + added;
        paymentDocket[mandateId] = total;
        emit PaymentsFiled(mandateId, msg.sender, added, total, fresh);
        vault.stipend(mandateId, msg.sender, paid);
        if (total <= m.budget || total == before) return;
        // Past the budget, but not past what the bucket's verdicts already measured (another path —
        // the one-shot challenge, a receipted case — may have convicted further): a recording, and
        // it must stay one. Before v0.14 this reached `verdict`, which refused it `NothingNew`, and
        // the docket could not record at all until one filing alone outran the high-water mark.
        // Found by the §6.8 invariant track.
        if (total - m.budget <= vault.severityIn(mandateId, Kinds.BUDGET_NATIVE)) return;

        vault.consumeCommitment(msg.sender, Kinds.BUDGET_PAYMENT, mandateId, keccak256(abi.encode(ids)), salt, minRound);
        // not strict: a crossing that raises the severity after the bond's base is already all taken
        // still records; the filer committed to it and is paid what there is, possibly nothing
        uint256 taken = vault.verdict(
            Kinds.BUDGET_PAYMENT, mandateId, m.budget, total - m.budget, msg.sender, fresh, bytes32("Payment"), m.sourceId, false
        );
        emit BudgetOverrunProven(mandateId, total, m.budget, fresh, msg.sender, taken);
    }

    /// @dev One receipted payment onto the docket: both witnesses, and the receipt used once.
    function _filePayment(
        uint256 mandateId,
        uint256 episodeIndex,
        Receipts.Leaf calldata leaf,
        bytes32[] calldata path,
        IPayment.Proof calldata pr,
        MandateRegistry.Mandate memory m
    ) internal returns (uint256 v) {
        bytes32 leafHash = _witnessOne(mandateId, episodeIndex, leaf, path, new bytes32[](0), 0);
        if (receiptFiled[mandateId][leafHash]) revert DuplicateLeaf();
        receiptFiled[mandateId][leafHash] = true;
        paymentFiled[mandateId][pr.data.requestBody.transactionId] = true;
        v = Deeds.payment(fdc(), pr, leaf, m);
        emit DeedJudged(mandateId, Kinds.BUDGET_PAYMENT, pr.data.requestBody.transactionId, v);
    }

    /// @dev Witness 1 for §6.8: a receipt of kind 3 (named by memo reference) or 4 (v0.12, named by
    ///      transaction id — the only handle an x402-on-XRPL facilitator gives back), naming this
    ///      mandate, anchored, and distinct from the receipts before it.
    function _witnessOne(
        uint256 mandateId,
        uint256 episodeIndex,
        Receipts.Leaf calldata leaf,
        bytes32[] calldata path,
        bytes32[] memory seen,
        uint256 i
    ) internal view returns (bytes32 leafHash) {
        if (leaf.kind != Receipts.KIND_EXTERNAL_PAYMENT && leaf.kind != Receipts.KIND_EXTERNAL_TX) {
            revert WrongReceiptKind();
        }
        if (leaf.mandateId != mandateId) revert ProofDoesNotMatchClaim();
        leafHash = Receipts.hash(leaf);
        for (uint256 j = 0; j < i; j++) {
            if (seen[j] == leafHash) revert DuplicateLeaf();
        }
        if (!Merkle.verify(path, log.episode(mandateId, episodeIndex).root, leafHash)) revert LeafNotAnchored();
    }

    // -----------------------------------------------------------------------------------
    // §6.10 Gross XRP outflow — the agent convicted without a single receipt
    //
    // `BalanceDecreasingTransaction` is keyed by (transaction, account), not by "the account's own
    // transactions": it attests how much a given account's XRP balance fell in a given transaction,
    // whoever signed it. Measured on Coston2 (2026-09-20, docs/DEPLOYMENTS.md): an offer resting in
    // the book and consumed by ANOTHER account's OfferCreate is a verified 9,000,000-drop outflow of
    // the offer's owner. So every way XRP leaves an account — Payment, an offer crossed at once or
    // taken later, escrow, AMM deposit, a check someone else cashes, AccountDelete — is provable.
    //
    // Why a conviction for a transaction the agent did not sign is sound: on XRPL nothing but the
    // account's own keys can make its XRP balance fall. Every path in which someone else's
    // transaction moves it — an offer, a check, an escrow, a delegation — starts from an object the
    // account created or a permission it granted. Clawback exists only for issued currencies.
    //
    // No receipts, so the account must have promised that everything leaving it inside the window
    // is this mandate's business — and promised it with the XRPL key (`AgentRefs.proveExclusive`).
    // -----------------------------------------------------------------------------------

    /// @notice The docket: gross outflow of each mandate's account proven so far, and which
    ///         transactions it already counts (v0.12, SPEC §6.10).
    /// @dev    Why it exists. The FDC's XRP verifier remembers ~14 days, so a cumulative case that
    ///         had to re-prove every deed at once died with the oldest one: an agent spending 90% of
    ///         a 30-day budget on day 1 and overrunning on day 20 was out of reach. A docket turns
    ///         the case into a file that grows — each deed proven once, while it can still be
    ///         proven, and counted for ever after.
    mapping(uint256 => uint256) public docket;
    mapping(uint256 => mapping(bytes32 => bool)) public filed;

    event OutflowFiled(uint256 indexed mandateId, address indexed filer, uint256 added, uint256 docketTotal, uint256 newDeeds);

    /// @notice File BDT proofs of the mandate's account's outflow on its docket. Below the budget
    ///         this only records, and needs no commitment — anyone can keep a docket current, and
    ///         nothing is paid for it. The filing that takes the docket PAST the budget is a
    ///         conviction, and that one must be committed (kind 7, digest over every transaction id
    ///         it supplies, ascending), exactly like any other challenge.
    /// @dev    - Proofs already on the docket are skipped, not refused. A copier who sees an honest
    ///           filing in the mempool can front-run part of it as a non-crossing filing (that
    ///           needs no commitment), but the honest transaction still lands: its digest is over
    ///           the ids it supplied, the skipped ones still count through the docket, and the
    ///           crossing — the only thing that pays — happens in its transaction.
    ///         - A filing that adds nothing reverts `NothingNew`.
    ///         - Only POSITIVE `spentAmount`s count: a budget of outflow limits what left; XRP that
    ///           came back does not un-spend it. Fees count: the agent paid them.
    ///         - The crossing filer is reimbursed for the attestations IT supplied (new proofs only)
    ///           and earns 10% of the rest. Filers below the budget are paid nothing — keeping a
    ///           docket is a public good today, and SPEC §10 says so.
    function fileXrpOutflow(uint256 mandateId, IBalanceDecreasingTransaction.Proof[] calldata fdcProofs, bytes32 salt)
        external
    {
        if (vault.bondOf(mandateId) == 0) revert NothingToSlash();
        uint256 n = fdcProofs.length;
        if (n == 0) revert LengthMismatch();
        MandateRegistry.Mandate memory m = registry.get(mandateId);
        if (m.agentRef == bytes32(0)) revert NoAgentRef();
        if (m.assetKey != Kinds.XRP_OUTFLOW_KEY) revert WrongAsset();
        if (!agentRefs.exclusive(mandateId)) revert NotExclusiveOnXrpl();

        (uint256 added, uint256 fresh, uint256 paid, uint64 minRound, bytes32[] memory ids) = _file(mandateId, fdcProofs, m);
        if (fresh == 0) revert NothingNew();
        uint256 before = docket[mandateId];
        uint256 total = before + added;
        docket[mandateId] = total;
        emit OutflowFiled(mandateId, msg.sender, added, total, fresh);
        vault.stipend(mandateId, msg.sender, paid);
        if (total <= m.budget || total == before) return; // recorded; nothing to judge yet
        // Past the budget, but not past what the bucket's verdicts already measured (another path —
        // the one-shot challenge, a receipted case — may have convicted further): a recording, and
        // it must stay one. Before v0.14 this reached `verdict`, which refused it `NothingNew`, and
        // the docket could not record at all until one filing alone outran the high-water mark.
        // Found by the §6.8 invariant track.
        if (total - m.budget <= vault.severityIn(mandateId, Kinds.BUDGET_NATIVE)) return;

        vault.consumeCommitment(msg.sender, Kinds.XRP_OUTFLOW, mandateId, keccak256(abi.encode(ids)), salt, minRound);
        uint256 taken = vault.verdict(
            Kinds.XRP_OUTFLOW, mandateId, m.budget, total - m.budget, msg.sender, fresh, bytes32("BalanceDecreasingTransaction"), m.sourceId, false
        );
        emit XrpOutflowProven(mandateId, total, m.budget, fresh, msg.sender, taken);
    }

    /// @dev Verifies and dockets every proof not yet filed. Returns what they add, how many were new,
    ///      the lowest voting round AMONG THE NEW ONES (a skipped proof is not verified here, so its
    ///      round is not evidence), and every supplied id in order, for the commitment digest.
    function _file(uint256 mandateId, IBalanceDecreasingTransaction.Proof[] calldata fdcProofs, MandateRegistry.Mandate memory m)
        internal
        returns (uint256 added, uint256 fresh, uint256 paid, uint64 minRound, bytes32[] memory ids)
    {
        uint256 n = fdcProofs.length;
        ids = new bytes32[](n);
        minRound = type(uint64).max;
        uint256 minV = vault.stipendMinValue(mandateId);
        for (uint256 i = 0; i < n; i++) {
            IBalanceDecreasingTransaction.Proof calldata pr = fdcProofs[i];
            bytes32 txid = pr.data.requestBody.transactionId;
            if (i != 0 && txid <= ids[i - 1]) revert UnorderedTxs();
            ids[i] = txid;
            if (filed[mandateId][txid]) continue;
            uint256 out = _outflow(pr, m);
            filed[mandateId][txid] = true;
            fresh++;
            added += out;
            // an inflow (anyone can send the agent XRP) is a provable deed that moved nothing out
            if (out != 0 && out >= minV) paid++;
            if (pr.data.votingRound < minRound) minRound = pr.data.votingRound;
            emit DeedJudged(mandateId, Kinds.XRP_OUTFLOW, txid, out);
        }
    }

    /// @dev One attested balance decrease of the mandate's account inside its window. Returns what
    ///      left the account in that transaction; an inflow counts as nothing.
    function _outflow(IBalanceDecreasingTransaction.Proof calldata pr, MandateRegistry.Mandate memory m)
        internal
        view
        returns (uint256)
    {
        if (!fdc().verifyBalanceDecreasingTransaction(pr)) revert FdcProofInvalid();
        if (pr.data.sourceId != m.sourceId) revert WrongSource();
        // The request names the account whose balance is asked about, and the response says whose
        // balance it answered for. Both must be the mandate's account.
        if (pr.data.requestBody.sourceAddressIndicator != m.agentRef) revert NotAgentTx();
        IBalanceDecreasingTransaction.ResponseBody calldata rb = pr.data.responseBody;
        if (rb.sourceAddressHash != m.agentRef) revert NotAgentTx();
        if (rb.blockTimestamp < m.validFrom || rb.blockTimestamp > m.validUntil) revert ClaimOutsideProvenRange();
        return rb.spentAmount > 0 ? uint256(rb.spentAmount) : 0;
    }
}
