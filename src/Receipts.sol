// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title Receipts — normalized "overt act" leaf derived from any third-party receipt
/// @notice DELICTI does not define a receipt format. Effector receipts (KYA-OS `_meta`
///         proofs, ACTA/ASQAV JSON, flario `x402_receipt`) are normalized off-chain into
///         this leaf; `receiptHash` binds the leaf to the original signed artifact so an
///         auditor can always walk back to the effector's own signature.
library Receipts {
    uint8 internal constant KIND_TOOL_CALL = 1; // no world-observable effect (class B evidence)
    uint8 internal constant KIND_EVM_TX = 2; // corroborable via FDC EVMTransaction
    uint8 internal constant KIND_EXTERNAL_PAYMENT = 3; // corroborable via FDC Payment / *Nonexistence

    struct Leaf {
        bytes32 receiptHash; // hash of the original third-party receipt (format-specific)
        uint8 kind;
        bytes32 sourceId; // FDC source id, e.g. "testXRP" padded, for kind 2/3
        bytes32 destinationAddressHash; // FDC standard address hash (kind 3)
        uint256 amount; // in source chain base units (drops / sats)
        bytes32 standardPaymentReference; // 32-byte memo / OP_RETURN reference (kind 3)
        uint64 claimedTimestamp; // when the effector says the deed happened
        uint256 mandateId; // mandate the effector was acting under
    }

    function hash(Leaf calldata leaf) internal pure returns (bytes32) {
        return keccak256(abi.encode(leaf));
    }

    function hashMem(Leaf memory leaf) internal pure returns (bytes32) {
        return keccak256(abi.encode(leaf));
    }
}
