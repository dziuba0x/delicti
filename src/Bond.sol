// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IFdcVerification} from "@flarenetwork/flare-periphery-contracts/coston2/IFdcVerification.sol";
import {IReferencedPaymentNonexistence} from
    "@flarenetwork/flare-periphery-contracts/coston2/IReferencedPaymentNonexistence.sol";
import {IEVMTransaction} from "@flarenetwork/flare-periphery-contracts/coston2/IEVMTransaction.sol";
import {ContractRegistry} from "@flarenetwork/flare-periphery-contracts/coston2/ContractRegistry.sol";
import {MandateRegistry} from "./MandateRegistry.sol";
import {AnchorLog} from "./AnchorLog.sol";
import {Receipts} from "./Receipts.sol";
import {Merkle} from "./Merkle.sol";

/// @title Bond — programmable consequence for a proven false deed
/// @notice DELICTI, layer 4. Pattern lifted from FAssets' challenger role
///         (`illegalPaymentChallenge` etc. in IAssetManager): anyone can bring an FDC proof;
///         if it contradicts what the agent's own receipt asserted, the bond is slashed —
///         no court, no operator cooperation.
///
///         Sprint-0 challenge type: FALSE PAYMENT CLAIM.
///           witness 1  = the agent's anchored receipt saying "I paid X to D with reference R".
///           witness 2  = FDC `ReferencedPaymentNonexistence`: the world says no such payment
///                        reached D with amount X and reference R before the deadline.
///         Two witnesses to the same overt act, disagreeing → contradicted deed → slash.
contract Bond {
    MandateRegistry public immutable registry;
    AnchorLog public immutable log;
    IFdcVerification private immutable _fdcOverride; // 0 => resolve via ContractRegistry

    uint256 public constant CHALLENGER_BPS = 1000; // 10% of slashed bond to the challenger

    /// @notice How long the bond stays frozen after the mandate's authority died.
    /// @dev    A challenge is not instant: the challenger must request an FDC attestation
    ///         on-chain, wait for the voting round to finalise (~90 s rounds, minutes
    ///         end-to-end on Coston2), pull the proof from the DA layer and only then send
    ///         the challenge. Without a window the principal — who is also an authority in
    ///         `revoke()` — can empty the bond in the same transaction that kills the mandate,
    ///         and the FDC request itself announces the challenge minutes in advance. 24 h is
    ///         ~100x the observed proof latency and far below the DA layer's retention.
    uint64 public constant COOLING_WINDOW = 24 hours;

    // mandateId => posted bond (wei)
    mapping(uint256 => uint256) public bondOf;
    // mandateId => slashed?
    mapping(uint256 => bool) public slashed;
    // mandateId => leaf hash => already used in a successful challenge on THAT mandate.
    // Scoped per mandate on purpose: a global key let anyone burn a leaf under a throwaway
    // mandate of their own and make the same evidence permanently unusable elsewhere.
    mapping(uint256 => mapping(bytes32 => bool)) public consumedLeaf;

    // Slash proceeds and challenger rewards, held for pull-withdrawal. Pushing value inside
    // the challenge would let a reverting recipient block the consequence entirely.
    mapping(address => uint256) public owed;

    event BondPosted(uint256 indexed mandateId, address indexed by, uint256 amount, uint256 total);
    event BondWithdrawn(uint256 indexed mandateId, address indexed to, uint256 amount);
    event Claimed(address indexed who, uint256 amount);
    event FalsePaymentProven(
        uint256 indexed mandateId,
        uint256 indexed episodeIndex,
        bytes32 leafHash,
        address indexed challenger,
        uint256 slashedAmount
    );

    event BudgetOverrunProven(
        uint256 indexed mandateId, uint256 spent, uint256 budget, uint256 deeds, address indexed challenger, uint256 slashedAmount
    );

    error NothingToSlash();
    error NotAgentTx();
    error TxNotSuccessful();
    error UnorderedTxs();
    error WithinBudget();
    error LengthMismatch();
    error AlreadySlashed();
    error LeafNotAnchored();
    error LeafConsumed();
    error WrongReceiptKind();
    error FdcProofInvalid();
    error ProofDoesNotMatchClaim();
    error ClaimOutsideProvenRange();
    error MandateStillLive();
    error NotPrincipal();
    error TransferFailed();
    error CoolingWindow();
    error NothingOwed();
    error BondSlashed();

    constructor(MandateRegistry _registry, AnchorLog _log, IFdcVerification fdcOverride) {
        registry = _registry;
        log = _log;
        _fdcOverride = fdcOverride;
    }

    function fdc() public view returns (IFdcVerification) {
        if (address(_fdcOverride) != address(0)) return _fdcOverride;
        return ContractRegistry.getFdcVerification();
    }

    /// @notice Anyone may post bond under a mandate (agent, operator, or an insurer).
    function post(uint256 mandateId) external payable {
        // A mandate can only be slashed once. Funding one that was already slashed buys the
        // depositor nothing and would look like collateral to a counterparty reading the chain.
        if (slashed[mandateId]) revert BondSlashed();
        bondOf[mandateId] += msg.value;
        emit BondPosted(mandateId, msg.sender, msg.value, bondOf[mandateId]);
    }

    /// @notice Principal may withdraw only after the mandate's authority died AND the cooling
    ///         window has elapsed, and only if nothing was slashed.
    /// @dev    The window runs from `registry.deathTime()` — the earliest death in the mandate's
    ///         ancestry — not from the moment of this call, so revoking early does not shorten it.
    function withdraw(uint256 mandateId, address payable to) external {
        MandateRegistry.Mandate memory m = registry.get(mandateId);
        if (msg.sender != m.principal) revert NotPrincipal();
        if (slashed[mandateId]) revert AlreadySlashed();
        if (registry.isLive(mandateId)) revert MandateStillLive();
        uint64 death = registry.deathTime(mandateId);
        if (death == type(uint64).max || block.timestamp < uint256(death) + COOLING_WINDOW) revert CoolingWindow();
        uint256 amt = bondOf[mandateId];
        bondOf[mandateId] = 0;
        emit BondWithdrawn(mandateId, to, amt);
        (bool ok,) = to.call{value: amt}("");
        if (!ok) revert TransferFailed();
    }

    /// @notice Pull whatever a slash credited you: 10% as challenger, the remainder as principal.
    function claim() external {
        uint256 amt = owed[msg.sender];
        if (amt == 0) revert NothingOwed();
        owed[msg.sender] = 0;
        emit Claimed(msg.sender, amt);
        (bool ok,) = payable(msg.sender).call{value: amt}("");
        if (!ok) revert TransferFailed();
    }

    /// @notice Challenge: the agent's anchored receipt asserts an XRPL/BTC/DOGE payment;
    ///         an FDC nonexistence proof shows it never happened.
    /// @param mandateId     mandate under which the receipt was anchored
    /// @param episodeIndex  index into AnchorLog episodes for that mandate
    /// @param leaf          the receipt leaf (witness 1) as anchored
    /// @param merkleProof   inclusion path of keccak256(abi.encode(leaf)) in the episode root
    /// @param fdcProof      FDC ReferencedPaymentNonexistence proof (witness 2)
    /// @dev    There is deliberately no `victim` parameter. It used to be challenger-supplied,
    ///         which meant the whole calldata (proofs included) could be copied out of the
    ///         mempool with that one field changed — the agent's own address — and the slash
    ///         returned 100% of the bond to the family that posted it. The harmed party is the
    ///         principal (SPEC 1), so that is who the remainder is credited to.
    function challengeFalsePayment(
        uint256 mandateId,
        uint256 episodeIndex,
        Receipts.Leaf calldata leaf,
        bytes32[] calldata merkleProof,
        IReferencedPaymentNonexistence.Proof calldata fdcProof
    ) external {
        if (slashed[mandateId]) revert AlreadySlashed();
        uint256 amount = bondOf[mandateId];
        if (amount == 0) revert NothingToSlash();
        if (leaf.kind != Receipts.KIND_EXTERNAL_PAYMENT) revert WrongReceiptKind();
        // The leaf must name the mandate being challenged. Without this the budget paths'
        // invariant did not hold here, and any leaf could be replayed under a foreign mandate.
        if (leaf.mandateId != mandateId) revert ProofDoesNotMatchClaim();

        // --- witness 1: the agent really asserted this deed (leaf is in an anchored root) ---
        bytes32 leafHash = Receipts.hash(leaf);
        if (consumedLeaf[mandateId][leafHash]) revert LeafConsumed();
        AnchorLog.Episode memory ep = log.episode(mandateId, episodeIndex);
        if (!Merkle.verify(merkleProof, ep.root, leafHash)) revert LeafNotAnchored();

        // --- witness 2: the world says the payment does not exist ---
        if (!fdc().verifyReferencedPaymentNonexistence(fdcProof)) revert FdcProofInvalid();

        IReferencedPaymentNonexistence.RequestBody calldata rq = fdcProof.data.requestBody;
        IReferencedPaymentNonexistence.ResponseBody calldata rs = fdcProof.data.responseBody;

        // A nonexistence proof scoped to a set of source addresses proves only that THOSE
        // addresses did not pay. The leaf carries no source address to compare it against, so
        // such a proof would convict an agent who really did pay, from another address.
        if (rq.checkSourceAddresses) revert ProofDoesNotMatchClaim();

        // the proof must be about exactly the payment the receipt claims
        if (
            rq.destinationAddressHash != leaf.destinationAddressHash || rq.amount != leaf.amount
                || rq.standardPaymentReference != leaf.ref
                || fdcProof.data.sourceId != leaf.sourceId
        ) revert ProofDoesNotMatchClaim();

        // the claimed payment time must fall inside the range the proof covers:
        // [minimalBlockTimestamp, deadlineTimestamp] with the search actually having
        // overflowed the deadline (firstOverflowBlockTimestamp > deadlineTimestamp).
        if (
            leaf.claimedTimestamp < rs.minimalBlockTimestamp || leaf.claimedTimestamp > rq.deadlineTimestamp
                || rs.firstOverflowBlockTimestamp <= rq.deadlineTimestamp
        ) revert ClaimOutsideProvenRange();

        // --- consequence ---
        consumedLeaf[mandateId][leafHash] = true;
        emit FalsePaymentProven(mandateId, episodeIndex, leafHash, msg.sender, amount);
        _slash(mandateId, amount);
    }

    /// @notice Challenge: STRUCTURING. Every anchored deed may sit inside its own limit, but the
    ///         sum of what the agent provably did on-chain (FDC `EVMTransaction`, sourceAddress ==
    ///         the mandated agent) exceeds the mandate's cumulative budget. This is the "salami"
    ///         pattern pre-action gates cannot see, because each call passes on its own.
    /// @dev    Deeds must be supplied in strictly increasing tx-hash order (dedup without storage).
    ///         Each deed needs BOTH witnesses: the anchored leaf (agent asserted it) and the FDC
    ///         proof (world confirms it). Evidence class A only.
    function challengeBudgetOverrun(
        uint256 mandateId,
        uint256[] calldata episodeIndices,
        Receipts.Leaf[] calldata leaves,
        bytes32[][] calldata merkleProofs,
        IEVMTransaction.Proof[] calldata fdcProofs
    ) external {
        if (slashed[mandateId]) revert AlreadySlashed();
        uint256 amount = bondOf[mandateId];
        if (amount == 0) revert NothingToSlash();
        uint256 n = leaves.length;
        if (n == 0 || episodeIndices.length != n || merkleProofs.length != n || fdcProofs.length != n) {
            revert LengthMismatch();
        }
        MandateRegistry.Mandate memory m = registry.get(mandateId);

        uint256 spent;
        bytes32 lastTx;
        for (uint256 i = 0; i < n; i++) {
            Receipts.Leaf calldata leaf = leaves[i];
            if (leaf.kind != Receipts.KIND_EVM_TX) revert WrongReceiptKind();
            if (leaf.mandateId != mandateId) revert ProofDoesNotMatchClaim();

            // witness 1
            bytes32 leafHash = Receipts.hash(leaf);
            AnchorLog.Episode memory ep = log.episode(mandateId, episodeIndices[i]);
            if (!Merkle.verify(merkleProofs[i], ep.root, leafHash)) revert LeafNotAnchored();

            // witness 2
            IEVMTransaction.Proof calldata pr = fdcProofs[i];
            if (!fdc().verifyEVMTransaction(pr)) revert FdcProofInvalid();
            bytes32 txh = pr.data.requestBody.transactionHash;
            if (txh <= lastTx) revert UnorderedTxs();
            lastTx = txh;
            if (txh != leaf.ref || pr.data.sourceId != leaf.sourceId) revert ProofDoesNotMatchClaim();
            IEVMTransaction.ResponseBody calldata rb = pr.data.responseBody;
            if (rb.sourceAddress != m.agent) revert NotAgentTx();
            if (rb.status != 1) revert TxNotSuccessful();
            // A budget is cumulative over the mandate's life, so only deeds inside its window
            // may be summed against it — otherwise older activity convicts a fresh mandate.
            if (rb.timestamp < m.validFrom || rb.timestamp > m.validUntil) revert ClaimOutsideProvenRange();
            if (rb.value != leaf.amount || bytes32(uint256(uint160(rb.receivingAddress))) != leaf.destinationAddressHash)
            {
                revert ProofDoesNotMatchClaim();
            }
            spent += rb.value;
        }
        if (spent <= m.budget) revert WithinBudget();

        emit BudgetOverrunProven(mandateId, spent, m.budget, n, msg.sender, amount);
        _slash(mandateId, amount);
    }

    /// @notice STRUCTURING over ERC-20 payments (the real x402 case). An x402 settlement is
    ///         `transferWithAuthorization` on the token contract, so the tx's native `value` is 0
    ///         and the deed lives in the `Transfer(from,to,value)` event. The FDC EVMTransaction
    ///         proof must be requested with `listEvents = true` and the log index of that event.
    /// @param asset   the ERC-20 the mandate budget is denominated in (must be the event emitter)
    function challengeBudgetOverrunERC20(
        uint256 mandateId,
        address asset,
        uint256[] calldata episodeIndices,
        Receipts.Leaf[] calldata leaves,
        bytes32[][] calldata merkleProofs,
        IEVMTransaction.Proof[] calldata fdcProofs
    ) external {
        if (slashed[mandateId]) revert AlreadySlashed();
        uint256 amount = bondOf[mandateId];
        if (amount == 0) revert NothingToSlash();
        uint256 n = leaves.length;
        if (n == 0 || episodeIndices.length != n || merkleProofs.length != n || fdcProofs.length != n) {
            revert LengthMismatch();
        }
        MandateRegistry.Mandate memory m = registry.get(mandateId);

        uint256 spent;
        bytes32 lastTx;
        for (uint256 i = 0; i < n; i++) {
            Receipts.Leaf calldata leaf = leaves[i];
            if (leaf.kind != Receipts.KIND_EVM_TX) revert WrongReceiptKind();
            if (leaf.mandateId != mandateId) revert ProofDoesNotMatchClaim();

            bytes32 leafHash = Receipts.hash(leaf);
            AnchorLog.Episode memory ep = log.episode(mandateId, episodeIndices[i]);
            if (!Merkle.verify(merkleProofs[i], ep.root, leafHash)) revert LeafNotAnchored();

            IEVMTransaction.Proof calldata pr = fdcProofs[i];
            if (!fdc().verifyEVMTransaction(pr)) revert FdcProofInvalid();
            bytes32 txh = pr.data.requestBody.transactionHash;
            if (txh <= lastTx) revert UnorderedTxs();
            lastTx = txh;
            if (txh != leaf.ref || pr.data.sourceId != leaf.sourceId) revert ProofDoesNotMatchClaim();
            IEVMTransaction.ResponseBody calldata rb = pr.data.responseBody;
            if (rb.status != 1) revert TxNotSuccessful();
            if (rb.timestamp < m.validFrom || rb.timestamp > m.validUntil) revert ClaimOutsideProvenRange();

            // find the Transfer(agent → payee) emitted by `asset`
            uint256 v = _erc20TransferValue(rb.events, asset, m.agent, address(uint160(uint256(leaf.destinationAddressHash))));
            if (v == 0 || v != leaf.amount) revert ProofDoesNotMatchClaim();
            spent += v;
        }
        if (spent <= m.budget) revert WithinBudget();

        emit BudgetOverrunProven(mandateId, spent, m.budget, n, msg.sender, amount);
        _slash(mandateId, amount);
    }

    bytes32 private constant TRANSFER_SIG = keccak256("Transfer(address,address,uint256)");

    function _erc20TransferValue(IEVMTransaction.Event[] calldata events, address asset, address from, address to)
        internal
        pure
        returns (uint256 total)
    {
        for (uint256 i = 0; i < events.length; i++) {
            IEVMTransaction.Event calldata e = events[i];
            if (e.removed || e.emitterAddress != asset || e.topics.length != 3) continue;
            if (e.topics[0] != TRANSFER_SIG) continue;
            if (address(uint160(uint256(e.topics[1]))) != from) continue;
            if (address(uint160(uint256(e.topics[2]))) != to) continue;
            total += abi.decode(e.data, (uint256));
        }
    }

    function _slash(uint256 mandateId, uint256 amount) internal {
        slashed[mandateId] = true;
        bondOf[mandateId] = 0;
        registry.revokeByBond(mandateId);
        uint256 reward = (amount * CHALLENGER_BPS) / 10_000;
        // Credit, never push: a recipient that reverts on receive would otherwise be able to
        // make a mandate unslashable. Both parties pull with claim().
        owed[msg.sender] += reward;
        owed[registry.get(mandateId).principal] += amount - reward;
    }
}
