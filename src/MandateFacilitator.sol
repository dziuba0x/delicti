// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MandateRegistry} from "./MandateRegistry.sol";
import {JudgeSumma} from "./JudgeSumma.sol";
import {SummaMeter} from "./SummaMeter.sol";

interface IERC3009Receive {
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
/// @dev    The seller is bound by the agent's own signature: the EIP-3009 nonce must equal
///         `payNonce(seller, umbrellaId, memberId, salt)`. The facilitator can therefore not
///         redirect a payment. It holds no funds between transactions, has no admin and is not a
///         judge. What it moves is the agent's Transfer, which §6.11 and JudgeSumma already see.
contract MandateFacilitator {
    using SafeERC20 for IERC20;

    MandateRegistry public immutable registry;
    JudgeSumma public immutable summa;
    SummaMeter public immutable meter;
    bytes32 public immutable sourceId; // the FDC source of this chain: "testFLR" on Coston2, "FLR" on Flare

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

    error NotMember();
    error WrongToken();
    error NotLive();
    error WouldExceed(uint256 usd6);

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
        if (summa.linkedAt(umbrellaId, memberId) == 0) revert NotMember();
        MandateRegistry.Mandate memory m = registry.get(memberId);
        if (m.sourceId != sourceId) revert WrongToken();
        address token = address(uint160(uint256(m.assetKey)));
        if (uint256(m.assetKey) >> 160 != 0 || token == address(0)) revert WrongToken();
        if (!registry.isLive(memberId) || !registry.isLive(umbrellaId)) revert NotLive();

        bool stop;
        (stop, usd6) = meter.wouldExceed(umbrellaId, sourceId, m.assetKey, a.value, slackBps);
        if (stop) revert WouldExceed(usd6);

        bytes32 nonce = payNonce(seller, umbrellaId, memberId, a.salt);
        IERC3009Receive(token).receiveWithAuthorization(
            m.agent, address(this), a.value, a.validAfter, a.validBefore, nonce, a.v, a.r, a.s
        );
        IERC20(token).safeTransfer(seller, a.value);
        meter.note(umbrellaId, sourceId, m.assetKey, a.value);
        emit Settled(umbrellaId, memberId, m.agent, seller, token, a.value, usd6, nonce);
    }
}
