// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IFdcVerification} from "@flarenetwork/flare-periphery-contracts/coston2/IFdcVerification.sol";
import {IReferencedPaymentNonexistence} from
    "@flarenetwork/flare-periphery-contracts/coston2/IReferencedPaymentNonexistence.sol";
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

    // mandateId => posted bond (wei)
    mapping(uint256 => uint256) public bondOf;
    // mandateId => slashed?
    mapping(uint256 => bool) public slashed;
    // leaf hash => already used in a successful challenge (no double-slash on one receipt)
    mapping(bytes32 => bool) public consumedLeaf;

    event BondPosted(uint256 indexed mandateId, address indexed by, uint256 amount, uint256 total);
    event BondWithdrawn(uint256 indexed mandateId, address indexed to, uint256 amount);
    event FalsePaymentProven(
        uint256 indexed mandateId,
        uint256 indexed episodeIndex,
        bytes32 leafHash,
        address indexed challenger,
        uint256 slashedAmount
    );

    error NothingToSlash();
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
        bondOf[mandateId] += msg.value;
        emit BondPosted(mandateId, msg.sender, msg.value, bondOf[mandateId]);
    }

    /// @notice Principal may withdraw only after the mandate has expired/been revoked
    ///         and nothing was slashed — a cooling window is a v0.2 hardening item.
    function withdraw(uint256 mandateId, address payable to) external {
        MandateRegistry.Mandate memory m = registry.get(mandateId);
        if (msg.sender != m.principal) revert NotPrincipal();
        if (registry.isLive(mandateId)) revert MandateStillLive();
        uint256 amt = bondOf[mandateId];
        bondOf[mandateId] = 0;
        emit BondWithdrawn(mandateId, to, amt);
        (bool ok,) = to.call{value: amt}("");
        if (!ok) revert TransferFailed();
    }

    /// @notice Challenge: the agent's anchored receipt asserts an XRPL/BTC/DOGE payment;
    ///         an FDC nonexistence proof shows it never happened.
    /// @param mandateId     mandate under which the receipt was anchored
    /// @param episodeIndex  index into AnchorLog episodes for that mandate
    /// @param leaf          the receipt leaf (witness 1) as anchored
    /// @param merkleProof   inclusion path of keccak256(abi.encode(leaf)) in the episode root
    /// @param fdcProof      FDC ReferencedPaymentNonexistence proof (witness 2)
    /// @param victim        who receives the slashed remainder (the harmed party)
    function challengeFalsePayment(
        uint256 mandateId,
        uint256 episodeIndex,
        Receipts.Leaf calldata leaf,
        bytes32[] calldata merkleProof,
        IReferencedPaymentNonexistence.Proof calldata fdcProof,
        address payable victim
    ) external {
        if (slashed[mandateId]) revert AlreadySlashed();
        uint256 amount = bondOf[mandateId];
        if (amount == 0) revert NothingToSlash();
        if (leaf.kind != Receipts.KIND_EXTERNAL_PAYMENT) revert WrongReceiptKind();

        // --- witness 1: the agent really asserted this deed (leaf is in an anchored root) ---
        bytes32 leafHash = Receipts.hash(leaf);
        if (consumedLeaf[leafHash]) revert LeafConsumed();
        AnchorLog.Episode memory ep = log.episode(mandateId, episodeIndex);
        if (!Merkle.verify(merkleProof, ep.root, leafHash)) revert LeafNotAnchored();

        // --- witness 2: the world says the payment does not exist ---
        if (!fdc().verifyReferencedPaymentNonexistence(fdcProof)) revert FdcProofInvalid();

        IReferencedPaymentNonexistence.RequestBody calldata rq = fdcProof.data.requestBody;
        IReferencedPaymentNonexistence.ResponseBody calldata rs = fdcProof.data.responseBody;

        // the proof must be about exactly the payment the receipt claims
        if (
            rq.destinationAddressHash != leaf.destinationAddressHash || rq.amount != leaf.amount
                || rq.standardPaymentReference != leaf.standardPaymentReference
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
        consumedLeaf[leafHash] = true;
        slashed[mandateId] = true;
        bondOf[mandateId] = 0;
        registry.revokeByBond(mandateId);

        uint256 reward = (amount * CHALLENGER_BPS) / 10_000;
        uint256 rest = amount - reward;
        emit FalsePaymentProven(mandateId, episodeIndex, leafHash, msg.sender, amount);

        (bool ok1,) = payable(msg.sender).call{value: reward}("");
        (bool ok2,) = victim.call{value: rest}("");
        if (!ok1 || !ok2) revert TransferFailed();
    }
}
