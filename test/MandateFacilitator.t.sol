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
}
