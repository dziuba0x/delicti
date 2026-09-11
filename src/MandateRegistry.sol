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

    /// @notice The Bond allowed to call `revokeByBond`. Set once, by the deployer.
    address public bond;
    address private immutable _deployer;

    constructor() {
        _deployer = msg.sender;
    }

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
    event ExclusiveDeclared(uint256 indexed id, address indexed agent);

    error InvalidWindow();
    error ParentNotFound();
    error NotParentAgent();
    error ExceedsParent();
    error NotAuthorized();
    error ZeroAgent();
    error NotBond();
    error BondAlreadySet();
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

    /// @notice Bind the Bond permitted to revoke on a proven violation. Set once, by the
    ///         deployer, because Bond and MandateRegistry cannot both be constructor
    ///         arguments to each other.
    function setBond(address b) external {
        if (msg.sender != _deployer) revert NotAuthorized();
        if (bond != address(0)) revert BondAlreadySet();
        bond = b;
    }

    /// @notice The agent binds its own address to this mandate for the mandate's window:
    ///         every deed from it that the FDC can see is expected to be anchored. Only the
    ///         agent can make this promise, and it cannot be taken back — otherwise an agent
    ///         would simply withdraw it the moment it wanted to act unobserved.
    function declareExclusive(uint256 id) external {
        if (msg.sender != _mandates[id].agent) revert NotAgent();
        if (!isLive(id)) revert MandateNotLive();
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
        if (msg.sender != bond || bond == address(0)) revert NotBond();
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
