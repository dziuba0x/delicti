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
        // --- v0.9: appended, never inserted. `get()` returns a static tuple, so a reader built
        //     against the nine fields above (flario's mandate gate) keeps decoding the prefix.
        bytes32 sourceId;      // FDC source the deeds happen on ("testFLR", "XRP", …). The unit's chain.
        bytes32 assetKey;      // what `budget` counts: 0 = the source's native asset; on an EVM source,
                               // the ERC-20 address left-padded to 32 bytes
        bytes32 agentRef;      // the agent's identity on a non-EVM source: FDC standard address hash
                               // (keccak256 of the r-address on XRPL). 0 on EVM sources, where `agent` is it.
        address bond;          // the one consequence contract allowed to revoke this mandate on proof
    }

    /// @notice The part of a mandate that says what the budget is *made of* and who may enforce it.
    ///         A separate struct only so that `commit` stays callable without a stack of eleven words.
    struct Terms {
        bytes32 sourceId;
        bytes32 assetKey;
        bytes32 agentRef;
        address bond;
    }

    uint256 public nextId = 1;
    mapping(uint256 => Mandate) private _mandates;

    /// @notice When a mandate was revoked (0 = never). Needed because the Bond's cooling
    ///         window must run from the moment authority actually died, and revocation can
    ///         happen long before `validUntil`.
    mapping(uint256 => uint64) public revokedAt;

    /// @notice Mandates whose agent has declared that, inside the mandate's window, this
    ///         address acts ONLY under this mandate — so every FDC-observable deed from it
    ///         must show up as an anchored leaf. Declared by the agent, never by anyone else:
    ///         it is a promise the agent makes about itself, and it is what makes silence
    ///         challengeable (SPEC 6.4). Sticky, like revocation.
    mapping(uint256 => bool) public exclusive;

    /// @notice Mandates their agent has acknowledged. A mandate names its agent unilaterally — the
    ///         principal writes the address — so until the agent says "yes, that is me, and those
    ///         are my terms" a mandate is a claim ABOUT an address, not a commitment BY it. Two
    ///         things go wrong without this: a principal can name a stranger's busy address, anchor
    ///         receipts for it (principals may anchor) and collect a third party's bond; and the same
    ///         trick poisons the stranger's contradiction rate in any public score built on top.
    ///         The Bond refuses collateral for an unacknowledged mandate. Sticky.
    mapping(uint256 => bool) public acknowledged;

    // There is deliberately no deployer, no owner and no global Bond. Until v0.8 the registry had a
    // set-once `bond` chosen by whoever deployed it, which meant every new challenge type needed a
    // new Bond, a new Bond needed a new registry, and a new registry orphaned every mandate ever
    // committed. Each mandate now names its own consequence contract (`Mandate.bond`): that
    // contract can revoke that mandate and nothing else, which is a power the mandate's principal
    // already holds. New consequence contracts can therefore be deployed over the same registry,
    // log and meter, and the registry itself has no privileged key at all.

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
    /// @dev Second half of `MandateCommitted`, emitted in the same transaction. Separate because the
    ///      first event's signature is what existing indexers already filter on.
    event MandateTerms(uint256 indexed id, bytes32 indexed sourceId, bytes32 assetKey, bytes32 agentRef, address indexed bond);
    event MandateRevoked(uint256 indexed id, address indexed by);
    event MandateAcknowledged(uint256 indexed id, address indexed agent);
    event ExclusiveDeclared(uint256 indexed id, address indexed agent);

    error InvalidWindow();
    error ParentNotFound();
    error NotParentAgent();
    error ExceedsParent();
    error NotAuthorized();
    error ZeroAgent();
    error NotBond();
    error NoSource();
    error ChangesParentAsset();
    error NotAgent();
    error MandateNotLive();

    /// @notice Commit a mandate. For a child mandate, msg.sender must be the parent's agent
    ///         (the delegating agent), and the child must be within the parent's envelope.
    function commit(
        address agent,
        bytes32 mandateHash,
        bytes32 authorityRef,
        uint256 parentId,
        uint256 budget,
        uint64 validFrom,
        uint64 validUntil,
        Terms calldata terms
    ) external returns (uint256 id) {
        if (agent == address(0)) revert ZeroAgent();
        // A budget is a number of *something*, *somewhere*. Until v0.9 both lived only in the
        // off-chain envelope, so nobody posting collateral could read on-chain what it insured.
        if (terms.sourceId == bytes32(0)) revert NoSource();
        if (validUntil <= validFrom || validUntil <= block.timestamp) revert InvalidWindow();

        if (parentId != 0) {
            Mandate storage p = _mandates[parentId];
            if (p.agent == address(0)) revert ParentNotFound();
            if (p.agent != msg.sender) revert NotParentAgent();
            // monotonic narrowing: child ⊆ parent
            if (budget > p.budget || validFrom < p.validFrom || validUntil > p.validUntil || p.revoked) {
                revert ExceedsParent();
            }
            // Narrowing attenuates a quantity; it cannot change what the quantity is. A child in
            // another asset, or on another chain, is not a smaller share of the parent's budget —
            // it is a different budget, and `budget <= p.budget` would be comparing drops to wei.
            if (terms.sourceId != p.sourceId || terms.assetKey != p.assetKey) revert ChangesParentAsset();
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
            revoked: false,
            sourceId: terms.sourceId,
            assetKey: terms.assetKey,
            agentRef: terms.agentRef,
            bond: terms.bond
        });

        emit MandateCommitted(id, parentId, agent, msg.sender, mandateHash, authorityRef, budget, validFrom, validUntil);
        emit MandateTerms(id, terms.sourceId, terms.assetKey, terms.agentRef, terms.bond);
    }

    /// @notice The agent accepts the mandate as written: its address, its budget, its asset, its
    ///         source, its `agentRef`, its consequence contract. Only the agent can, and it cannot
    ///         be taken back. Allowed before `validFrom` (that is when a careful agent would do it)
    ///         but not on a mandate that is already revoked.
    function acknowledge(uint256 id) external {
        if (msg.sender != _mandates[id].agent) revert NotAgent();
        if (_mandates[id].revoked) revert MandateNotLive();
        _acknowledge(id);
    }

    function _acknowledge(uint256 id) internal {
        if (acknowledged[id]) return;
        acknowledged[id] = true;
        emit MandateAcknowledged(id, msg.sender);
    }

    /// @notice The agent binds its own address to this mandate for the mandate's window:
    ///         every deed from it that the FDC can see is expected to be anchored. Only the
    ///         agent can make this promise, and it cannot be taken back — otherwise an agent
    ///         would simply withdraw it the moment it wanted to act unobserved.
    function declareExclusive(uint256 id) external {
        if (msg.sender != _mandates[id].agent) revert NotAgent();
        if (!isLive(id)) revert MandateNotLive();
        _acknowledge(id); // a promise about the mandate is a fortiori an acceptance of it
        exclusive[id] = true;
        emit ExclusiveDeclared(id, msg.sender);
    }

    /// @notice Principal (or any ancestor principal) may revoke. Revocation is sticky.
    function revoke(uint256 id) external {
        if (!_isAuthority(id, msg.sender)) revert NotAuthorized();
        _revoke(id);
    }

    /// @notice Bond calls this on a proven violation (sticky revoke by authority = bond).
    /// @dev    Access control matters beyond tidiness: revocation kills `isLive`, which stops
    ///         the agent anchoring anything (AnchorLog), makes a DELICTI-aware effector refuse
    ///         to act (SPEC 7), and opens the principal's withdrawal path. An unguarded
    ///         revoke is censorship of the evidence layer for the price of one transaction.
    function revokeByBond(uint256 id) external {
        address b = _mandates[id].bond;
        if (b == address(0) || msg.sender != b) revert NotBond();
        _revoke(id);
    }

    function _revoke(uint256 id) internal {
        _mandates[id].revoked = true;
        if (revokedAt[id] == 0) revokedAt[id] = uint64(block.timestamp);
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
        // Fail closed: a delegation chain deeper than the guard is treated as dead, not alive.
        // The other way round, 65 self-delegations would make a mandate unrevokable by its root.
        return id != 0 && cur == 0;
    }

    /// @notice The moment this mandate's authority died (or will die): the earliest of its own
    ///         and every ancestor's revocation time or `validUntil`. `type(uint64).max` while
    ///         the answer is unknowable (chain deeper than the guard, or unknown mandate).
    /// @dev    The Bond's cooling window runs from here, so a principal cannot shorten a
    ///         challenger's runway by revoking early.
    function deathTime(uint256 id) external view returns (uint64) {
        if (id == 0) return type(uint64).max;
        uint256 cur = id;
        uint256 guard = 0;
        uint64 death = type(uint64).max;
        while (cur != 0 && guard < 64) {
            Mandate storage m = _mandates[cur];
            if (m.agent == address(0)) return type(uint64).max;
            uint64 own = revokedAt[cur] != 0 && revokedAt[cur] < m.validUntil ? revokedAt[cur] : m.validUntil;
            if (own < death) death = own;
            cur = m.parentId;
            guard++;
        }
        if (cur != 0) return type(uint64).max;
        return death;
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
