// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {MandateRegistry} from "../../src/MandateRegistry.sol";
import {AnchorLog} from "../../src/AnchorLog.sol";
import {AgentRefs} from "../../src/AgentRefs.sol";
import {SpendMeter} from "../../src/SpendMeter.sol";
import {Vault} from "../../src/Vault.sol";
import {JudgeSumma} from "../../src/JudgeSumma.sol";
import {Core} from "../Core.sol";
import {MockProtocolsV2} from "../Rounds.sol";
import {MockFdcSumma, MockFtso} from "../Summa.t.sol";
import {IFdcVerification} from "@flarenetwork/flare-periphery-contracts/coston2/IFdcVerification.sol";
import {IEVMTransaction} from "@flarenetwork/flare-periphery-contracts/coston2/IEVMTransaction.sol";
import {IPayment} from "@flarenetwork/flare-periphery-contracts/coston2/IPayment.sol";
import {IBalanceDecreasingTransaction} from
    "@flarenetwork/flare-periphery-contracts/coston2/IBalanceDecreasingTransaction.sol";
import {FtsoV2Interface} from "@flarenetwork/flare-periphery-contracts/coston2/FtsoV2Interface.sol";
import {ProtocolsV2Interface} from "@flarenetwork/flare-periphery-contracts/coston2/ProtocolsV2Interface.sol";

/// @dev Drives JudgeSumma with random filings over a small pool of deed ids (so duplicates, re-filings
///      and proof splits happen constantly), random prices per round, and committed crossings. It keeps
///      an independent ghost of every distinct deed that a successful filing counted.
contract SummaHandler is Test {
    JudgeSumma public summa;
    Vault public vault;
    MockFtso public ftso;
    MockProtocolsV2 public rounds;
    uint256 public umbrella;
    uint256 public xrpMember;
    uint256 public usdtMember;
    address public agent;
    uint64 public t0;

    bytes32 constant XRP_SRC = bytes32("testXRP");
    bytes32 constant FLR_SRC = bytes32("testFLR");
    bytes32 constant AGENT_XRPL = keccak256("rAgentAccountOnXrpl");
    address constant USDT0 = address(0x05D7);
    bytes21 constant XRP_USD = bytes21(0x015852502f55534400000000000000000000000000);
    bytes21 constant USDT_USD = bytes21(0x01555344542f555344000000000000000000000000);
    bytes32 constant TRANSFER = keccak256("Transfer(address,address,uint256)");

    // ghosts
    mapping(bytes32 => bool) public counted;
    uint256 public ghostDocket;
    uint256 public lastDocket;
    bool public docketWentDown;
    uint256 public filings;
    uint256 public crossings;

    constructor(JudgeSumma s, Vault v, MockFtso f, MockProtocolsV2 r, uint256 u, uint256 x, uint256 e, address a, uint64 t) {
        (summa, vault, ftso, rounds, umbrella, xrpMember, usdtMember, agent, t0) = (s, v, f, r, u, x, e, a, t);
    }

    function _price(bytes21 feed, uint64 ts, uint256 seed) internal returns (FtsoV2Interface.FeedDataWithProof memory p, int32 v) {
        uint32 r = summa.roundOf(ts);
        v = ftso.value(feed, r);
        if (v == 0) {
            v = int32(int256(bound(seed, 50_000, 300_000))); // 0.5 … 3.0 USD at 5 decimals
            ftso.set(feed, r, v);
        }
        p.body = FtsoV2Interface.FeedData({votingRoundId: r, id: feed, value: v, turnoutBIPS: 10_000, decimals: 5});
    }

    function _usd(uint256 amount, int32 v) internal pure returns (uint256) {
        return (amount * uint256(uint32(v))) / 1e5; // 6-decimal assets at 5-decimal prices
    }

    function _check() internal {
        uint256 d = summa.docket(umbrella);
        if (d < lastDocket) docketWentDown = true;
        lastDocket = d;
    }

    function fileXrp(uint256 seed, uint8 n, bool commit) external {
        n = uint8(bound(n, 1, 4));
        vm.warp(t0 + 2 hours);
        IBalanceDecreasingTransaction.Proof[] memory pr = new IBalanceDecreasingTransaction.Proof[](n);
        FtsoV2Interface.FeedDataWithProof[] memory px = new FtsoV2Interface.FeedDataWithProof[](n);
        uint256 base = bound(seed, 0, 12);
        uint256 added;
        bytes32[] memory ids = new bytes32[](n);
        for (uint256 i = 0; i < n; i++) {
            uint256 id = base + i; // ascending, from a pool of ~16: collisions with earlier filings are the point
            uint64 ts = t0 + uint64(60 * (id + 1));
            int256 spent = int256(bound(uint256(keccak256(abi.encode(id))), 0, 3_000_000)) - 200_000; // sometimes an inflow
            pr[i].data.attestationType = bytes32("BalanceDecreasingTransaction");
            pr[i].data.sourceId = XRP_SRC;
            pr[i].data.votingRound = summa.roundOf(uint64(block.timestamp));
            pr[i].data.requestBody.transactionId = bytes32(0xA000 + id);
            pr[i].data.requestBody.sourceAddressIndicator = AGENT_XRPL;
            pr[i].data.responseBody.blockTimestamp = ts;
            pr[i].data.responseBody.sourceAddressHash = AGENT_XRPL;
            pr[i].data.responseBody.spentAmount = spent;
            int32 v;
            (px[i], v) = _price(XRP_USD, ts, uint256(keccak256(abi.encode(seed, id))));
            ids[i] = bytes32(0xA000 + id);
            bytes32 k = keccak256(abi.encode(XRP_SRC, ids[i]));
            if (!counted[k]) added += _usd(spent > 0 ? uint256(spent) : 0, v);
        }
        if (commit) _arm(ids);
        try summa.fileXrp(umbrella, xrpMember, pr, px, commit ? bytes32("salt") : bytes32(0)) {
            for (uint256 i = 0; i < n; i++) counted[keccak256(abi.encode(XRP_SRC, ids[i]))] = true;
            ghostDocket += added;
            filings++;
            if (vault.slashed(umbrella)) crossings++;
        } catch {}
        _check();
    }

    function fileErc20(uint256 seed, uint8 n, bool commit) external {
        n = uint8(bound(n, 1, 3));
        vm.warp(t0 + 2 hours);
        IEVMTransaction.Proof[] memory pr = new IEVMTransaction.Proof[](n);
        FtsoV2Interface.FeedDataWithProof[] memory px = new FtsoV2Interface.FeedDataWithProof[](n);
        uint256 base = bound(seed, 0, 10);
        uint256 added;
        bytes32[] memory ids = new bytes32[](n);
        for (uint256 i = 0; i < n; i++) {
            uint256 id = base + i;
            uint64 ts = t0 + uint64(60 * (id + 1));
            // two logs per transaction, one of them sometimes to the agent (an inflow, not the agent's act)
            IEVMTransaction.Event[] memory evs = new IEVMTransaction.Event[](2);
            for (uint256 j = 0; j < 2; j++) {
                evs[j].logIndex = uint32(id * 2 + j);
                evs[j].emitterAddress = USDT0;
                evs[j].topics = new bytes32[](3);
                evs[j].topics[0] = TRANSFER;
                bool out = j == 0 || id % 3 != 0;
                evs[j].topics[1] = bytes32(uint256(uint160(out ? agent : address(0xBEEF))));
                evs[j].topics[2] = bytes32(uint256(uint160(out ? address(0xBEEF) : agent)));
                evs[j].data = abi.encode(bound(uint256(keccak256(abi.encode(id, j))), 0, 2_000_000));
            }
            pr[i].data.attestationType = bytes32("EVMTransaction");
            pr[i].data.sourceId = FLR_SRC;
            pr[i].data.votingRound = summa.roundOf(uint64(block.timestamp));
            pr[i].data.requestBody.transactionHash = bytes32(0xB000 + id);
            pr[i].data.requestBody.requiredConfirmations = 1;
            pr[i].data.requestBody.listEvents = true;
            pr[i].data.responseBody.timestamp = ts;
            pr[i].data.responseBody.status = 1;
            pr[i].data.responseBody.events = evs;
            int32 v;
            (px[i], v) = _price(USDT_USD, ts, uint256(keccak256(abi.encode(seed, id, "u"))));
            ids[i] = bytes32(0xB000 + id);
            uint256 sum;
            for (uint256 j = 0; j < 2; j++) {
                bytes32 k = keccak256(abi.encode(FLR_SRC, ids[i], uint32(id * 2 + j)));
                if (!counted[k] && (j == 0 || id % 3 != 0)) sum += abi.decode(evs[j].data, (uint256));
            }
            added += _usd(sum, v);
        }
        if (commit) _arm(ids);
        try summa.fileErc20(umbrella, usdtMember, pr, px, commit ? bytes32("salt") : bytes32(0)) {
            for (uint256 i = 0; i < n; i++) {
                uint256 id = uint256(ids[i]) - 0xB000;
                for (uint256 j = 0; j < 2; j++) {
                    if (j == 0 || id % 3 != 0) counted[keccak256(abi.encode(FLR_SRC, ids[i], uint32(id * 2 + j)))] = true;
                }
            }
            ghostDocket += added;
            filings++;
            if (vault.slashed(umbrella)) crossings++;
        } catch {}
        _check();
    }

    function _arm(bytes32[] memory ids) internal {
        uint64 r = summa.roundOf(uint64(block.timestamp));
        uint64 rs = rounds.firstVotingRoundStartTs() + r * rounds.votingEpochDurationSeconds();
        uint64 nowTs = uint64(vm.getBlockTimestamp());
        vm.warp(rs - 10 minutes);
        vault.commitChallenge(vault.commitmentFor(address(this), umbrella, 9, keccak256(abi.encode(ids)), bytes32("salt")));
        vm.warp(nowTs);
    }
}

/// @title SUMMA invariants (amendment v1.1, S.12.7)
contract SummaInvariants is StdInvariant, Test {
    SummaHandler h;
    Vault vault;
    JudgeSumma summa;
    uint256 constant BOND = 10 ether;
    uint256 constant BUDGET = 10_000_000; // $10
    address principal;

    function setUp() public {
        vm.warp(1_800_000_000);
        uint64 t0 = uint64(block.timestamp);
        MandateRegistry reg = new MandateRegistry();
        MockFdcSumma fdc = new MockFdcSumma();
        MockFtso ftso = new MockFtso();
        MockProtocolsV2 rounds = new MockProtocolsV2();
        AgentRefs refs = new AgentRefs(reg, IFdcVerification(address(fdc)));
        (Vault railVault,,) = Core.deploy(reg, new AnchorLog(reg), IFdcVerification(address(fdc)), 24 hours, 1 hours, new SpendMeter(reg),
            10 minutes, ProtocolsV2Interface(address(rounds)), refs, 5 minutes);
        JudgeSumma.PriceRow[] memory map = new JudgeSumma.PriceRow[](2);
        map[0] = JudgeSumma.PriceRow(bytes32("testXRP"), bytes32("XRP/outflow"), bytes21(0x015852502f55534400000000000000000000000000), 6);
        map[1] = JudgeSumma.PriceRow(bytes32("testFLR"), bytes32(uint256(uint160(address(0x05D7)))), bytes21(0x01555344542f555344000000000000000000000000), 6);
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        summa = new JudgeSumma(Vault(predicted), reg, refs, IFdcVerification(address(fdc)), FtsoV2Interface(address(ftso)), map);
        address[] memory js = new address[](1);
        js[0] = address(summa);
        vault = new Vault(reg, refs, ProtocolsV2Interface(address(rounds)), 10 minutes, js);

        principal = makeAddr("principal");
        address agent = makeAddr("agent");
        vm.startPrank(principal);
        uint256 x = reg.commit(agent, "x", 0, 0, 1e12, t0, t0 + 1 days,
            MandateRegistry.Terms({sourceId: bytes32("testXRP"), assetKey: bytes32("XRP/outflow"), agentRef: keccak256("rAgentAccountOnXrpl"), bond: address(railVault)}));
        uint256 e = reg.commit(agent, "e", 0, 0, 1e12, t0, t0 + 1 days,
            MandateRegistry.Terms({sourceId: bytes32("testFLR"), assetKey: bytes32(uint256(uint160(address(0x05D7)))), agentRef: 0, bond: address(railVault)}));
        uint256 u = reg.commit(agent, "u", 0, 0, BUDGET, t0, t0 + 1 days,
            MandateRegistry.Terms({sourceId: bytes32("SUMMA"), assetKey: bytes32("USD/1e6"), agentRef: 0, bond: address(vault)}));
        vm.stopPrank();
        vm.startPrank(agent);
        reg.acknowledge(x);
        reg.declareExclusive(e);
        reg.acknowledge(u);
        vm.stopPrank();
        IPayment.Proof memory st;
        st.data.attestationType = bytes32("Payment");
        st.data.sourceId = bytes32("testXRP");
        st.data.requestBody.transactionId = keccak256("statement");
        st.data.responseBody.blockTimestamp = t0;
        st.data.responseBody.sourceAddressHash = keccak256("rAgentAccountOnXrpl");
        st.data.responseBody.receivingAddressHash = keccak256("rAnyone");
        st.data.responseBody.receivedAmount = 1000;
        st.data.responseBody.standardPaymentReference = refs.exclusiveFor(x);
        st.data.responseBody.oneToOne = true;
        refs.proveExclusive(x, st);
        vm.startPrank(agent);
        summa.link(u, x);
        summa.link(u, e);
        vm.stopPrank();
        vm.deal(principal, BOND);
        vm.prank(principal);
        vault.post{value: BOND}(u);

        h = new SummaHandler(summa, vault, ftso, rounds, u, x, e, agent, t0);
        targetContract(address(h));
    }

    /// The docket is exactly the sum of every distinct deed any successful filing counted: no deed twice,
    /// no inflow, no log that is not the agent's, however the proofs were split or repeated.
    function invariant_docketIsTheSumOfDistinctDeeds() public view {
        assertEq(summa.docket(h.umbrella()), h.ghostDocket());
    }

    function invariant_docketNeverDecreases() public view {
        assertFalse(h.docketWentDown());
    }

    /// The bond's books: what is left plus what was taken is what was posted, and a verdict never takes
    /// more than the proportional penalty for the docket's overrun (with the 10 % floor, capped at the bond).
    function invariant_bondBooksAndProportionality() public view {
        uint256 u = h.umbrella();
        assertEq(vault.bondOf(u) + vault.slashedAmount(u), BOND);
        uint256 d = summa.docket(u);
        if (!vault.slashed(u)) return;
        assertGt(d, BUDGET); // no verdict without an overrun
        uint256 sev = d - BUDGET;
        uint256 p = sev >= BUDGET ? BOND : (BOND * sev) / BUDGET;
        if (p < BOND / 10) p = BOND / 10;
        assertLe(vault.slashedAmount(u), p);
    }

    /// Every wei is accounted for in the Vault: bonds, credited proceeds and unsettled remainders.
    function invariant_vaultHoldsWhatItOwes() public view {
        uint256 u = h.umbrella();
        assertGe(address(vault).balance, vault.bondOf(u));
        assertEq(address(vault).balance, vault.bondOf(u) + vault.owed(address(h)) + vault.owed(principal) + vault.unsettled(u));
    }

    /// The campaign must actually reach the interesting states, or the invariants above prove nothing.
    function afterInvariant() public view {
        assertGt(h.filings(), 0);
        console.log("filings", h.filings(), "after-crossing filings", h.crossings());
    }
}
