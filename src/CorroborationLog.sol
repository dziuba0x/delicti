// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IFdcVerification} from "@flarenetwork/flare-periphery-contracts/coston2/IFdcVerification.sol";
import {IEVMTransaction} from "@flarenetwork/flare-periphery-contracts/coston2/IEVMTransaction.sol";
import {IPayment} from "@flarenetwork/flare-periphery-contracts/coston2/IPayment.sol";
import {ContractRegistry} from "@flarenetwork/flare-periphery-contracts/coston2/ContractRegistry.sol";
import {MandateRegistry} from "./MandateRegistry.sol";
import {AnchorLog} from "./AnchorLog.sol";
import {Receipts} from "./Receipts.sol";
import {Deeds} from "./Deeds.sol";

/// @title CorroborationLog — the deeds whose two witnesses AGREED
/// @notice Everything else in DELICTI records disagreement or excess. A deed that was anchored and
///         that the FDC confirms exactly as the receipt describes it — evidence class A, the good
///         case — used to leave no trace on-chain at all: `corroboration rate` (SPEC §11) had a
///         definition and no data. This is the data.
///
///         It holds no funds and has no privileges: it reads the registry, the log and the FDC, and
///         writes only its own tallies. That is also why it is a separate contract — it could have
///         been deployed a year after the core without touching it, and a better one still can be.
///         The definition of "agree" is `Deeds`, the same code the Bond convicts with.
///
///         Who calls it: whoever wants the record to exist and is willing to pay the attestation —
///         in practice the agent, building a reputation out of deeds rather than out of feedback.
///         What it does NOT show is in SPEC §10: it counts what somebody chose to prove, so it is a
///         floor on corroboration, never the rate itself; and an agent can corroborate dust it paid
///         to itself all day, which is why §11 says to weigh by value and by counterparty.
contract CorroborationLog {
    MandateRegistry public immutable registry;
    AnchorLog public immutable log;
    IFdcVerification private immutable _fdcOverride; // 0 => resolve via ContractRegistry

    /// @notice mandateId => leaf hash => already recorded (one receipt, one corroboration)
    mapping(uint256 => mapping(bytes32 => bool)) public corroborated;
    /// @notice mandateId => source transaction id => already recorded (one effect, one corroboration —
    ///         on the payment path two receipts can describe the same payment)
    mapping(uint256 => mapping(bytes32 => bool)) public deedRecorded;
    mapping(uint256 => uint256) public countOf; // per mandate
    mapping(uint256 => uint256) public valueOf; // per mandate, in the mandate's unit
    mapping(address => uint256) public countOfAgent; // per EVM agent, across mandates (units differ: count only)

    event DeedCorroborated(
        uint256 indexed mandateId,
        address indexed agent,
        bytes32 indexed deedId,
        bytes32 leafHash,
        uint256 episodeIndex,
        uint256 value,
        uint64 deedTime,
        uint64 votingRound,
        address by
    );

    error NotAcknowledged();
    error AlreadyCorroborated();
    error NoAgentRef();
    error WrongAsset();

    constructor(MandateRegistry _registry, AnchorLog _log, IFdcVerification fdcOverride) {
        registry = _registry;
        log = _log;
        _fdcOverride = fdcOverride;
    }

    function fdc() public view returns (IFdcVerification) {
        if (address(_fdcOverride) != address(0)) return _fdcOverride;
        return ContractRegistry.getFdcVerification();
    }

    /// @notice An anchored kind-2 leaf and the FDC `EVMTransaction` proof that agrees with it. What
    ///         the deed's value is follows the mandate's asset, exactly as in `Bond.challengeBudgetOverrun`.
    function corroborateEvm(
        uint256 mandateId,
        uint256 episodeIndex,
        Receipts.Leaf calldata leaf,
        bytes32[] calldata merkleProof,
        IEVMTransaction.Proof calldata proof
    ) external {
        MandateRegistry.Mandate memory m = _mandate(mandateId);
        bytes32 leafHash = Deeds.requireAnchored(log, mandateId, episodeIndex, leaf, merkleProof, Receipts.KIND_EVM_TX);
        address asset = m.assetKey == bytes32(0) ? address(0) : Deeds.erc20Of(m);
        uint256 v = Deeds.evm(fdc(), proof, leaf, m, asset);
        _record(mandateId, m.agent, leafHash, proof.data.requestBody.transactionHash, episodeIndex, v, proof.data.responseBody.timestamp, proof.data.votingRound);
    }

    /// @notice An anchored kind-3 leaf and the FDC `Payment` proof that agrees with it (XRPL).
    function corroboratePayment(
        uint256 mandateId,
        uint256 episodeIndex,
        Receipts.Leaf calldata leaf,
        bytes32[] calldata merkleProof,
        IPayment.Proof calldata proof
    ) external {
        MandateRegistry.Mandate memory m = _mandate(mandateId);
        if (m.agentRef == bytes32(0)) revert NoAgentRef();
        if (m.assetKey != bytes32(0)) revert WrongAsset();
        bytes32 leafHash =
            Deeds.requireAnchored(log, mandateId, episodeIndex, leaf, merkleProof, Receipts.KIND_EXTERNAL_PAYMENT);
        uint256 v = Deeds.payment(fdc(), proof, leaf, m);
        _record(mandateId, m.agent, leafHash, proof.data.requestBody.transactionId, episodeIndex, v, proof.data.responseBody.blockTimestamp, proof.data.votingRound);
    }

    /// @dev Only acknowledged mandates. A principal can name any address as "agent" and anchor under
    ///      it; a record that an outsider can write into — even a flattering one — is not the agent's.
    function _mandate(uint256 mandateId) internal view returns (MandateRegistry.Mandate memory m) {
        if (!registry.acknowledged(mandateId)) revert NotAcknowledged();
        m = registry.get(mandateId);
    }

    function _record(
        uint256 mandateId,
        address agent,
        bytes32 leafHash,
        bytes32 deedId,
        uint256 episodeIndex,
        uint256 value,
        uint64 deedTime,
        uint64 votingRound
    ) internal {
        if (corroborated[mandateId][leafHash] || deedRecorded[mandateId][deedId]) revert AlreadyCorroborated();
        corroborated[mandateId][leafHash] = true;
        deedRecorded[mandateId][deedId] = true;
        countOf[mandateId]++;
        valueOf[mandateId] += value;
        countOfAgent[agent]++;
        emit DeedCorroborated(mandateId, agent, deedId, leafHash, episodeIndex, value, deedTime, votingRound, msg.sender);
    }
}
