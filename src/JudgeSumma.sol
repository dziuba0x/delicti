// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IFdcVerification} from "@flarenetwork/flare-periphery-contracts/coston2/IFdcVerification.sol";
import {IEVMTransaction} from "@flarenetwork/flare-periphery-contracts/coston2/IEVMTransaction.sol";
import {IBalanceDecreasingTransaction} from
    "@flarenetwork/flare-periphery-contracts/coston2/IBalanceDecreasingTransaction.sol";
import {FtsoV2Interface} from "@flarenetwork/flare-periphery-contracts/coston2/FtsoV2Interface.sol";
import {ProtocolsV2Interface} from "@flarenetwork/flare-periphery-contracts/coston2/ProtocolsV2Interface.sol";
import {ContractRegistry} from "@flarenetwork/flare-periphery-contracts/coston2/ContractRegistry.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MandateRegistry} from "./MandateRegistry.sol";
import {AgentRefs} from "./AgentRefs.sol";
import {Deeds} from "./Deeds.sol";
import {Kinds} from "./Kinds.sol";
import {Vault} from "./Vault.sol";
import {DelictiErrors} from "./DelictiErrors.sol";

/// @title JudgeSumma: one budget in US dollars across every rail (SPEC amendment v1.1, kind 9)
/// @notice An *umbrella* is an ordinary mandate whose unit is the micro-dollar (`sourceId = "SUMMA"`,
///         `assetKey = "USD/1e6"`). Its agent links *members*: rail mandates of the same principal
///         that a third party can watch without receipts (§6.10 gross XRP outflow, §6.11 gross ERC-20
///         outflow). Every deed a member's agent does from the moment of linking counts toward the
///         umbrella, valued at the FTSO anchor price of the voting round it happened in. The filing that
///         takes the umbrella past its budget is a conviction, through the same Vault gate as every
///         other kind. The Vault's arithmetic is unit-free, so an umbrella's Vault is the v0.15 `Vault`
///         bytecode with this judge as its only judge.
/// @dev    Holds no funds and has no admin. The price map is written once, in the constructor: the party
///         being judged must never choose which price values its spending.
contract JudgeSumma is DelictiErrors {
    uint8 public constant KIND = 9; // amendment v1.1; `Kinds` is core and stays untouched: bucket(9) = 9, not additive
    bytes32 public constant SUMMA_SOURCE = bytes32("SUMMA");
    bytes32 public constant USD_KEY = bytes32("USD/1e6");
    uint256 public constant MAX_MEMBERS = 16;
    uint256 private constant USD_DECIMALS = 6;

    struct Price {
        bytes21 feedId;
        uint8 assetDecimals;
    }

    /// @notice One row of the price map, as passed to the constructor.
    struct PriceRow {
        bytes32 sourceId;
        bytes32 assetKey;
        bytes21 feedId;
        uint8 assetDecimals;
    }

    Vault public immutable vault;
    MandateRegistry public immutable registry;
    AgentRefs public immutable agentRefs;
    IFdcVerification private immutable _fdcOverride; // 0 => ContractRegistry
    FtsoV2Interface private immutable _ftsoOverride; // 0 => ContractRegistry

    /// (sourceId, assetKey) => price source. Written in the constructor only.
    mapping(bytes32 => mapping(bytes32 => Price)) private _price;

    /// umbrella => its members, in the order they were linked
    mapping(uint256 => uint256[]) private _members;
    /// umbrella => member => when it was linked (0 = not a member). Sticky.
    mapping(uint256 => mapping(uint256 => uint64)) public linkedAt;
    /// umbrella => total proven outflow in µUSD
    mapping(uint256 => uint256) public docket;
    /// umbrella => deed identity => filed. ERC-20: (source, tx, logIndex); XRP: (source, tx).
    mapping(uint256 => mapping(bytes32 => bool)) public filed;
    /// feedId => voting round => verified anchor value (0 = not yet proven). Shared by all umbrellas.
    mapping(bytes21 => mapping(uint32 => int32)) public provenValue;
    mapping(bytes21 => mapping(uint32 => int8)) public provenDecimals;

    event PriceMapped(bytes32 indexed sourceId, bytes32 indexed assetKey, bytes21 feedId, uint8 assetDecimals);
    event MemberLinked(uint256 indexed umbrellaId, uint256 indexed memberId, uint64 at);
    event PriceProven(bytes21 indexed feedId, uint32 indexed votingRound, int32 value, int8 decimals);
    event DeedValued(
        uint256 indexed umbrellaId, uint256 indexed memberId, bytes32 deedId, uint256 amount, uint32 votingRound, uint256 valueUsd6
    );
    event SummaFiled(uint256 indexed umbrellaId, address indexed filer, uint256 addedUsd6, uint256 docketUsd6, uint256 newDeeds);
    event SummaProven(uint256 indexed umbrellaId, uint256 docketUsd6, uint256 budgetUsd6, address indexed challenger, uint256 taken);

    error NotUmbrella();
    error NotUmbrellaAgent();
    error PrincipalMismatch();
    error NotWatchable();
    error Unpriced();
    error AlreadyLinked();
    error TooManyMembers();
    error NotMember();
    error WrongPrice();
    error BadPrice();
    error NotLive();
    error DuplicatePrice();

    constructor(
        Vault vault_,
        MandateRegistry registry_,
        AgentRefs agentRefs_,
        IFdcVerification fdcOverride,
        FtsoV2Interface ftsoOverride,
        PriceRow[] memory priceMap
    ) {
        vault = vault_;
        registry = registry_;
        agentRefs = agentRefs_;
        _fdcOverride = fdcOverride;
        _ftsoOverride = ftsoOverride;
        for (uint256 i = 0; i < priceMap.length; i++) {
            PriceRow memory r = priceMap[i];
            if (r.feedId == bytes21(0) || r.sourceId == SUMMA_SOURCE) revert BadPrice();
            if (_price[r.sourceId][r.assetKey].feedId != bytes21(0)) revert DuplicatePrice();
            _price[r.sourceId][r.assetKey] = Price(r.feedId, r.assetDecimals);
            emit PriceMapped(r.sourceId, r.assetKey, r.feedId, r.assetDecimals);
        }
    }

    // -----------------------------------------------------------------------------------
    // Reads
    // -----------------------------------------------------------------------------------

    function fdc() public view returns (IFdcVerification) {
        if (address(_fdcOverride) != address(0)) return _fdcOverride;
        return ContractRegistry.getFdcVerification();
    }

    function ftso() public view returns (FtsoV2Interface) {
        if (address(_ftsoOverride) != address(0)) return _ftsoOverride;
        return ContractRegistry.getFtsoV2();
    }

    function priceOf(bytes32 sourceId, bytes32 assetKey) external view returns (bytes21 feedId, uint8 assetDecimals) {
        Price memory p = _price[sourceId][assetKey];
        return (p.feedId, p.assetDecimals);
    }

    function members(uint256 umbrellaId) external view returns (uint256[] memory) {
        return _members[umbrellaId];
    }

    /// @notice The voting round in progress at `t`, on the same clock the Vault's gate reads (§6.7).
    function roundOf(uint64 t) public view returns (uint32) {
        ProtocolsV2Interface p = vault.protocols();
        uint64 first = p.firstVotingRoundStartTs();
        if (t < first) revert ClockDrift();
        return uint32((t - first) / p.votingEpochDurationSeconds());
    }

    /// @notice What `amount` base units of an asset with `assetDecimals` decimals are worth in µUSD at a
    ///         price `value × 10^-decimals` USD. Rounds DOWN: rounding can never convict (amendment S.5).
    function valueUsd6(uint256 amount, uint8 assetDecimals, int32 value, int8 decimals) public pure returns (uint256) {
        if (value <= 0) revert BadPrice();
        // amount × value × 10^6 / 10^(assetDecimals + decimals)
        int256 e = int256(uint256(assetDecimals)) + int256(decimals) - int256(USD_DECIMALS);
        uint256 v = uint256(uint32(value));
        if (e >= 0) return Math.mulDiv(amount, v, 10 ** uint256(e));
        return amount * v * 10 ** uint256(-e);
    }

    // -----------------------------------------------------------------------------------
    // Membership (amendment S.4)
    // -----------------------------------------------------------------------------------

    /// @notice The umbrella's agent puts a rail mandate under it. Sticky; counts deeds from now on.
    function link(uint256 umbrellaId, uint256 memberId) external {
        MandateRegistry.Mandate memory u = _umbrella(umbrellaId);
        if (msg.sender != u.agent) revert NotUmbrellaAgent();
        if (!registry.isLive(umbrellaId)) revert NotLive();
        if (linkedAt[umbrellaId][memberId] != 0) revert AlreadyLinked();
        if (_members[umbrellaId].length >= MAX_MEMBERS) revert TooManyMembers();
        MandateRegistry.Mandate memory m = registry.get(memberId);
        if (m.principal != u.principal) revert PrincipalMismatch();
        if (!registry.acknowledged(memberId)) revert NotAcknowledged();
        if (!_watchable(memberId, m)) revert NotWatchable();
        if (_price[m.sourceId][m.assetKey].feedId == bytes21(0)) revert Unpriced();
        linkedAt[umbrellaId][memberId] = uint64(block.timestamp);
        _members[umbrellaId].push(memberId);
        emit MemberLinked(umbrellaId, memberId, uint64(block.timestamp));
    }

    /// @dev Receipt-less members only: a sum over a set of deeds the agent chose to write down is a
    ///      sum the agent chooses. §6.10 (XRP outflow, exclusivity proven by the XRPL key) or §6.11
    ///      (an ERC-20, exclusivity declared by the agent).
    function _watchable(uint256 memberId, MandateRegistry.Mandate memory m) internal view returns (bool) {
        if (m.sourceId == SUMMA_SOURCE) return false;
        if (m.assetKey == Kinds.XRP_OUTFLOW_KEY) return m.agentRef != bytes32(0) && agentRefs.exclusive(memberId);
        return Deeds.erc20Of(m) != address(0) && registry.exclusive(memberId);
    }

    // -----------------------------------------------------------------------------------
    // Filing (amendment S.6)
    // -----------------------------------------------------------------------------------

    /// @notice File ERC-20 outflow of one member (§6.11 rules), each proof priced by `prices[i]`.
    function fileErc20(
        uint256 umbrellaId,
        uint256 memberId,
        IEVMTransaction.Proof[] calldata proofs,
        FtsoV2Interface.FeedDataWithProof[] calldata prices,
        bytes32 salt
    ) external {
        (MandateRegistry.Mandate memory u, MandateRegistry.Mandate memory m, uint64 lo, uint64 hi) = _case(umbrellaId, memberId);
        if (proofs.length == 0 || proofs.length != prices.length) revert LengthMismatch();
        if (m.assetKey == Kinds.XRP_OUTFLOW_KEY) revert WrongAsset();
        Price memory px = _price[m.sourceId][m.assetKey];
        Tally memory t = _tally(proofs.length);
        address asset = Deeds.erc20Of(m);
        for (uint256 i = 0; i < proofs.length; i++) {
            IEVMTransaction.Proof calldata pr = proofs[i];
            bytes32 txh = pr.data.requestBody.transactionHash;
            if (i != 0 && txh <= t.ids[i - 1]) revert UnorderedTxs();
            t.ids[i] = txh;
            if (!fdc().verifyEVMTransaction(pr)) revert FdcProofInvalid();
            if (pr.data.sourceId != m.sourceId) revert WrongSource();
            if (pr.data.requestBody.requiredConfirmations < _minConfirmations(m.sourceId)) revert TooFewConfirmations();
            IEVMTransaction.ResponseBody calldata rb = pr.data.responseBody;
            if (rb.status != 1) revert TxNotSuccessful();
            if (rb.timestamp < lo || rb.timestamp > hi) revert ClaimOutsideProvenRange();
            uint256 out = _newErc20(umbrellaId, m.sourceId, txh, rb.events, asset, m.agent);
            if (out == type(uint256).max) continue; // nothing new in this proof
            _count(t, umbrellaId, memberId, txh, out, px, prices[i], rb.timestamp, pr.data.votingRound);
            if (t.lastUsd != 0 && t.lastUsd >= t.minV) {
                t.keys[t.paid++] = Deeds.deedKey(pr.data.attestationType, pr.data.sourceId, abi.encode(pr.data.requestBody));
            }
        }
        _judge(umbrellaId, u, t, salt, bytes32("EVMTransaction"), m.sourceId);
    }

    /// @notice File gross XRP outflow of one member (§6.10 rules), each proof priced by `prices[i]`.
    function fileXrp(
        uint256 umbrellaId,
        uint256 memberId,
        IBalanceDecreasingTransaction.Proof[] calldata proofs,
        FtsoV2Interface.FeedDataWithProof[] calldata prices,
        bytes32 salt
    ) external {
        (MandateRegistry.Mandate memory u, MandateRegistry.Mandate memory m, uint64 lo, uint64 hi) = _case(umbrellaId, memberId);
        if (proofs.length == 0 || proofs.length != prices.length) revert LengthMismatch();
        if (m.assetKey != Kinds.XRP_OUTFLOW_KEY) revert WrongAsset();
        Price memory px = _price[m.sourceId][m.assetKey];
        Tally memory t = _tally(proofs.length);
        for (uint256 i = 0; i < proofs.length; i++) {
            IBalanceDecreasingTransaction.Proof calldata pr = proofs[i];
            bytes32 txid = pr.data.requestBody.transactionId;
            if (i != 0 && txid <= t.ids[i - 1]) revert UnorderedTxs();
            t.ids[i] = txid;
            bytes32 key = keccak256(abi.encode(m.sourceId, txid));
            if (filed[umbrellaId][key]) continue;
            if (!fdc().verifyBalanceDecreasingTransaction(pr)) revert FdcProofInvalid();
            if (pr.data.sourceId != m.sourceId) revert WrongSource();
            if (pr.data.requestBody.sourceAddressIndicator != m.agentRef) revert NotAgentTx();
            IBalanceDecreasingTransaction.ResponseBody calldata rb = pr.data.responseBody;
            if (rb.sourceAddressHash != m.agentRef) revert NotAgentTx();
            if (rb.blockTimestamp < lo || rb.blockTimestamp > hi) revert ClaimOutsideProvenRange();
            filed[umbrellaId][key] = true;
            // Only positive amounts: XRP that came back does not un-spend what went (§6.10).
            uint256 out = rb.spentAmount > 0 ? uint256(rb.spentAmount) : 0;
            _count(t, umbrellaId, memberId, txid, out, px, prices[i], rb.blockTimestamp, pr.data.votingRound);
            if (t.lastUsd != 0 && t.lastUsd >= t.minV) {
                t.keys[t.paid++] = Deeds.deedKey(pr.data.attestationType, pr.data.sourceId, abi.encode(pr.data.requestBody));
            }
        }
        _judge(umbrellaId, u, t, salt, bytes32("BalanceDecreasingTransaction"), m.sourceId);
    }

    // -----------------------------------------------------------------------------------
    // Internals
    // -----------------------------------------------------------------------------------

    struct Tally {
        bytes32[] ids;
        bytes32[] keys;
        uint256 paid;
        uint256 added;
        uint256 fresh;
        uint64 minRound;
        uint256 minV;
        uint256 lastUsd;
    }

    function _tally(uint256 n) internal pure returns (Tally memory t) {
        t.ids = new bytes32[](n);
        t.keys = new bytes32[](n);
        t.minRound = type(uint64).max;
    }

    /// @dev The umbrella must be one, bonded; the member must be linked. Returns the window in which a
    ///      member's deed counts: max(starts, linkedAt) .. min(ends).
    function _case(uint256 umbrellaId, uint256 memberId)
        internal
        view
        returns (MandateRegistry.Mandate memory u, MandateRegistry.Mandate memory m, uint64 lo, uint64 hi)
    {
        u = _umbrella(umbrellaId);
        if (vault.bondOf(umbrellaId) == 0) revert NothingToSlash();
        uint64 at = linkedAt[umbrellaId][memberId];
        if (at == 0) revert NotMember();
        m = registry.get(memberId);
        lo = u.validFrom;
        if (m.validFrom > lo) lo = m.validFrom;
        if (at > lo) lo = at;
        hi = u.validUntil < m.validUntil ? u.validUntil : m.validUntil;
    }

    function _umbrella(uint256 umbrellaId) internal view returns (MandateRegistry.Mandate memory u) {
        u = registry.get(umbrellaId);
        if (u.sourceId != SUMMA_SOURCE || u.assetKey != USD_KEY || u.bond != address(vault)) revert NotUmbrella();
    }

    /// @dev Values one proof's new outflow and adds it to the tally. `t.minV` is read lazily.
    function _count(
        Tally memory t,
        uint256 umbrellaId,
        uint256 memberId,
        bytes32 deedId,
        uint256 out,
        Price memory px,
        FtsoV2Interface.FeedDataWithProof calldata price,
        uint64 when,
        uint64 fdcRound
    ) internal {
        if (t.fresh == 0) t.minV = vault.stipendMinValue(umbrellaId);
        uint32 r = roundOf(when);
        (int32 v, int8 d) = _priceAt(px.feedId, r, price);
        uint256 usd = valueUsd6(out, px.assetDecimals, v, d);
        t.added += usd;
        t.fresh++;
        t.lastUsd = usd;
        if (fdcRound < t.minRound) t.minRound = fdcRound;
        emit DeedValued(umbrellaId, memberId, deedId, out, r, usd);
    }

    /// @dev The anchor value of `feedId` in round `r`: from the cache, or proven now and cached.
    ///      `verifyFeedData` REVERTS on a bad proof (measured on Coston2 and Flare, 2026-09-24).
    function _priceAt(bytes21 feedId, uint32 r, FtsoV2Interface.FeedDataWithProof calldata price)
        internal
        returns (int32 v, int8 d)
    {
        v = provenValue[feedId][r];
        if (v != 0) return (v, provenDecimals[feedId][r]);
        if (price.body.id != feedId || price.body.votingRoundId != r) revert WrongPrice();
        if (!ftso().verifyFeedData(price)) revert WrongPrice();
        v = price.body.value;
        d = price.body.decimals;
        if (v <= 0) revert BadPrice();
        provenValue[feedId][r] = v;
        provenDecimals[feedId][r] = d;
        emit PriceProven(feedId, r, v, d);
    }

    /// @dev Every live `Transfer(from, *, v)` of `asset` in these events not yet on this umbrella's
    ///      docket: files it and returns the sum, or `type(uint256).max` when nothing was new.
    function _newErc20(
        uint256 umbrellaId,
        bytes32 sourceId,
        bytes32 txh,
        IEVMTransaction.Event[] calldata events,
        address asset,
        address from
    ) internal returns (uint256 total) {
        bool any;
        for (uint256 j = 0; j < events.length; j++) {
            IEVMTransaction.Event calldata e = events[j];
            if (!Deeds.isTransferFrom(e, asset, from)) continue;
            bytes32 key = keccak256(abi.encode(sourceId, txh, e.logIndex));
            if (filed[umbrellaId][key]) continue;
            filed[umbrellaId][key] = true;
            total += abi.decode(e.data, (uint256));
            any = true;
        }
        if (!any) return type(uint256).max;
    }

    function _judge(uint256 umbrellaId, MandateRegistry.Mandate memory u, Tally memory t, bytes32 salt, bytes32 attType, bytes32 sourceId)
        internal
    {
        if (t.fresh == 0) revert NothingNew();
        Deeds.trim(t.keys, t.paid);
        uint256 before = docket[umbrellaId];
        uint256 total = before + t.added;
        docket[umbrellaId] = total;
        emit SummaFiled(umbrellaId, msg.sender, t.added, total, t.fresh);
        vault.stipend(umbrellaId, t.keys);
        if (total <= u.budget || total == before) return;
        if (vault.wouldTake(KIND, umbrellaId, u.budget, total - u.budget) == 0) return;
        vault.consumeCommitment(msg.sender, KIND, umbrellaId, keccak256(abi.encode(t.ids)), salt, t.minRound);
        uint256 taken = vault.verdict(KIND, umbrellaId, u.budget, total - u.budget, msg.sender, t.fresh, attType, sourceId, true);
        emit SummaProven(umbrellaId, total, u.budget, msg.sender, taken);
    }

    function _minConfirmations(bytes32 sourceId) internal pure returns (uint16) {
        return (sourceId == bytes32("ETH") || sourceId == bytes32("testETH")) ? 64 : 1;
    }
}
