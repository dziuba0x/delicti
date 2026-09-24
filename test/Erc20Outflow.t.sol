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
import {MockFdcEvm} from "./Structuring.t.sol";
import {IFdcVerification} from "@flarenetwork/flare-periphery-contracts/coston2/IFdcVerification.sol";
import {IEVMTransaction} from "@flarenetwork/flare-periphery-contracts/coston2/IEVMTransaction.sol";
import {ProtocolsV2Interface} from "@flarenetwork/flare-periphery-contracts/coston2/ProtocolsV2Interface.sol";

/// @title §6.11 — gross ERC-20 outflow on a docket (v0.13)
/// @notice The x402-on-EVM agent: it signs EIP-3009 authorisations, a facilitator sends them, it
///         writes no receipts. Its stablecoin budget is enforced from the token's own event log.
contract Erc20OutflowTest is Test {
    MandateRegistry reg;
    AnchorLog anchorLog;
    Vault bond;
    JudgeEvm judge;
    JudgeXrpl xjudge;
    MockFdcEvm mock;
    MockProtocolsV2 rounds;

    address principal = makeAddr("principal");
    address agent = makeAddr("agent");
    address facilitator = makeAddr("facilitator");
    address merchant = makeAddr("merchant");
    address challenger = makeAddr("challenger");
    address constant USDC = address(0x5DC0);
    address constant OTHER = address(0x07E4);

    bytes32 constant SRC = bytes32("testFLR");
    uint256 constant EACH = 1_000_000; // 1 USDC, 6 decimals
    uint256 constant BUDGET = 4_000_000;
    uint64 constant COMMIT_LEAD = 10 minutes;
    uint64 constant ROUND = 500;
    bytes32 constant SALT = keccak256("stablecoin watcher");
    bytes32 constant TRANSFER = keccak256("Transfer(address,address,uint256)");

    uint256 mandateId;

    function setUp() public {
        vm.warp(1_800_000_000);
        reg = new MandateRegistry();
        anchorLog = new AnchorLog(reg);
        mock = new MockFdcEvm();
        rounds = new MockProtocolsV2();
        (bond, judge, xjudge) = Core.deploy(
            reg, anchorLog, IFdcVerification(address(mock)), 24 hours, 1 hours, new SpendMeter(reg),
            COMMIT_LEAD, ProtocolsV2Interface(address(rounds)), new AgentRefs(reg, IFdcVerification(address(0))), 5 minutes);
        vm.deal(principal, 100 ether);
        mandateId = _mandate(SRC, true);
    }

    // ------------------------------------------------------------------ helpers

    function _mandate(bytes32 src, bool exclusive) internal returns (uint256 id) {
        vm.prank(principal);
        id = reg.commit(
            agent, keccak256("may pay up to 4 USDC"), 0, 0, BUDGET, uint64(block.timestamp), uint64(block.timestamp + 1 days),
            MandateRegistry.Terms({sourceId: src, assetKey: bytes32(uint256(uint160(USDC))), agentRef: bytes32(0), bond: address(bond)})
        );
        vm.prank(agent);
        if (exclusive) reg.declareExclusive(id);
        else reg.acknowledge(id);
        vm.prank(principal);
        bond.post{value: 10 ether}(id);
    }

    function _ev(uint32 logIndex, address token, address from, address to, uint256 v)
        internal
        pure
        returns (IEVMTransaction.Event memory e)
    {
        e.logIndex = logIndex;
        e.emitterAddress = token;
        e.topics = new bytes32[](3);
        e.topics[0] = TRANSFER;
        e.topics[1] = bytes32(uint256(uint160(from)));
        e.topics[2] = bytes32(uint256(uint160(to)));
        e.data = abi.encode(v);
    }

    /// A transaction SENT BY THE FACILITATOR (EIP-3009), carrying the given events.
    function _tx(uint256 i, IEVMTransaction.Event[] memory evs) internal view returns (IEVMTransaction.Proof memory p) {
        p.data.attestationType = bytes32("EVMTransaction");
        p.data.sourceId = SRC;
        p.data.votingRound = ROUND;
        p.data.requestBody.transactionHash = bytes32(uint256(0x1000 + i));
        p.data.requestBody.requiredConfirmations = 1;
        p.data.requestBody.listEvents = true;
        p.data.responseBody.timestamp = uint64(block.timestamp + i * 60);
        p.data.responseBody.sourceAddress = facilitator;
        p.data.responseBody.receivingAddress = USDC;
        p.data.responseBody.status = 1;
        p.data.responseBody.events = evs;
    }

    function _one(IEVMTransaction.Event memory e) internal pure returns (IEVMTransaction.Event[] memory evs) {
        evs = new IEVMTransaction.Event[](1);
        evs[0] = e;
    }

    /// k x402 settlements of 1 USDC, agent → merchant.
    function _salami(uint256 k) internal view returns (IEVMTransaction.Proof[] memory pr) {
        pr = new IEVMTransaction.Proof[](k);
        for (uint256 i = 0; i < k; i++) pr[i] = _tx(i, _one(_ev(uint32(i), USDC, agent, merchant, EACH)));
    }

    function _arm(address who, IEVMTransaction.Proof[] memory pr) internal {
        bytes32[] memory ids = new bytes32[](pr.length);
        for (uint256 i = 0; i < pr.length; i++) ids[i] = pr[i].data.requestBody.transactionHash;
        bytes32 c = bond.commitmentFor(who, mandateId, bond.KIND_ERC20_OUTFLOW(), bond.deedsDigest(ids), SALT);
        uint64 t = uint64(block.timestamp);
        vm.warp(t - COMMIT_LEAD);
        bond.commitChallenge(c);
        vm.warp(t);
        rounds.setRoundStart(ROUND, t);
    }

    function _file(address who, IEVMTransaction.Proof[] memory pr) internal {
        vm.prank(who);
        judge.fileErc20Outflow(mandateId, pr, SALT);
    }

    // ------------------------------------------------------------------ the verdicts

    /// Five 1-USDC x402 settlements, none sent by the agent, no receipt anywhere: 1 USDC over.
    function test_x402SalamiThroughAFacilitatorSlashes() public {
        IEVMTransaction.Proof[] memory pr = _salami(5);
        _arm(challenger, pr);
        _file(challenger, pr);
        assertTrue(bond.slashed(mandateId));
        assertFalse(reg.isLive(mandateId));
        assertEq(judge.erc20Docket(mandateId), 5 * EACH);
        assertEq(bond.severityOf(mandateId), EACH);
        assertEq(bond.slashedAmount(mandateId), (10 ether * EACH) / BUDGET);
    }

    /// Below the budget a filing only records, and needs no commitment; the crossing does.
    function test_docketGrowsThenTheCommittedCrossingConvicts() public {
        IEVMTransaction.Proof[] memory first = _salami(3);
        _file(address(0xF11E), first); // anyone, uncommitted
        assertEq(judge.erc20Docket(mandateId), 3 * EACH);
        assertFalse(bond.slashed(mandateId));

        IEVMTransaction.Proof[] memory rest = new IEVMTransaction.Proof[](2);
        rest[0] = _tx(3, _one(_ev(3, USDC, agent, merchant, EACH)));
        rest[1] = _tx(4, _one(_ev(4, USDC, agent, merchant, EACH)));
        vm.expectRevert(DelictiErrors.NoCommitment.selector);
        _file(challenger, rest);

        _arm(challenger, rest);
        _file(challenger, rest);
        assertEq(bond.severityOf(mandateId), EACH);
    }

    /// The griefing a per-transaction docket would allow: file a transaction with none of its
    /// logs listed (the FDC permits a subset), and its real outflow is marked counted at zero.
    /// Keyed per event, such a filing adds nothing and is refused; partial filings add up.
    function test_aFilingWithoutTheLogsCannotBuryThem() public {
        IEVMTransaction.Proof[] memory empty = new IEVMTransaction.Proof[](1);
        empty[0] = _tx(0, new IEVMTransaction.Event[](0));
        vm.expectRevert(DelictiErrors.NothingNew.selector);
        _file(address(0xBAD), empty);

        // the same transaction really moved 3 USDC in three logs; filed one log at a time
        for (uint32 k = 0; k < 3; k++) {
            IEVMTransaction.Proof[] memory part = new IEVMTransaction.Proof[](1);
            part[0] = _tx(0, _one(_ev(10 + k, USDC, agent, merchant, EACH)));
            _file(address(0xF11E), part);
        }
        assertEq(judge.erc20Docket(mandateId), 3 * EACH);
        assertTrue(judge.eventFiled(mandateId, bytes32(uint256(0x1000)), 12));
    }

    /// The same event twice — in one filing's replay or a later overlapping one — counts once.
    function test_anEventIsCountedOnce() public {
        IEVMTransaction.Proof[] memory pr = _salami(2);
        _file(address(0xF11E), pr);
        vm.expectRevert(DelictiErrors.NothingNew.selector);
        _file(address(0xF11E), pr);
        assertEq(judge.erc20Docket(mandateId), 2 * EACH);
    }

    /// Only Transfer(agent → *) by the mandate's token counts: not another token, not money coming
    /// in, not someone else's transfer, not a log removed by a reorg, not an Approval.
    function test_onlyTheAgentsOutflowInTheMandatesTokenCounts() public {
        IEVMTransaction.Event[] memory evs = new IEVMTransaction.Event[](6);
        evs[0] = _ev(0, USDC, agent, merchant, EACH); // counts
        evs[1] = _ev(1, OTHER, agent, merchant, 9 * EACH); // another token
        evs[2] = _ev(2, USDC, merchant, agent, 9 * EACH); // inflow
        evs[3] = _ev(3, USDC, facilitator, merchant, 9 * EACH); // not the agent
        evs[4] = _ev(4, USDC, agent, merchant, 9 * EACH);
        evs[4].removed = true; // reorged away
        evs[5] = _ev(5, USDC, agent, merchant, 9 * EACH);
        evs[5].topics[0] = keccak256("Approval(address,address,uint256)");
        IEVMTransaction.Proof[] memory pr = new IEVMTransaction.Proof[](1);
        pr[0] = _tx(0, evs);
        _file(address(0xF11E), pr);
        assertEq(judge.erc20Docket(mandateId), EACH);
        assertFalse(judge.eventFiled(mandateId, bytes32(uint256(0x1000)), 1), "ignored logs must not be marked");
    }

    /// FXRP redeemed to XRPL is burned (`to = 0`): value that left the account. It counts.
    function test_aBurnIsOutflow() public {
        IEVMTransaction.Proof[] memory pr = new IEVMTransaction.Proof[](1);
        pr[0] = _tx(0, _one(_ev(0, USDC, agent, address(0), 5 * EACH)));
        _arm(challenger, pr);
        _file(challenger, pr);
        assertEq(bond.severityOf(mandateId), EACH);
    }

    /// One attestation carrying five logs is one deed for the Vault's per-attestation
    /// reimbursement — counting logs would pay the crossing filer for four proofs it never bought.
    function test_reimbursementCountsProofsNotLogs() public {
        IEVMTransaction.Event[] memory evs = new IEVMTransaction.Event[](5);
        for (uint32 k = 0; k < 5; k++) evs[k] = _ev(k, USDC, agent, merchant, EACH);
        IEVMTransaction.Proof[] memory pr = new IEVMTransaction.Proof[](1);
        pr[0] = _tx(0, evs);
        _arm(challenger, pr);
        vm.expectEmit(true, true, true, true, address(judge));
        emit JudgeEvm.Erc20OutflowProven(mandateId, 5 * EACH, BUDGET, 1, challenger, (10 ether * EACH) / BUDGET);
        _file(challenger, pr);
    }

    /// Without receipts the agent must have said everything its address does is this mandate's.
    function test_revert_notExclusive() public {
        mandateId = _mandate(SRC, false);
        IEVMTransaction.Proof[] memory pr = _salami(1);
        vm.expectRevert(DelictiErrors.NotExclusive.selector);
        _file(address(0xF11E), pr);
    }

    function test_revert_nativeMandateHasNoTokenDocket() public {
        vm.prank(principal);
        uint256 id = reg.commit(
            agent, keccak256("native"), 0, 0, BUDGET, uint64(block.timestamp), uint64(block.timestamp + 1 days),
            MandateRegistry.Terms({sourceId: SRC, assetKey: bytes32(0), agentRef: bytes32(0), bond: address(bond)})
        );
        vm.prank(agent);
        reg.declareExclusive(id);
        vm.prank(principal);
        bond.post{value: 1 ether}(id);
        IEVMTransaction.Proof[] memory pr = _salami(1);
        vm.expectRevert(DelictiErrors.WrongAsset.selector);
        judge.fileErc20Outflow(id, pr, SALT);
    }

    function test_revert_outsideTheWindow() public {
        IEVMTransaction.Proof[] memory pr = _salami(1);
        pr[0].data.responseBody.timestamp = uint64(block.timestamp + 2 days);
        vm.expectRevert(DelictiErrors.ClaimOutsideProvenRange.selector);
        _file(address(0xF11E), pr);
    }

    function test_revert_failedTransaction() public {
        IEVMTransaction.Proof[] memory pr = _salami(1);
        pr[0].data.responseBody.status = 0;
        vm.expectRevert(DelictiErrors.TxNotSuccessful.selector);
        _file(address(0xF11E), pr);
    }

    function test_revert_fdcSaysNo() public {
        IEVMTransaction.Proof[] memory pr = _salami(1);
        mock.setVerdict(false);
        vm.expectRevert(DelictiErrors.FdcProofInvalid.selector);
        _file(address(0xF11E), pr);
    }

    function test_revert_unordered() public {
        IEVMTransaction.Proof[] memory pr = _salami(2);
        (pr[0], pr[1]) = (pr[1], pr[0]);
        vm.expectRevert(DelictiErrors.UnorderedTxs.selector);
        _file(address(0xF11E), pr);
    }

    /// On Ethereum a shallow proof could be of a block later reorged: an agent convicted of an
    /// outflow that never happened. The docket asks for ~2 epochs there, one block on Flare.
    function test_ethereumProofsMustBeDeep() public {
        mandateId = _mandate(bytes32("testETH"), true);
        IEVMTransaction.Proof[] memory pr = _salami(1);
        pr[0].data.sourceId = bytes32("testETH");
        pr[0].data.requestBody.requiredConfirmations = 12;
        vm.expectRevert(DelictiErrors.TooFewConfirmations.selector);
        _file(address(0xF11E), pr);
        pr[0].data.requestBody.requiredConfirmations = 64;
        _file(address(0xF11E), pr);
        assertEq(judge.erc20Docket(mandateId), EACH);
        assertEq(judge.minConfirmations(SRC), 1);
    }

    /// Nested with every other budget kind: a later, larger crossing takes the difference.
    function test_laterFilingTakesOnlyTheDifference() public {
        IEVMTransaction.Proof[] memory five = _salami(5);
        _arm(challenger, five);
        _file(challenger, five);
        uint256 first = bond.slashedAmount(mandateId);

        IEVMTransaction.Proof[] memory six = new IEVMTransaction.Proof[](1);
        six[0] = _tx(5, _one(_ev(5, USDC, agent, merchant, EACH)));
        _arm(challenger, six);
        _file(challenger, six);
        assertEq(bond.severityOf(mandateId), 2 * EACH, "severity is the docket's overrun, not a sum of verdicts");
        assertGt(bond.slashedAmount(mandateId), first);
    }

    /// However the same events are split into filings, in whatever order and with whatever
    /// overlap, the docket is their sum, each counted once.
    function testFuzz_docketIsTheSumOverDistinctEvents(uint8 nSeed, uint256 splitSeed, uint256 amountSeed) public {
        uint256 n = bound(nSeed, 1, 12);
        uint256[] memory amounts = new uint256[](n);
        uint256 expected;
        for (uint256 i = 0; i < n; i++) {
            amounts[i] = bound(uint256(keccak256(abi.encode(amountSeed, i))), 0, 300_000);
            expected += amounts[i];
        }
        // raise the budget so nothing crosses: this is about counting, not conviction
        vm.prank(principal);
        uint256 id = reg.commit(
            agent, keccak256("large"), 0, 0, type(uint128).max, uint64(block.timestamp), uint64(block.timestamp + 1 days),
            MandateRegistry.Terms({sourceId: SRC, assetKey: bytes32(uint256(uint160(USDC))), agentRef: bytes32(0), bond: address(bond)})
        );
        vm.prank(agent);
        reg.declareExclusive(id);
        vm.prank(principal);
        bond.post{value: 1 ether}(id);

        for (uint256 round = 0; round < 3; round++) {
            uint256 start = uint256(keccak256(abi.encode(splitSeed, round))) % n;
            uint256 len = 1 + uint256(keccak256(abi.encode(splitSeed, round, "len"))) % (n - start);
            IEVMTransaction.Proof[] memory pr = new IEVMTransaction.Proof[](len);
            for (uint256 k = 0; k < len; k++) {
                pr[k] = _tx(start + k, _one(_ev(uint32(start + k), USDC, agent, merchant, amounts[start + k])));
            }
            try judge.fileErc20Outflow(id, pr, SALT) {} catch {}
        }
        IEVMTransaction.Proof[] memory all = new IEVMTransaction.Proof[](n);
        for (uint256 k = 0; k < n; k++) all[k] = _tx(k, _one(_ev(uint32(k), USDC, agent, merchant, amounts[k])));
        try judge.fileErc20Outflow(id, all, SALT) {} catch {}
        assertEq(judge.erc20Docket(id), expected);
    }
}
