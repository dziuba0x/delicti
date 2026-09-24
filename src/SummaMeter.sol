// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {FtsoV2Interface} from "@flarenetwork/flare-periphery-contracts/coston2/FtsoV2Interface.sol";
import {ContractRegistry} from "@flarenetwork/flare-periphery-contracts/coston2/ContractRegistry.sol";
import {MandateRegistry} from "./MandateRegistry.sol";
import {JudgeSumma} from "./JudgeSumma.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title SummaMeter: the brake across rails (SPEC amendment v1.1, S.8)
/// @notice `SpendMeter` refuses the fifth slice on one rail. This refuses it across all of them. An
///         effector on any rail (the XRPL co-signer, an x402 facilitator on Flare) asks
///         `wouldExceed` with the asset and amount it is about to move. The answer values the amount
///         with the FTSO **block-latency** feed, through the same immutable price map `JudgeSumma`
///         convicts with, and compares it with the umbrella's tally in µUSD. After the funds move the
///         effector calls `note`. The tally is a sequence of checkpoints, so `spentAt` reads the past.
/// @dev    One witness. It never convicts on its own: the docket in `JudgeSumma` does, from FDC
///         proofs. The price read here is live and advisory. The price a verdict uses is the anchor
///         value of the deed's round, proven on-chain. The two can differ by the ±0.25 % band that
///         FTSO keeps block-latency feeds in around the anchors, so an effector that wants margin
///         should brake a little early (`wouldExceed` takes a `slackBps`).
contract SummaMeter {
    struct Checkpoint {
        uint64 at;
        uint256 total;
    }

    MandateRegistry public immutable registry;
    JudgeSumma public immutable summa;
    FtsoV2Interface private immutable _ftsoOverride; // 0 => ContractRegistry

    /// umbrella => running tally in µUSD
    mapping(uint256 => uint256) public spentUsd6;
    mapping(uint256 => mapping(address => bool)) public effector;
    mapping(uint256 => Checkpoint[]) private _history;

    event EffectorDeclared(uint256 indexed umbrellaId, address indexed effector);
    event Noted(uint256 indexed umbrellaId, address indexed effector, bytes32 sourceId, bytes32 assetKey, uint256 amount, uint256 usd6, uint256 total);

    error NotPrincipal();
    error NotEffector();
    error ZeroEffector();
    error NotLive();
    error Unpriced();

    constructor(MandateRegistry registry_, JudgeSumma summa_, FtsoV2Interface ftsoOverride) {
        registry = registry_;
        summa = summa_;
        _ftsoOverride = ftsoOverride;
    }

    function ftso() public view returns (FtsoV2Interface) {
        if (address(_ftsoOverride) != address(0)) return _ftsoOverride;
        return ContractRegistry.getFtsoV2();
    }

    /// @notice The umbrella's principal names an address allowed to keep the tally. Add-only, as in §7.1.
    function declareEffector(uint256 umbrellaId, address e) external {
        if (e == address(0)) revert ZeroEffector();
        if (msg.sender != registry.get(umbrellaId).principal) revert NotPrincipal();
        effector[umbrellaId][e] = true;
        emit EffectorDeclared(umbrellaId, e);
    }

    /// @notice What `amount` of this rail asset is worth now, in µUSD, at the block-latency feed.
    /// @dev    Not `view`: FtsoV2 reads are payable (free today, verified 2026-09-24). Call it with
    ///         `eth_call` off-chain, or inside the effector's own transaction.
    function valueNow(bytes32 sourceId, bytes32 assetKey, uint256 amount) public returns (uint256) {
        (bytes21 feedId, uint8 assetDecimals) = summa.priceOf(sourceId, assetKey);
        if (feedId == bytes21(0)) revert Unpriced();
        (uint256 v, int8 d,) = ftso().getFeedById(feedId);
        // Same arithmetic as JudgeSumma.valueUsd6, rounding down, but on the full-width
        // block-latency value (it does not fit the anchor feeds' int32 for every asset).
        int256 e = int256(uint256(assetDecimals)) + int256(d) - 6;
        if (e >= 0) return Math.mulDiv(amount, v, 10 ** uint256(e));
        return amount * v * 10 ** uint256(-e);
    }

    /// @notice Would moving `amount` of this asset now take the umbrella past its budget, braking
    ///         `slackBps` early? Returns the answer and the amount's value in µUSD.
    function wouldExceed(uint256 umbrellaId, bytes32 sourceId, bytes32 assetKey, uint256 amount, uint16 slackBps)
        external
        returns (bool, uint256 usd6)
    {
        usd6 = valueNow(sourceId, assetKey, amount);
        uint256 budget = registry.get(umbrellaId).budget;
        uint256 limit = budget - (budget * slackBps) / 10_000;
        return (spentUsd6[umbrellaId] + usd6 > limit || !registry.isLive(umbrellaId), usd6);
    }

    /// @notice Record a settlement after the funds moved. Records past the budget too: a meter
    ///         that refuses to record an overrun is a meter that lies about it (§7.1).
    function note(uint256 umbrellaId, bytes32 sourceId, bytes32 assetKey, uint256 amount) external returns (uint256 usd6) {
        if (!effector[umbrellaId][msg.sender]) revert NotEffector();
        if (!registry.isLive(umbrellaId)) revert NotLive();
        usd6 = valueNow(sourceId, assetKey, amount);
        uint256 total = spentUsd6[umbrellaId] + usd6;
        spentUsd6[umbrellaId] = total;
        Checkpoint[] storage h = _history[umbrellaId];
        uint256 n = h.length;
        if (n != 0 && h[n - 1].at == uint64(block.timestamp)) h[n - 1].total = total;
        else h.push(Checkpoint({at: uint64(block.timestamp), total: total}));
        emit Noted(umbrellaId, msg.sender, sourceId, assetKey, amount, usd6, total);
    }

    /// @notice What the tally said at `ts`. Zero before the first note.
    function spentAt(uint256 umbrellaId, uint64 ts) external view returns (uint256) {
        Checkpoint[] storage h = _history[umbrellaId];
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

    function checkpointCount(uint256 umbrellaId) external view returns (uint256) {
        return _history[umbrellaId].length;
    }
}
