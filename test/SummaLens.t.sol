// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {MandateRegistry} from "../src/MandateRegistry.sol";
import {AgentRefs} from "../src/AgentRefs.sol";
import {Vault} from "../src/Vault.sol";
import {JudgeSumma} from "../src/JudgeSumma.sol";
import {SummaMeter} from "../src/SummaMeter.sol";
import {SummaLens} from "../src/SummaLens.sol";
import {MockProtocolsV2} from "./Rounds.sol";
import {MockFtsoLive} from "./SummaMeter.t.sol";
import {IFdcVerification} from "@flarenetwork/flare-periphery-contracts/coston2/IFdcVerification.sol";
import {FtsoV2Interface} from "@flarenetwork/flare-periphery-contracts/coston2/FtsoV2Interface.sol";
import {ProtocolsV2Interface} from "@flarenetwork/flare-periphery-contracts/coston2/ProtocolsV2Interface.sol";

/// @title SummaLens: the FLR bond, read in dollars (amendment v1.1, S.7)
contract SummaLensTest is Test {
    MandateRegistry reg;
    Vault vault;
    SummaMeter meter;
    SummaLens lens;
    MockFtsoLive ftso;
    address principal = makeAddr("principal");
    address agent = makeAddr("agent");
    bytes21 constant FLR_USD = bytes21(0x01464c522f55534400000000000000000000000000);
    uint256 umbrella;

    function setUp() public {
        vm.warp(1_800_000_000);
        reg = new MandateRegistry();
        AgentRefs refs = new AgentRefs(reg, IFdcVerification(address(1)));
        ftso = new MockFtsoLive();
        ftso.set(FLR_USD, 720_000, 8); // 0.0072 USD, as on 2026-09-24
        MockProtocolsV2 clock = new MockProtocolsV2();
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        JudgeSumma summa = new JudgeSumma(Vault(predicted), reg, refs, IFdcVerification(address(1)), FtsoV2Interface(address(ftso)), new JudgeSumma.PriceRow[](0));
        address[] memory js = new address[](1);
        js[0] = address(summa);
        vault = new Vault(reg, refs, ProtocolsV2Interface(address(clock)), 600, js);
        meter = new SummaMeter(reg, summa, FtsoV2Interface(address(ftso)));
        lens = new SummaLens(reg, meter, FLR_USD, 3000, FtsoV2Interface(address(ftso)));

        vm.prank(principal);
        umbrella = reg.commit(agent, keccak256("at most $5"), 0, 0, 5_000_000, uint64(block.timestamp), uint64(block.timestamp + 1 days),
            MandateRegistry.Terms({sourceId: bytes32("SUMMA"), assetKey: bytes32("USD/1e6"), agentRef: 0, bond: address(vault)}));
        vm.prank(agent);
        reg.acknowledge(umbrella);
        vm.deal(principal, 10_000 ether);
        vm.prank(principal);
        vault.post{value: 10 ether}(umbrella);
    }

    /// 10 FLR at 0.0072 is $0.072, $0.0504 after the 30 % haircut: 1 % of a $5 budget.
    function test_theBondIsReadInDollarsAfterTheHaircut() public {
        SummaLens.Reading memory r = lens.read(umbrella);
        assertEq(r.nativeUsd6, 7_200);
        assertEq(r.coverageUsd6, 50_400);
        assertEq(r.budgetUsd6, 5_000_000);
        assertEq(r.remainingUsd6, 5_000_000);
        assertEq(r.kBps, 100);
        assertFalse(lens.covers(umbrella, 10_000));
    }

    /// The margin call: post what `topUpFor` says, and the umbrella covers 1× its budget at today's price.
    function test_topUpRestoresCoverage() public {
        uint256 need = lens.topUpFor(umbrella, 10_000);
        assertApproxEqRel(need, 982.0634921 ether, 1e12);
        vm.prank(principal);
        vault.post{value: need}(umbrella);
        assertTrue(lens.covers(umbrella, 10_000));
        assertEq(lens.topUpFor(umbrella, 10_000), 0);
    }

    /// FLR halves: the same bond covers half as much, and the counterparty sees it at once.
    function test_aFallingPriceShowsUpImmediately() public {
        vm.prank(principal);
        vault.post{value: lens.topUpFor(umbrella, 10_000)}(umbrella);
        assertTrue(lens.covers(umbrella, 10_000));
        ftso.set(FLR_USD, 360_000, 8);
        assertFalse(lens.covers(umbrella, 10_000));
        assertApproxEqAbs(lens.read(umbrella).kBps, 5_000, 1);
    }

    function test_aHaircutOfEverythingIsRefused() public {
        vm.expectRevert(SummaLens.BadHaircut.selector);
        new SummaLens(reg, meter, FLR_USD, 10_000, FtsoV2Interface(address(ftso)));
    }

    /// Whatever the price and the target, posting `topUpFor` always suffices: the inverse rounds up at every floor.
    function testFuzz_topUpAlwaysSuffices(uint64 price, uint16 kBps) public {
        price = uint64(bound(price, 1_000, 1e12));
        kBps = uint16(bound(kBps, 1, 30_000));
        ftso.set(FLR_USD, price, 8);
        uint256 need = lens.topUpFor(umbrella, kBps);
        vm.deal(principal, need + 1 ether);
        if (need != 0) {
            vm.prank(principal);
            vault.post{value: need}(umbrella);
        }
        assertTrue(lens.covers(umbrella, kBps));
    }
}
