// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ContractRegistry} from "@flarenetwork/flare-periphery-contracts/coston2/ContractRegistry.sol";
import {ProtocolsV2Interface} from "@flarenetwork/flare-periphery-contracts/coston2/ProtocolsV2Interface.sol";
import {IFlareContractRegistry} from "@flarenetwork/flare-periphery-contracts/coston2/IFlareContractRegistry.sol";
import {IFdcRequestFeeConfigurations} from
    "@flarenetwork/flare-periphery-contracts/coston2/IFdcRequestFeeConfigurations.sol";
import {MandateRegistry} from "./MandateRegistry.sol";
import {AgentRefs} from "./AgentRefs.sol";
import {DelictiErrors} from "./DelictiErrors.sol";
import {Kinds} from "./Kinds.sol";

/// @notice What a Vault asks of each contract it lets pass verdicts.
/// @dev The one FdcHub function the Vault forwards to.
interface IFdcHubLike {
    function requestAttestation(bytes calldata data) external payable;
}

interface IJudge {
    function vault() external view returns (address);
}

/// @title Vault — the collateral, the books, and the one gate every challenge passes through
/// @notice DELICTI, layer 4, v0.11. Until v0.10 all of this lived in `Bond` together with the logic of
///         every challenge type, and the contract ended 242 bytes under EIP-170: the next challenge
///         type could not be added at all. The split (SPEC §8.2):
///
///         - the **Vault** holds every wei — bonds, credited proceeds, accusation stakes — and is the
///           only contract that moves value, so there is one balance to reason about;
///         - **judges** hold no funds. Each verifies one family of evidence and, when it stands, asks
///           the Vault for a verdict. The set of judges is fixed in the constructor: no admin, no
///           upgrade, no setter. A deposit is exposed to exactly the judges that existed when it was
///           made, and a depositor can read which they are before posting (EigenLayer ELIP-002 calls
///           this unique stake; here it is simply immutability).
///
///         A new challenge type is a new Vault over (the old judges + the new one). Mandates already
///         bonded stay with the Vault they name; new mandates name the new one (`Terms.bond`). The
///         registry, the anchor log and the meter do not change.
contract Vault is DelictiErrors {
    MandateRegistry public immutable registry;
    /// @notice Where accounts on other chains confirm the mandates that name them (SPEC §6.8).
    AgentRefs public immutable agentRefs;
    /// @dev 0 => resolve via ContractRegistry. Only the voting-round clock.
    ProtocolsV2Interface private immutable _protocolsOverride;

    /// @notice The judges, in constructor order, and a lookup for the gate.
    address[] private _judges;
    mapping(address => bool) public isJudge;

    uint256 public constant CHALLENGER_BPS = 1000; // 10% of what a verdict takes goes to the challenger

    // Commitment kinds, exposed for tooling. Their meaning is in `Kinds`.
    uint8 public constant KIND_FALSE_PAYMENT = Kinds.FALSE_PAYMENT;
    uint8 public constant KIND_BUDGET_NATIVE = Kinds.BUDGET_NATIVE;
    uint8 public constant KIND_BUDGET_ERC20 = Kinds.BUDGET_ERC20;
    uint8 public constant KIND_UNANCHORED_DEED = Kinds.UNANCHORED_DEED;
    uint8 public constant KIND_UNDER_REPORTED = Kinds.UNDER_REPORTED;
    uint8 public constant KIND_BUDGET_PAYMENT = Kinds.BUDGET_PAYMENT;
    uint8 public constant KIND_XRP_OUTFLOW = Kinds.XRP_OUTFLOW;
    uint8 public constant KIND_ERC20_OUTFLOW = Kinds.ERC20_OUTFLOW;

    // -----------------------------------------------------------------------------------
    // Proportional slashing (SPEC §8.1).
    //
    //     P(s) = clamp( base * s / budget ,  base * MIN_SLASH_BPS / 10_000 ,  base )
    //
    // `s` is the mandate's total proven severity in its own unit, `base` the bond as it stood at
    // the FIRST verdict. The slope is bond/budget, the collateralisation ratio the market chose.
    // Severity ACCUMULATES and each verdict takes the difference between the penalty for the new
    // total and what was already taken: "slashed at most once" plus a proportional penalty would
    // let an agent convict itself of a trivial breach and shield the rest of the bond.
    //   - NESTED kinds (every budget kind; under-reported spend) keep a high-water mark.
    //   - ADDITIVE kinds (false payment; unanchored deed) sum: each verdict is about a different
    //     receipt or transaction, which the judge that passes it guarantees.
    // -----------------------------------------------------------------------------------

    /// @notice The least any proven breach costs, as a share of the bond at first verdict (10%).
    uint256 public constant MIN_SLASH_BPS = 1000;

    mapping(uint256 => uint256) public slashBase;
    mapping(uint256 => uint256) public slashedAmount;
    mapping(uint256 => uint256) public severityOf;
    mapping(uint256 => mapping(uint8 => uint256)) public severityIn;

    /// @notice agent => verdicts against mandates it had acknowledged, and what they took. This
    ///         Vault's history only.
    mapping(address => uint256) public verdictsAgainst;
    mapping(address => uint256) public takenFrom;

    mapping(uint256 => mapping(address => uint256)) public depositOf;
    mapping(uint256 => uint256) public totalDeposits;

    // -----------------------------------------------------------------------------------
    // The surety rule (v0.12, SPEC §8.3): a deposit compensates whom its depositor names.
    //
    // Until v0.12 the remainder of every verdict went to the principal, whoever had posted the
    // money. That made a third party's deposit a prize for the one collusion no challenge can
    // detect: principal and agent agree, the agent "overruns" by paying an address the principal
    // controls, and the verdict hands the principal the insurer's collateral. The protocol cannot
    // tell a principal from its sock puppet, so it stops pretending to know who was harmed and
    // asks the party that bears the risk. Each depositor names a beneficiary once per mandate:
    //
    //   - the principal and the agent, posting with `post`, name the principal (as before);
    //   - anyone else, posting with `post`, names ITSELF — no third party's money reaches the
    //     principal unless that third party says so (`postFor(mandateId, principal)`);
    //   - `postFor` names anyone: the insured venue, a merchant, a burn address.
    //
    // A verdict still takes the same fraction of every deposit (pro rata, §8.1) and still pays the
    // challenger first. What changes is where the REST of each deposit's share goes. Colluders
    // can then extract from an outsider's deposit only the challenger's reward — bounded by
    // `CHALLENGER_BPS` of what the verdict took plus the attestation fees they really paid —
    // instead of all of it.
    //
    // Principal-side shares are credited at the verdict, exactly as before. Every other share
    // accrues per unit of deposit and is credited to its beneficiary by `settle` (anyone may call
    // it; `withdraw` calls it too), so a verdict costs the same gas whatever the number of depositors.
    // -----------------------------------------------------------------------------------

    /// @notice mandateId => depositor => who that deposit compensates. Fixed at its first post.
    mapping(uint256 => mapping(address => address)) public beneficiaryOf;
    /// @notice mandateId => deposits whose beneficiary is the mandate's principal.
    mapping(uint256 => uint256) public principalSide;
    /// @notice mandateId => remainder per unit of non-principal deposit, scaled by `ACC_SCALE`.
    mapping(uint256 => uint256) public remainderPerUnit;
    /// @dev 1e36, not 1e18: the per-unit division is followed by a multiplication in `settle`, and at
    ///      this scale what rounding keeps back is below one wei per 1e18 FLR of deposit. The largest
    ///      product, deposit × accumulator, stays under 1e66 for any real amount of FLR.
    uint256 private constant ACC_SCALE = 1e36;
    /// @notice mandateId => depositor => how much of its accrued remainder was already credited.
    mapping(uint256 => mapping(address => uint256)) public remainderSettled;
    /// @notice mandateId => remainder accrued to non-principal deposits and not yet credited.
    ///         Holds a few wei of rounding for ever; that is what makes the books exact.
    mapping(uint256 => uint256) public unsettled;

    /// @notice How long the bond stays frozen after the mandate's authority died. A challenge needs
    ///         an on-chain FDC request, a finalised round and a DA fetch; without the window the
    ///         principal empties the bond in the transaction that revokes the mandate.
    uint64 public constant COOLING_WINDOW = 24 hours;

    /// @dev Flare's ContractRegistry, the same address on every Flare network.
    address internal constant FLARE_REGISTRY = 0xaD67FE66660Fb8dFE9d6b1b4240d8650e30F6019;

    /// @notice Stake an accuser puts up (SPEC §6.4). Held here, not by the judge that took it, so that
    ///         every wei the protocol holds is in one contract under one invariant.
    uint256 public constant ACCUSATION_STAKE = 0.1 ether;

    /// @notice Accusations against a mandate that are neither answered nor resolved. While non-zero
    ///         the bond cannot be withdrawn.
    mapping(uint256 => uint256) public openAccusations;

    // -----------------------------------------------------------------------------------
    // Commit–reveal (SPEC §6.7). One gate for every judge: a commitment is
    //
    //   keccak256(abi.encode(challenger, mandateId, kind, deedsDigest, salt))
    //
    // and kinds are unique across judges, so no judge can spend another's commitment.
    // -----------------------------------------------------------------------------------

    /// @notice How much older than its evidence round a commitment must be. See SPEC §6.7 for why
    ///         `committedAt < roundStart(R)` alone does not close the copier's later-round race.
    uint64 public immutable commitLead;

    /// @notice How stale a commitment may be when revealed. A constant: a deployer with discretion
    ///         over it could set it just above `commitLead` and make challenges nearly untimeable.
    uint64 public constant COMMIT_TTL = 1 hours;

    mapping(bytes32 => uint64) public committedAt;

    mapping(uint256 => uint256) public bondOf;
    mapping(uint256 => bool) public slashed;

    /// @notice Slash proceeds, challenger rewards and returned stakes, held for pull-withdrawal.
    mapping(address => uint256) public owed;

    event BondPosted(uint256 indexed mandateId, address indexed by, uint256 amount, uint256 total);
    event BondWithdrawn(uint256 indexed mandateId, address indexed by, address to, uint256 amount);
    event BeneficiaryNamed(uint256 indexed mandateId, address indexed depositor, address indexed beneficiary);
    event RemainderSettled(uint256 indexed mandateId, address indexed depositor, address indexed beneficiary, uint256 amount);
    event Claimed(address indexed who, uint256 amount);
    event ChallengeCommitted(bytes32 indexed commitment, address indexed by, uint64 at);
    event CommitmentConsumed(bytes32 indexed commitment, uint256 indexed mandateId, uint8 kind, uint64 votingRound);
    /// @notice Every verdict, whatever its kind and whichever judge passed it, in one shape.
    event Verdict(
        uint256 indexed mandateId,
        address indexed challenger,
        uint8 indexed kind,
        uint256 severity,
        uint256 severityTotal,
        uint256 budget,
        uint256 taken,
        uint256 reward,
        uint256 slashedTotal
    );

    modifier onlyJudge() {
        if (!isJudge[msg.sender]) revert NotJudge();
        _;
    }

    /// @param judges every contract that may pass verdicts on this Vault's bonds, for ever. Each must
    ///        already exist and name this Vault as its own — deploy them first, at the address this
    ///        Vault will have (`vm.computeCreateAddress`). A judge pointing at another Vault could
    ///        never be called back, and one that is not a judge at all would be a key, not code.
    constructor(
        MandateRegistry _registry,
        AgentRefs agentRefs_,
        ProtocolsV2Interface protocolsOverride,
        uint64 commitLead_,
        address[] memory judges
    ) {
        if (judges.length == 0) revert NoJudges();
        registry = _registry;
        agentRefs = agentRefs_;
        _protocolsOverride = protocolsOverride;
        commitLead = commitLead_;
        for (uint256 i = 0; i < judges.length; i++) {
            if (IJudge(judges[i]).vault() != address(this)) revert JudgeOfAnotherVault();
            isJudge[judges[i]] = true;
            _judges.push(judges[i]);
        }
    }

    function judges() external view returns (address[] memory) {
        return _judges;
    }

    // -----------------------------------------------------------------------------------
    // Round clock
    // -----------------------------------------------------------------------------------

    function protocols() public view returns (ProtocolsV2Interface) {
        if (address(_protocolsOverride) != address(0)) return _protocolsOverride;
        return ContractRegistry.getProtocolsV2();
    }

    function roundStartTs(uint64 round) public view returns (uint64) {
        ProtocolsV2Interface p = protocols();
        return p.firstVotingRoundStartTs() + round * p.votingEpochDurationSeconds();
    }

    // -----------------------------------------------------------------------------------
    // Commit side (open to anyone)
    // -----------------------------------------------------------------------------------

    /// @notice Stake a claim on a challenge you have found but cannot prove yet. Idempotent, keeping
    ///         the EARLIEST submission: a replay must not be able to push a victim's commitment
    ///         past `commitLead`.
    function commitChallenge(bytes32 commitment) external {
        uint64 at = committedAt[commitment];
        if (at == 0) {
            at = uint64(block.timestamp);
            committedAt[commitment] = at;
        }
        emit ChallengeCommitted(commitment, msg.sender, at);
    }

    function commitmentFor(address challenger, uint256 mandateId, uint8 kind, bytes32 digest, bytes32 salt)
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(challenger, mandateId, kind, digest, salt));
    }

    function deedsDigest(bytes32[] calldata deedIds) external pure returns (bytes32) {
        return keccak256(abi.encode(deedIds));
    }

    /// @notice Spend `challenger`'s commitment for this case, or refuse the reveal.
    /// @dev    Judges only. The judge passes its own `msg.sender` as `challenger`; judges are code
    ///         fixed at this Vault's construction, so the argument is as trustworthy as the caller.
    /// @param minVotingRound the LOWEST voting round among the case's proofs, so one fresh proof
    ///        cannot launder a stale commitment.
    function consumeCommitment(
        address challenger,
        uint8 kind,
        uint256 mandateId,
        bytes32 digest,
        bytes32 salt,
        uint64 minVotingRound
    ) external onlyJudge {
        bytes32 c = commitmentFor(challenger, mandateId, kind, digest, salt);
        uint64 at = committedAt[c];
        if (at == 0) revert NoCommitment();

        uint64 rs = roundStartTs(minVotingRound);
        // A finalised round cannot have begun in the future. Fails closed if Flare's epoch clock
        // ever stops being linear (SPEC §6.7, §10).
        if (rs > block.timestamp) revert ClockDrift();
        if (uint256(at) + commitLead > rs) revert CommittedTooLate();
        if (uint256(at) + COMMIT_TTL < rs) revert CommitmentStale();

        delete committedAt[c]; // single use
        emit CommitmentConsumed(c, mandateId, kind, minVotingRound);
    }

    // -----------------------------------------------------------------------------------
    // Deposits
    // -----------------------------------------------------------------------------------

    /// @notice Anyone may post bond under a mandate (agent, operator, or an insurer). The principal
    ///         and the agent compensate the principal; anyone else compensates itself (§8.3).
    function post(uint256 mandateId) external payable {
        MandateRegistry.Mandate memory m = registry.get(mandateId);
        _post(mandateId, m, (msg.sender == m.principal || msg.sender == m.agent) ? m.principal : msg.sender);
    }

    /// @notice Post bond that compensates `beneficiary` — the party this depositor insures.
    function postFor(uint256 mandateId, address beneficiary) external payable {
        if (beneficiary == address(0)) revert NoBeneficiary();
        _post(mandateId, registry.get(mandateId), beneficiary);
    }

    function _post(uint256 mandateId, MandateRegistry.Mandate memory m, address beneficiary) internal {
        if (slashed[mandateId]) revert BondSlashed();
        // Only this Vault can revoke the mandate on proof; posted anywhere else, the deposit would
        // merely look like collateral.
        if (m.bond != address(this)) revert NotThisBond();
        // A mandate is a claim ABOUT an address until the agent accepts it.
        if (!registry.acknowledged(mandateId)) revert NotAcknowledged();
        // ...and the account on the other chain must have said so itself.
        if (m.agentRef != bytes32(0) && !agentRefs.proven(mandateId)) revert AgentRefNotProven();
        address named = beneficiaryOf[mandateId][msg.sender];
        if (named == address(0)) {
            beneficiaryOf[mandateId][msg.sender] = beneficiary;
            emit BeneficiaryNamed(mandateId, msg.sender, beneficiary);
        } else if (named != beneficiary) {
            revert BeneficiaryFixed();
        }
        if (beneficiary == m.principal) principalSide[mandateId] += msg.value;
        // No verdict has happened yet (a slashed mandate takes no deposits), so nothing has accrued
        // and the new deposit owes nothing to the past.
        bondOf[mandateId] += msg.value;
        depositOf[mandateId][msg.sender] += msg.value;
        totalDeposits[mandateId] += msg.value;
        emit BondPosted(mandateId, msg.sender, msg.value, bondOf[mandateId]);
    }

    /// @notice A depositor takes back its pro-rata share of what the verdicts left, once the
    ///         mandate's authority has died, the cooling window has elapsed, and no accusation is
    ///         open. The window runs from `registry.deathTime()`, so revoking early does not shorten it.
    function withdraw(uint256 mandateId, address payable to) external {
        uint256 dep = depositOf[mandateId][msg.sender];
        if (dep == 0) revert NoDeposit();
        _requireSettledDeath(mandateId);
        settle(mandateId, msg.sender); // the beneficiary is owed its share before the deposit leaves
        uint256 amt = (dep * bondOf[mandateId]) / totalDeposits[mandateId];
        if (beneficiaryOf[mandateId][msg.sender] == registry.get(mandateId).principal) principalSide[mandateId] -= dep;
        depositOf[mandateId][msg.sender] = 0;
        remainderSettled[mandateId][msg.sender] = 0;
        totalDeposits[mandateId] -= dep;
        bondOf[mandateId] -= amt;
        emit BondWithdrawn(mandateId, msg.sender, to, amt);
        (bool ok,) = to.call{value: amt}("");
        if (!ok) revert TransferFailed();
    }

    /// @dev The mandate's authority died at least `COOLING_WINDOW` ago and no accusation is open:
    ///      the moment collateral — and, since v0.14, an unspent watch pool — may leave.
    function _requireSettledDeath(uint256 mandateId) internal view {
        if (registry.isLive(mandateId)) revert MandateStillLive();
        uint64 death = registry.deathTime(mandateId);
        if (death == type(uint64).max || block.timestamp < uint256(death) + COOLING_WINDOW) revert CoolingWindow();
        if (openAccusations[mandateId] != 0) revert AccusationOpen();
    }

    // -----------------------------------------------------------------------------------
    // The watch pool (v0.14, reworked in v0.15; SPEC §8.4): paying for the docket to be kept.
    //
    // A crossing bounty alone pays watchers nothing when the agent behaves, which is exactly the
    // outcome the protocol exists to produce. Lightning's watchtowers ran into this deterrence
    // paradox, and their reward towers were never shipped (docs/research/watchers.md).
    //
    // WHO FUNDS: the principal, nobody else. The principal sets the terms, so any other funder's
    // money would sit behind a rate the principal can raise: outsiders (v0.14 review) and, as the
    // v0.14 adversarial review showed with a working exploit, the agent too — agent funds, principal
    // raises `perDeed` to the whole pool, a sock puppet files one ordinary deed. The §8.3 answer
    // again: a party that wants a mandate watched and is not its principal posts bond.
    //
    // WHO IS PAID: whoever PAID FOR THE ATTESTATION, not whoever files it. Recordings below the
    // budget need no commitment, and an FDC proof works for whoever submits it, so in v0.14 a
    // copier could lift a watcher's proofs from the mempool (or from the public DA layer, using the
    // request the watcher paid FdcHub for), file first, and take every stipend while the watcher's
    // own filing reverted `NothingNew`. Since v0.15 attestations for stipend-paying deeds are
    // requested THROUGH this Vault (`requestAttestation`), which forwards the fee to FdcHub and
    // records the first payer of each request under a key the judge can rebuild from the proof:
    //
    //   deedKey = keccak256(abi.encode(attestationType, sourceId, keccak256(requestBody bytes)))
    //
    // (a request is attestationType ‖ sourceId ‖ messageIntegrityCode ‖ abi.encode(requestBody)
    // — measured against the verifier on 2026-09-24, test/FdcKey.t.sol). Filing becomes a public
    // service: a copier pays the gas to deliver someone else's stipend. And the key is claimed the
    // moment a watcher pays for it, so a second watcher can read `requesterOf` before buying the
    // same attestation — the race §10 described, closed without a separate claim step.
    //
    // WHAT IS PAID: `perDeed` for every NEW deed that moved positive value of at least `minValue`,
    // on any docket (§6.8, §6.10, §6.11), crossing or not. Anyone can make a token emit
    // `Transfer(agent, x, 0)` and anyone can send XRP TO the agent: provable, not the agent's act,
    // worth nothing here. Splitting one act into many deeds (an XRPL offer consumed in many fills,
    // each ≥ `minValue`) is bounded by `perDeed / minValue` per unit of value — the principal's
    // chosen price of watching — and each piece costs its requester a real attestation fee.
    //
    // WHEN IT CLOSES: the principal takes back what is left once no bond remains (nothing more can
    // be filed) or `WATCH_TAIL` after the cooling window — long enough for the deeds at the end of a
    // window to be proven on XRPL (~14 days).
    // -----------------------------------------------------------------------------------

    uint64 public constant WATCH_TAIL = 14 days;

    mapping(uint256 => uint256) public watchPool;
    mapping(uint256 => uint256) public stipendPerDeed;
    mapping(uint256 => uint256) public stipendMinValue;
    mapping(uint256 => bool) public watchTermsSet;
    mapping(uint256 => bool) public watchClosed;
    /// @notice deedKey => the first address that paid FdcHub for that attestation through this Vault
    mapping(bytes32 => address) public requesterOf;

    event WatchTerms(uint256 indexed mandateId, uint256 perDeed, uint256 minValue);
    event WatchFunded(uint256 indexed mandateId, uint256 amount, uint256 pool);
    event AttestationRequested(bytes32 indexed deedKey, address indexed requester, bytes32 attestationType, uint256 fee);
    event StipendPaid(uint256 indexed mandateId, bytes32 indexed deedKey, address indexed requester, uint256 paid);
    event WatchRefunded(uint256 indexed mandateId, address to, uint256 amount);

    /// @notice The principal's offer to watchers. Once set, it can only improve for them: the
    ///         stipend can rise and the minimum can fall. A principal who could cut the rate would
    ///         cut it under a watcher that has already paid for attestations.
    function setWatchTerms(uint256 mandateId, uint256 perDeed, uint256 minValue) external {
        MandateRegistry.Mandate memory m = registry.get(mandateId);
        if (msg.sender != m.principal) revert NotPrincipal();
        if (m.bond != address(this)) revert NotThisBond();
        if (watchClosed[mandateId]) revert WatchClosed();
        if (watchTermsSet[mandateId] && (perDeed < stipendPerDeed[mandateId] || minValue > stipendMinValue[mandateId])) {
            revert WatchTermsOnlyImprove();
        }
        watchTermsSet[mandateId] = true;
        stipendPerDeed[mandateId] = perDeed;
        stipendMinValue[mandateId] = minValue;
        emit WatchTerms(mandateId, perDeed, minValue);
    }

    /// @notice Pay into a mandate's watch pool. The principal only.
    function fundWatch(uint256 mandateId) external payable {
        MandateRegistry.Mandate memory m = registry.get(mandateId);
        if (msg.sender != m.principal) revert NotPrincipal();
        if (m.bond != address(this)) revert NotThisBond();
        if (watchClosed[mandateId]) revert WatchClosed();
        watchPool[mandateId] += msg.value;
        emit WatchFunded(mandateId, msg.value, watchPool[mandateId]);
    }

    /// @notice The key a judge rebuilds from a proof: type, source, and the hash of the request body.
    function deedKey(bytes32 attestationType, bytes32 sourceId, bytes32 requestBodyHash) public pure returns (bytes32) {
        return keccak256(abi.encode(attestationType, sourceId, requestBodyHash));
    }

    /// @notice Request an FDC attestation through the Vault: the fee (`msg.value`) is forwarded to
    ///         FdcHub unchanged, and the first payer of this request is recorded as the one a
    ///         stipend for the deed it proves will be paid to. Holds nothing.
    function requestAttestation(bytes calldata request) external payable returns (bytes32 key) {
        if (request.length < 128) revert BadRequest();
        key = deedKey(bytes32(request[0:32]), bytes32(request[32:64]), keccak256(request[96:]));
        if (requesterOf[key] == address(0)) requesterOf[key] = msg.sender;
        (bool ok, bytes memory r) = FLARE_REGISTRY.staticcall(
            abi.encodeCall(IFlareContractRegistry.getContractAddressByName, ("FdcHub"))
        );
        if (!ok || r.length != 32) revert BadRequest();
        IFdcHubLike(address(uint160(uint256(bytes32(r))))).requestAttestation{value: msg.value}(request);
        emit AttestationRequested(key, msg.sender, bytes32(request[0:32]), msg.value);
    }

    /// @notice A judge filed new, value-moving deeds, one per key: pay each deed's stipend to the
    ///         address that paid for its attestation here, as far as the pool goes. A deed nobody
    ///         requested through the Vault earns nothing. Never reverts on an empty or closed pool
    ///         — a filing must not fail because nobody paid for it.
    function stipend(uint256 mandateId, bytes32[] calldata keys) external onlyJudge returns (uint256 total) {
        uint256 rate = stipendPerDeed[mandateId];
        uint256 pool = watchPool[mandateId];
        if (rate == 0 || pool == 0 || watchClosed[mandateId]) return 0;
        for (uint256 i = 0; i < keys.length && pool != 0; i++) {
            address to = requesterOf[keys[i]];
            if (to == address(0)) continue;
            uint256 paid = rate > pool ? pool : rate;
            pool -= paid;
            total += paid;
            owed[to] += paid;
            emit StipendPaid(mandateId, keys[i], to, paid);
        }
        watchPool[mandateId] = pool;
    }

    /// @notice The principal takes back what the pool has left, once nothing more can be filed (no
    ///         bond left) or `WATCH_TAIL` past the cooling window. Closes the pool for good.
    function refundWatch(uint256 mandateId, address payable to) external {
        MandateRegistry.Mandate memory m = registry.get(mandateId);
        if (msg.sender != m.principal) revert NotPrincipal();
        if (registry.isLive(mandateId)) revert MandateStillLive();
        uint64 death = registry.deathTime(mandateId);
        if (bondOf[mandateId] != 0 && (death == type(uint64).max || block.timestamp < uint256(death) + COOLING_WINDOW + WATCH_TAIL)) {
            revert CoolingWindow();
        }
        uint256 amt = watchPool[mandateId];
        if (amt == 0) revert NothingFunded();
        watchClosed[mandateId] = true;
        watchPool[mandateId] = 0;
        emit WatchRefunded(mandateId, to, amt);
        (bool ok,) = to.call{value: amt}("");
        if (!ok) revert TransferFailed();
    }

    /// @notice What a verdict of this kind and severity would take right now — the same arithmetic
    ///         as `verdict`, read-only. Docket judges ask before spending a commitment: a crossing
    ///         that would take nothing (the severity is already covered, or a proportional increase
    ///         still under the 10 % floor already taken) is a recording, not a conviction.
    function wouldTake(uint8 kind, uint256 mandateId, uint256 budget, uint256 severity) public view returns (uint256 t) {
        uint256 prev = severityIn[mandateId][Kinds.bucket(kind)];
        uint256 add = Kinds.additive(kind) ? severity : (severity > prev ? severity - prev : 0);
        if (add == 0) return 0;
        uint256 total = severityOf[mandateId];
        unchecked {
            total = total + add < total ? type(uint256).max : total + add;
        }
        uint256 base = slashed[mandateId] ? slashBase[mandateId] : bondOf[mandateId];
        uint256 target = _penalty(base, budget, total);
        uint256 done = slashedAmount[mandateId];
        t = target > done ? target - done : 0;
        if (t > bondOf[mandateId]) t = bondOf[mandateId];
    }

    /// @notice Credit a non-principal deposit's beneficiary with what verdicts have accrued to it.
    ///         Permissionless and idempotent; a principal-side deposit has nothing to settle.
    function settle(uint256 mandateId, address depositor) public {
        address b = beneficiaryOf[mandateId][depositor];
        if (b == address(0) || b == registry.get(mandateId).principal) return;
        uint256 accrued = (depositOf[mandateId][depositor] * remainderPerUnit[mandateId]) / ACC_SCALE;
        uint256 done = remainderSettled[mandateId][depositor];
        if (accrued <= done) return;
        uint256 due = accrued - done;
        remainderSettled[mandateId][depositor] = accrued;
        unsettled[mandateId] -= due;
        owed[b] += due;
        emit RemainderSettled(mandateId, depositor, b, due);
    }

    /// @notice Pull whatever you were credited: a challenger's reward, a principal's remainder, a stake.
    function claim() external {
        uint256 amt = owed[msg.sender];
        if (amt == 0) revert NothingOwed();
        owed[msg.sender] = 0;
        emit Claimed(msg.sender, amt);
        (bool ok,) = payable(msg.sender).call{value: amt}("");
        if (!ok) revert TransferFailed();
    }

    // -----------------------------------------------------------------------------------
    // Accusation stakes (SPEC §6.4). The judge verifies; the money stays here.
    // -----------------------------------------------------------------------------------

    /// @notice A judge opened an accusation against `mandateId`; the stake travels with the call.
    function openAccusation(uint256 mandateId) external payable onlyJudge {
        if (msg.value != ACCUSATION_STAKE) revert BadStake();
        openAccusations[mandateId]++;
    }

    /// @notice A judge closed one: the stake is credited to `payee` — the accuser if it stood, the
    ///         principal if the agent answered it.
    function closeAccusation(uint256 mandateId, address payee) external onlyJudge {
        if (openAccusations[mandateId] == 0) revert NoAccusationOpen();
        openAccusations[mandateId]--;
        owed[payee] += ACCUSATION_STAKE;
    }

    // -----------------------------------------------------------------------------------
    // Verdicts
    // -----------------------------------------------------------------------------------

    /// @notice What `n` attestations of this type and source cost on this chain today, read from
    ///         Flare's own `FdcRequestFeeConfigurations`. Zero wherever that cannot be read.
    /// @dev    Low-level on purpose: this sits on the path of resolving an accusation, which must
    ///         never revert, and a high-level call to an address without code reverts before any
    ///         try/catch can see it.
    function fdcCost(bytes32 attestationType, bytes32 sourceId, uint256 n) public view returns (uint256) {
        (bool ok, bytes memory r) = FLARE_REGISTRY.staticcall(
            abi.encodeCall(IFlareContractRegistry.getContractAddressByName, ("FdcRequestFeeConfigurations"))
        );
        if (!ok || r.length != 32) return 0;
        (ok, r) = address(uint160(uint256(bytes32(r)))).staticcall(
            abi.encodeCall(IFdcRequestFeeConfigurations.getRequestFee, (abi.encode(attestationType, sourceId, bytes32(0))))
        );
        if (!ok || r.length != 32) return 0;
        uint256 fee = abi.decode(r, (uint256));
        return fee > type(uint128).max ? type(uint256).max : fee * n;
    }

    /// @notice The one place value leaves a bond. Judges only.
    /// @param severity     size of the breach in the mandate's unit
    /// @param beneficiary  who earns the challenger's share
    /// @param strict       revert `NothingNew` instead of returning 0 (direct challenges); resolving
    ///                     an accusation is not strict, because closing it must never revert
    /// @return taken what this verdict took from the bond
    function verdict(
        uint8 kind,
        uint256 mandateId,
        uint256 budget,
        uint256 severity,
        address beneficiary,
        uint256 nProofs,
        bytes32 attestationType,
        bytes32 sourceId,
        bool strict
    ) external onlyJudge returns (uint256 taken) {
        bool first = !slashed[mandateId];
        if (first) {
            slashed[mandateId] = true;
            slashBase[mandateId] = bondOf[mandateId];
        }
        uint256 target = _penalty(slashBase[mandateId], budget, _accumulate(kind, mandateId, severity));
        uint256 done = slashedAmount[mandateId];
        taken = target > done ? target - done : 0;
        if (taken > bondOf[mandateId]) taken = bondOf[mandateId];
        if (taken == 0) {
            if (strict) revert NothingNew();
            if (first) registry.revokeByBond(mandateId);
            return 0;
        }
        slashedAmount[mandateId] = done + taken;
        bondOf[mandateId] -= taken;

        uint256 cost = fdcCost(attestationType, sourceId, nProofs);
        if (cost > taken) cost = taken;
        uint256 reward = cost + ((taken - cost) * CHALLENGER_BPS) / 10_000;
        owed[beneficiary] += reward;
        MandateRegistry.Mandate memory m = registry.get(mandateId);
        _distribute(mandateId, m.principal, taken - reward);
        verdictsAgainst[m.agent]++;
        takenFrom[m.agent] += taken;
        if (first) registry.revokeByBond(mandateId);
        emit Verdict(mandateId, beneficiary, kind, severity, severityOf[mandateId], budget, taken, reward, slashedAmount[mandateId]);
    }

    /// @dev The remainder of a verdict, split the way the deposits it came from were: the principal-
    ///      side fraction to the principal now, the rest accrued per unit for `settle`. Rounding goes
    ///      to the principal side, and with no principal-side deposits stays in `unsettled`.
    function _distribute(uint256 mandateId, address principal, uint256 rest) internal {
        uint256 total = totalDeposits[mandateId];
        uint256 others = total - principalSide[mandateId];
        uint256 toOthers = others == 0 ? 0 : (rest * others) / total;
        owed[principal] += rest - toOthers;
        if (toOthers != 0) {
            remainderPerUnit[mandateId] += (toOthers * ACC_SCALE) / others;
            unsettled[mandateId] += toOthers;
        }
    }

    function _penalty(uint256 base, uint256 budget, uint256 severity) internal pure returns (uint256 p) {
        if (budget == 0 || severity >= budget) return base;
        p = (base * severity) / budget;
        uint256 floor = (base * MIN_SLASH_BPS) / 10_000;
        if (p < floor) p = floor;
    }

    function _accumulate(uint8 kind, uint256 mandateId, uint256 severity) internal returns (uint256 total) {
        uint8 bucket = Kinds.bucket(kind);
        uint256 prev = severityIn[mandateId][bucket];
        uint256 add = Kinds.additive(kind) ? severity : (severity > prev ? severity - prev : 0);
        total = severityOf[mandateId];
        unchecked {
            // Saturating: an overflow here would revert the resolution of an accusation.
            severityIn[mandateId][bucket] = prev + add < prev ? type(uint256).max : prev + add;
            total = total + add < total ? type(uint256).max : total + add;
        }
        severityOf[mandateId] = total;
    }
}
