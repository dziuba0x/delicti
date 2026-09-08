// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title MandateRegistry — commitment of an agent's mandate BEFORE it acts
/// @notice DELICTI, layer 1: the "flight plan". A principal commits, ahead of an
///         episode, what an agent is allowed to do: a hash of the off-chain mandate
///         envelope (effectors, limits, counterparties), a cumulative budget, a validity
///         window, and a reference to the authority proof (e.g. hash of a W3C VC
///         delegation credential, KYA-OS style). Delegation is a tree: a child mandate
///         can only narrow its parent (monotonic narrowing — capability semantics).
///
///         Nothing sensitive goes on-chain: only commitments. The envelope itself is
///         disclosed selectively to auditors off-chain.
contract MandateRegistry {
    struct Mandate {
        address principal;     // who grants authority (or delegating agent for children)
        address agent;         // who is bound by it
        bytes32 mandateHash;   // keccak256 of the off-chain mandate envelope (canonical JSON)
        bytes32 authorityRef;  // hash of delegation credential / VC chain (0 for root)
        uint256 parentId;      // 0 for root mandates
        uint256 budget;        // cumulative budget (unit defined by envelope, e.g. drops / wei)
        uint64 validFrom;
        uint64 validUntil;
        bool revoked;
    }

    uint256 public nextId = 1;
    mapping(uint256 => Mandate) private _mandates;

    event MandateCommitted(
        uint256 indexed id,
        uint256 indexed parentId,
        address indexed agent,
        address principal,
        bytes32 mandateHash,
        bytes32 authorityRef,
        uint256 budget,
        uint64 validFrom,
        uint64 validUntil
    );
    event MandateRevoked(uint256 indexed id, address indexed by);

    error InvalidWindow();
    error ParentNotFound();
    error NotParentAgent();
    error ExceedsParent();
    error NotAuthorized();
    error ZeroAgent();

    /// @notice Commit a mandate. For a child mandate, msg.sender must be the parent's agent
    ///         (the delegating agent), and the child must be within the parent's envelope.
    function commit(
        address agent,
        bytes32 mandateHash,
        bytes32 authorityRef,
        uint256 parentId,
        uint256 budget,
        uint64 validFrom,
        uint64 validUntil
    ) external returns (uint256 id) {
        if (agent == address(0)) revert ZeroAgent();
        if (validUntil <= validFrom || validUntil <= block.timestamp) revert InvalidWindow();

        if (parentId != 0) {
            Mandate storage p = _mandates[parentId];
            if (p.agent == address(0)) revert ParentNotFound();
            if (p.agent != msg.sender) revert NotParentAgent();
            // monotonic narrowing: child ⊆ parent
            if (budget > p.budget || validFrom < p.validFrom || validUntil > p.validUntil || p.revoked) {
                revert ExceedsParent();
            }
        }

        id = nextId++;
        _mandates[id] = Mandate({
            principal: msg.sender,
            agent: agent,
            mandateHash: mandateHash,
            authorityRef: authorityRef,
            parentId: parentId,
            budget: budget,
            validFrom: validFrom,
            validUntil: validUntil,
            revoked: false
        });

        emit MandateCommitted(id, parentId, agent, msg.sender, mandateHash, authorityRef, budget, validFrom, validUntil);
    }

    /// @notice Principal (or any ancestor principal) may revoke. Revocation is sticky.
    function revoke(uint256 id) external {
        if (!_isAuthority(id, msg.sender)) revert NotAuthorized();
        _mandates[id].revoked = true;
        emit MandateRevoked(id, msg.sender);
    }

    /// @notice Bond contract calls this on proven violation (sticky revoke by authority = bond).
    function revokeByBond(uint256 id) external {
        // Minimal trust model for Sprint 0: anyone can call, but only Bond is expected to.
        // Hardening (access control to a registered Bond) is a v0.2 item.
        _mandates[id].revoked = true;
        emit MandateRevoked(id, msg.sender);
    }

    function get(uint256 id) external view returns (Mandate memory) {
        return _mandates[id];
    }

    /// @notice A mandate is live if it and every ancestor are unrevoked and inside their windows.
    function isLive(uint256 id) public view returns (bool) {
        uint256 cur = id;
        uint256 guard = 0;
        while (cur != 0 && guard < 64) {
            Mandate storage m = _mandates[cur];
            if (m.agent == address(0) || m.revoked) return false;
            if (block.timestamp < m.validFrom || block.timestamp > m.validUntil) return false;
            cur = m.parentId;
            guard++;
        }
        return id != 0;
    }

    function _isAuthority(uint256 id, address who) internal view returns (bool) {
        uint256 cur = id;
        uint256 guard = 0;
        while (cur != 0 && guard < 64) {
            Mandate storage m = _mandates[cur];
            if (m.principal == who) return true;
            cur = m.parentId;
            guard++;
        }
        return false;
    }
}
