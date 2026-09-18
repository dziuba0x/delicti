// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IFdcVerification} from "@flarenetwork/flare-periphery-contracts/coston2/IFdcVerification.sol";
import {IReferencedPaymentNonexistence} from
    "@flarenetwork/flare-periphery-contracts/coston2/IReferencedPaymentNonexistence.sol";
import {IEVMTransaction} from "@flarenetwork/flare-periphery-contracts/coston2/IEVMTransaction.sol";
import {IPayment} from "@flarenetwork/flare-periphery-contracts/coston2/IPayment.sol";
import {ContractRegistry} from "@flarenetwork/flare-periphery-contracts/coston2/ContractRegistry.sol";
import {ProtocolsV2Interface} from "@flarenetwork/flare-periphery-contracts/coston2/ProtocolsV2Interface.sol";
import {IFlareContractRegistry} from "@flarenetwork/flare-periphery-contracts/coston2/IFlareContractRegistry.sol";
import {IFdcRequestFeeConfigurations} from
    "@flarenetwork/flare-periphery-contracts/coston2/IFdcRequestFeeConfigurations.sol";
import {MandateRegistry} from "./MandateRegistry.sol";
import {AnchorLog} from "./AnchorLog.sol";
import {SpendMeter} from "./SpendMeter.sol";
import {Receipts} from "./Receipts.sol";
import {Merkle} from "./Merkle.sol";

/// @title Bond — programmable consequence for a proven false deed
/// @notice DELICTI, layer 4. Pattern lifted from FAssets' challenger role
///         (`illegalPaymentChallenge` etc. in IAssetManager): anyone can bring an FDC proof;
///         if it contradicts what the agent's own receipt asserted, the bond is slashed —
///         no court, no operator cooperation.
///
///         Sprint-0 challenge type: FALSE PAYMENT CLAIM.
///           witness 1  = the agent's anchored receipt saying "I paid X to D with reference R".
///           witness 2  = FDC `ReferencedPaymentNonexistence`: the world says no such payment
///                        reached D with amount X and reference R before the deadline.
///         Two witnesses to the same overt act, disagreeing → contradicted deed → slash.
contract Bond {
    MandateRegistry public immutable registry;
    AnchorLog public immutable log;
    /// @notice The tally the effectors keep (SpendMeter). Optional: address(0) disables the
    ///         under-reporting challenge without affecting anything else.
    SpendMeter public immutable meter;
    IFdcVerification private immutable _fdcOverride; // 0 => resolve via ContractRegistry
    /// @dev 0 => resolve via ContractRegistry. Only the voting-round clock
    ///      (`firstVotingRoundStartTs`, `votingEpochDurationSeconds`); a unit test has no Flare
    ///      contracts to read it from, same reason `_fdcOverride` exists.
    ProtocolsV2Interface private immutable _protocolsOverride;

    uint256 public constant CHALLENGER_BPS = 1000; // 10% of what a verdict takes goes to the challenger

    // -----------------------------------------------------------------------------------
    // Proportional slashing (SPEC §8.1).
    //
    // Until v0.9 any proven breach took the whole bond. A step function makes the deed's optimal
    // size, conditional on breaching at all, the largest one available — and makes loss-given-
    // default 100%, which no insurer will write. The penalty is now
    //
    //     P(s) = clamp( base * s / budget ,  base * MIN_SLASH_BPS / 10_000 ,  base )
    //
    // where `s` is the verdict's severity in the mandate's own unit (overrun, hidden spend, the
    // amount of a payment that never existed, the value of a deed nobody wrote down) and `base`
    // is the bond as it stood at the mandate's FIRST verdict.
    //
    // The slope introduces no constant: it is bond/budget, the collateralisation ratio k the
    // market already chose (§8). Each unit of overrun costs k units of bond, so with k >= 1 — what
    // §8 tells a counterparty to require — no overrun up to 100% of the budget pays for itself.
    //
    // A mandate is not slashed once; its proven severity ACCUMULATES, and each verdict takes the
    // difference between the penalty for the new total and what was already taken. "Slashed at
    // most once" plus a proportional penalty would have been worse than what it replaced — an
    // agent could convict itself of a trivial breach, pay the minimum, and thereby shield the rest
    // of the bond from the real case.
    //
    // How severities combine depends on whether two verdicts can be about the same thing:
    //   - NESTED kinds (budget overrun; under-reported spend): a larger set of deeds subsumes a
    //     smaller one, so the kind's severity is the largest proven so far, never the sum — five
    //     deeds and then the same five plus a sixth is one overrun, not two.
    //   - ADDITIVE kinds (a false payment; an unanchored deed): each verdict is about a different
    //     receipt or a different transaction — `consumedLeaf` and `accused` guarantee it — so two
    //     lies are twice one lie.
    // -----------------------------------------------------------------------------------

    /// @notice The least any proven breach costs, as a share of the bond at first verdict.
    /// @dev    10%. Three of the five verdicts are about a LIE (a payment that never existed, a deed
    ///         nobody wrote down, a tally that under-reported), and a lie about a small amount is not
    ///         a small lie — it is the thing the bond exists to price. The floor is what that costs.
    ///         It equals the challenger's entire reward under v0.8, so the smallest verdict still
    ///         moves as much value as the smallest reward used to.
    uint256 public constant MIN_SLASH_BPS = 1000;

    /// @notice mandateId => the bond as it stood at the first verdict. Every penalty is a share of
    ///         THIS, so a second verdict is measured on the same scale as the first.
    mapping(uint256 => uint256) public slashBase;
    /// @notice mandateId => how much verdicts have taken so far. Never exceeds `slashBase`.
    mapping(uint256 => uint256) public slashedAmount;
    /// @notice mandateId => total proven severity, in the mandate's unit (see the note above).
    mapping(uint256 => uint256) public severityOf;
    /// @dev mandateId => bucket => severity proven in it. Buckets: see `_bucket`.
    mapping(uint256 => mapping(uint8 => uint256)) public severityIn;

    // Who posted what. Until v0.9 `post` did not record the depositor and `withdraw` paid the
    // principal — so a bond posted by an insurer was a free option for the agent's own side. With
    // a partial slash there is now routinely a remainder, and it goes back to whoever put it up,
    // pro rata: each depositor bears the same fraction of every verdict.
    mapping(uint256 => mapping(address => uint256)) public depositOf;
    mapping(uint256 => uint256) public totalDeposits;

    /// @notice How long the bond stays frozen after the mandate's authority died.
    /// @dev    A challenge is not instant: the challenger must request an FDC attestation
    ///         on-chain, wait for the voting round to finalise (~90 s rounds, minutes
    ///         end-to-end on Coston2), pull the proof from the DA layer and only then send
    ///         the challenge. Without a window the principal — who is also an authority in
    ///         `revoke()` — can empty the bond in the same transaction that kills the mandate,
    ///         and the FDC request itself announces the challenge minutes in advance. 24 h is
    ///         ~100x the observed proof latency and far below the DA layer's retention.
    uint64 public constant COOLING_WINDOW = 24 hours;

    /// @notice How long after a deed the agent has to anchor it before silence is challengeable.
    /// @dev    1 hour in production. Immutable rather than constant for the same reason as
    ///         `responseWindow`: a testnet deployment has to be able to show the whole loop
    ///         without waiting out production timers. Both values are read off the contract.
    uint64 public immutable anchorGrace;

    /// @notice Stake an accuser must put up. Returned if the accusation stands, forfeited to the
    ///         principal if the agent answers it — accusing is cheap, but not free.
    uint256 public constant ACCUSATION_STAKE = 0.1 ether;

    /// @notice How long the agent has to answer an accusation of an unanchored deed.
    /// @dev    Unlike the cooling window this is not waiting on the FDC: the answer is data the
    ///         agent already holds (its own leaf and the episode it sits in), so the window is
    ///         about liveness, not proof latency. Production value is 24 h; it is a constructor
    ///         argument so a testnet deployment can demonstrate the full loop in one sitting.
    uint64 public immutable responseWindow;

    // -----------------------------------------------------------------------------------
    // Commit–reveal on the challenge (SPEC §6.7).
    //
    // The challenger's 10% is paid to whoever lands the `challenge*` call, and the call is
    // self-contained: proofs in calldata, verifiable by anyone. Worse, the challenger has to
    // announce the case on-chain minutes earlier — `FdcHub.requestAttestation(requestBytes)`
    // carries the deed's transaction hash or payment reference in the clear. So a parasite that
    // watches FdcHub, copies the reveal out of the mempool and outbids the gas collects the
    // reward at zero monitoring cost, and the equilibrium number of real watchers is zero.
    //
    // Fix: the reward is earned by whoever DETECTED the violation first, not by whoever pressed
    // the button first. A challenge must be committed — hash only, nothing leaked — before the
    // voting round in which its evidence was requested from the FDC even began.
    //
    //   commitment = keccak256(abi.encode(challenger, mandateId, kind, deedsDigest, salt))
    //
    // Everything that could be varied to STEAL someone else's work sits inside the preimage:
    // `challenger` (so a commitment cannot be revealed by anyone else), `mandateId` and `kind`
    // (so a commitment for a cheap challenge type cannot be spent on an expensive one), and
    // `deedsDigest` — the exact ordered set of deeds the challenge will present, so a blind
    // commitment does not fit a case the committer had not actually found.
    //
    // `asset`, on the ERC-20 paths, deliberately does NOT: it is not a field a copier can vary to
    // its advantage. Naming the wrong asset sums the wrong Transfer events and the challenge fails
    // on its own merits, so binding it would buy no security — only two more places for a shell
    // script's signature string to drift out of sync with the ABI.
    // -----------------------------------------------------------------------------------

    uint8 public constant KIND_FALSE_PAYMENT = 1;
    uint8 public constant KIND_BUDGET_NATIVE = 2;
    uint8 public constant KIND_BUDGET_ERC20 = 3;
    uint8 public constant KIND_UNANCHORED_DEED = 4;
    uint8 public constant KIND_UNDER_REPORTED = 5;
    uint8 public constant KIND_BUDGET_PAYMENT = 6;

    /// @notice How much older than its evidence round a commitment must be.
    /// @dev    Requiring only `committedAt < roundStart(minVotingRound)` — the obvious rule — does
    ///         NOT close the hole, and this is worth spelling out because it looks like it does.
    ///         A parasite that sees the victim's request land in round R can commit inside R,
    ///         then request its own attestation for the same deed in round R+1 and reveal against
    ///         that: its commitment predates `roundStart(R+1)` honestly. It pays one more
    ///         attestation fee and one more round of latency, and then it is a race — which it
    ///         wins whenever the honest challenger's proof happens to be the slow one. Observed
    ///         DA latency on Coston2 ranges from ~100 s to ~500 s for the same request type, so
    ///         the race is real, not theoretical.
    ///
    ///         With a lead of L, the parasite's earliest usable round starts L after it learned of
    ///         the case, so it loses unless the honest challenger's proof is more than L slower
    ///         than its own. 10 minutes is ~1.5x the widest latency spread measured on Coston2 and
    ///         ~4x the median round trip, which makes the defence deterministic rather than a
    ///         coin flip. It costs the honest challenger a one-off wait between detecting and
    ///         requesting — affordable, because `COOLING_WINDOW` keeps the bond in place for 24 h.
    ///
    ///         Immutable rather than constant for the same reason as `responseWindow` and
    ///         `anchorGrace`: a testnet deployment has to demonstrate the loop in one sitting.
    ///         A deployment that sets it near zero keeps the base rule (a commitment made after
    ///         the request is still refused) and gives up only the later-round variant above.
    uint64 public immutable commitLead;

    /// @notice How stale a commitment may be when it is finally revealed.
    /// @dev    `commitLead` alone leaves the gate open at the other end, and that end matters more
    ///         than it looks. Without an upper bound a commitment is a free, permanent option:
    ///         anyone can pre-commit to deeds that have not been challenged — for the single-deed
    ///         paths the deed set is one public transaction hash or one published receipt leaf, and
    ///         for the cumulative paths "every deed so far, ascending" is the canonical set every
    ///         honest challenger will use — and then simply copy a reveal out of the mempool months
    ///         later, changing one field, the salt. The commitment would be years old, so
    ///         `commitLead` is satisfied by a mile. Detection would again be worth nothing.
    ///
    ///         An upper bound turns that free option into rent: a squatter must re-commit every
    ///         candidate deed set, with a fresh salt (a replay keeps the earliest timestamp), once
    ///         per TTL, forever, for every mandate it hopes someone else will one day challenge.
    ///         An honest challenger pays for exactly one, once, for the case it actually found.
    ///
    ///         1 hour, against a `commitLead` of 10 minutes, leaves a 50-minute window between
    ///         committing and requesting the attestations. The honest sequence — detect, commit,
    ///         wait out the lead, request — takes minutes, so the slack is ~5x, and a challenger
    ///         who misses the window has lost 31k gas and can simply commit again.
    ///
    ///         This is a constant, not a constructor argument, precisely because a deployer with
    ///         discretion over it could set it just above `commitLead` and make honest challenges
    ///         against its own agents nearly impossible to time.
    uint64 public constant COMMIT_TTL = 1 hours;

    /// @notice commitment => the timestamp it was first submitted (0 = never, or already spent).
    mapping(bytes32 => uint64) public committedAt;

    // mandateId => posted bond (wei)
    mapping(uint256 => uint256) public bondOf;
    // mandateId => slashed?
    mapping(uint256 => bool) public slashed;
    // mandateId => leaf hash => already used in a successful challenge on THAT mandate.
    // Scoped per mandate on purpose: a global key let anyone burn a leaf under a throwaway
    // mandate of their own and make the same evidence permanently unusable elsewhere.
    mapping(uint256 => mapping(bytes32 => bool)) public consumedLeaf;

    // Slash proceeds and challenger rewards, held for pull-withdrawal. Pushing value inside
    // the challenge would let a reverting recipient block the consequence entirely.
    mapping(address => uint256) public owed;

    event BondPosted(uint256 indexed mandateId, address indexed by, uint256 amount, uint256 total);
    event BondWithdrawn(uint256 indexed mandateId, address indexed to, uint256 amount);
    event Claimed(address indexed who, uint256 amount);
    event FalsePaymentProven(
        uint256 indexed mandateId,
        uint256 indexed episodeIndex,
        bytes32 leafHash,
        address indexed challenger,
        uint256 slashedAmount
    );

    event DeedAccused(
        uint256 indexed accusationId, uint256 indexed mandateId, bytes32 txHash, uint64 deedTime, address indexed challenger
    );
    event AccusationAnswered(uint256 indexed accusationId, uint256 indexed mandateId, bytes32 leafHash, uint256 episodeIndex);
    event UnanchoredDeedProven(
        uint256 indexed accusationId, uint256 indexed mandateId, bytes32 txHash, address indexed challenger, uint256 slashedAmount
    );

    event UnderReportedSpendProven(
        uint256 indexed mandateId, uint256 proven, uint256 recorded, uint256 deeds, address indexed challenger, uint256 slashedAmount
    );

    event ChallengeCommitted(bytes32 indexed commitment, address indexed by, uint64 at);
    event CommitmentConsumed(bytes32 indexed commitment, uint256 indexed mandateId, uint8 kind, uint64 votingRound);

    event AgentRefProven(uint256 indexed mandateId, bytes32 indexed agentRef, bytes32 transactionId, address indexed by);

    /// @notice Every verdict, whatever its kind, in one shape: how big the breach was, on what scale,
    ///         what it took, who was paid what, and the mandate's running total.
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

    event BudgetOverrunProven(
        uint256 indexed mandateId, uint256 spent, uint256 budget, uint256 deeds, address indexed challenger, uint256 slashedAmount
    );

    error NothingToSlash();
    error NotAgentTx();
    error TxNotSuccessful();
    error UnorderedTxs();
    error WithinBudget();
    error LengthMismatch();
    error LeafNotAnchored();
    error LeafConsumed();
    error WrongReceiptKind();
    error FdcProofInvalid();
    error ProofDoesNotMatchClaim();
    error ClaimOutsideProvenRange();
    error MandateStillLive();
    error TransferFailed();
    error CoolingWindow();
    error NothingOwed();
    error BondSlashed();
    error BadStake();
    error NotExclusive();
    error DeedWithinGrace();
    error AlreadyAccused();
    error AccusationClosed();
    error ResponseWindowOpen();
    error AnchoredInTime();
    error AnchoredTooLate();
    error WrongDeed();
    error NoMeter();
    error NotMetered();
    error TallyAgrees();
    error NoCommitment();
    error CommittedTooLate();
    error CommitmentStale();
    error ClockDrift();
    error WrongSource();
    error WrongAsset();
    error NotThisBond();
    error NotAcknowledged();
    error AccusationOpen();
    error NoAgentRef();
    error AgentRefNotProven();
    error DuplicateLeaf();
    error NothingNew();
    error NoDeposit();

    constructor(
        MandateRegistry _registry,
        AnchorLog _log,
        IFdcVerification fdcOverride,
        uint64 responseWindow_,
        uint64 anchorGrace_,
        SpendMeter meter_,
        uint64 commitLead_,
        ProtocolsV2Interface protocolsOverride
    ) {
        registry = _registry;
        log = _log;
        _fdcOverride = fdcOverride;
        responseWindow = responseWindow_;
        anchorGrace = anchorGrace_;
        meter = meter_;
        commitLead = commitLead_;
        _protocolsOverride = protocolsOverride;
    }

    /// @notice An open claim that a deed happened with no receipt behind it. Resolved either by
    ///         the agent producing the anchored leaf, or by the clock running out.
    struct Accusation {
        uint256 mandateId;
        bytes32 txHash;
        uint64 deedTime;
        uint64 deadline;
        address challenger;
        bool closed;
        uint256 value; // what the deed moved, in the mandate's unit: the verdict's severity if it stands
    }

    uint256 public nextAccusationId = 1;
    mapping(uint256 => Accusation) public accusations;
    // mandateId => tx hash => already accused (one open question per deed)
    mapping(uint256 => mapping(bytes32 => bool)) public accused;
    /// @notice Accusations against a mandate that are neither answered nor resolved yet. While this
    ///         is non-zero the bond cannot be withdrawn: the response window (24 h) is as long as
    ///         the cooling window, so an accusation filed late in the cooling window would otherwise
    ///         outlive the collateral it was filed against.
    mapping(uint256 => uint256) public openAccusations;

    function fdc() public view returns (IFdcVerification) {
        if (address(_fdcOverride) != address(0)) return _fdcOverride;
        return ContractRegistry.getFdcVerification();
    }

    /// @notice The voting-round clock. `ProtocolsV2` and `FlareSystemsManager` resolve to the same
    ///         address on Coston2, but `firstVotingRoundStartTs` / `votingEpochDurationSeconds` are
    ///         declared on `ProtocolsV2Interface`, not on `IFlareSystemsManager` — so this is the
    ///         handle that actually type-checks. Read live; never hardcoded.
    function protocols() public view returns (ProtocolsV2Interface) {
        if (address(_protocolsOverride) != address(0)) return _protocolsOverride;
        return ContractRegistry.getProtocolsV2();
    }

    /// @notice When the given FDC voting round began, in seconds since the epoch.
    function roundStartTs(uint64 round) public view returns (uint64) {
        ProtocolsV2Interface p = protocols();
        return p.firstVotingRoundStartTs() + round * p.votingEpochDurationSeconds();
    }

    // -----------------------------------------------------------------------------------
    // Commit side.
    // -----------------------------------------------------------------------------------

    /// @notice Stake a claim on a challenge you have found but cannot prove yet. Costs one SSTORE
    ///         and leaks nothing: the argument is a hash.
    /// @dev    Idempotent, keeping the EARLIEST submission, and that is a security property rather
    ///         than tidiness. Commitments are public calldata, so if a second call could refresh
    ///         the stored timestamp, a parasite could simply replay the victim's own commitment
    ///         bytes just before the reveal and push it past `commitLead` — griefing the challenge
    ///         it could not steal. Replaying the commitment is instead a no-op; and replaying it
    ///         *early* only registers it on the victim's behalf, because the preimage names the
    ///         one address allowed to reveal it.
    function commitChallenge(bytes32 commitment) external {
        uint64 at = committedAt[commitment];
        if (at == 0) {
            at = uint64(block.timestamp);
            committedAt[commitment] = at;
        }
        emit ChallengeCommitted(commitment, msg.sender, at);
    }

    /// @notice The commitment for a challenge. Pure helper so off-chain tooling never has to
    ///         re-derive the encoding — the bug that encoding by hand invites is silent.
    function commitmentFor(address challenger, uint256 mandateId, uint8 kind, bytes32 digest, bytes32 salt)
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(challenger, mandateId, kind, digest, salt));
    }

    /// @notice Digest over the exact ordered set of deeds a challenge will present.
    /// @param deedIds  for `KIND_FALSE_PAYMENT` the single receipt leaf hash; for every other kind
    ///                 the deeds' transaction hashes, in the same order the challenge supplies them
    ///                 (which the multi-deed paths require to be strictly increasing).
    function deedsDigest(bytes32[] calldata deedIds) public pure returns (bytes32) {
        return keccak256(abi.encode(deedIds));
    }

    /// @dev Spend the caller's commitment for this case, or refuse the reveal.
    /// @param minVotingRound the LOWEST voting round among the supplied proofs. Taking the lowest
    ///        is what stops a challenger from padding a stale commitment with one fresh proof.
    function _consumeCommitment(
        uint8 kind,
        uint256 mandateId,
        bytes32 digest,
        bytes32 salt,
        uint64 minVotingRound
    ) internal {
        bytes32 c = commitmentFor(msg.sender, mandateId, kind, digest, salt);
        uint64 at = committedAt[c];
        if (at == 0) revert NoCommitment();

        uint64 rs = roundStartTs(minVotingRound);
        // `roundStartTs` extrapolates: it multiplies a round number that may be years old by the
        // epoch length Flare reports RIGHT NOW. If Flare ever lengthens the voting epoch or
        // redeploys with a rebased `firstVotingRoundStartTs`, that product lands in the future and
        // every commitment — including one made in this very block — clears the test below. The
        // gate would stop existing, silently, with nothing reverting to say so. A finalised round
        // cannot have begun in the future, so this holds unconditionally on a healthy chain and
        // fails closed on an unhealthy one. The mirror-image drift (a shortened epoch pushing the
        // product into the past) only ever refuses challenges, which is the direction to fail in.
        if (rs > block.timestamp) revert ClockDrift();

        // The evidence round must not merely postdate the commitment — it must postdate it by
        // `commitLead`, so that nobody who first heard of the case from the attestation request
        // can ever assemble a commitment old enough. See the note on `commitLead`.
        if (uint256(at) + commitLead > rs) revert CommittedTooLate();
        // ...and it must not postdate it by more than COMMIT_TTL. See the note there: without an
        // upper bound, a commitment is a free option held forever, and the whole gate reduces to
        // "did you guess the deed set in advance".
        if (uint256(at) + COMMIT_TTL < rs) revert CommitmentStale();

        delete committedAt[c]; // single use
        emit CommitmentConsumed(c, mandateId, kind, minVotingRound);
    }

    /// @dev `bytes32[]` of one element, for the single-deed challenge paths.
    function _one(bytes32 id) internal pure returns (bytes32 digest) {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = id;
        return keccak256(abi.encode(ids));
    }

    /// @notice Anyone may post bond under a mandate (agent, operator, or an insurer).
    function post(uint256 mandateId) external payable {
        // A mandate can only be slashed once. Funding one that was already slashed buys the
        // depositor nothing and would look like collateral to a counterparty reading the chain.
        if (slashed[mandateId]) revert BondSlashed();
        // Collateral only means something if THIS contract can carry out the consequence. A mandate
        // names its own consequence contract; posted anywhere else, the slash would revert on
        // `revokeByBond` forever and the deposit would merely look like a bond to whoever read it.
        if (registry.get(mandateId).bond != address(this)) revert NotThisBond();
        // ...and only if the agent has accepted the mandate. Otherwise the principal can name any
        // address it likes as "agent" and be paid for that stranger's ordinary activity.
        if (!registry.acknowledged(mandateId)) revert NotAcknowledged();
        // ...and, where the agent's identity is an address on another chain, only once that address
        // has itself said so (`proveAgentRef`). `acknowledge` is signed by the EVM key; nothing in it
        // shows that the same party controls the XRPL account the mandate names.
        if (registry.get(mandateId).agentRef != bytes32(0) && !agentRefProven[mandateId]) revert AgentRefNotProven();
        bondOf[mandateId] += msg.value;
        depositOf[mandateId][msg.sender] += msg.value;
        totalDeposits[mandateId] += msg.value;
        emit BondPosted(mandateId, msg.sender, msg.value, bondOf[mandateId]);
    }

    /// @notice A depositor takes back its share of whatever the verdicts left, once the mandate's
    ///         authority has died AND the cooling window has elapsed AND no accusation is open.
    /// @dev    The window runs from `registry.deathTime()` — the earliest death in the mandate's
    ///         ancestry — not from the moment of this call, so revoking early does not shorten it.
    ///         A slashed mandate is no longer a bar: its first verdict revoked it, the window then
    ///         runs like any other, and during it a larger breach can still take more.
    ///         The share is `deposit * bondOf / totalDeposits`, rounded down, so the books can only
    ///         err towards holding a few wei too many; the last depositor out gets exactly the rest.
    function withdraw(uint256 mandateId, address payable to) external {
        uint256 dep = depositOf[mandateId][msg.sender];
        if (dep == 0) revert NoDeposit();
        if (registry.isLive(mandateId)) revert MandateStillLive();
        uint64 death = registry.deathTime(mandateId);
        if (death == type(uint64).max || block.timestamp < uint256(death) + COOLING_WINDOW) revert CoolingWindow();
        if (openAccusations[mandateId] != 0) revert AccusationOpen();
        uint256 amt = (dep * bondOf[mandateId]) / totalDeposits[mandateId];
        depositOf[mandateId][msg.sender] = 0;
        totalDeposits[mandateId] -= dep;
        bondOf[mandateId] -= amt;
        emit BondWithdrawn(mandateId, to, amt);
        (bool ok,) = to.call{value: amt}("");
        if (!ok) revert TransferFailed();
    }

    /// @notice Pull whatever a slash credited you: 10% as challenger, the remainder as principal.
    function claim() external {
        uint256 amt = owed[msg.sender];
        if (amt == 0) revert NothingOwed();
        owed[msg.sender] = 0;
        emit Claimed(msg.sender, amt);
        (bool ok,) = payable(msg.sender).call{value: amt}("");
        if (!ok) revert TransferFailed();
    }

    /// @notice Challenge: the agent's anchored receipt asserts an XRPL/BTC/DOGE payment;
    ///         an FDC nonexistence proof shows it never happened.
    /// @param mandateId     mandate under which the receipt was anchored
    /// @param episodeIndex  index into AnchorLog episodes for that mandate
    /// @param leaf          the receipt leaf (witness 1) as anchored
    /// @param merkleProof   inclusion path of keccak256(abi.encode(leaf)) in the episode root
    /// @param fdcProof      FDC ReferencedPaymentNonexistence proof (witness 2)
    /// @dev    There is deliberately no `victim` parameter. It used to be challenger-supplied,
    ///         which meant the whole calldata (proofs included) could be copied out of the
    ///         mempool with that one field changed — the agent's own address — and the slash
    ///         returned 100% of the bond to the family that posted it. The harmed party is the
    ///         principal (SPEC 1), so that is who the remainder is credited to.
    /// @param salt the secret from the commitment made before the attestation was requested
    ///        (`commitmentFor(msg.sender, mandateId, KIND_FALSE_PAYMENT, deedsDigest([leafHash]), salt)`)
    function challengeFalsePayment(
        uint256 mandateId,
        uint256 episodeIndex,
        Receipts.Leaf calldata leaf,
        bytes32[] calldata merkleProof,
        IReferencedPaymentNonexistence.Proof calldata fdcProof,
        bytes32 salt
    ) external {
        if (bondOf[mandateId] == 0) revert NothingToSlash();
        if (leaf.kind != Receipts.KIND_EXTERNAL_PAYMENT) revert WrongReceiptKind();
        // The leaf must name the mandate being challenged. Without this the budget paths'
        // invariant did not hold here, and any leaf could be replayed under a foreign mandate.
        if (leaf.mandateId != mandateId) revert ProofDoesNotMatchClaim();
        _requireNativeOn(registry.get(mandateId), leaf.sourceId);

        // --- witness 1: the agent really asserted this deed (leaf is in an anchored root) ---
        bytes32 leafHash = Receipts.hash(leaf);
        if (consumedLeaf[mandateId][leafHash]) revert LeafConsumed();
        AnchorLog.Episode memory ep = log.episode(mandateId, episodeIndex);
        if (!Merkle.verify(merkleProof, ep.root, leafHash)) revert LeafNotAnchored();

        // --- witness 2: the world says the payment does not exist ---
        if (!fdc().verifyReferencedPaymentNonexistence(fdcProof)) revert FdcProofInvalid();

        // Only now is `votingRound` trustworthy — it is part of the response the FDC just
        // verified against the Relay root, so it cannot be forged to buy a later deadline.
        _consumeCommitment(KIND_FALSE_PAYMENT, mandateId, _one(leafHash), salt, fdcProof.data.votingRound);

        IReferencedPaymentNonexistence.RequestBody calldata rq = fdcProof.data.requestBody;
        IReferencedPaymentNonexistence.ResponseBody calldata rs = fdcProof.data.responseBody;

        // A nonexistence proof scoped to a set of source addresses proves only that THOSE
        // addresses did not pay. The leaf carries no source address to compare it against, so
        // such a proof would convict an agent who really did pay, from another address.
        if (rq.checkSourceAddresses) revert ProofDoesNotMatchClaim();

        // the proof must be about exactly the payment the receipt claims
        if (
            rq.destinationAddressHash != leaf.destinationAddressHash || rq.amount != leaf.amount
                || rq.standardPaymentReference != leaf.ref
                || fdcProof.data.sourceId != leaf.sourceId
        ) revert ProofDoesNotMatchClaim();

        // the claimed payment time must fall inside the range the proof covers:
        // [minimalBlockTimestamp, deadlineTimestamp] with the search actually having
        // overflowed the deadline (firstOverflowBlockTimestamp > deadlineTimestamp).
        if (
            leaf.claimedTimestamp < rs.minimalBlockTimestamp || leaf.claimedTimestamp > rq.deadlineTimestamp
                || rs.firstOverflowBlockTimestamp <= rq.deadlineTimestamp
        ) revert ClaimOutsideProvenRange();

        // --- consequence ---
        consumedLeaf[mandateId][leafHash] = true;
        // severity: the payment that was claimed and never existed
        uint256 taken = _verdict(KIND_FALSE_PAYMENT, mandateId, registry.get(mandateId).budget, leaf.amount, msg.sender, 1, fdcProof.data.attestationType, fdcProof.data.sourceId, true);
        emit FalsePaymentProven(mandateId, episodeIndex, leafHash, msg.sender, taken);
    }

    /// @notice Challenge: STRUCTURING. Every anchored deed may sit inside its own limit, but the
    ///         sum of what the agent provably did on-chain (FDC `EVMTransaction`) exceeds the
    ///         mandate's cumulative budget. This is the "salami" pattern pre-action gates cannot
    ///         see, because each call passes on its own.
    ///
    ///         What a deed's value IS follows the mandate's asset (v0.9):
    ///         - native (`assetKey == 0`): the transaction's `value`, `sourceAddress` == the agent;
    ///         - ERC-20: the `Transfer(agent → payee)` event emitted by that token inside the proof —
    ///           the real x402 case, where settlement is `transferWithAuthorization`, native value is
    ///           zero and the sender is the facilitator. Request the proof with `listEvents = true`.
    /// @dev    One entry point and one loop. Until v0.9 there were two of each, `…ERC20` taking the
    ///         asset as a parameter; once the asset is the mandate's there is nothing left for the
    ///         caller to choose, and two copies of a loop is how `answerAccusation` came to miss a
    ///         check its twin had.
    ///         Deeds must be supplied in strictly increasing tx-hash order (dedup without storage).
    ///         Each deed needs BOTH witnesses: the anchored leaf and the FDC proof. Class A only.
    /// @param salt the secret from the commitment made before the attestations were requested.
    ///        `kind` in the commitment is `KIND_BUDGET_NATIVE` for a native mandate and
    ///        `KIND_BUDGET_ERC20` for a token one; the digest is over the tx hashes in this order.
    function challengeBudgetOverrun(
        uint256 mandateId,
        uint256[] calldata episodeIndices,
        Receipts.Leaf[] calldata leaves,
        bytes32[][] calldata merkleProofs,
        IEVMTransaction.Proof[] calldata fdcProofs,
        bytes32 salt
    ) external {
        if (bondOf[mandateId] == 0) revert NothingToSlash();
        uint256 n = leaves.length;
        if (n == 0 || episodeIndices.length != n || merkleProofs.length != n || fdcProofs.length != n) {
            revert LengthMismatch();
        }
        MandateRegistry.Mandate memory m = registry.get(mandateId);
        address asset = m.assetKey == bytes32(0) ? address(0) : _erc20Of(m);
        uint8 kind = asset == address(0) ? KIND_BUDGET_NATIVE : KIND_BUDGET_ERC20;

        uint256 spent;
        bytes32[] memory ids = new bytes32[](n);
        uint64 minRound = type(uint64).max;
        for (uint256 i = 0; i < n; i++) {
            _requireAnchored(mandateId, episodeIndices[i], leaves[i], merkleProofs[i]); // witness 1
            IEVMTransaction.Proof calldata pr = fdcProofs[i]; // witness 2
            ids[i] = pr.data.requestBody.transactionHash;
            if (i != 0 && ids[i] <= ids[i - 1]) revert UnorderedTxs();
            if (pr.data.votingRound < minRound) minRound = pr.data.votingRound;
            spent += _evmDeed(pr, leaves[i], m, asset);
        }
        // Authorisation before verdict: the set of deeds is only now known, and it is the set the
        // commitment had to name.
        _consumeCommitment(kind, mandateId, keccak256(abi.encode(ids)), salt, minRound);
        if (spent <= m.budget) revert WithinBudget();

        uint256 taken = _verdict(kind, mandateId, m.budget, spent - m.budget, msg.sender, n, fdcProofs[0].data.attestationType, m.sourceId, true);
        emit BudgetOverrunProven(mandateId, spent, m.budget, n, msg.sender, taken);
    }

    // -----------------------------------------------------------------------------------
    // Deeds on XRPL (SPEC §6.8).
    //
    // Every cumulative challenge above needs an `EVMTransaction` proof and compares its
    // `sourceAddress` with `m.agent`. A deed done on XRPL therefore could not be summed at all:
    // the only XRPL challenge was the negative one (§6.1, a payment that did NOT happen). These two
    // functions are the positive half — who the agent is on XRPL, and how much it really paid.
    // -----------------------------------------------------------------------------------

    /// @notice mandateId => the account named by `agentRef` has itself confirmed the mandate.
    mapping(uint256 => bool) public agentRefProven;

    /// @notice The reference an XRPL account must put in a payment's memo to confirm a mandate.
    /// @dev    Binds chain, registry and mandate, so a confirmation cannot be replayed for another
    ///         mandate, another deployment, or the same deployment on another network.
    function agentRefChallenge(uint256 mandateId) public view returns (bytes32) {
        return keccak256(abi.encode("DELICTI/agentRef", block.chainid, address(registry), mandateId));
    }

    /// @notice Proof of control over `agentRef`: an FDC `Payment` attestation of a successful payment
    ///         FROM that account whose standard payment reference is `agentRefChallenge(mandateId)`.
    ///         Any amount, any destination — the reference is the statement, the payment is the pen.
    ///         Permissionless: the proof speaks, not the caller.
    /// @dev    Why it exists. `agentRef` is written by the principal, like `agent`. `acknowledge` is the
    ///         EVM key saying yes; it says nothing about who holds the XRPL key. Without this a
    ///         principal (with a sock-puppet `agent` to acknowledge) names a stranger's busy account,
    ///         anchors leaves mirroring that stranger's ordinary payments, and is paid out of a third
    ///         party's bond. `post` refuses collateral until this has been done.
    function proveAgentRef(uint256 mandateId, IPayment.Proof calldata proof) external {
        MandateRegistry.Mandate memory m = registry.get(mandateId);
        if (m.agentRef == bytes32(0)) revert NoAgentRef();
        if (!fdc().verifyPayment(proof)) revert FdcProofInvalid();
        IPayment.ResponseBody calldata rb = proof.data.responseBody;
        if (proof.data.sourceId != m.sourceId) revert WrongSource();
        if (rb.sourceAddressHash != m.agentRef) revert NotAgentTx();
        if (rb.status != 0) revert TxNotSuccessful();
        if (rb.standardPaymentReference != agentRefChallenge(mandateId)) revert ProofDoesNotMatchClaim();
        agentRefProven[mandateId] = true;
        emit AgentRefProven(mandateId, m.agentRef, proof.data.requestBody.transactionId, msg.sender);
    }

    /// @notice STRUCTURING on XRPL. N anchored kind-3 leaves, each with a POSITIVE FDC `Payment`
    ///         attestation: the payment exists, it succeeded, it came from the account the mandate
    ///         names, inside the mandate's window, to the destination, for the amount and with the
    ///         reference the receipt claims. The sum of what was delivered exceeds the budget.
    /// @dev    - What is summed is `receivedAmount`, not `spentAmount`. On XRPL `spentAmount` includes
    ///           the transaction fee; the EVM paths sum `value` and ignore gas, and a budget that an
    ///           agent can overrun by 12 drops of fee while delivering exactly what it was allowed to
    ///           is a trap, not a limit. The fee is not nothing, and SPEC §10 says so.
    ///         - `oneToOne` is required. On XRPL it is always true. On the UTXO sources the same
    ///           attestation type serves, a transaction can have several funders and the "source" is
    ///           whichever input the requester pointed at; this path refuses those rather than reason
    ///           about them.
    ///         - Transaction ids strictly increasing: dedup without storage, same as §6.2. But unlike
    ///           §6.2 the leaf does not carry the transaction id (its `ref` is the payment reference),
    ///           so distinct transactions do not imply distinct leaves, and one receipt must not be
    ///           allowed to account for two payments. Leaves are therefore checked pairwise distinct.
    ///         - The `Payment` attestation covers XRPL transactions of type `Payment` ONLY. An
    ///           `OfferCreate`, an `EscrowCreate`, an AMM deposit move value and are invisible here.
    /// @param salt the secret from the commitment (`kind = KIND_BUDGET_PAYMENT`, digest over the
    ///        payments' transaction ids in this same ascending order)
    function challengeBudgetOverrunPayment(
        uint256 mandateId,
        uint256[] calldata episodeIndices,
        Receipts.Leaf[] calldata leaves,
        bytes32[][] calldata merkleProofs,
        IPayment.Proof[] calldata fdcProofs,
        bytes32 salt
    ) external {
        if (bondOf[mandateId] == 0) revert NothingToSlash();
        uint256 n = leaves.length;
        if (n == 0 || episodeIndices.length != n || merkleProofs.length != n || fdcProofs.length != n) {
            revert LengthMismatch();
        }
        MandateRegistry.Mandate memory m = registry.get(mandateId);
        if (m.agentRef == bytes32(0)) revert NoAgentRef();
        if (m.assetKey != bytes32(0)) revert WrongAsset(); // `Payment` attests the native asset only

        uint256 spent;
        bytes32 lastTx;
        bytes32[] memory ids = new bytes32[](n);
        bytes32[] memory leafHashes = new bytes32[](n);
        uint64 minRound = type(uint64).max;
        for (uint256 i = 0; i < n; i++) {
            Receipts.Leaf calldata leaf = leaves[i];
            if (leaf.kind != Receipts.KIND_EXTERNAL_PAYMENT) revert WrongReceiptKind();
            if (leaf.mandateId != mandateId) revert ProofDoesNotMatchClaim();

            // witness 1
            bytes32 leafHash = Receipts.hash(leaf);
            for (uint256 j = 0; j < i; j++) {
                if (leafHashes[j] == leafHash) revert DuplicateLeaf();
            }
            leafHashes[i] = leafHash;
            AnchorLog.Episode memory ep = log.episode(mandateId, episodeIndices[i]);
            if (!Merkle.verify(merkleProofs[i], ep.root, leafHash)) revert LeafNotAnchored();

            // witness 2
            IPayment.Proof calldata pr = fdcProofs[i];
            if (!fdc().verifyPayment(pr)) revert FdcProofInvalid();
            bytes32 txid = pr.data.requestBody.transactionId;
            if (txid <= lastTx) revert UnorderedTxs();
            lastTx = txid;
            ids[i] = txid;
            if (pr.data.votingRound < minRound) minRound = pr.data.votingRound;
            if (pr.data.sourceId != leaf.sourceId) revert ProofDoesNotMatchClaim();
            if (pr.data.sourceId != m.sourceId) revert WrongSource();
            spent += _paymentDeed(pr.data.responseBody, leaf, m);
        }
        _consumeCommitment(KIND_BUDGET_PAYMENT, mandateId, keccak256(abi.encode(ids)), salt, minRound);
        if (spent <= m.budget) revert WithinBudget();

        uint256 taken = _verdict(KIND_BUDGET_PAYMENT, mandateId, m.budget, spent - m.budget, msg.sender, n, fdcProofs[0].data.attestationType, m.sourceId, true);
        emit BudgetOverrunProven(mandateId, spent, m.budget, n, msg.sender, taken);
    }

    /// @dev Witness 1 for the EVM overrun paths: an EVM-deed leaf, naming this mandate, in an
    ///      anchored root of this mandate.
    function _requireAnchored(uint256 mandateId, uint256 episodeIndex, Receipts.Leaf calldata leaf, bytes32[] calldata path)
        internal
        view
    {
        if (leaf.kind != Receipts.KIND_EVM_TX) revert WrongReceiptKind();
        if (leaf.mandateId != mandateId) revert ProofDoesNotMatchClaim();
        if (!Merkle.verify(path, log.episode(mandateId, episodeIndex).root, Receipts.hash(leaf))) revert LeafNotAnchored();
    }

    /// @dev One attested EVM transaction against one receipt. Returns the value it moved.
    function _evmDeed(
        IEVMTransaction.Proof calldata pr,
        Receipts.Leaf calldata leaf,
        MandateRegistry.Mandate memory m,
        address asset
    ) internal view returns (uint256 v) {
        if (!fdc().verifyEVMTransaction(pr)) revert FdcProofInvalid();
        if (pr.data.requestBody.transactionHash != leaf.ref || pr.data.sourceId != leaf.sourceId) {
            revert ProofDoesNotMatchClaim();
        }
        if (pr.data.sourceId != m.sourceId) revert WrongSource();
        IEVMTransaction.ResponseBody calldata rb = pr.data.responseBody;
        if (rb.status != 1) revert TxNotSuccessful();
        // A budget is cumulative over the mandate's life, so only deeds inside its window
        // may be summed against it — otherwise older activity convicts a fresh mandate.
        if (rb.timestamp < m.validFrom || rb.timestamp > m.validUntil) revert ClaimOutsideProvenRange();

        if (asset == address(0)) {
            if (rb.sourceAddress != m.agent) revert NotAgentTx();
            if (bytes32(uint256(uint160(rb.receivingAddress))) != leaf.destinationAddressHash) {
                revert ProofDoesNotMatchClaim();
            }
            v = rb.value;
        } else {
            // the Transfer(agent → payee) emitted by the mandate's asset. The transaction's own
            // sender is the facilitator, not the agent, so `sourceAddress` is not compared.
            v = _erc20TransferValue(rb.events, asset, m.agent, address(uint160(uint256(leaf.destinationAddressHash))));
            if (v == 0) revert ProofDoesNotMatchClaim();
        }
        if (v != leaf.amount) revert ProofDoesNotMatchClaim();
    }

    /// @dev One attested payment against one receipt. Returns what it delivered.
    function _paymentDeed(IPayment.ResponseBody calldata rb, Receipts.Leaf calldata leaf, MandateRegistry.Mandate memory m)
        internal
        pure
        returns (uint256)
    {
        if (rb.sourceAddressHash != m.agentRef) revert NotAgentTx();
        if (rb.status != 0 || !rb.oneToOne) revert TxNotSuccessful();
        if (rb.blockTimestamp < m.validFrom || rb.blockTimestamp > m.validUntil) revert ClaimOutsideProvenRange();
        if (
            rb.receivedAmount <= 0 || uint256(rb.receivedAmount) != leaf.amount
                || rb.receivingAddressHash != leaf.destinationAddressHash || rb.standardPaymentReference != leaf.ref
        ) revert ProofDoesNotMatchClaim();
        return uint256(rb.receivedAmount);
    }

    // -----------------------------------------------------------------------------------
    // Mandate-less deed (SPEC 6.4): a muscle moving with no signal.
    //
    // Every other challenge starts from an anchored leaf, so consequence reached only agents
    // that had already confessed: not anchoring was free, and an agent maximising its public
    // corroboration rate should anchor the easy deeds and stay quiet about the rest.
    //
    // You cannot prove a negative cheaply on-chain — enumerating "no leaf references this tx"
    // would need a non-inclusion proof over every episode. So the burden is inverted, the way
    // an accusation works: the challenger states the deed and posts a stake, and the agent has
    // a window to produce the receipt it says it wrote. Silence resolves against it. Retroactive
    // anchoring does not help, because the episode must have been anchored within anchorGrace
    // of the deed, and a revoked mandate cannot anchor at all.
    // -----------------------------------------------------------------------------------

    /// @notice Accuse a bonded agent of a deed with no anchored receipt behind it.
    /// @param proof FDC EVMTransaction proof that the mandate's agent really made this transaction
    /// @param salt  the secret from the commitment made before the attestation was requested
    ///        (`kind = KIND_UNANCHORED_DEED`, digest over the single deed's tx hash). The accusation
    ///        is gated, not `resolveAccusation`: the accusation is what publishes the case, and the
    ///        reward follows `a.challenger` rather than whoever resolves it, so resolving stays open.
    function accuseUnanchoredDeed(uint256 mandateId, IEVMTransaction.Proof calldata proof, bytes32 salt)
        external
        payable
        returns (uint256 id)
    {
        if (bondOf[mandateId] == 0) revert NothingToSlash();
        if (msg.value != ACCUSATION_STAKE) revert BadStake();
        // Only an agent that promised exclusivity can be asked to account for every deed.
        if (!registry.exclusive(mandateId)) revert NotExclusive();

        MandateRegistry.Mandate memory m = registry.get(mandateId);
        if (!fdc().verifyEVMTransaction(proof)) revert FdcProofInvalid();
        // The promise of exclusivity is about one address on one chain. The same key is the same
        // address on every EVM chain the FDC attests, and what it does elsewhere was never promised.
        if (proof.data.sourceId != m.sourceId) revert WrongSource();
        IEVMTransaction.ResponseBody calldata rb = proof.data.responseBody;
        if (rb.sourceAddress != m.agent) revert NotAgentTx();
        if (rb.status != 1) revert TxNotSuccessful();
        if (rb.timestamp < m.validFrom || rb.timestamp > m.validUntil) revert ClaimOutsideProvenRange();
        // The agent is allowed to be slower than the chain; only silence past the grace counts.
        if (block.timestamp < uint256(rb.timestamp) + anchorGrace) revert DeedWithinGrace();

        bytes32 txh = proof.data.requestBody.transactionHash;
        if (accused[mandateId][txh]) revert AlreadyAccused();
        accused[mandateId][txh] = true;
        _consumeCommitment(KIND_UNANCHORED_DEED, mandateId, _one(txh), salt, proof.data.votingRound);

        id = nextAccusationId++;
        openAccusations[mandateId]++;
        accusations[id] = Accusation({
            mandateId: mandateId,
            txHash: txh,
            deedTime: rb.timestamp,
            deadline: uint64(block.timestamp) + responseWindow,
            challenger: msg.sender,
            closed: false,
            value: m.assetKey == bytes32(0) ? rb.value : _erc20OutflowFrom(rb.events, _erc20Of(m), m.agent)
        });
        emit DeedAccused(id, mandateId, txh, rb.timestamp, msg.sender);
    }

    /// @notice Answer an accusation by producing the anchored receipt for that deed. Anyone may
    ///         do it — the evidence speaks, not the speaker. The accuser's stake goes to the
    ///         principal: a false accusation costs something.
    function answerAccusation(
        uint256 accusationId,
        uint256 episodeIndex,
        Receipts.Leaf calldata leaf,
        bytes32[] calldata merkleProof
    ) external {
        Accusation storage a = accusations[accusationId];
        if (a.challenger == address(0) || a.closed) revert AccusationClosed();
        // The accusation is about an EVM deed, so only an EVM-deed receipt answers it. Every other
        // path that reads a leaf pins its kind; this one did not. No exploit follows from the gap
        // — the agent controls its own leaves and a correct-kind one is no harder to anchor — but
        // an invariant present in one path and absent in its twin is exactly how this repo has
        // grown holes before, so the twin gets the check.
        if (leaf.kind != Receipts.KIND_EVM_TX) revert WrongReceiptKind();
        if (leaf.mandateId != a.mandateId || leaf.ref != a.txHash) revert WrongDeed();

        AnchorLog.Episode memory ep = log.episode(a.mandateId, episodeIndex);
        // Anchoring after the fact is not a receipt, it is a cover story.
        if (ep.anchoredAt > a.deedTime + anchorGrace) revert AnchoredTooLate();
        bytes32 leafHash = Receipts.hash(leaf);
        if (!Merkle.verify(merkleProof, ep.root, leafHash)) revert LeafNotAnchored();

        a.closed = true;
        openAccusations[a.mandateId]--;
        owed[registry.get(a.mandateId).principal] += ACCUSATION_STAKE;
        emit AccusationAnswered(accusationId, a.mandateId, leafHash, episodeIndex);
    }

    /// @notice The window closed with no receipt produced. The deed stands unaccounted for.
    function resolveAccusation(uint256 accusationId) external {
        Accusation storage a = accusations[accusationId];
        if (a.challenger == address(0) || a.closed) revert AccusationClosed();
        if (block.timestamp <= a.deadline) revert ResponseWindowOpen();

        // The accusation stood: nobody produced the receipt. That is settled whatever has happened
        // to the bond in the meantime, so closing it and returning the stake must never revert.
        // Until v0.9 this path reverted `AlreadySlashed` when the mandate had been slashed by
        // another challenge while the window was open — and `answerAccusation` needs a leaf that by
        // hypothesis does not exist, so the accuser's stake stayed in this contract for ever.
        // Found by the invariant campaign (`invariant_everyExpiredAccusationCanBeClosed`).
        a.closed = true;
        openAccusations[a.mandateId]--;
        owed[a.challenger] += ACCUSATION_STAKE; // stake back
        MandateRegistry.Mandate memory m = registry.get(a.mandateId);
        uint256 taken = _verdict(KIND_UNANCHORED_DEED, a.mandateId, m.budget, a.value, a.challenger, 1, bytes32("EVMTransaction"), m.sourceId, false);
        emit UnanchoredDeedProven(accusationId, a.mandateId, a.txHash, a.challenger, taken);
    }

    // -----------------------------------------------------------------------------------
    // The tally that lied (SPEC §6.5).
    //
    // SpendMeter is the fast half: the effector records every settlement, and reads the tally
    // before it acts, so structuring is refused in milliseconds instead of slashed in minutes.
    // An effector can simply not write — and that is what this challenge is for. The meter is
    // witness 1 over the *sequence*; the FDC proofs are witness 2 over the same sequence. When
    // the world shows more than the tally admits, both witnesses are present and §5 holds.
    //
    // Scope, deliberately narrow: only a mandate that is BOTH metered (the principal named an
    // effector) and exclusive (the agent promised this address acts under this mandate alone).
    // Without exclusivity an outflow from the agent's address might be none of the mandate's
    // business, and slashing on it would convict an honest agent — the same mistake as accepting
    // a source-scoped nonexistence proof.
    // -----------------------------------------------------------------------------------

    /// @dev   What is summed follows the mandate: `assetKey == 0` sums native transaction value,
    ///        otherwise `Transfer` events out of the agent emitted by that ERC-20 (the x402 case).
    /// @param salt the secret from the commitment made before the attestations were requested
    ///        (`kind = KIND_UNDER_REPORTED`, digest over the deeds' tx hashes in this same order)
    function challengeUnderReportedSpend(
        uint256 mandateId,
        IEVMTransaction.Proof[] calldata fdcProofs,
        bytes32 salt
    ) external {
        if (bondOf[mandateId] == 0) revert NothingToSlash();
        if (address(meter) == address(0)) revert NoMeter();
        if (!meter.metered(mandateId)) revert NotMetered();
        if (!registry.exclusive(mandateId)) revert NotExclusive();

        uint256 n = fdcProofs.length;
        if (n == 0) revert LengthMismatch();
        MandateRegistry.Mandate memory m = registry.get(mandateId);
        address asset = m.assetKey == bytes32(0) ? address(0) : _erc20Of(m);

        uint256 proven;
        bytes32 lastTx;
        bytes32[] memory ids = new bytes32[](n);
        uint64 minRound = type(uint64).max;
        for (uint256 i = 0; i < n; i++) {
            IEVMTransaction.Proof calldata pr = fdcProofs[i];
            if (!fdc().verifyEVMTransaction(pr)) revert FdcProofInvalid();
            bytes32 txh = pr.data.requestBody.transactionHash;
            if (txh <= lastTx) revert UnorderedTxs();
            lastTx = txh;
            ids[i] = txh;
            if (pr.data.votingRound < minRound) minRound = pr.data.votingRound;
            // Until v0.9 this path checked no source at all, and it has no leaf to borrow one from:
            // a transfer by the same key on another EVM chain the FDC attests would have been summed
            // against a tally that never promised to cover it.
            if (pr.data.sourceId != m.sourceId) revert WrongSource();
            IEVMTransaction.ResponseBody calldata rb = pr.data.responseBody;
            if (rb.status != 1) revert TxNotSuccessful();
            if (rb.timestamp < m.validFrom || rb.timestamp > m.validUntil) revert ClaimOutsideProvenRange();
            if (asset == address(0)) {
                if (rb.sourceAddress != m.agent) revert NotAgentTx();
                proven += rb.value;
            } else {
                proven += _erc20OutflowFrom(rb.events, asset, m.agent);
            }
        }

        _consumeCommitment(KIND_UNDER_REPORTED, mandateId, keccak256(abi.encode(ids)), salt, minRound);

        uint256 recorded = meter.spent(mandateId);
        if (proven <= recorded) revert TallyAgrees();

        // severity: what the tally hid
        uint256 taken = _verdict(KIND_UNDER_REPORTED, mandateId, m.budget, proven - recorded, msg.sender, n, fdcProofs[0].data.attestationType, m.sourceId, true);
        emit UnderReportedSpendProven(mandateId, proven, recorded, n, msg.sender, taken);
    }

    /// @dev Every `Transfer` out of `from` emitted by `asset`, whoever the counterparty is.
    ///      Sound only under an exclusivity declaration — see the note above.
    function _erc20OutflowFrom(IEVMTransaction.Event[] calldata events, address asset, address from)
        internal
        pure
        returns (uint256 total)
    {
        for (uint256 i = 0; i < events.length; i++) {
            IEVMTransaction.Event calldata e = events[i];
            if (e.removed || e.emitterAddress != asset || e.topics.length != 3) continue;
            if (e.topics[0] != TRANSFER_SIG) continue;
            if (address(uint160(uint256(e.topics[1]))) != from) continue;
            total += abi.decode(e.data, (uint256));
        }
    }

    /// @dev The mandate's ERC-20, or a refusal. `assetKey` is a left-padded address on an EVM source;
    ///      anything with high bits set is some other source's asset identifier and not ours to guess.
    function _erc20Of(MandateRegistry.Mandate memory m) internal pure returns (address) {
        if (m.assetKey == bytes32(0) || uint256(m.assetKey) >> 160 != 0) revert WrongAsset();
        return address(uint160(uint256(m.assetKey)));
    }

    /// @dev For the external-payment paths: the deed's source must be the mandate's, and the budget
    ///      must be in that source's native asset — the only thing `Payment`-family attestations count.
    function _requireNativeOn(MandateRegistry.Mandate memory m, bytes32 sourceId) internal pure {
        if (sourceId != m.sourceId) revert WrongSource();
        if (m.assetKey != bytes32(0)) revert WrongAsset();
    }

    bytes32 private constant TRANSFER_SIG = keccak256("Transfer(address,address,uint256)");

    function _erc20TransferValue(IEVMTransaction.Event[] calldata events, address asset, address from, address to)
        internal
        pure
        returns (uint256 total)
    {
        for (uint256 i = 0; i < events.length; i++) {
            IEVMTransaction.Event calldata e = events[i];
            if (e.removed || e.emitterAddress != asset || e.topics.length != 3) continue;
            if (e.topics[0] != TRANSFER_SIG) continue;
            if (address(uint160(uint256(e.topics[1]))) != from) continue;
            if (address(uint160(uint256(e.topics[2]))) != to) continue;
            total += abi.decode(e.data, (uint256));
        }
    }

    function _penalty(uint256 base, uint256 budget, uint256 severity) internal pure returns (uint256 p) {
        // A zero budget permits nothing, so any deed at all is a total breach. Also keeps the
        // division honest. `severity >= budget` is the cap: you cannot lose more than the bond.
        if (budget == 0 || severity >= budget) return base;
        p = (base * severity) / budget; // severity < budget, so this cannot overflow past `base`
        uint256 floor = (base * MIN_SLASH_BPS) / 10_000;
        if (p < floor) p = floor;
    }

    /// @notice What `n` attestations of this type and source cost on this chain today, read from
    ///         Flare's own `FdcRequestFeeConfigurations`. Zero wherever that cannot be read.
    /// @dev    The challenger's share has to cover the cost of proving the case or nobody proves
    ///         small ones — and since FIP.16 that cost is real: 20 FLR per request on mainnet, so
    ///         100 FLR for a five-deed salami before gas. A constant would be stale at the next
    ///         governance vote; the fee is on-chain, so it is read, the same way the voting-round
    ///         clock is. The first 64 bytes of a request are all the fee lookup reads.
    function fdcCost(bytes32 attestationType, bytes32 sourceId, uint256 n) public view returns (uint256) {
        address flareRegistry = 0xaD67FE66660Fb8dFE9d6b1b4240d8650e30F6019; // ContractRegistry's constant
        if (flareRegistry.code.length == 0) return 0; // unit tests, or a chain that is not Flare
        try IFlareContractRegistry(flareRegistry).getContractAddressByName("FdcRequestFeeConfigurations") returns (address cfg) {
            if (cfg.code.length == 0) return 0;
            try IFdcRequestFeeConfigurations(cfg).getRequestFee(abi.encode(attestationType, sourceId, bytes32(0))) returns (uint256 fee) {
                return fee * n;
            } catch {
                return 0;
            }
        } catch {
            return 0;
        }
    }

    /// @dev Nested kinds keep a high-water mark, additive kinds a running sum. Saturating, because
    ///      an overflow here would revert `resolveAccusation`, and the one thing that function must
    ///      never do is fail to close.
    function _severityAfter(uint8 kind, uint256 mandateId, uint256 severity)
        internal
        view
        returns (uint8 bucket, uint256 inBucket, uint256 total)
    {
        bool additive = kind == KIND_FALSE_PAYMENT || kind == KIND_UNANCHORED_DEED;
        // the three overrun kinds share a bucket: a mandate has one asset on one source, so at most
        // one of them can ever apply to it, and they measure the same thing
        bucket = (kind == KIND_BUDGET_ERC20 || kind == KIND_BUDGET_PAYMENT) ? KIND_BUDGET_NATIVE : kind;
        uint256 prev = severityIn[mandateId][bucket];
        uint256 add = additive ? severity : (severity > prev ? severity - prev : 0);
        total = severityOf[mandateId];
        unchecked {
            inBucket = prev + add < prev ? type(uint256).max : prev + add;
            total = total + add < total ? type(uint256).max : total + add;
        }
    }

    function _accumulate(uint8 kind, uint256 mandateId, uint256 severity) internal returns (uint256 total) {
        uint8 bucket;
        uint256 inBucket;
        (bucket, inBucket, total) = _severityAfter(kind, mandateId, severity);
        severityIn[mandateId][bucket] = inBucket;
        severityOf[mandateId] = total;
    }

    /// @dev The one place value leaves a bond. Returns what this verdict took (0 if it proved
    ///      nothing worse than what was already proven and `strict` is false).
    /// @param severity     size of the breach in the mandate's unit
    /// @param beneficiary  who earns the challenger's share — not always `msg.sender`, since an
    ///                     accusation may be resolved by anyone once its window has closed
    /// @param strict       revert `NothingNew` instead of returning 0. Direct challenges are strict:
    ///                     a transaction that changes nothing should not look like a verdict.
    ///                     Resolving an accusation is not, because closing it must never revert.
    function _verdict(
        uint8 kind,
        uint256 mandateId,
        uint256 budget,
        uint256 severity,
        address beneficiary,
        uint256 nProofs,
        bytes32 attestationType,
        bytes32 sourceId,
        bool strict
    ) internal returns (uint256 taken) {
        if (!slashed[mandateId]) {
            slashed[mandateId] = true;
            slashBase[mandateId] = bondOf[mandateId];
            registry.revokeByBond(mandateId); // the first proven breach ends the mandate
        }
        uint256 target = _penalty(slashBase[mandateId], budget, _accumulate(kind, mandateId, severity));
        uint256 done = slashedAmount[mandateId];
        taken = target > done ? target - done : 0;
        if (taken > bondOf[mandateId]) taken = bondOf[mandateId];
        if (taken == 0) {
            if (strict) revert NothingNew();
            return 0;
        }
        slashedAmount[mandateId] = done + taken;
        bondOf[mandateId] -= taken;

        // The challenger is made whole for the attestations first, and earns 10% of the rest.
        uint256 cost = fdcCost(attestationType, sourceId, nProofs);
        if (cost > taken) cost = taken;
        uint256 reward = cost + ((taken - cost) * CHALLENGER_BPS) / 10_000;
        // Credit, never push: a recipient that reverts on receive would otherwise be able to
        // make a mandate unslashable. Both parties pull with claim().
        owed[beneficiary] += reward;
        owed[registry.get(mandateId).principal] += taken - reward;
        emit Verdict(mandateId, beneficiary, kind, severity, severityOf[mandateId], budget, taken, reward, slashedAmount[mandateId]);
    }
}
