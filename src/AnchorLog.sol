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

    /// @notice mandateId => receipts anchored so far, summed over episodes. The numerator's upper
    ///         bound for a coverage rate, readable by a contract without walking the episodes.
    mapping(uint256 => uint256) public receiptCountOf;

    /// @param anchoredAt the block time, repeated in the log so that "how long after the deed was it
    ///        written down" needs no block-header lookup per episode
    /// @param leavesURI  where the episode's leaves can be fetched ("" if the anchorer published none).
    ///        The chain holds a root; a score needs the leaves. An episode whose leaves nobody can
    ///        fetch is evidence the agent can still be convicted on, and evidence no one can count
    ///        in its favour — which is the right asymmetry.
    event Anchored(
        uint256 indexed mandateId,
        uint256 indexed index,
        bytes32 root,
        uint64 receiptCount,
        address indexed by,
        uint64 anchoredAt,
        string leavesURI
    );

    error NotMandateParty();
    error MandateNotLive();

    constructor(MandateRegistry _registry) {
        registry = _registry;
    }

    /// @notice Only the mandate's agent or principal may anchor under it, and only while live.
    ///         Anchoring under a dead mandate is itself an alarm — so we refuse it on-chain.
    function anchor(uint256 mandateId, bytes32 root, uint64 receiptCount) external returns (uint256 index) {
        return _anchor(mandateId, root, receiptCount, "");
    }

    /// @notice The same, publishing where the leaves live (ipfs://…, https://…). Not verified and not
    ///         verifiable here: the root is the commitment, the URI is a courtesy to whoever counts.
    function anchor(uint256 mandateId, bytes32 root, uint64 receiptCount, string calldata leavesURI)
        external
        returns (uint256 index)
    {
        return _anchor(mandateId, root, receiptCount, leavesURI);
    }

    function _anchor(uint256 mandateId, bytes32 root, uint64 receiptCount, string memory leavesURI)
        internal
        returns (uint256 index)
    {
        MandateRegistry.Mandate memory m = registry.get(mandateId);
        if (msg.sender != m.agent && msg.sender != m.principal) revert NotMandateParty();
        if (!registry.isLive(mandateId)) revert MandateNotLive();

        index = _episodes[mandateId].length;
        _episodes[mandateId].push(
            Episode({root: root, receiptCount: receiptCount, anchoredAt: uint64(block.timestamp), anchoredBy: msg.sender})
        );
        receiptCountOf[mandateId] += receiptCount;
        emit Anchored(mandateId, index, root, receiptCount, msg.sender, uint64(block.timestamp), leavesURI);
    }

    function episodeCount(uint256 mandateId) external view returns (uint256) {
        return _episodes[mandateId].length;
    }

    function episode(uint256 mandateId, uint256 index) external view returns (Episode memory) {
        return _episodes[mandateId][index];
    }
}
