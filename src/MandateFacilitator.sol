// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MandateRegistry} from "./MandateRegistry.sol";
import {JudgeSumma} from "./JudgeSumma.sol";
import {SummaMeter} from "./SummaMeter.sol";

/// @dev The parts of EIP-3009 used here. USD₮0 on Flare answers all three (read 2026-09-26).
interface IERC3009 {
    function receiveWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;

    function authorizationState(address authorizer, bytes32 nonce) external view returns (bool);

    function DOMAIN_SEPARATOR() external view returns (bytes32);
}

/// @title MandateFacilitator: an x402 facilitator that cannot settle past the mandate
/// @notice Flare's own x402 guide settles through a facilitator *contract*. This one puts the brake,
///         the settlement and the receipt in one transaction:
///           1. `SummaMeter.wouldExceed`: would this payment take the umbrella past its dollar
///              budget, counting what the agent already spent on every other rail? Then revert.
///           2. `receiveWithAuthorization`: EIP-3009's pull form, which only the payee can execute.
///              The agent signs its authorisation *to this contract*, so nobody can take the same
///              signature to the token directly and settle around the brake. The brake is not a
///              server's promise; it is the only door.
///           3. forward to the seller, `SummaMeter.note`, and emit the receipt (witness 1).
///
///         Since v0.16 the door also keeps a log of who pushed on it (amendment v1.2, Conatus).
///         `recordAttempt` turns a refused authorisation into a public record, signed by the agent
///         itself, and strikes the umbrella's tripwire in the meter.
/// @dev    The seller is bound by the agent's own signature: the EIP-3009 nonce must equal
///         `payNonce(seller, umbrellaId, memberId, salt)`. The facilitator can therefore not
///         redirect a payment. It holds no funds between transactions, has no admin and is not a
///         judge. What it moves is the agent's Transfer, which §6.11 and JudgeSumma already see.
contract MandateFacilitator {
    using SafeERC20 for IERC20;

    /// EIP-3009's typehash for the pull form. The same constant USD₮0 on Flare returns.
    bytes32 public constant RECEIVE_WITH_AUTHORIZATION_TYPEHASH =
        keccak256("ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)");
    /// An attempt is counted at 99 % of its live value: the price may have moved since it was signed.
    uint256 public constant PRICE_MARGIN_BPS = 100;

    MandateRegistry public immutable registry;
    JudgeSumma public immutable summa;
    SummaMeter public immutable meter;
    bytes32 public immutable sourceId; // the FDC source of this chain: "testFLR" on Coston2, "FLR" on Flare

    /// nonce => when it was recorded as an attempt (0 = never). A recorded nonce never settles here.
    mapping(bytes32 => uint64) public attemptedAt;
    /// member mandate => attempts recorded against it
    mapping(uint256 => uint256) public attempts;

    event Settled(
        uint256 indexed umbrellaId,
        uint256 indexed memberId,
        address indexed agent,
        address seller,
        address token,
        uint256 value,
        uint256 usd6,
        bytes32 nonce
    );
    event Attempted(
        uint256 indexed umbrellaId,
        uint256 indexed memberId,
        address indexed agent,
        address seller,
        uint256 value,
        uint256 usd6,
        uint256 spentBeforeUsd6,
        bytes32 nonce
    );

    error NotMember();
    error WrongToken();
    error NotLive();
    error WouldExceed(uint256 usd6);
    error Tripped();
    error Recorded();
    error NotAnAttempt();
    error BadSignature();
    error NotLiveAuthorization();

    constructor(MandateRegistry registry_, JudgeSumma summa_, SummaMeter meter_, bytes32 sourceId_) {
        registry = registry_;
        summa = summa_;
        meter = meter_;
        sourceId = sourceId_;
    }

    /// @notice The EIP-3009 nonce an agent signs to pay `seller` under this umbrella and member.
    function payNonce(address seller, uint256 umbrellaId, uint256 memberId, bytes32 salt) public pure returns (bytes32) {
        return keccak256(abi.encode("DELICTI/x402", seller, umbrellaId, memberId, salt));
    }

    struct Auth {
        uint256 value;
        uint256 validAfter;
        uint256 validBefore;
        bytes32 salt;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    /// @notice Settle one x402 payment from a member's agent to `seller`, or refuse it.
    /// @param slackBps brake this many basis points before the budget, as margin for the gap between
    ///        the live price read here and the anchor price a verdict would use.
    function settle(uint256 umbrellaId, uint256 memberId, address seller, Auth calldata a, uint16 slackBps)
        external
        returns (uint256 usd6)
    {
        (MandateRegistry.Mandate memory m, address token) = _member(umbrellaId, memberId);
        if (!registry.isLive(memberId) || !registry.isLive(umbrellaId)) revert NotLive();
        if (meter.tripped(umbrellaId)) revert Tripped();
        bytes32 nonce = payNonce(seller, umbrellaId, memberId, a.salt);
        if (attemptedAt[nonce] != 0) revert Recorded();

        bool stop;
        (stop, usd6) = meter.wouldExceed(umbrellaId, sourceId, m.assetKey, a.value, slackBps);
        if (stop) revert WouldExceed(usd6);

        IERC3009(token).receiveWithAuthorization(
            m.agent, address(this), a.value, a.validAfter, a.validBefore, nonce, a.v, a.r, a.s
        );
        IERC20(token).safeTransfer(seller, a.value);
        meter.note(umbrellaId, sourceId, m.assetKey, a.value);
        emit Settled(umbrellaId, memberId, m.agent, seller, token, a.value, usd6, nonce);
    }

    /// @notice Conatus: record an attempt the brake refuses. Anyone holding the authorisation may.
    ///         Recorded only when all of these hold:
    ///           - the agent signed it, to this contract (the same signature `settle` would take);
    ///           - it is live at the token: inside its window, neither used nor cancelled. An agent
    ///             that cancels its own authorisation first has withdrawn the attempt;
    ///           - it breaks the budget against the tally as it stood at `validAfter`, the earliest
    ///             moment it could be used, at 99 % of its value. Spend noted after that does not
    ///             count, so an honest authorisation that lost a race, or that a seller sat on, is
    ///             not an attempt.
    ///         The nonce then never settles here, and, if the principal declared this contract an
    ///         effector, the umbrella's tripwire takes a strike.
    /// @return overUsd6 by how much it would have broken the budget, in µUSD
    function recordAttempt(uint256 umbrellaId, uint256 memberId, address seller, Auth calldata a)
        external
        returns (uint256 overUsd6)
    {
        (MandateRegistry.Mandate memory m, address token) = _member(umbrellaId, memberId);
        bytes32 nonce = payNonce(seller, umbrellaId, memberId, a.salt);
        if (attemptedAt[nonce] != 0) revert Recorded();
        if (block.timestamp <= a.validAfter || block.timestamp >= a.validBefore) revert NotLiveAuthorization();
        if (IERC3009(token).authorizationState(m.agent, nonce)) revert NotLiveAuthorization();
        _signedByAgent(token, m.agent, nonce, a);

        uint256 usd6 = meter.valueNow(sourceId, m.assetKey, a.value);
        uint256 before = meter.spentAt(umbrellaId, uint64(a.validAfter));
        uint256 counted = before + usd6 - (usd6 * PRICE_MARGIN_BPS) / 10_000;
        uint256 budget = registry.get(umbrellaId).budget;
        if (counted <= budget) revert NotAnAttempt();

        attemptedAt[nonce] = uint64(block.timestamp);
        attempts[memberId] += 1;
        emit Attempted(umbrellaId, memberId, m.agent, seller, a.value, usd6, before, nonce);
        if (meter.effector(umbrellaId, address(this))) meter.strike(umbrellaId, nonce);
        return counted - budget;
    }

    function _member(uint256 umbrellaId, uint256 memberId)
        private
        view
        returns (MandateRegistry.Mandate memory m, address token)
    {
        if (summa.linkedAt(umbrellaId, memberId) == 0) revert NotMember();
        m = registry.get(memberId);
        if (m.sourceId != sourceId) revert WrongToken();
        token = address(uint160(uint256(m.assetKey)));
        if (uint256(m.assetKey) >> 160 != 0 || token == address(0)) revert WrongToken();
    }

    /// @dev The EIP-712 digest the token itself checks in `receiveWithAuthorization`, recovered here
    ///      without moving anything. High-s and malformed signatures are refused, as the token does.
    function _signedByAgent(address token, address agent, bytes32 nonce, Auth calldata a) private view {
        bytes32 structHash = keccak256(
            abi.encode(RECEIVE_WITH_AUTHORIZATION_TYPEHASH, agent, address(this), a.value, a.validAfter, a.validBefore, nonce)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", IERC3009(token).DOMAIN_SEPARATOR(), structHash));
        (address signer, ECDSA.RecoverError err,) = ECDSA.tryRecover(digest, a.v, a.r, a.s);
        if (err != ECDSA.RecoverError.NoError || signer != agent) revert BadSignature();
    }
}
