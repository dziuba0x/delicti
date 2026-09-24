// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {MandateRegistry} from "../src/MandateRegistry.sol";
import {AgentRefs} from "../src/AgentRefs.sol";
import {Vault} from "../src/Vault.sol";
import {JudgeSumma} from "../src/JudgeSumma.sol";
import {SummaMeter} from "../src/SummaMeter.sol";
import {MockProtocolsV2} from "./Rounds.sol";
import {IFdcVerification} from "@flarenetwork/flare-periphery-contracts/coston2/IFdcVerification.sol";
import {FtsoV2Interface} from "@flarenetwork/flare-periphery-contracts/coston2/FtsoV2Interface.sol";
import {ProtocolsV2Interface} from "@flarenetwork/flare-periphery-contracts/coston2/ProtocolsV2Interface.sol";

contract MockFtsoLive {
    mapping(bytes21 => uint256) public v;
    mapping(bytes21 => int8) public d;

    function set(bytes21 id, uint256 value, int8 decimals) external {
        v[id] = value;
        d[id] = decimals;
    }

    function getFeedById(bytes21 id) external payable returns (uint256, int8, uint64) {
        return (v[id], d[id], uint64(block.timestamp));
    }
}

/// @title SummaMeter: the brake across rails (amendment v1.1, S.8)
contract SummaMeterTest is Test {
    MandateRegistry reg;
    JudgeSumma summa;
    Vault vault;
    SummaMeter meter;
    MockFtsoLive ftso;

    address principal = makeAddr("principal");
    address agent = makeAddr("agent");
    address guard = makeAddr("guard"); // the XRPL co-signer
    address facilitator = makeAddr("facilitator"); // x402 on Flare
    address constant USDT0 = address(0x05D7);
    bytes21 constant XRP_USD = bytes21(0x015852502f55534400000000000000000000000000);
    bytes21 constant USDT_USD = bytes21(0x01555344542f555344000000000000000000000000);
    bytes32 constant XRP_SRC = bytes32("testXRP");
    bytes32 constant FLR_SRC = bytes32("testFLR");
    bytes32 constant OUTFLOW = bytes32("XRP/outflow");
    bytes32 usdtKey = bytes32(uint256(uint160(USDT0)));
    uint256 umbrella;

    function setUp() public {
        vm.warp(1_800_000_000);
        reg = new MandateRegistry();
        AgentRefs refs = new AgentRefs(reg, IFdcVerification(address(1)));
        ftso = new MockFtsoLive();
        ftso.set(XRP_USD, 152_000_000, 8); // 1.52 USD, 8 decimals like the live feed
        ftso.set(USDT_USD, 99_966_000, 8);
        JudgeSumma.PriceRow[] memory map = new JudgeSumma.PriceRow[](2);
        map[0] = JudgeSumma.PriceRow(XRP_SRC, OUTFLOW, XRP_USD, 6);
        map[1] = JudgeSumma.PriceRow(FLR_SRC, usdtKey, USDT_USD, 6);
        MockProtocolsV2 clock = new MockProtocolsV2();
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        summa = new JudgeSumma(Vault(predicted), reg, refs, IFdcVerification(address(1)), FtsoV2Interface(address(ftso)), map);
        address[] memory js = new address[](1);
        js[0] = address(summa);
        vault = new Vault(reg, refs, ProtocolsV2Interface(address(clock)), 600, js);
        meter = new SummaMeter(reg, summa, FtsoV2Interface(address(ftso)));

        vm.prank(principal);
        umbrella = reg.commit(agent, keccak256("at most $10"), 0, 0, 10_000_000, uint64(block.timestamp), uint64(block.timestamp + 1 days),
            MandateRegistry.Terms({sourceId: bytes32("SUMMA"), assetKey: bytes32("USD/1e6"), agentRef: 0, bond: address(vault)}));
        vm.startPrank(principal);
        meter.declareEffector(umbrella, guard);
        meter.declareEffector(umbrella, facilitator);
        vm.stopPrank();
    }

    /// Three 2-XRP payments co-signed on XRPL ($9.12), then an x402 payment on Flare that would cross:
    /// refused by the facilitator before it settles, on a tally the other rail wrote.
    function test_theFifthSliceIsRefusedOnAnotherChain() public {
        for (uint256 i = 0; i < 3; i++) {
            (bool stop,) = meter.wouldExceed(umbrella, XRP_SRC, OUTFLOW, 2_000_000, 0);
            assertFalse(stop);
            vm.prank(guard);
            meter.note(umbrella, XRP_SRC, OUTFLOW, 2_000_000);
        }
        assertEq(meter.spentUsd6(umbrella), 9_120_000);

        (bool ok, uint256 small) = meter.wouldExceed(umbrella, FLR_SRC, usdtKey, 800_000, 0);
        assertFalse(ok); // $0.80 still fits
        assertEq(small, 799_728);
        (bool cross,) = meter.wouldExceed(umbrella, FLR_SRC, usdtKey, 1_000_000, 0);
        assertTrue(cross); // $1.00 would take it to $10.12: refused, on Flare, because of XRPL
    }

    function test_slackBrakesEarly() public {
        vm.prank(guard);
        meter.note(umbrella, XRP_SRC, OUTFLOW, 6_000_000); // $9.12
        (bool plain,) = meter.wouldExceed(umbrella, FLR_SRC, usdtKey, 800_000, 0);
        (bool careful,) = meter.wouldExceed(umbrella, FLR_SRC, usdtKey, 800_000, 100); // brake 1 % early
        assertFalse(plain);
        assertTrue(careful);
    }

    function test_onlyDeclaredEffectorsWrite() public {
        vm.prank(agent);
        vm.expectRevert(SummaMeter.NotEffector.selector);
        meter.note(umbrella, XRP_SRC, OUTFLOW, 1);
        vm.prank(agent);
        vm.expectRevert(SummaMeter.NotPrincipal.selector);
        meter.declareEffector(umbrella, agent);
    }

    function test_unpricedAssetsAreRefused() public {
        vm.expectRevert(SummaMeter.Unpriced.selector);
        meter.wouldExceed(umbrella, FLR_SRC, bytes32(uint256(0xBEEF)), 1, 0);
    }

    function test_theTallyRemembersAndRecordsPastTheBudget() public {
        vm.prank(guard);
        meter.note(umbrella, XRP_SRC, OUTFLOW, 6_000_000);
        uint64 t1 = uint64(block.timestamp);
        vm.warp(t1 + 60);
        vm.prank(facilitator);
        meter.note(umbrella, FLR_SRC, usdtKey, 2_000_000); // past $10: recorded anyway
        assertEq(meter.spentAt(umbrella, t1 - 1), 0);
        assertEq(meter.spentAt(umbrella, t1), 9_120_000);
        assertEq(meter.spentAt(umbrella, t1 + 60), 9_120_000 + 1_999_320);
        assertEq(meter.checkpointCount(umbrella), 2);
    }
}
