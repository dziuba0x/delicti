// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {MandateRegistry} from "./MandateRegistry.sol";

/// @title SpendMeter — the running tally an effector keeps against a mandate's budget
/// @notice DELICTI, the fast half of layer 4.
///
///         Everything else in DELICTI is evidence after the fact: an FDC attestation takes
///         minutes, so a structuring attack succeeds and is only *punished* later. The brake
///         in SPEC §7 could not see it, because it judges one call at a time and every call
///         is inside its limit.
///
///         This is the missing piece. The effector keeps a cumulative tally here, one SSTORE
///         per settlement, and reads `wouldExceed` before it acts — an `eth_call`, so the
///         payment path stays fast. The fifth slice of the salami is refused in milliseconds
///         instead of being slashed four minutes later.
///
///         An effector can of course simply not write. That is the point of the division of
///         labour: the fast path protects against the honest-but-constrained agent, and the
///         slow path (Bond.challengeUnderReportedSpend) convicts the effector whose tally
///         disagrees with what the FDC proves actually happened. The meter is witness 1 over
///         the *sequence*, not over a single deed — so a divergence still carries two
///         witnesses and §5 is not weakened.
///
///         The meter is never on its own a reason to slash. It refuses, it records, it is read.
contract SpendMeter {
    MandateRegistry public immutable registry;

    /// @notice Cumulative amount the declared effectors have recorded against this mandate,
    ///         in the unit the mandate's envelope names. May exceed `budget`: the meter records
    ///         what happened, it does not flatter anyone.
    mapping(uint256 => uint256) public spent;

    /// @notice mandateId => address allowed to record against it. The principal chooses, because
    ///         the principal is the party harmed by an effector that lies or stays silent.
    mapping(uint256 => mapping(address => bool)) public effector;

    /// @notice Whether any effector was ever declared — a mandate nobody meters cannot be
    ///         challenged for under-reporting, because it never promised a tally.
    mapping(uint256 => bool) public metered;

    event EffectorDeclared(uint256 indexed mandateId, address indexed effector, address indexed by);
    event Noted(uint256 indexed mandateId, address indexed effector, uint256 amount, uint256 total);

    error NotPrincipal();
    error NotEffector();
    error MandateNotLive();
    error ZeroEffector();

    constructor(MandateRegistry _registry) {
        registry = _registry;
    }

    /// @notice The principal names an address allowed to keep this mandate's tally.
    /// @dev    Add-only. Revoking the mandate is how you stop an effector; a mandate that is not
    ///         live can neither be metered nor acted under.
    function declareEffector(uint256 mandateId, address e) external {
        if (e == address(0)) revert ZeroEffector();
        if (msg.sender != registry.get(mandateId).principal) revert NotPrincipal();
        effector[mandateId][e] = true;
        metered[mandateId] = true;
        emit EffectorDeclared(mandateId, e, msg.sender);
    }

    /// @notice Record a settlement against the mandate. Called by the effector after the funds
    ///         moved, so the tally reflects deeds, not intentions.
    /// @dev    Deliberately does NOT revert when the total passes the budget. A meter that
    ///         refuses to record an overrun is a meter that lies about it, and the overrun has
    ///         to stay publicly visible — that is what makes the brake meaningful to the next
    ///         caller and the divergence provable to a challenger.
    function note(uint256 mandateId, uint256 amount) external {
        if (!effector[mandateId][msg.sender]) revert NotEffector();
        if (!registry.isLive(mandateId)) revert MandateNotLive();
        uint256 total = spent[mandateId] + amount;
        spent[mandateId] = total;
        emit Noted(mandateId, msg.sender, amount, total);
    }

    /// @notice What an effector reads before acting. One eth_call, no transaction, no wait.
    function wouldExceed(uint256 mandateId, uint256 amount) external view returns (bool) {
        return spent[mandateId] + amount > registry.get(mandateId).budget;
    }

    /// @notice Budget left according to the tally; 0 once the budget is reached or passed.
    function headroom(uint256 mandateId) external view returns (uint256) {
        uint256 budget = registry.get(mandateId).budget;
        uint256 used = spent[mandateId];
        return used >= budget ? 0 : budget - used;
    }

    /// @notice True when the recorded tally has already passed the budget. Public, instant, and
    ///         readable by any counterparty — but not, on its own, grounds for a slash (§5).
    function exceeded(uint256 mandateId) external view returns (bool) {
        return spent[mandateId] > registry.get(mandateId).budget;
    }
}
