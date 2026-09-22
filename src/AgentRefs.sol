// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IFdcVerification} from "@flarenetwork/flare-periphery-contracts/coston2/IFdcVerification.sol";
import {IPayment} from "@flarenetwork/flare-periphery-contracts/coston2/IPayment.sol";
import {ContractRegistry} from "@flarenetwork/flare-periphery-contracts/coston2/ContractRegistry.sol";
import {MandateRegistry} from "./MandateRegistry.sol";

/// @title AgentRefs — an account on another chain says "yes, that mandate is about me"
/// @notice A mandate on a non-EVM source names the agent's account there as `agentRef` (FDC standard
///         address hash; for XRPL, keccak256 of the r-address). The principal writes it, exactly as
///         it writes `agent`, and `MandateRegistry.acknowledge` is the EVM key speaking: it shows
///         nothing about who holds the XRPL key. Without this contract a principal with a sock-puppet
///         `agent` names a stranger's busy account, anchors leaves mirroring that stranger's ordinary
///         payments, and is paid out of a third party's bond.
///
///         No funds, no privileges, no owner. The Bond refuses collateral for a mandate with an
///         `agentRef` until `proven[mandateId]` is true.
contract AgentRefs {
    MandateRegistry public immutable registry;
    IFdcVerification private immutable _fdcOverride; // 0 => resolve via ContractRegistry

    /// @notice mandateId => the account named by `agentRef` has itself confirmed the mandate.
    mapping(uint256 => bool) public proven;

    /// @notice mandateId => the account named by `agentRef` has itself declared that, inside the
    ///         mandate's window, EVERY decrease of its XRP balance is a deed under this mandate (v0.11,
    ///         SPEC §6.10). Sticky. Implies `proven`.
    /// @dev    The XRPL-side twin of `MandateRegistry.declareExclusive`, and it has to be separate:
    ///         `declareExclusive` is the EVM key speaking, and a promise about an XRPL account's
    ///         outflow is only worth anything if the XRPL key makes it. It is what lets a challenge
    ///         sum that outflow with no receipts at all — the agent's silence stops being a hiding place.
    mapping(uint256 => bool) public exclusive;

    event ExclusiveProven(uint256 indexed mandateId, bytes32 indexed agentRef, bytes32 transactionId, address indexed by);
    event AgentRefProven(uint256 indexed mandateId, bytes32 indexed agentRef, bytes32 transactionId, address indexed by);

    error NoAgentRef();
    error FdcProofInvalid();
    error WrongSource();
    error NotAgentTx();
    error TxNotSuccessful();
    error ProofDoesNotMatchClaim();

    constructor(MandateRegistry _registry, IFdcVerification fdcOverride) {
        registry = _registry;
        _fdcOverride = fdcOverride;
    }

    function fdc() public view returns (IFdcVerification) {
        if (address(_fdcOverride) != address(0)) return _fdcOverride;
        return ContractRegistry.getFdcVerification();
    }

    /// @notice The reference the account must put in a payment's memo to confirm a mandate.
    /// @dev    Binds chain, registry and mandate, so a confirmation cannot be replayed for another
    ///         mandate, another deployment, or the same deployment on another network.
    function challengeFor(uint256 mandateId) public view returns (bytes32) {
        return keccak256(abi.encode("DELICTI/agentRef", block.chainid, address(registry), mandateId));
    }

    /// @notice The reference that makes a payment a declaration of exclusivity (SPEC §6.10).
    function exclusiveFor(uint256 mandateId) public view returns (bytes32) {
        return keccak256(abi.encode("DELICTI/exclusive", block.chainid, address(registry), mandateId));
    }

    /// @notice Proof of control: an FDC `Payment` attestation of a successful payment FROM the account
    ///         whose standard payment reference is `challengeFor(mandateId)`. Any amount, any
    ///         destination — the reference is the statement, the payment is the pen. Permissionless:
    ///         the proof speaks, not the caller.
    function prove(uint256 mandateId, IPayment.Proof calldata proof) external {
        bytes32 agentRef = _statement(mandateId, proof, challengeFor(mandateId));
        proven[mandateId] = true;
        emit AgentRefProven(mandateId, agentRef, proof.data.requestBody.transactionId, msg.sender);
    }

    /// @notice The account declares exclusivity for the mandate: a successful payment FROM it whose
    ///         standard payment reference is `exclusiveFor(mandateId)`. Proves control too, so it also
    ///         sets `proven`. Permissionless, like `prove`.
    /// @dev    The payment itself leaves the account, and if it falls inside the mandate's window it
    ///         counts toward that window's outflow like any other. Deliberately not exempted: an
    ///         exemption keyed on a memo is an exemption anyone holding the key can reuse.
    function proveExclusive(uint256 mandateId, IPayment.Proof calldata proof) external {
        bytes32 agentRef = _statement(mandateId, proof, exclusiveFor(mandateId));
        proven[mandateId] = true;
        exclusive[mandateId] = true;
        emit ExclusiveProven(mandateId, agentRef, proof.data.requestBody.transactionId, msg.sender);
    }

    /// @dev A successful FDC-attested payment from the mandate's `agentRef` carrying `ref`.
    function _statement(uint256 mandateId, IPayment.Proof calldata proof, bytes32 ref) internal view returns (bytes32) {
        MandateRegistry.Mandate memory m = registry.get(mandateId);
        if (m.agentRef == bytes32(0)) revert NoAgentRef();
        if (!fdc().verifyPayment(proof)) revert FdcProofInvalid();
        IPayment.ResponseBody calldata rb = proof.data.responseBody;
        if (proof.data.sourceId != m.sourceId) revert WrongSource();
        if (rb.sourceAddressHash != m.agentRef) revert NotAgentTx();
        if (rb.status != 0) revert TxNotSuccessful();
        if (rb.standardPaymentReference != ref) revert ProofDoesNotMatchClaim();
        return m.agentRef;
    }
}
