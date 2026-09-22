// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IFdcVerification} from "@flarenetwork/flare-periphery-contracts/coston2/IFdcVerification.sol";
import {IReferencedPaymentNonexistence} from
    "@flarenetwork/flare-periphery-contracts/coston2/IReferencedPaymentNonexistence.sol";
import {IEVMTransaction} from "@flarenetwork/flare-periphery-contracts/coston2/IEVMTransaction.sol";
import {ContractRegistry} from "@flarenetwork/flare-periphery-contracts/coston2/ContractRegistry.sol";
import {MandateRegistry} from "./MandateRegistry.sol";
import {AnchorLog} from "./AnchorLog.sol";
import {SpendMeter} from "./SpendMeter.sol";
import {Receipts} from "./Receipts.sol";
import {Merkle} from "./Merkle.sol";
import {Deeds} from "./Deeds.sol";
import {Kinds} from "./Kinds.sol";
import {Vault} from "./Vault.sol";
import {DelictiErrors} from "./DelictiErrors.sol";

/// @title JudgeEvm — the challenges that start from a receipt or from an EVM transaction
/// @notice §6.1 false payment, §6.2–6.3 budget overrun (native / ERC-20), §6.4 the unanchored deed,
///         §6.5 the tally that lied. Moved out of `Bond` in v0.11 without changing a single rule:
///         every check below is the one v0.10 made, in the same order. What moved is the money —
///         this contract holds none. It verifies, and asks its `Vault` for the verdict.
///
///         Stateful only where a judgement needs memory: which receipts were already used
///         (`consumedLeaf`) and which transactions were already accused (`accused`, `accusations`).
contract JudgeEvm is DelictiErrors {
    Vault public immutable vault;
    MandateRegistry public immutable registry;
    AnchorLog public immutable log;
    /// @notice The tally the effectors keep. address(0) disables §6.5 and nothing else.
    SpendMeter public immutable meter;
    IFdcVerification private immutable _fdcOverride; // 0 => resolve via ContractRegistry

    /// @notice How long after a deed the agent has to anchor it before silence is challengeable (§6.4).
    uint64 public immutable anchorGrace;
    /// @notice How long the agent has to answer an accusation (§6.4).
    uint64 public immutable responseWindow;
    /// @notice How late an effector's tally may still be honest (§6.5).
    uint64 public immutable meterGrace;

    /// @notice mandateId => leaf hash => already used in a successful challenge on THAT mandate.
    mapping(uint256 => mapping(bytes32 => bool)) public consumedLeaf;

    struct Accusation {
        uint256 mandateId;
        bytes32 txHash;
        uint64 deedTime;
        uint64 deadline;
        address challenger;
        bool closed;
        uint256 value; // what the deed moved, in the mandate's unit: the verdict's severity if it stands
    }

    uint256 public nextAccusationId = 1;
    mapping(uint256 => Accusation) public accusations;
    mapping(uint256 => mapping(bytes32 => bool)) public accused;

    event FalsePaymentProven(
        uint256 indexed mandateId, uint256 indexed episodeIndex, bytes32 leafHash, address indexed challenger, uint256 slashedAmount
    );
    event DeedAccused(
        uint256 indexed accusationId, uint256 indexed mandateId, bytes32 txHash, uint64 deedTime, address indexed challenger
    );
    event AccusationAnswered(uint256 indexed accusationId, uint256 indexed mandateId, bytes32 leafHash, uint256 episodeIndex);
    event UnanchoredDeedProven(
        uint256 indexed accusationId, uint256 indexed mandateId, bytes32 txHash, address indexed challenger, uint256 slashedAmount
    );
    event UnderReportedSpendProven(
        uint256 indexed mandateId, uint256 proven, uint256 recorded, uint256 deeds, address indexed challenger, uint256 slashedAmount
    );
    event DeedJudged(uint256 indexed mandateId, uint8 indexed kind, bytes32 indexed deedId, uint256 value);
    event BudgetOverrunProven(
        uint256 indexed mandateId, uint256 spent, uint256 budget, uint256 deeds, address indexed challenger, uint256 slashedAmount
    );

    constructor(
        Vault vault_,
        MandateRegistry _registry,
        AnchorLog _log,
        IFdcVerification fdcOverride,
        SpendMeter meter_,
        uint64 anchorGrace_,
        uint64 responseWindow_,
        uint64 meterGrace_
    ) {
        vault = vault_;
        registry = _registry;
        log = _log;
        _fdcOverride = fdcOverride;
        meter = meter_;
        anchorGrace = anchorGrace_;
        responseWindow = responseWindow_;
        meterGrace = meterGrace_;
    }

    function fdc() public view returns (IFdcVerification) {
        if (address(_fdcOverride) != address(0)) return _fdcOverride;
        return ContractRegistry.getFdcVerification();
    }

    function _one(bytes32 id) internal pure returns (bytes32) {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = id;
        return keccak256(abi.encode(ids));
    }

    function _requireBonded(uint256 mandateId) internal view {
        if (vault.bondOf(mandateId) == 0) revert NothingToSlash();
    }

    // -----------------------------------------------------------------------------------
    // §6.1 False payment
    // -----------------------------------------------------------------------------------

    /// @notice The agent's anchored receipt asserts an XRPL/BTC/DOGE payment; an FDC nonexistence
    ///         proof shows it never happened. No `victim` parameter: the remainder goes to the
    ///         principal, so the calldata cannot be copied with one field changed.
    function challengeFalsePayment(
        uint256 mandateId,
        uint256 episodeIndex,
        Receipts.Leaf calldata leaf,
        bytes32[] calldata merkleProof,
        IReferencedPaymentNonexistence.Proof calldata fdcProof,
        bytes32 salt
    ) external {
        _requireBonded(mandateId);
        if (leaf.kind != Receipts.KIND_EXTERNAL_PAYMENT) revert WrongReceiptKind();
        if (leaf.mandateId != mandateId) revert ProofDoesNotMatchClaim();
        MandateRegistry.Mandate memory m = registry.get(mandateId);
        if (leaf.sourceId != m.sourceId) revert WrongSource();
        // The claimed payment is in the source's native asset. v0.11: a mandate whose budget is
        // gross XRP outflow (§6.10) counts in the same drops, and a receipt for a payment that never
        // existed is a lie whichever of the two quantities the budget promised.
        if (m.assetKey != bytes32(0) && m.assetKey != Kinds.XRP_OUTFLOW_KEY) revert WrongAsset();

        // witness 1
        bytes32 leafHash = Receipts.hash(leaf);
        if (consumedLeaf[mandateId][leafHash]) revert LeafConsumed();
        // Marked before any external call. The Vault is fixed code that calls back into no judge,
        // but a write that follows a call is exactly what an auditor should not have to reason about.
        consumedLeaf[mandateId][leafHash] = true;
        AnchorLog.Episode memory ep = log.episode(mandateId, episodeIndex);
        if (!Merkle.verify(merkleProof, ep.root, leafHash)) revert LeafNotAnchored();

        // witness 2
        if (!fdc().verifyReferencedPaymentNonexistence(fdcProof)) revert FdcProofInvalid();
        vault.consumeCommitment(msg.sender, Kinds.FALSE_PAYMENT, mandateId, _one(leafHash), salt, fdcProof.data.votingRound);

        IReferencedPaymentNonexistence.RequestBody calldata rq = fdcProof.data.requestBody;
        IReferencedPaymentNonexistence.ResponseBody calldata rs = fdcProof.data.responseBody;
        if (rq.checkSourceAddresses) revert ProofDoesNotMatchClaim();
        if (
            rq.destinationAddressHash != leaf.destinationAddressHash || rq.amount != leaf.amount
                || rq.standardPaymentReference != leaf.ref || fdcProof.data.sourceId != leaf.sourceId
        ) revert ProofDoesNotMatchClaim();
        if (
            leaf.claimedTimestamp < rs.minimalBlockTimestamp || leaf.claimedTimestamp > rq.deadlineTimestamp
                || rs.firstOverflowBlockTimestamp <= rq.deadlineTimestamp
        ) revert ClaimOutsideProvenRange();

        uint256 taken = vault.verdict(
            Kinds.FALSE_PAYMENT, mandateId, m.budget, leaf.amount, msg.sender, 1, fdcProof.data.attestationType, fdcProof.data.sourceId, true
        );
        emit FalsePaymentProven(mandateId, episodeIndex, leafHash, msg.sender, taken);
    }

    // -----------------------------------------------------------------------------------
    // §6.2–6.3 Budget overrun on an EVM source
    // -----------------------------------------------------------------------------------

    /// @notice STRUCTURING. N anchored kind-2 leaves, each with an FDC `EVMTransaction` proof, summing
    ///         past the budget. The value of a deed follows the mandate's asset. Tx hashes strictly
    ///         increasing; the commitment kind is 2 for native and 3 for ERC-20.
    function challengeBudgetOverrun(
        uint256 mandateId,
        uint256[] calldata episodeIndices,
        Receipts.Leaf[] calldata leaves,
        bytes32[][] calldata merkleProofs,
        IEVMTransaction.Proof[] calldata fdcProofs,
        bytes32 salt
    ) external {
        _requireBonded(mandateId);
        uint256 n = leaves.length;
        if (n == 0 || episodeIndices.length != n || merkleProofs.length != n || fdcProofs.length != n) {
            revert LengthMismatch();
        }
        MandateRegistry.Mandate memory m = registry.get(mandateId);
        address asset = m.assetKey == bytes32(0) ? address(0) : Deeds.erc20Of(m);
        uint8 kind = asset == address(0) ? Kinds.BUDGET_NATIVE : Kinds.BUDGET_ERC20;

        uint256 spent;
        bytes32[] memory ids = new bytes32[](n);
        uint64 minRound = type(uint64).max;
        for (uint256 i = 0; i < n; i++) {
            Deeds.requireAnchored(log, mandateId, episodeIndices[i], leaves[i], merkleProofs[i], Receipts.KIND_EVM_TX);
            IEVMTransaction.Proof calldata pr = fdcProofs[i];
            ids[i] = pr.data.requestBody.transactionHash;
            if (i != 0 && ids[i] <= ids[i - 1]) revert UnorderedTxs();
            if (pr.data.votingRound < minRound) minRound = pr.data.votingRound;
            uint256 v = Deeds.evm(fdc(), pr, leaves[i], m, asset);
            spent += v;
            emit DeedJudged(mandateId, kind, ids[i], v);
        }
        vault.consumeCommitment(msg.sender, kind, mandateId, keccak256(abi.encode(ids)), salt, minRound);
        if (spent <= m.budget) revert WithinBudget();

        uint256 taken = vault.verdict(
            kind, mandateId, m.budget, spent - m.budget, msg.sender, n, fdcProofs[0].data.attestationType, m.sourceId, true
        );
        emit BudgetOverrunProven(mandateId, spent, m.budget, n, msg.sender, taken);
    }

    // -----------------------------------------------------------------------------------
    // §6.4 The unanchored deed
    // -----------------------------------------------------------------------------------

    /// @notice Accuse a bonded agent of a deed with no anchored receipt behind it. The stake is
    ///         forwarded to the Vault, which holds it until the accusation closes.
    function accuseUnanchoredDeed(uint256 mandateId, IEVMTransaction.Proof calldata proof, bytes32 salt)
        external
        payable
        returns (uint256 id)
    {
        _requireBonded(mandateId);
        if (msg.value != vault.ACCUSATION_STAKE()) revert BadStake();
        if (!registry.exclusive(mandateId)) revert NotExclusive();

        MandateRegistry.Mandate memory m = registry.get(mandateId);
        if (!fdc().verifyEVMTransaction(proof)) revert FdcProofInvalid();
        if (proof.data.sourceId != m.sourceId) revert WrongSource();
        IEVMTransaction.ResponseBody calldata rb = proof.data.responseBody;
        if (rb.sourceAddress != m.agent) revert NotAgentTx();
        if (rb.status != 1) revert TxNotSuccessful();
        if (rb.timestamp < m.validFrom || rb.timestamp > m.validUntil) revert ClaimOutsideProvenRange();
        if (block.timestamp < uint256(rb.timestamp) + anchorGrace) revert DeedWithinGrace();

        bytes32 txh = proof.data.requestBody.transactionHash;
        if (accused[mandateId][txh]) revert AlreadyAccused();
        accused[mandateId][txh] = true;
        vault.consumeCommitment(msg.sender, Kinds.UNANCHORED_DEED, mandateId, _one(txh), salt, proof.data.votingRound);

        id = nextAccusationId++;
        accusations[id] = Accusation({
            mandateId: mandateId,
            txHash: txh,
            deedTime: rb.timestamp,
            deadline: uint64(block.timestamp) + responseWindow,
            challenger: msg.sender,
            closed: false,
            value: m.assetKey == bytes32(0) ? rb.value : Deeds.erc20OutflowFrom(rb.events, Deeds.erc20Of(m), m.agent)
        });
        vault.openAccusation{value: msg.value}(mandateId);
        emit DeedAccused(id, mandateId, txh, rb.timestamp, msg.sender);
    }

    /// @notice Answer an accusation with the anchored receipt for that deed. Anyone may; the
    ///         accuser's stake goes to the principal.
    function answerAccusation(
        uint256 accusationId,
        uint256 episodeIndex,
        Receipts.Leaf calldata leaf,
        bytes32[] calldata merkleProof
    ) external {
        Accusation storage a = accusations[accusationId];
        if (a.challenger == address(0) || a.closed) revert AccusationClosed();
        if (leaf.kind != Receipts.KIND_EVM_TX) revert WrongReceiptKind();
        if (leaf.mandateId != a.mandateId || leaf.ref != a.txHash) revert WrongDeed();

        AnchorLog.Episode memory ep = log.episode(a.mandateId, episodeIndex);
        if (ep.anchoredAt > a.deedTime + anchorGrace) revert AnchoredTooLate();
        bytes32 leafHash = Receipts.hash(leaf);
        if (!Merkle.verify(merkleProof, ep.root, leafHash)) revert LeafNotAnchored();

        a.closed = true;
        vault.closeAccusation(a.mandateId, registry.get(a.mandateId).principal);
        emit AccusationAnswered(accusationId, a.mandateId, leafHash, episodeIndex);
    }

    /// @notice The window closed with no receipt produced. Must never revert once the window is over.
    function resolveAccusation(uint256 accusationId) external {
        Accusation storage a = accusations[accusationId];
        if (a.challenger == address(0) || a.closed) revert AccusationClosed();
        if (block.timestamp <= a.deadline) revert ResponseWindowOpen();

        a.closed = true;
        vault.closeAccusation(a.mandateId, a.challenger); // stake back
        MandateRegistry.Mandate memory m = registry.get(a.mandateId);
        uint256 taken = vault.verdict(
            Kinds.UNANCHORED_DEED, a.mandateId, m.budget, a.value, a.challenger, 1, bytes32("EVMTransaction"), m.sourceId, false
        );
        emit UnanchoredDeedProven(accusationId, a.mandateId, a.txHash, a.challenger, taken);
    }

    // -----------------------------------------------------------------------------------
    // §6.5 The tally that lied
    // -----------------------------------------------------------------------------------

    /// @notice N FDC `EVMTransaction` proofs of deeds by the mandate's agent summing to more than the
    ///         meter recorded as of the last deed plus `meterGrace`. Metered AND exclusive mandates only.
    function challengeUnderReportedSpend(uint256 mandateId, IEVMTransaction.Proof[] calldata fdcProofs, bytes32 salt)
        external
    {
        _requireBonded(mandateId);
        if (address(meter) == address(0)) revert NoMeter();
        if (!meter.metered(mandateId)) revert NotMetered();
        if (!registry.exclusive(mandateId)) revert NotExclusive();

        uint256 n = fdcProofs.length;
        if (n == 0) revert LengthMismatch();
        MandateRegistry.Mandate memory m = registry.get(mandateId);
        address asset = m.assetKey == bytes32(0) ? address(0) : Deeds.erc20Of(m);

        uint256 proven;
        bytes32 lastTx;
        bytes32[] memory ids = new bytes32[](n);
        uint64 minRound = type(uint64).max;
        uint64 lastDeed;
        for (uint256 i = 0; i < n; i++) {
            IEVMTransaction.Proof calldata pr = fdcProofs[i];
            if (!fdc().verifyEVMTransaction(pr)) revert FdcProofInvalid();
            bytes32 txh = pr.data.requestBody.transactionHash;
            if (txh <= lastTx) revert UnorderedTxs();
            lastTx = txh;
            ids[i] = txh;
            if (pr.data.votingRound < minRound) minRound = pr.data.votingRound;
            if (pr.data.sourceId != m.sourceId) revert WrongSource();
            IEVMTransaction.ResponseBody calldata rb = pr.data.responseBody;
            if (rb.status != 1) revert TxNotSuccessful();
            if (rb.timestamp < m.validFrom || rb.timestamp > m.validUntil) revert ClaimOutsideProvenRange();
            uint256 v;
            if (asset == address(0)) {
                if (rb.sourceAddress != m.agent) revert NotAgentTx();
                v = rb.value;
            } else {
                v = Deeds.erc20OutflowFrom(rb.events, asset, m.agent);
            }
            if (rb.timestamp > lastDeed) lastDeed = rb.timestamp;
            proven += v;
            emit DeedJudged(mandateId, Kinds.UNDER_REPORTED, txh, v);
        }

        vault.consumeCommitment(msg.sender, Kinds.UNDER_REPORTED, mandateId, keccak256(abi.encode(ids)), salt, minRound);

        uint256 recorded = meter.spentAt(mandateId, lastDeed + meterGrace);
        if (proven <= recorded) revert TallyAgrees();

        uint256 taken = vault.verdict(
            Kinds.UNDER_REPORTED, mandateId, m.budget, proven - recorded, msg.sender, n, fdcProofs[0].data.attestationType, m.sourceId, true
        );
        emit UnderReportedSpendProven(mandateId, proven, recorded, n, msg.sender, taken);
    }
}
