// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {MandateRegistry} from "./MandateRegistry.sol";

/// @title AnchorLog — ordered commitment of effector receipts per mandate
/// @notice DELICTI, layer 2: the "flight recorder" anchor. Receipts (witness 1) are
///         produced off-chain by effectors in third-party formats (KYA-OS / ACTA / x402
///         receipts). They are batched into a Merkle tree; only the root is anchored here,
///         sequenced per mandate. This gives an ordering nobody controls, survivability
///         beyond the operator, and a leaf-inclusion path a challenger can use in Bond.
contract AnchorLog {
    struct Episode {
        bytes32 root;
        uint64 receiptCount;
        uint64 anchoredAt;
        address anchoredBy;
    }

    MandateRegistry public immutable registry;
    // mandateId => sequence of episodes
    mapping(uint256 => Episode[]) private _episodes;

    event Anchored(uint256 indexed mandateId, uint256 indexed index, bytes32 root, uint64 receiptCount, address by);

    error NotMandateParty();
    error MandateNotLive();

    constructor(MandateRegistry _registry) {
        registry = _registry;
    }

    /// @notice Only the mandate's agent or principal may anchor under it, and only while live.
    ///         Anchoring under a dead mandate is itself an alarm — so we refuse it on-chain.
    function anchor(uint256 mandateId, bytes32 root, uint64 receiptCount) external returns (uint256 index) {
        MandateRegistry.Mandate memory m = registry.get(mandateId);
        if (msg.sender != m.agent && msg.sender != m.principal) revert NotMandateParty();
        if (!registry.isLive(mandateId)) revert MandateNotLive();

        index = _episodes[mandateId].length;
        _episodes[mandateId].push(
            Episode({root: root, receiptCount: receiptCount, anchoredAt: uint64(block.timestamp), anchoredBy: msg.sender})
        );
        emit Anchored(mandateId, index, root, receiptCount, msg.sender);
    }

    function episodeCount(uint256 mandateId) external view returns (uint256) {
        return _episodes[mandateId].length;
    }

    function episode(uint256 mandateId, uint256 index) external view returns (Episode memory) {
        return _episodes[mandateId][index];
    }
}
