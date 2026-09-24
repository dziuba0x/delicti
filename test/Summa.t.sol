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
import {JudgeSumma} from "../src/JudgeSumma.sol";
import {DelictiErrors} from "../src/DelictiErrors.sol";
import {Core} from "./Core.sol";
import {MockProtocolsV2} from "./Rounds.sol";
import {IFdcVerification} from "@flarenetwork/flare-periphery-contracts/coston2/IFdcVerification.sol";
import {IEVMTransaction} from "@flarenetwork/flare-periphery-contracts/coston2/IEVMTransaction.sol";
import {IPayment} from "@flarenetwork/flare-periphery-contracts/coston2/IPayment.sol";
import {IBalanceDecreasingTransaction} from
    "@flarenetwork/flare-periphery-contracts/coston2/IBalanceDecreasingTransaction.sol";
import {IReferencedPaymentNonexistence} from
    "@flarenetwork/flare-periphery-contracts/coston2/IReferencedPaymentNonexistence.sol";
import {FtsoV2Interface} from "@flarenetwork/flare-periphery-contracts/coston2/FtsoV2Interface.sol";
import {ProtocolsV2Interface} from "@flarenetwork/flare-periphery-contracts/coston2/ProtocolsV2Interface.sol";

contract MockFdcSumma {
    function verifyEVMTransaction(IEVMTransaction.Proof calldata) external pure returns (bool) {
        return true;
    }

    function verifyBalanceDecreasingTransaction(IBalanceDecreasingTransaction.Proof calldata) external pure returns (bool) {
        return true;
    }

    function verifyPayment(IPayment.Proof calldata) external pure returns (bool) {
        return true;
    }

    function verifyReferencedPaymentNonexistence(IReferencedPaymentNonexistence.Proof calldata) external pure returns (bool) {
        return true;
    }
}

/// @dev Behaves like the real FtsoV2 as measured on 2026-09-24: a value that is not the finalized one
///      makes `verifyFeedData` REVERT, not return false.
contract MockFtso {
    mapping(bytes21 => mapping(uint32 => int32)) public value;

    function set(bytes21 id, uint32 round, int32 v) external {
        value[id][round] = v;
    }

    function verifyFeedData(FtsoV2Interface.FeedDataWithProof calldata f) external view returns (bool) {
        require(value[f.body.id][f.body.votingRoundId] == f.body.value && f.body.value != 0, "Invalid proof");
        return true;
    }
}

/// @title SUMMA (amendment v1.1, kind 9): one budget in dollars across XRPL and Flare
contract SummaTest is Test {
    MandateRegistry reg;
    AgentRefs agentRefs;
    Vault railVault;
    Vault summaVault;
    JudgeSumma summa;
    MockFdcSumma fdc;
    MockFtso ftso;
    MockProtocolsV2 rounds;

    address principal = makeAddr("principal");
    address agent = makeAddr("agent"); // the EVM agent, and the one answering for the sum
    address merchant = makeAddr("merchant");
    address challenger = makeAddr("challenger");
    address stranger = makeAddr("stranger");

    bytes32 constant XRP_SRC = bytes32("testXRP");
    bytes32 constant FLR_SRC = bytes32("testFLR");
    bytes32 constant OUTFLOW = bytes32("XRP/outflow");
    bytes32 constant AGENT_XRPL = keccak256("rAgentAccountOnXrpl");
    address constant USDT0 = address(0x05D7);
    bytes21 constant XRP_USD = bytes21(0x015852502f55534400000000000000000000000000);
    bytes21 constant USDT_USD = bytes21(0x01555344542f555344000000000000000000000000);
    bytes32 constant TRANSFER = keccak256("Transfer(address,address,uint256)");
    uint64 constant COMMIT_LEAD = 10 minutes;
    bytes32 constant SALT = keccak256("summa watcher");

    uint256 umbrella;
    uint256 xrpMember;
    uint256 usdtMember;
    uint64 t0;

    function setUp() public {
        vm.warp(1_800_000_000);
        t0 = uint64(block.timestamp);
        reg = new MandateRegistry();
        AnchorLog anchorLog = new AnchorLog(reg);
        fdc = new MockFdcSumma();
        ftso = new MockFtso();
        rounds = new MockProtocolsV2();
        agentRefs = new AgentRefs(reg, IFdcVerification(address(fdc)));
        (railVault,,) = Core.deploy(
            reg, anchorLog, IFdcVerification(address(fdc)), 24 hours, 1 hours, new SpendMeter(reg),
            COMMIT_LEAD, ProtocolsV2Interface(address(rounds)), agentRefs, 5 minutes);

        // VaultSumma: the v0.15 Vault bytecode, with JudgeSumma as its only judge (amendment S.7)
        JudgeSumma.PriceRow[] memory map = new JudgeSumma.PriceRow[](2);
        map[0] = JudgeSumma.PriceRow(XRP_SRC, OUTFLOW, XRP_USD, 6);
        map[1] = JudgeSumma.PriceRow(FLR_SRC, bytes32(uint256(uint160(USDT0))), USDT_USD, 6);
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        summa = new JudgeSumma(Vault(predicted), reg, agentRefs, IFdcVerification(address(fdc)), FtsoV2Interface(address(ftso)), map);
        address[] memory js = new address[](1);
        js[0] = address(summa);
        summaVault = new Vault(reg, agentRefs, ProtocolsV2Interface(address(rounds)), COMMIT_LEAD, js);
        assertEq(address(summaVault), predicted);

        vm.deal(principal, 100 ether);

        // the rails: 10 XRP of gross outflow on XRPL, 10 USDT0 on Flare, each well inside its own budget below
        xrpMember = _xrpRail(10_000_000);
        usdtMember = _usdtRail(10_000_000);

        // the umbrella: $10 across both
        umbrella = _umbrella(10_000_000);
        vm.startPrank(agent);
        summa.link(umbrella, xrpMember);
        summa.link(umbrella, usdtMember);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ fixtures

    function _xrpRail(uint256 budget) internal returns (uint256 id) {
        vm.prank(principal);
        id = reg.commit(agent, keccak256("xrp rail"), 0, 0, budget, t0, t0 + 1 days,
            MandateRegistry.Terms({sourceId: XRP_SRC, assetKey: OUTFLOW, agentRef: AGENT_XRPL, bond: address(railVault)}));
        vm.prank(agent);
        reg.acknowledge(id);
        agentRefs.proveExclusive(id, _statement(agentRefs.exclusiveFor(id)));
    }

    function _usdtRail(uint256 budget) internal returns (uint256 id) {
        vm.prank(principal);
        id = reg.commit(agent, keccak256("usdt rail"), 0, 0, budget, t0, t0 + 1 days,
            MandateRegistry.Terms({sourceId: FLR_SRC, assetKey: bytes32(uint256(uint160(USDT0))), agentRef: 0, bond: address(railVault)}));
        vm.prank(agent);
        reg.declareExclusive(id);
    }

    function _umbrella(uint256 budgetUsd6) internal returns (uint256 id) {
        vm.prank(principal);
        id = reg.commit(agent, keccak256("at most $10, anywhere"), 0, 0, budgetUsd6, t0, t0 + 1 days,
            MandateRegistry.Terms({sourceId: bytes32("SUMMA"), assetKey: bytes32("USD/1e6"), agentRef: 0, bond: address(summaVault)}));
        vm.prank(agent);
        reg.acknowledge(id);
        vm.prank(principal);
        summaVault.post{value: 10 ether}(id);
    }

    function _statement(bytes32 ref) internal view returns (IPayment.Proof memory p) {
        p.data.attestationType = bytes32("Payment");
        p.data.sourceId = XRP_SRC;
        p.data.requestBody.transactionId = keccak256(abi.encode("statement", ref));
        p.data.responseBody.blockTimestamp = uint64(block.timestamp);
        p.data.responseBody.sourceAddressHash = AGENT_XRPL;
        p.data.responseBody.receivingAddressHash = keccak256("rAnyone");
        p.data.responseBody.receivedAmount = 1000;
        p.data.responseBody.standardPaymentReference = ref;
        p.data.responseBody.oneToOne = true;
    }

    function _round() internal view returns (uint64) {
        return summa.roundOf(uint64(block.timestamp));
    }

    function _bdt(uint256 i, int256 spent, uint64 ts) internal view returns (IBalanceDecreasingTransaction.Proof memory p) {
        p.data.attestationType = bytes32("BalanceDecreasingTransaction");
        p.data.sourceId = XRP_SRC;
        p.data.votingRound = _round();
        p.data.requestBody.transactionId = bytes32(uint256(0xA000 + i));
        p.data.requestBody.sourceAddressIndicator = AGENT_XRPL;
        p.data.responseBody.blockTimestamp = ts;
        p.data.responseBody.sourceAddressHash = AGENT_XRPL;
        p.data.responseBody.spentAmount = spent;
    }

    function _erc20(uint256 i, uint256 v, uint64 ts) internal view returns (IEVMTransaction.Proof memory p) {
        IEVMTransaction.Event[] memory evs = new IEVMTransaction.Event[](1);
        evs[0].logIndex = uint32(i);
        evs[0].emitterAddress = USDT0;
        evs[0].topics = new bytes32[](3);
        evs[0].topics[0] = TRANSFER;
        evs[0].topics[1] = bytes32(uint256(uint160(agent)));
        evs[0].topics[2] = bytes32(uint256(uint160(merchant)));
        evs[0].data = abi.encode(v);
        p.data.attestationType = bytes32("EVMTransaction");
        p.data.sourceId = FLR_SRC;
        p.data.votingRound = _round();
        p.data.requestBody.transactionHash = bytes32(uint256(0xB000 + i));
        p.data.requestBody.requiredConfirmations = 1;
        p.data.requestBody.listEvents = true;
        p.data.responseBody.timestamp = ts;
        p.data.responseBody.status = 1;
        p.data.responseBody.events = evs;
    }

    /// A price proof for `feed` at the round of `ts`, registered as the finalized value.
    function _price(bytes21 feed, uint64 ts, int32 v) internal returns (FtsoV2Interface.FeedDataWithProof memory f) {
        uint32 r = summa.roundOf(ts);
        ftso.set(feed, r, v);
        f.body = FtsoV2Interface.FeedData({votingRoundId: r, id: feed, value: v, turnoutBIPS: 10_000, decimals: 5});
    }

    /// k XRP outflows of `each` drops at t0 + 1 min, 2 min, …, XRP at 1.50000 USD
    function _xrpSalami(uint256 k, uint256 each, uint256 idBase)
        internal
        returns (IBalanceDecreasingTransaction.Proof[] memory pr, FtsoV2Interface.FeedDataWithProof[] memory px)
    {
        pr = new IBalanceDecreasingTransaction.Proof[](k);
        px = new FtsoV2Interface.FeedDataWithProof[](k);
        for (uint256 i = 0; i < k; i++) {
            uint64 ts = t0 + uint64((idBase + i + 1) * 60);
            pr[i] = _bdt(idBase + i, int256(each), ts);
            px[i] = _price(XRP_USD, ts, 150_000);
        }
    }

    function _usdtSalami(uint256 k, uint256 each, uint256 idBase, int32 usdt)
        internal
        returns (IEVMTransaction.Proof[] memory pr, FtsoV2Interface.FeedDataWithProof[] memory px)
    {
        pr = new IEVMTransaction.Proof[](k);
        px = new FtsoV2Interface.FeedDataWithProof[](k);
        for (uint256 i = 0; i < k; i++) {
            uint64 ts = t0 + uint64((idBase + i + 1) * 60);
            pr[i] = _erc20(idBase + i, each, ts);
            px[i] = _price(USDT_USD, ts, usdt);
        }
    }

    function _arm(address who, bytes32[] memory ids) internal {
        uint64 r = _round();
        uint64 rs = rounds.firstVotingRoundStartTs() + r * rounds.votingEpochDurationSeconds();
        uint64 nowTs = uint64(vm.getBlockTimestamp()); // not block.timestamp: via-ir may re-read it after the warp
        vm.warp(rs - COMMIT_LEAD);
        summaVault.commitChallenge(summaVault.commitmentFor(who, umbrella, 9, keccak256(abi.encode(ids)), SALT));
        vm.warp(nowTs);
    }

    function _ids(IEVMTransaction.Proof[] memory pr) internal pure returns (bytes32[] memory ids) {
        ids = new bytes32[](pr.length);
        for (uint256 i = 0; i < pr.length; i++) ids[i] = pr[i].data.requestBody.transactionHash;
    }

    // ------------------------------------------------------------------ S.12.1 the sum, S.12.5 unit-free slash

    /// 6 XRP on XRPL ($9) + 3.5 USD₮0 on Flare ($3.5) against a $10 umbrella: every rail is inside its
    /// own budget, the sum is 25 % over, and the umbrella loses 25 % of its bond.
    function test_sumAcrossRailsConvictsAndTakesTheOverrunFraction() public {
        vm.warp(t0 + 1 hours);
        (IBalanceDecreasingTransaction.Proof[] memory x, FtsoV2Interface.FeedDataWithProof[] memory xp) = _xrpSalami(3, 2_000_000, 0);
        vm.prank(challenger);
        summa.fileXrp(umbrella, xrpMember, x, xp, SALT); // records $9, below the budget: no commitment needed
        assertEq(summa.docket(umbrella), 9_000_000);
        assertFalse(summaVault.slashed(umbrella));

        (IEVMTransaction.Proof[] memory u, FtsoV2Interface.FeedDataWithProof[] memory up) = _usdtSalami(2, 1_750_000, 10, 100_000);
        _arm(challenger, _ids(u));
        vm.prank(challenger);
        summa.fileErc20(umbrella, usdtMember, u, up, SALT);

        assertEq(summa.docket(umbrella), 12_500_000);
        assertTrue(summaVault.slashed(umbrella));
        assertEq(summaVault.slashedAmount(umbrella), 2.5 ether); // 25 % over → 25 % of 10 ether
        assertFalse(reg.isLive(umbrella)); // the verdict revoked the umbrella
        assertTrue(reg.isLive(xrpMember) && reg.isLive(usdtMember)); // the rails keep their own standing
    }

    /// A stablecoin is priced, not assumed: 3.5 USD₮0 at 0.99966 is worth 3.49881 USD.
    function test_stablecoinIsPricedAtTheRound() public {
        vm.warp(t0 + 1 hours);
        (IEVMTransaction.Proof[] memory u, FtsoV2Interface.FeedDataWithProof[] memory up) = _usdtSalami(1, 3_500_000, 0, 99_966);
        vm.prank(challenger);
        summa.fileErc20(umbrella, usdtMember, u, up, SALT);
        assertEq(summa.docket(umbrella), 3_498_810);
    }

    // ------------------------------------------------------------------ S.12.1 no double count

    function test_aDeedCountsOnce() public {
        vm.warp(t0 + 1 hours);
        (IBalanceDecreasingTransaction.Proof[] memory x, FtsoV2Interface.FeedDataWithProof[] memory xp) = _xrpSalami(2, 1_000_000, 0);
        vm.prank(challenger);
        summa.fileXrp(umbrella, xrpMember, x, xp, SALT);
        vm.prank(stranger);
        vm.expectRevert(DelictiErrors.NothingNew.selector);
        summa.fileXrp(umbrella, xrpMember, x, xp, SALT);
        assertEq(summa.docket(umbrella), 3_000_000);
    }

    /// A price proven once serves every later deed in the same round, on any umbrella.
    function test_priceIsCachedPerRound() public {
        vm.warp(t0 + 1 hours);
        (IBalanceDecreasingTransaction.Proof[] memory x, FtsoV2Interface.FeedDataWithProof[] memory xp) = _xrpSalami(1, 1_000_000, 0);
        vm.prank(challenger);
        summa.fileXrp(umbrella, xrpMember, x, xp, SALT);
        uint32 r = summa.roundOf(x[0].data.responseBody.blockTimestamp);
        assertEq(summa.provenValue(XRP_USD, r), 150_000);
    }

    // ------------------------------------------------------------------ S.12.3 the round is the deed's

    function test_priceFromAnotherRoundIsRefused() public {
        vm.warp(t0 + 1 hours);
        (IBalanceDecreasingTransaction.Proof[] memory x, FtsoV2Interface.FeedDataWithProof[] memory xp) = _xrpSalami(1, 1_000_000, 0);
        xp[0].body.votingRoundId += 1;
        ftso.set(XRP_USD, xp[0].body.votingRoundId, 150_000);
        vm.prank(challenger);
        vm.expectRevert(JudgeSumma.WrongPrice.selector);
        summa.fileXrp(umbrella, xrpMember, x, xp, SALT);
    }

    function test_aForgedPriceReverts() public {
        vm.warp(t0 + 1 hours);
        (IBalanceDecreasingTransaction.Proof[] memory x, FtsoV2Interface.FeedDataWithProof[] memory xp) = _xrpSalami(1, 1_000_000, 0);
        xp[0].body.value = 1; // an agent's dream price
        vm.prank(challenger);
        vm.expectRevert(bytes("Invalid proof"));
        summa.fileXrp(umbrella, xrpMember, x, xp, SALT);
    }

    function test_theFeedIsTheMapsNotTheFilers() public {
        vm.warp(t0 + 1 hours);
        (IBalanceDecreasingTransaction.Proof[] memory x, FtsoV2Interface.FeedDataWithProof[] memory xp) = _xrpSalami(1, 1_000_000, 0);
        xp[0].body.id = USDT_USD; // value XRP at the price of a dollar
        ftso.set(USDT_USD, xp[0].body.votingRoundId, 100_000);
        vm.prank(challenger);
        vm.expectRevert(JudgeSumma.WrongPrice.selector);
        summa.fileXrp(umbrella, xrpMember, x, xp, SALT);
    }

    // ------------------------------------------------------------------ S.12.4 who may link what

    function test_onlyTheUmbrellasAgentLinks() public {
        uint256 id = _usdtRail(1);
        vm.prank(principal);
        vm.expectRevert(JudgeSumma.NotUmbrellaAgent.selector);
        summa.link(umbrella, id);
    }

    function test_anotherPrincipalsRailCannotBeLinked() public {
        address other = makeAddr("otherPrincipal");
        vm.prank(other);
        uint256 id = reg.commit(agent, keccak256("x"), 0, 0, 1, t0, t0 + 1 days,
            MandateRegistry.Terms({sourceId: FLR_SRC, assetKey: bytes32(uint256(uint160(USDT0))), agentRef: 0, bond: address(railVault)}));
        vm.prank(agent);
        reg.declareExclusive(id);
        vm.prank(agent);
        vm.expectRevert(JudgeSumma.PrincipalMismatch.selector);
        summa.link(umbrella, id);
    }

    function test_aRailWithoutExclusivityIsNotWatchable() public {
        vm.prank(principal);
        uint256 id = reg.commit(agent, keccak256("x"), 0, 0, 1, t0, t0 + 1 days,
            MandateRegistry.Terms({sourceId: FLR_SRC, assetKey: bytes32(uint256(uint160(USDT0))), agentRef: 0, bond: address(railVault)}));
        vm.prank(agent);
        reg.acknowledge(id);
        vm.prank(agent);
        vm.expectRevert(JudgeSumma.NotWatchable.selector);
        summa.link(umbrella, id);
    }

    function test_anUnpricedAssetCannotBeLinked() public {
        vm.prank(principal);
        uint256 id = reg.commit(agent, keccak256("x"), 0, 0, 1, t0, t0 + 1 days,
            MandateRegistry.Terms({sourceId: FLR_SRC, assetKey: bytes32(uint256(uint160(address(0xBEEF)))), agentRef: 0, bond: address(railVault)}));
        vm.prank(agent);
        reg.declareExclusive(id);
        vm.prank(agent);
        vm.expectRevert(JudgeSumma.Unpriced.selector);
        summa.link(umbrella, id);
    }

    function test_aLinkIsOnceAndCountsForwardOnly() public {
        vm.prank(agent);
        vm.expectRevert(JudgeSumma.AlreadyLinked.selector);
        summa.link(umbrella, xrpMember);

        // a rail linked an hour in: its deeds from before the link are not the umbrella's
        vm.warp(t0 + 1 hours);
        uint256 late = _usdtRail(10_000_000);
        vm.prank(agent);
        summa.link(umbrella, late);
        vm.warp(t0 + 2 hours);
        (IEVMTransaction.Proof[] memory u, FtsoV2Interface.FeedDataWithProof[] memory up) = _usdtSalami(1, 1_000_000, 20, 100_000);
        vm.prank(challenger);
        vm.expectRevert(DelictiErrors.ClaimOutsideProvenRange.selector);
        summa.fileErc20(umbrella, late, u, up, SALT);
    }

    // ------------------------------------------------------------------ S.12.6 isolation

    function test_aRailMandateIsNotAnUmbrella() public {
        vm.warp(t0 + 1 hours);
        (IBalanceDecreasingTransaction.Proof[] memory x, FtsoV2Interface.FeedDataWithProof[] memory xp) = _xrpSalami(1, 1_000_000, 0);
        vm.prank(challenger);
        vm.expectRevert(JudgeSumma.NotUmbrella.selector);
        summa.fileXrp(xrpMember, xrpMember, x, xp, SALT);
    }

    function test_anUnlinkedRailCannotBeFiled() public {
        uint256 id = _usdtRail(10_000_000);
        vm.warp(t0 + 1 hours);
        (IEVMTransaction.Proof[] memory u, FtsoV2Interface.FeedDataWithProof[] memory up) = _usdtSalami(1, 1_000_000, 0, 100_000);
        vm.prank(challenger);
        vm.expectRevert(JudgeSumma.NotMember.selector);
        summa.fileErc20(umbrella, id, u, up, SALT);
    }

    // ------------------------------------------------------------------ S.12.2 rounding

    /// value × 10^e ≤ amount × price < (value + 1) × 10^e: never more than the truth, less by under 1 µUSD.
    function testFuzz_roundingNeverConvicts(uint96 amount, uint8 assetDecimals, int32 price, int8 decimals) public view {
        assetDecimals = uint8(bound(assetDecimals, 0, 18));
        decimals = int8(bound(decimals, -4, 12));
        price = int32(bound(price, 1, type(int32).max));
        uint256 v = summa.valueUsd6(amount, assetDecimals, price, decimals);
        int256 e = int256(uint256(assetDecimals)) + decimals - 6;
        uint256 exactNum = uint256(amount) * uint256(uint32(price));
        if (e >= 0) {
            uint256 scale = 10 ** uint256(e);
            assertLe(v * scale, exactNum);
            assertGt((v + 1) * scale, exactNum);
        } else {
            assertEq(v, exactNum * 10 ** uint256(-e));
        }
    }
}
