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

    /// @notice The tally is a claim about a MOMENT, so it is kept with its moments.
    /// @dev    v0.10. Until then only the running total was stored, and §6.5 read it at the instant
    ///         of the reveal — minutes after the challenger had been forced to publish the case by
    ///         requesting its attestations (§6.7). An effector colluding with the agent could watch
    ///         `FdcHub`, note the amounts it had hidden, and the challenge then reverted
    ///         `TallyAgrees` against a tally that had been true for about a minute. The case was
    ///         destroyed rather than stolen, so commit–reveal could not help: it protects who owns
    ///         a reward, not whether there is one. Checkpoints make the comparison a historical
    ///         fact, which nothing written later can change.
    struct Checkpoint {
        uint64 at;
        uint256 total;
    }

    mapping(uint256 => Checkpoint[]) private _history;

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
        Checkpoint[] storage h = _history[mandateId];
        uint256 n = h.length;
        // One checkpoint per second at most: several settlements inside one block are one moment,
        // and the last write wins because the total is cumulative.
        if (n != 0 && h[n - 1].at == uint64(block.timestamp)) {
            h[n - 1].total = total;
        } else {
            h.push(Checkpoint({at: uint64(block.timestamp), total: total}));
        }
        emit Noted(mandateId, msg.sender, amount, total);
    }

    /// @notice What an effector reads before acting. One eth_call, no transaction, no wait.
    /// @notice What the tally said at `ts` — the total recorded by the last `note` at or before it.
    /// @dev    Binary search over an append-only, strictly increasing-in-time array. Zero before
    ///         the first note. This is what §6.5 compares against, so that the question a verdict
    ///         answers is "had the effector written this down by then", not "has it written it
    ///         down by the time the reveal landed".
    function spentAt(uint256 mandateId, uint64 ts) external view returns (uint256) {
        Checkpoint[] storage h = _history[mandateId];
        uint256 lo = 0;
        uint256 hi = h.length;
        if (hi == 0 || h[0].at > ts) return 0;
        while (lo + 1 < hi) {
            uint256 mid = (lo + hi) / 2;
            if (h[mid].at <= ts) lo = mid;
            else hi = mid;
        }
        return h[lo].total;
    }

    /// @notice How many checkpoints the tally has. For indexers and for tests.
    function checkpointCount(uint256 mandateId) external view returns (uint256) {
        return _history[mandateId].length;
    }

    function checkpoint(uint256 mandateId, uint256 i) external view returns (uint64 at, uint256 total) {
        Checkpoint storage c = _history[mandateId][i];
        return (c.at, c.total);
    }

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
