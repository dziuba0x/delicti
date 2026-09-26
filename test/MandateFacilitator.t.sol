// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {MandateRegistry} from "../src/MandateRegistry.sol";
import {AgentRefs} from "../src/AgentRefs.sol";
import {Vault} from "../src/Vault.sol";
import {JudgeSumma} from "../src/JudgeSumma.sol";
import {SummaMeter} from "../src/SummaMeter.sol";
import {MandateFacilitator} from "../src/MandateFacilitator.sol";
import {MockUSDT0} from "../src/mocks/MockUSDT0.sol";
import {MockProtocolsV2} from "./Rounds.sol";
import {MockFtsoLive} from "./SummaMeter.t.sol";
import {IFdcVerification} from "@flarenetwork/flare-periphery-contracts/coston2/IFdcVerification.sol";
import {FtsoV2Interface} from "@flarenetwork/flare-periphery-contracts/coston2/FtsoV2Interface.sol";
import {ProtocolsV2Interface} from "@flarenetwork/flare-periphery-contracts/coston2/ProtocolsV2Interface.sol";

/// @title MandateFacilitator: brake, settlement and receipt in one transaction
contract MandateFacilitatorTest is Test {
    MandateRegistry reg;
    JudgeSumma summa;
    SummaMeter meter;
    MandateFacilitator fac;
    MockUSDT0 usdt;
    MockFtsoLive ftso;

    address principal = makeAddr("principal");
    address agent;
    uint256 agentKey;
    address seller = makeAddr("seller");
    address thief = makeAddr("thief");
    bytes21 constant USDT_USD = bytes21(0x01555344542f555344000000000000000000000000);
    bytes32 constant SRC = bytes32("testFLR");
    uint256 umbrella;
    uint256 member;

    function setUp() public {
        vm.warp(1_800_000_000);
        (agent, agentKey) = makeAddrAndKey("agent");
        reg = new MandateRegistry();
        AgentRefs refs = new AgentRefs(reg, IFdcVerification(address(1)));
        usdt = new MockUSDT0();
        ftso = new MockFtsoLive();
        ftso.set(USDT_USD, 99_966_000, 8);
        JudgeSumma.PriceRow[] memory map = new JudgeSumma.PriceRow[](1);
        map[0] = JudgeSumma.PriceRow(SRC, bytes32(uint256(uint160(address(usdt)))), USDT_USD, 6);
        MockProtocolsV2 clock = new MockProtocolsV2();
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        summa = new JudgeSumma(Vault(predicted), reg, refs, IFdcVerification(address(1)), FtsoV2Interface(address(ftso)), map);
        address[] memory js = new address[](1);
        js[0] = address(summa);
        Vault vault = new Vault(reg, refs, ProtocolsV2Interface(address(clock)), 600, js);
        meter = new SummaMeter(reg, summa, FtsoV2Interface(address(ftso)));
        fac = new MandateFacilitator(reg, summa, meter, SRC);

        uint64 t = uint64(block.timestamp);
        vm.startPrank(principal);
        member = reg.commit(agent, keccak256("usdt rail"), 0, 0, 10_000_000, t, t + 1 days,
            MandateRegistry.Terms({sourceId: SRC, assetKey: bytes32(uint256(uint160(address(usdt)))), agentRef: 0, bond: address(vault)}));
        umbrella = reg.commit(agent, keccak256("at most $3"), 0, 0, 3_000_000, t, t + 1 days,
            MandateRegistry.Terms({sourceId: bytes32("SUMMA"), assetKey: bytes32("USD/1e6"), agentRef: 0, bond: address(vault)}));
        meter.declareEffector(umbrella, address(fac));
        vm.stopPrank();
        vm.startPrank(agent);
        reg.declareExclusive(member);
        reg.acknowledge(umbrella);
        summa.link(umbrella, member);
        vm.stopPrank();
        usdt.mint(agent, 10_000_000);
    }

    function _auth(address to, uint256 value, bytes32 salt, address payTo) internal view returns (MandateFacilitator.Auth memory a) {
        bytes32 nonce = fac.payNonce(payTo, umbrella, member, salt);
        bytes32 structHash = keccak256(abi.encode(usdt.RECEIVE_WITH_AUTHORIZATION_TYPEHASH(), agent, to, value, 0, block.timestamp + 1 hours, nonce));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(agentKey, keccak256(abi.encodePacked("\x19\x01", usdt.DOMAIN_SEPARATOR(), structHash)));
        a = MandateFacilitator.Auth({value: value, validAfter: 0, validBefore: block.timestamp + 1 hours, salt: salt, v: v, r: r, s: s});
    }

    function _pay(uint256 i) internal returns (uint256) {
        return fac.settle(umbrella, member, seller, _auth(address(fac), 1_000_000, bytes32(i), seller), 0);
    }

    function test_settlesAndMetersInOneTransaction() public {
        _pay(1);
        _pay(2);
        assertEq(usdt.balanceOf(seller), 2_000_000);
        assertEq(usdt.balanceOf(address(fac)), 0);
        assertEq(meter.spentUsd6(umbrella), 1_999_320);
    }

    /// $3 umbrella: three 1-USD₮0 payments ($2.99898) pass, the fourth is refused before any token moves.
    function test_theSliceThatWouldCrossIsRefused() public {
        _pay(1);
        _pay(2);
        _pay(3);
        MandateFacilitator.Auth memory a = _auth(address(fac), 1_000_000, bytes32(uint256(4)), seller);
        vm.expectRevert(abi.encodeWithSelector(MandateFacilitator.WouldExceed.selector, 999_660));
        fac.settle(umbrella, member, seller, a, 0);
        assertEq(usdt.balanceOf(seller), 3_000_000);
        assertEq(usdt.balanceOf(agent), 7_000_000);
    }

    /// The agent's signature names this contract as payee: nobody can take it to the token and settle
    /// around the brake.
    function test_theBrakeCannotBeBypassedAtTheToken() public {
        MandateFacilitator.Auth memory a = _auth(address(fac), 1_000_000, bytes32(uint256(9)), seller);
        bytes32 nonce = fac.payNonce(seller, umbrella, member, a.salt);
        vm.prank(thief);
        vm.expectRevert(MockUSDT0.CallerMustBePayee.selector);
        usdt.receiveWithAuthorization(agent, address(fac), 1_000_000, 0, a.validBefore, nonce, a.v, a.r, a.s);
        vm.prank(thief);
        vm.expectRevert();
        usdt.transferWithAuthorization(agent, address(fac), 1_000_000, 0, a.validBefore, nonce, a.v, a.r, a.s);
    }

    /// The seller is inside the signature (through the nonce): the facilitator cannot redirect a payment.
    function test_theSellerIsBoundByTheAgentsSignature() public {
        MandateFacilitator.Auth memory a = _auth(address(fac), 1_000_000, bytes32(uint256(5)), seller);
        vm.expectRevert();
        fac.settle(umbrella, member, thief, a, 0);
        assertEq(usdt.balanceOf(thief), 0);
    }

    function test_onlyLinkedMembersSettle() public {
        MandateFacilitator.Auth memory a = _auth(address(fac), 1_000_000, bytes32(uint256(6)), seller);
        vm.expectRevert(MandateFacilitator.NotMember.selector);
        fac.settle(umbrella, member + 7, seller, a, 0);
    }

    // ------------------------------------------------------------------ amendment v1.2: Conatus

    function _signed(uint256 key, address to, uint256 value, bytes32 salt, address payTo, uint256 validAfter)
        internal
        view
        returns (MandateFacilitator.Auth memory a)
    {
        bytes32 nonce = fac.payNonce(payTo, umbrella, member, salt);
        uint256 validBefore = block.timestamp + 5 minutes;
        bytes32 structHash = keccak256(abi.encode(usdt.RECEIVE_WITH_AUTHORIZATION_TYPEHASH(), agent, to, value, validAfter, validBefore, nonce));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, keccak256(abi.encodePacked("\x19\x01", usdt.DOMAIN_SEPARATOR(), structHash)));
        a = MandateFacilitator.Auth(value, validAfter, validBefore, salt, v, r, s);
    }

    /// x402's own convention: an authorisation is valid from ten minutes before it is signed.
    function _x402(uint256 value, uint256 salt) internal view returns (MandateFacilitator.Auth memory) {
        return _signed(agentKey, address(fac), value, bytes32(salt), seller, block.timestamp - 10 minutes);
    }

    /// $2.99898 spent, then the agent signs a fourth dollar: refused, and recorded with the agent's
    /// own signature. With no tripwire set the umbrella keeps working; the strike is still counted.
    function test_conatus_aRefusedAttemptIsRecorded() public {
        _pay(1);
        _pay(2);
        _pay(3);
        vm.warp(block.timestamp + 11 minutes); // the tally at validAfter already holds all three
        MandateFacilitator.Auth memory a = _x402(1_000_000, 4);
        vm.expectRevert(abi.encodeWithSelector(MandateFacilitator.WouldExceed.selector, 999_660));
        fac.settle(umbrella, member, seller, a, 0);

        vm.prank(seller);
        uint256 over = fac.recordAttempt(umbrella, member, seller, a);
        assertEq(over, 2_998_980 + 999_660 - 9_996 - 3_000_000); // counted at 99 %
        assertEq(fac.attempts(member), 1);
        assertEq(fac.attemptedAt(fac.payNonce(seller, umbrella, member, a.salt)), block.timestamp);
        assertEq(meter.strikes(umbrella), 1);
        assertFalse(meter.tripped(umbrella));
    }

    /// Signed with room to spare, then beaten to the headroom by another payment (or held back by a
    /// seller until it was). The brake refuses it, but it is not an attempt: only spend noted by
    /// `validAfter` counts against it.
    function test_conatus_anHonestAuthorisationThatLostARaceIsNotAnAttempt() public {
        _pay(1);
        _pay(2);
        vm.warp(block.timestamp + 11 minutes);
        MandateFacilitator.Auth memory mine = _x402(1_000_000, 7); // $2.99898 if it settles now
        _pay(3); // another payment gets there first
        vm.expectRevert(abi.encodeWithSelector(MandateFacilitator.WouldExceed.selector, 999_660));
        fac.settle(umbrella, member, seller, mine, 0);
        vm.expectRevert(MandateFacilitator.NotAnAttempt.selector);
        fac.recordAttempt(umbrella, member, seller, mine);
        assertEq(meter.strikes(umbrella), 0);
    }

    /// One payment larger than the whole budget is an attempt whatever window it was signed with.
    function test_conatus_moreThanTheWholeBudgetIsAnAttemptFromAnyWindow() public {
        MandateFacilitator.Auth memory a = _signed(agentKey, address(fac), 5_000_000, bytes32(uint256(8)), seller, 0);
        fac.recordAttempt(umbrella, member, seller, a);
        assertEq(fac.attempts(member), 1);
    }

    /// The agent withdraws its own authorisation at the token before anyone records it.
    function test_conatus_aCancelledAuthorisationIsNotRecorded() public {
        _pay(1);
        _pay(2);
        _pay(3);
        vm.warp(block.timestamp + 11 minutes);
        MandateFacilitator.Auth memory a = _x402(1_000_000, 4);
        bytes32 nonce = fac.payNonce(seller, umbrella, member, a.salt);
        bytes32 ch = keccak256(abi.encode(keccak256("CancelAuthorization(address authorizer,bytes32 nonce)"), agent, nonce));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(agentKey, keccak256(abi.encodePacked("\x19\x01", usdt.DOMAIN_SEPARATOR(), ch)));
        usdt.cancelAuthorization(agent, nonce, v, r, s);
        vm.expectRevert(MandateFacilitator.NotLiveAuthorization.selector);
        fac.recordAttempt(umbrella, member, seller, a);
    }

    /// Nobody can put an attempt in the agent's name: not another key, not the agent's signature for
    /// another payee, not the right signature under a different seller.
    function test_conatus_onlyTheAgentsOwnSignatureToThisDoorCounts() public {
        (, uint256 malloryKey) = makeAddrAndKey("mallory");
        uint256 t = block.timestamp;
        MandateFacilitator.Auth memory forged = _signed(malloryKey, address(fac), 5_000_000, bytes32(uint256(1)), seller, t - 1);
        vm.expectRevert(MandateFacilitator.BadSignature.selector);
        fac.recordAttempt(umbrella, member, seller, forged);

        MandateFacilitator.Auth memory elsewhere = _signed(agentKey, seller, 5_000_000, bytes32(uint256(2)), seller, t - 1);
        vm.expectRevert(MandateFacilitator.BadSignature.selector);
        fac.recordAttempt(umbrella, member, seller, elsewhere);

        MandateFacilitator.Auth memory real = _signed(agentKey, address(fac), 5_000_000, bytes32(uint256(3)), seller, t - 1);
        vm.expectRevert(MandateFacilitator.BadSignature.selector);
        fac.recordAttempt(umbrella, member, thief, real);
        fac.recordAttempt(umbrella, member, seller, real);
    }

    function test_conatus_usedOrExpiredAuthorisationsAreNotAttempts() public {
        MandateFacilitator.Auth memory used = _auth(address(fac), 1_000_000, bytes32(uint256(1)), seller);
        fac.settle(umbrella, member, seller, used, 0);
        vm.expectRevert(MandateFacilitator.NotLiveAuthorization.selector);
        fac.recordAttempt(umbrella, member, seller, used);

        MandateFacilitator.Auth memory late = _signed(agentKey, address(fac), 5_000_000, bytes32(uint256(2)), seller, 0);
        vm.warp(block.timestamp + 5 minutes);
        vm.expectRevert(MandateFacilitator.NotLiveAuthorization.selector);
        fac.recordAttempt(umbrella, member, seller, late);
    }

    /// A recorded attempt is final at this door, even if a price move would now let it through.
    function test_conatus_aRecordedAttemptNeverSettles() public {
        _pay(1);
        _pay(2);
        _pay(3);
        vm.warp(block.timestamp + 11 minutes);
        MandateFacilitator.Auth memory a = _x402(1_000_000, 4);
        fac.recordAttempt(umbrella, member, seller, a);
        ftso.set(USDT_USD, 1, 8); // a dollar of USD₮0 now reads as nothing: the brake alone would pass it
        vm.expectRevert(MandateFacilitator.Recorded.selector);
        fac.settle(umbrella, member, seller, a, 0);
        vm.expectRevert(MandateFacilitator.Recorded.selector);
        fac.recordAttempt(umbrella, member, seller, a);
        assertEq(usdt.balanceOf(seller), 3_000_000);
    }

    /// Tripwire 1: the first recorded attempt stops every payment of the umbrella, on every rail,
    /// until the principal re-arms. The XRPL co-signer asks the same `wouldExceed` and stops too.
    function test_tripwire_oneAttemptStopsEverythingUntilThePrincipalRearms() public {
        vm.prank(principal);
        meter.setTripwire(umbrella, 1);
        _pay(1);
        vm.warp(block.timestamp + 11 minutes);
        fac.recordAttempt(umbrella, member, seller, _x402(3_000_000, 9));
        assertTrue(meter.tripped(umbrella));

        MandateFacilitator.Auth memory small = _x402(500_000, 10); // $0.50 would fit
        vm.expectRevert(MandateFacilitator.Tripped.selector);
        fac.settle(umbrella, member, seller, small, 0);
        (bool stop,) = meter.wouldExceed(umbrella, SRC, bytes32(uint256(uint160(address(usdt)))), 1, 0);
        assertTrue(stop);

        vm.prank(principal);
        meter.rearm(umbrella);
        fac.settle(umbrella, member, seller, small, 0);
        assertEq(usdt.balanceOf(seller), 1_500_000);
    }
}
