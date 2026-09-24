// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {MandateRegistry} from "../src/MandateRegistry.sol";
import {AnchorLog} from "../src/AnchorLog.sol";
import {AgentRefs} from "../src/AgentRefs.sol";
import {SpendMeter} from "../src/SpendMeter.sol";
import {Vault} from "../src/Vault.sol";
import {JudgeEvm} from "../src/JudgeEvm.sol";
import {JudgeXrpl} from "../src/JudgeXrpl.sol";
import {DelictiErrors} from "../src/DelictiErrors.sol";
import {Core} from "./Core.sol";
import {MockProtocolsV2} from "./Rounds.sol";
import {MockFdcXrpl} from "./Outflow.t.sol";
import {IFdcVerification} from "@flarenetwork/flare-periphery-contracts/coston2/IFdcVerification.sol";
import {IEVMTransaction} from "@flarenetwork/flare-periphery-contracts/coston2/IEVMTransaction.sol";
import {IPayment} from "@flarenetwork/flare-periphery-contracts/coston2/IPayment.sol";
import {IBalanceDecreasingTransaction} from
    "@flarenetwork/flare-periphery-contracts/coston2/IBalanceDecreasingTransaction.sol";
import {ProtocolsV2Interface} from "@flarenetwork/flare-periphery-contracts/coston2/ProtocolsV2Interface.sol";

/// An FDC that believes everything, for all three docket types.
contract YesFdc {
    function verifyEVMTransaction(IEVMTransaction.Proof calldata) external pure returns (bool) {
        return true;
    }

    function verifyPayment(IPayment.Proof calldata) external pure returns (bool) {
        return true;
    }

    function verifyBalanceDecreasingTransaction(IBalanceDecreasingTransaction.Proof calldata) external pure returns (bool) {
        return true;
    }
}

/// @title The watch pool (v0.14, SPEC §8.4) — paying for the docket to be kept
contract WatchPoolTest is Test {
    MandateRegistry reg;
    AnchorLog anchorLog;
    Vault bond;
    JudgeEvm judge;
    JudgeXrpl xjudge;
    AgentRefs refs;
    MockProtocolsV2 rounds;

    address principal = makeAddr("principal");
    address agent = makeAddr("agent");
    address watcher = makeAddr("watcher");
    address rival = makeAddr("rival");
    address insurer = makeAddr("insurer");
    address constant USDC = address(0x5DC0);
    bytes32 constant TRANSFER = keccak256("Transfer(address,address,uint256)");
    bytes32 constant SALT = keccak256("salt");
    uint256 constant EACH = 1_000_000;
    uint256 constant BUDGET = 4_000_000;
    uint256 constant RATE = 0.01 ether;

    uint256 id;

    function setUp() public {
        vm.warp(1_800_000_000);
        reg = new MandateRegistry();
        anchorLog = new AnchorLog(reg);
        rounds = new MockProtocolsV2();
        IFdcVerification fdc = IFdcVerification(address(new YesFdc()));
        refs = new AgentRefs(reg, fdc);
        (bond, judge, xjudge) = Core.deploy(
            reg, anchorLog, fdc, 24 hours, 1 hours, new SpendMeter(reg), 10 minutes, ProtocolsV2Interface(address(rounds)), refs, 5 minutes
        );
        vm.deal(principal, 100 ether);
        vm.deal(agent, 100 ether);
        vm.deal(insurer, 100 ether);
        vm.prank(principal);
        id = reg.commit(
            agent, keccak256("usdc"), 0, 0, BUDGET, uint64(block.timestamp), uint64(block.timestamp + 1 days),
            MandateRegistry.Terms({sourceId: bytes32("testFLR"), assetKey: bytes32(uint256(uint160(USDC))), agentRef: bytes32(0), bond: address(bond)})
        );
        vm.prank(agent);
        reg.declareExclusive(id);
        vm.prank(principal);
        bond.post{value: 10 ether}(id);
    }

    // ------------------------------------------------------------------ helpers

    function _ev(uint32 li, address from, uint256 v) internal pure returns (IEVMTransaction.Event memory e) {
        e.logIndex = li;
        e.emitterAddress = USDC;
        e.topics = new bytes32[](3);
        e.topics[0] = TRANSFER;
        e.topics[1] = bytes32(uint256(uint160(from)));
        e.topics[2] = bytes32(uint256(uint160(address(0x2222))));
        e.data = abi.encode(v);
    }

    function _tx(uint256 i, uint256 v) internal view returns (IEVMTransaction.Proof memory p) {
        p.data.sourceId = bytes32("testFLR");
        p.data.votingRound = 500;
        p.data.requestBody.transactionHash = bytes32(uint256(0x1000 + i));
        p.data.requestBody.requiredConfirmations = 1;
        p.data.responseBody.timestamp = 1_800_000_060; // inside the window, whenever it is filed
        p.data.responseBody.status = 1;
        p.data.responseBody.events = new IEVMTransaction.Event[](1);
        p.data.responseBody.events[0] = _ev(uint32(i), agent, v);
    }

    function _txs(uint256 from, uint256 k, uint256 v) internal view returns (IEVMTransaction.Proof[] memory pr) {
        pr = new IEVMTransaction.Proof[](k);
        for (uint256 i = 0; i < k; i++) pr[i] = _tx(from + i, v);
    }

    function _terms(uint256 rate, uint256 minV, uint256 fund) internal {
        vm.startPrank(principal);
        bond.setWatchTerms(id, rate, minV);
        bond.fundWatch{value: fund}(id);
        vm.stopPrank();
    }

    function _file(address who, IEVMTransaction.Proof[] memory pr, bytes32 salt) internal {
        vm.prank(who);
        judge.fileErc20Outflow(id, pr, salt);
    }

    // ------------------------------------------------------------------ paid work

    /// An agent that behaves: three deeds under a budget of four. Before v0.14 the watcher who kept
    /// its docket earned nothing; now each new deed pays the stipend.
    function test_recordingIsPaidPerNewDeed() public {
        _terms(RATE, 0, 1 ether);
        _file(watcher, _txs(0, 3, EACH), bytes32(0));
        assertEq(bond.owed(watcher), 3 * RATE);
        assertEq(bond.watchPool(id), 1 ether - 3 * RATE);
        assertFalse(bond.slashed(id));
    }

    /// The race is for new work only: a second filer of the same deeds is refused, and a filing that
    /// overlaps earns only for what it adds.
    function test_onlyTheFirstFilerOfADeedIsPaid() public {
        _terms(RATE, 0, 1 ether);
        _file(watcher, _txs(0, 2, EACH), bytes32(0));
        vm.expectRevert(DelictiErrors.NothingNew.selector);
        _file(rival, _txs(0, 2, EACH), bytes32(0));
        _file(rival, _txs(0, 3, EACH), bytes32(0)); // overlaps two, adds one
        assertEq(bond.owed(watcher), 2 * RATE);
        assertEq(bond.owed(rival), RATE);
    }

    /// Anyone can make a standard token emit Transfer(agent, x, 0) by calling transferFrom(agent,
    /// x, 0). Such a "deed" is provable and is not the agent's act. It must earn nothing, or a
    /// stranger drains the pool for the price of gas.
    function test_zeroValueTransfersEarnNothing() public {
        _terms(RATE, 0, 1 ether);
        _file(rival, _txs(0, 5, 0), bytes32(0));
        assertEq(bond.owed(rival), 0);
        assertEq(bond.watchPool(id), 1 ether);
    }

    /// The minimum is the principal's defence against dust: an agent paying 1-unit transfers to feed
    /// its own watcher pays a real transfer and an attestation per deed, and earns nothing below it.
    function test_deedsBelowTheMinimumEarnNothing() public {
        _terms(RATE, EACH / 2, 1 ether);
        IEVMTransaction.Proof[] memory pr = _txs(0, 3, EACH);
        pr[1] = _tx(1, 1); // dust
        _file(watcher, pr, bytes32(0));
        assertEq(bond.owed(watcher), 2 * RATE);
    }

    /// The pool pays what it has and never makes a filing fail.
    function test_anEmptyPoolNeverBlocksAFiling() public {
        _terms(RATE, 0, RATE + RATE / 2); // one and a half stipends
        _file(watcher, _txs(0, 3, EACH), bytes32(0));
        assertEq(bond.owed(watcher), RATE + RATE / 2);
        assertEq(bond.watchPool(id), 0);
        _file(rival, _txs(3, 1, 0), bytes32(0)); // still files, earns nothing
        assertEq(judge.erc20Docket(id), 3 * EACH);
    }

    /// The crossing filer earns its stipends AND the challenger's reward.
    function test_theCrossingFilingIsPaidTwice() public {
        _terms(RATE, 0, 1 ether);
        _file(watcher, _txs(0, 3, EACH), bytes32(0));
        IEVMTransaction.Proof[] memory pr = _txs(3, 2, EACH);
        bytes32[] memory ids = new bytes32[](2);
        ids[0] = pr[0].data.requestBody.transactionHash;
        ids[1] = pr[1].data.requestBody.transactionHash;
        uint64 t = uint64(block.timestamp);
        vm.warp(t - 10 minutes);
        bond.commitChallenge(bond.commitmentFor(rival, id, bond.KIND_ERC20_OUTFLOW(), bond.deedsDigest(ids), SALT));
        vm.warp(t);
        rounds.setRoundStart(500, t);
        _file(rival, pr, SALT);
        assertTrue(bond.slashed(id));
        assertEq(bond.owed(rival), 2 * RATE + (bond.slashedAmount(id) * 1000) / 10_000);
    }

    // ------------------------------------------------------------------ terms

    function test_revert_onlyThePrincipalSetsTerms() public {
        vm.prank(agent);
        vm.expectRevert(DelictiErrors.NotPrincipal.selector);
        bond.setWatchTerms(id, RATE, 0);
    }

    /// Once offered, terms only get better for watchers: a principal who could cut the rate would
    /// cut it under a watcher that already paid for attestations.
    function test_termsOnlyImprove() public {
        _terms(RATE, EACH, 0);
        vm.startPrank(principal);
        vm.expectRevert(DelictiErrors.WatchTermsOnlyImprove.selector);
        bond.setWatchTerms(id, RATE - 1, EACH);
        vm.expectRevert(DelictiErrors.WatchTermsOnlyImprove.selector);
        bond.setWatchTerms(id, RATE, EACH + 1);
        bond.setWatchTerms(id, 2 * RATE, EACH / 2);
        vm.stopPrank();
        assertEq(bond.stipendPerDeed(id), 2 * RATE);
        assertEq(bond.stipendMinValue(id), EACH / 2);
    }

    /// No terms, no stipend: a funded pool with no rate waits, and filings still land.
    function test_aPoolWithoutTermsPaysNothing() public {
        vm.prank(agent);
        bond.fundWatch{value: 1 ether}(id);
        _file(watcher, _txs(0, 2, EACH), bytes32(0));
        assertEq(bond.owed(watcher), 0);
    }

    /// An outsider's money in a pool whose rate the principal sets would be a prize for collusion:
    /// the agent moves real value to itself, a sock puppet files it, the principal raises the rate.
    function test_revert_outsidersCannotFundAPool() public {
        vm.prank(insurer);
        vm.expectRevert(DelictiErrors.NotPrincipalOrAgent.selector);
        bond.fundWatch{value: 1 ether}(id);
    }

    // ------------------------------------------------------------------ refunds

    /// Funders get back their share of what is left, once the mandate is dead past the cooling
    /// window — the same moment the bond may leave. The first refund closes the pool.
    function test_refundIsProRataAndClosesThePool() public {
        _terms(RATE, 0, 3 ether);
        vm.prank(agent); // the agent funds its own watching: a statement of confidence
        bond.fundWatch{value: 1 ether}(id);
        _file(watcher, _txs(0, 3, EACH), bytes32(0)); // 3 stipends out of 4 ether

        vm.prank(principal);
        vm.expectRevert(DelictiErrors.MandateStillLive.selector);
        bond.refundWatch(id, payable(principal));

        vm.warp(block.timestamp + 1 days + 1 days + 1);
        uint256 left = 4 ether - 3 * RATE;
        uint256 p0 = principal.balance;
        vm.prank(principal);
        bond.refundWatch(id, payable(principal));
        assertEq(principal.balance - p0, (left * 3) / 4);
        assertTrue(bond.watchClosed(id));

        // closed: a late filing (the bond is still there) records but pays nothing
        _file(rival, _txs(4, 1, 0), bytes32(0));
        _file(rival, _txs(5, 1, EACH / 4), bytes32(0));
        assertEq(bond.owed(rival), 0);

        uint256 a0 = agent.balance;
        vm.prank(agent);
        bond.refundWatch(id, payable(agent));
        assertEq(agent.balance - a0, left / 4);
        vm.prank(agent);
        vm.expectRevert(DelictiErrors.NothingFunded.selector);
        bond.refundWatch(id, payable(agent));
        vm.prank(principal);
        vm.expectRevert(DelictiErrors.WatchClosed.selector);
        bond.fundWatch{value: 1}(id);
    }

    // ------------------------------------------------------------------ the XRPL dockets pay too

    /// §6.10: an inflow (anyone can send the agent XRP) is a provable deed that moved nothing out.
    function test_xrplOutflowDocketPaysForOutflowNotInflow() public {
        bytes32 ref = keccak256("rAgent");
        vm.prank(principal);
        uint256 x = reg.commit(
            agent, keccak256("xrp outflow"), 0, 0, 4_000_000, uint64(block.timestamp), uint64(block.timestamp + 1 days),
            MandateRegistry.Terms({sourceId: bytes32("testXRP"), assetKey: bytes32("XRP/outflow"), agentRef: ref, bond: address(bond)})
        );
        vm.prank(agent);
        reg.acknowledge(x);
        IPayment.Proof memory st;
        st.data.sourceId = bytes32("testXRP");
        st.data.responseBody.sourceAddressHash = ref;
        st.data.responseBody.standardPaymentReference = refs.exclusiveFor(x);
        refs.proveExclusive(x, st);
        vm.startPrank(principal);
        bond.post{value: 1 ether}(x);
        bond.setWatchTerms(x, RATE, 0);
        bond.fundWatch{value: 1 ether}(x);
        vm.stopPrank();

        IBalanceDecreasingTransaction.Proof[] memory pr = new IBalanceDecreasingTransaction.Proof[](3);
        for (uint256 i = 0; i < 3; i++) {
            pr[i].data.sourceId = bytes32("testXRP");
            pr[i].data.requestBody.transactionId = bytes32(uint256(0x100 + i));
            pr[i].data.requestBody.sourceAddressIndicator = ref;
            pr[i].data.responseBody.sourceAddressHash = ref;
            pr[i].data.responseBody.blockTimestamp = uint64(block.timestamp);
            pr[i].data.responseBody.spentAmount = int256(1_000_012);
        }
        pr[1].data.responseBody.spentAmount = -5_000_000; // somebody paid the agent
        vm.prank(watcher);
        xjudge.fileXrpOutflow(x, pr, bytes32(0));
        assertEq(bond.owed(watcher), 2 * RATE);
    }
}
