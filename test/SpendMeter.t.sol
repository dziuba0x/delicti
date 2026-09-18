// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {MandateRegistry} from "../src/MandateRegistry.sol";
import {AnchorLog} from "../src/AnchorLog.sol";
import {Bond} from "../src/Bond.sol";
import {SpendMeter} from "../src/SpendMeter.sol";
import {IFdcVerification} from "@flarenetwork/flare-periphery-contracts/coston2/IFdcVerification.sol";
import {IEVMTransaction} from "@flarenetwork/flare-periphery-contracts/coston2/IEVMTransaction.sol";
import {ProtocolsV2Interface} from "@flarenetwork/flare-periphery-contracts/coston2/ProtocolsV2Interface.sol";
import {MockProtocolsV2} from "./Rounds.sol";

contract MockFdcMeter {
    bool public verdict = true;

    function setVerdict(bool v) external {
        verdict = v;
    }

    function verifyEVMTransaction(IEVMTransaction.Proof calldata) external view returns (bool) {
        return verdict;
    }
}

/// The fast half: structuring refused in milliseconds, and the effector that keeps a false
/// tally convicted in minutes.
contract SpendMeterTest is Test {
    MandateRegistry reg;
    AnchorLog anchorLog;
    Bond bond;
    SpendMeter meter;
    MockFdcMeter mock;
    MockProtocolsV2 rounds;

    address principal = makeAddr("principal");
    address agent = makeAddr("agent");
    address effector = makeAddr("effector");
    address merchant = makeAddr("merchant");
    address challenger = makeAddr("challenger");
    address token = makeAddr("usdt0");

    bytes32 constant SRC = bytes32("testFLR");
    uint256 constant EACH = 1 ether;
    uint256 constant BUDGET = 4 ether;

    uint64 constant COMMIT_LEAD = 10 minutes;
    bytes32 constant SALT = keccak256("the watcher's salt");

    uint256 mandateId;
    bytes32 assetKey_; // what the next committed mandate's budget is made of

    function _terms() internal view returns (MandateRegistry.Terms memory) {
        return MandateRegistry.Terms({sourceId: SRC, assetKey: assetKey_, agentRef: bytes32(0), bond: address(bond)});
    }

    /// @dev A second, native-asset mandate: metered, exclusive, bonded — same shape as the ERC-20 one.
    function _nativeMandate() internal returns (uint256 id) {
        assetKey_ = bytes32(0);
        vm.prank(principal);
        id = reg.commit(agent, keccak256("native, metered"), 0, 0, BUDGET, uint64(block.timestamp), uint64(block.timestamp + 7 days), _terms());
        vm.prank(agent);
        reg.declareExclusive(id);
        vm.prank(principal);
        meter.declareEffector(id, effector);
        vm.prank(principal);
        bond.post{value: 10 ether}(id);
    }

    function setUp() public {
        assetKey_ = bytes32(uint256(uint160(token)));
        reg = new MandateRegistry();
        anchorLog = new AnchorLog(reg);
        mock = new MockFdcMeter();
        meter = new SpendMeter(reg);
        rounds = new MockProtocolsV2();
        bond = new Bond(
            reg, anchorLog, IFdcVerification(address(mock)), 24 hours, 1 hours, meter,
            COMMIT_LEAD, ProtocolsV2Interface(address(rounds))
        );
        vm.warp(1_800_000_000);

        vm.prank(principal);
        mandateId = reg.commit(
            agent, keccak256("may spend up to 4 at merchant, metered"), 0, 0, BUDGET,
            uint64(block.timestamp), uint64(block.timestamp + 7 days), _terms()
        );
        vm.prank(agent);
        reg.declareExclusive(mandateId);
        vm.prank(principal);
        meter.declareEffector(mandateId, effector);

        vm.deal(principal, 100 ether);
        vm.prank(principal);
        bond.post{value: 10 ether}(mandateId);
    }

    function _proof(uint256 i, uint256 amount, bool erc20) internal view returns (IEVMTransaction.Proof memory p) {
        p.data.attestationType = bytes32("EVMTransaction");
        p.data.sourceId = SRC;
        p.data.requestBody.transactionHash = bytes32(uint256(0x1000 + i)); // strictly increasing
        p.data.responseBody.blockNumber = uint64(100 + i);
        p.data.responseBody.timestamp = uint64(block.timestamp + i);
        p.data.responseBody.sourceAddress = agent;
        p.data.responseBody.status = 1;
        if (erc20) {
            p.data.responseBody.receivingAddress = token;
            p.data.responseBody.value = 0;
            bytes32[] memory topics = new bytes32[](3);
            topics[0] = keccak256("Transfer(address,address,uint256)");
            topics[1] = bytes32(uint256(uint160(agent)));
            topics[2] = bytes32(uint256(uint160(merchant)));
            p.data.responseBody.events = new IEVMTransaction.Event[](1);
            p.data.responseBody.events[0] = IEVMTransaction.Event({
                logIndex: uint32(i), emitterAddress: token, topics: topics, data: abi.encode(amount), removed: false
            });
        } else {
            p.data.responseBody.receivingAddress = merchant;
            p.data.responseBody.value = amount;
        }
    }

    function _bundle(uint256 k, bool erc20) internal view returns (IEVMTransaction.Proof[] memory ps) {
        ps = new IEVMTransaction.Proof[](k);
        for (uint256 i = 0; i < k; i++) ps[i] = _proof(i, EACH, erc20);
    }

    /// @dev The deed ids a commitment must name: the bundle's tx hashes, in the order supplied.
    function _ids(IEVMTransaction.Proof[] memory ps) internal pure returns (bytes32[] memory ids) {
        ids = new bytes32[](ps.length);
        for (uint256 i = 0; i < ps.length; i++) ids[i] = ps[i].data.requestBody.transactionHash;
    }

    /// @dev Put `who`'s commitment `commitLead` in the past and start the bundle's lowest voting
    ///      round NOW. A finalised round cannot begin in the future, so a harness that put the
    ///      round start ahead of `block.timestamp` would sail past `ClockDrift`. Time ends where
    ///      it started, so the proofs stay inside the mandate window.
    function _armAged(address who, uint256 mid, IEVMTransaction.Proof[] memory ps, uint64 age) internal {
        uint64 t = uint64(block.timestamp);
        uint64 minRound = type(uint64).max;
        for (uint256 i = 0; i < ps.length; i++) {
            if (ps[i].data.votingRound < minRound) minRound = ps[i].data.votingRound;
        }
        vm.warp(t - age);
        bond.commitChallenge(
            bond.commitmentFor(who, mid, bond.KIND_UNDER_REPORTED(), bond.deedsDigest(_ids(ps)), SALT)
        );
        vm.warp(t);
        rounds.setRoundStart(minRound, t);
    }

    function _arm(address who, uint256 mid, IEVMTransaction.Proof[] memory ps) internal {
        _armAged(who, mid, ps, COMMIT_LEAD);
    }

    // --- the brake: structuring refused before it completes ---

    /// Four slices fit. The fifth is refused by an eth_call, not slashed four minutes later.
    function test_meterRefusesTheFifthSlice() public {
        for (uint256 i = 0; i < 4; i++) {
            assertFalse(meter.wouldExceed(mandateId, EACH), "slice should still fit");
            vm.prank(effector);
            meter.note(mandateId, EACH);
        }
        assertEq(meter.spent(mandateId), BUDGET);
        assertEq(meter.headroom(mandateId), 0);
        assertTrue(meter.wouldExceed(mandateId, 1), "the fifth slice must be refused");
        assertFalse(meter.exceeded(mandateId), "at budget is not over budget");
    }

    /// The meter records the truth even past the budget: refusing to record an overrun is
    /// the same as lying about it, and the next caller has to be able to see it.
    function test_meterRecordsPastTheBudget() public {
        vm.startPrank(effector);
        meter.note(mandateId, BUDGET);
        meter.note(mandateId, EACH);
        vm.stopPrank();
        assertEq(meter.spent(mandateId), BUDGET + EACH);
        assertTrue(meter.exceeded(mandateId));
        assertEq(meter.headroom(mandateId), 0);
    }

    function test_revert_onlyPrincipalDeclaresEffector() public {
        vm.prank(agent);
        vm.expectRevert(SpendMeter.NotPrincipal.selector);
        meter.declareEffector(mandateId, makeAddr("other"));
    }

    function test_revert_onlyDeclaredEffectorMayNote() public {
        vm.prank(agent);
        vm.expectRevert(SpendMeter.NotEffector.selector);
        meter.note(mandateId, EACH);
    }

    /// A dead mandate cannot accrue spend — the same rule AnchorLog applies to receipts.
    function test_revert_noteUnderDeadMandate() public {
        vm.prank(principal);
        reg.revoke(mandateId);
        vm.prank(effector);
        vm.expectRevert(SpendMeter.MandateNotLive.selector);
        meter.note(mandateId, EACH);
    }

    // --- the slow half: the tally that lied ---

    /// The effector recorded two slices and stayed silent about three. The FDC shows five.
    function test_underReportedSpend_slashes_erc20() public {
        vm.startPrank(effector);
        meter.note(mandateId, EACH);
        meter.note(mandateId, EACH);
        vm.stopPrank();

        _arm(challenger, mandateId, _bundle(5, true));
        vm.prank(challenger);
        bond.challengeUnderReportedSpend(mandateId, _bundle(5, true), SALT);

        assertTrue(bond.slashed(mandateId));
        assertFalse(reg.isLive(mandateId));
        assertEq(bond.owed(challenger), 1 ether);
        assertEq(bond.owed(principal), 9 ether);
    }

    function test_underReportedSpend_slashes_native() public {
        uint256 id = _nativeMandate();
        vm.prank(effector);
        meter.note(id, EACH);
        _arm(challenger, id, _bundle(3, false));
        vm.prank(challenger);
        bond.challengeUnderReportedSpend(id, _bundle(3, false), SALT);
        assertTrue(bond.slashed(id));
    }

    /// v0.9 — the asset is the mandate's, not the challenger's. Native transfers by the agent are
    /// real, but they are not what an ERC-20 mandate's tally promised to cover: summed against it
    /// they come to zero, and the challenge fails on its merits instead of on a parameter.
    function test_revert_nativeDeedsAgainstAnErc20Mandate() public {
        _arm(challenger, mandateId, _bundle(3, false));
        vm.prank(challenger);
        vm.expectRevert(Bond.TallyAgrees.selector);
        bond.challengeUnderReportedSpend(mandateId, _bundle(3, false), SALT);
    }

    /// v0.9 — same key, same address, another EVM chain. Until now this path checked no source.
    function test_revert_deedOnAnotherChain() public {
        IEVMTransaction.Proof[] memory ps = _bundle(5, true);
        ps[3].data.sourceId = bytes32("testETH");
        vm.prank(challenger);
        vm.expectRevert(Bond.WrongSource.selector);
        bond.challengeUnderReportedSpend(mandateId, ps, SALT);
    }

    /// An honest effector is not a target: the tally matches what the world shows.
    function test_revert_whenTallyAgrees() public {
        vm.startPrank(effector);
        for (uint256 i = 0; i < 5; i++) meter.note(mandateId, EACH);
        vm.stopPrank();
        _arm(challenger, mandateId, _bundle(5, true));
        vm.prank(challenger);
        vm.expectRevert(Bond.TallyAgrees.selector);
        bond.challengeUnderReportedSpend(mandateId, _bundle(5, true), SALT);
    }

    /// A mandate nobody meters never promised a tally, so it cannot have broken one.
    function test_revert_whenMandateNotMetered() public {
        vm.prank(principal);
        uint256 other = reg.commit(
            agent, keccak256("unmetered"), 0, 0, BUDGET, uint64(block.timestamp), uint64(block.timestamp + 1 days), _terms()
        );
        vm.prank(agent);
        reg.declareExclusive(other);
        vm.prank(principal);
        bond.post{value: 1 ether}(other);
        vm.prank(challenger);
        vm.expectRevert(Bond.NotMetered.selector);
        bond.challengeUnderReportedSpend(other, _bundle(5, true), SALT);
    }

    /// Without exclusivity an outflow from the agent may be none of this mandate's business.
    /// Summing it would convict an honest agent, so the challenge refuses to run at all.
    function test_revert_withoutExclusivity() public {
        vm.prank(principal);
        uint256 other = reg.commit(
            agent, keccak256("metered but not exclusive"), 0, 0, BUDGET,
            uint64(block.timestamp), uint64(block.timestamp + 1 days), _terms()
        );
        vm.prank(agent);
        reg.acknowledge(other);
        vm.prank(principal);
        meter.declareEffector(other, effector);
        vm.prank(principal);
        bond.post{value: 1 ether}(other);
        vm.prank(challenger);
        vm.expectRevert(Bond.NotExclusive.selector);
        bond.challengeUnderReportedSpend(other, _bundle(5, true), SALT);
    }

    function test_revert_duplicateDeedInBundle() public {
        IEVMTransaction.Proof[] memory ps = _bundle(3, true);
        ps[2] = ps[1];
        vm.prank(challenger);
        vm.expectRevert(Bond.UnorderedTxs.selector);
        bond.challengeUnderReportedSpend(mandateId, ps, SALT);
    }

    function test_revert_deedOutsideMandateWindow() public {
        IEVMTransaction.Proof[] memory ps = _bundle(3, true);
        ps[1].data.responseBody.timestamp = uint64(block.timestamp - 1);
        vm.prank(challenger);
        vm.expectRevert(Bond.ClaimOutsideProvenRange.selector);
        bond.challengeUnderReportedSpend(mandateId, ps, SALT);
    }

    function test_revert_nativeDeedByAnotherAddress() public {
        uint256 id = _nativeMandate();
        IEVMTransaction.Proof[] memory ps = _bundle(2, false);
        ps[0].data.responseBody.sourceAddress = makeAddr("someone else");
        vm.prank(challenger);
        vm.expectRevert(Bond.NotAgentTx.selector);
        bond.challengeUnderReportedSpend(id, ps, SALT);
    }

    function test_revert_whenFdcRejectsTheProof() public {
        mock.setVerdict(false);
        vm.prank(challenger);
        vm.expectRevert(Bond.FdcProofInvalid.selector);
        bond.challengeUnderReportedSpend(mandateId, _bundle(3, true), SALT);
    }

    // --- commit–reveal over a sequence (SPEC 6.7) ---

    /// The digest names the exact ordered set of deeds. Committing to five and revealing three is
    /// a different case, which is what makes blind pre-commitment useless on the multi-deed paths:
    /// the committer has to have found the sequence first.
    function test_revert_commitmentForADifferentSetOfDeeds() public {
        vm.prank(effector);
        meter.note(mandateId, EACH);
        _arm(challenger, mandateId, _bundle(5, true)); // committed to five deeds
        vm.prank(challenger);
        vm.expectRevert(Bond.NoCommitment.selector);
        bond.challengeUnderReportedSpend(mandateId, _bundle(3, true), SALT); // revealed three
    }

    /// The deadline is set by the LOWEST voting round in the bundle, not the highest. Otherwise one
    /// freshly requested proof would launder a commitment made after the rest of the case was public.
    function test_revert_oneFreshProofDoesNotLaunderALateCommitment() public {
        vm.prank(effector);
        meter.note(mandateId, EACH);
        IEVMTransaction.Proof[] memory ps = _bundle(3, true);
        ps[1].data.votingRound = 500; // one proof requested much later than the others

        // round 0 — the lowest — began one second too late for this commitment; round 500 did not.
        _armAged(challenger, mandateId, ps, COMMIT_LEAD - 1);
        vm.prank(challenger);
        vm.expectRevert(Bond.CommittedTooLate.selector);
        bond.challengeUnderReportedSpend(mandateId, ps, SALT);
    }

    /// The counterpart: give the LOWEST round the full lead and the same bundle lands. Separate
    /// test because re-arming inside one would be a no-op — `commitChallenge` keeps the earliest.
    function test_oneFreshProofIsFineOnceTheLowestRoundHasTheLead() public {
        vm.prank(effector);
        meter.note(mandateId, EACH);
        IEVMTransaction.Proof[] memory ps = _bundle(3, true);
        ps[1].data.votingRound = 500;
        _armAged(challenger, mandateId, ps, COMMIT_LEAD);
        vm.prank(challenger);
        bond.challengeUnderReportedSpend(mandateId, ps, SALT);
        assertTrue(bond.slashed(mandateId));
    }
}
