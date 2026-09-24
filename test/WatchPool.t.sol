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

/// Flare's ContractRegistry and FdcHub, etched where the Vault looks for them.
contract HubStub {
    uint256 public requests;

    function requestAttestation(bytes calldata) external payable {
        requests++;
    }
}

contract RegistryStub {
    address public hub; // slot 0

    function getContractAddressByName(string calldata name) external view returns (address) {
        return keccak256(bytes(name)) == keccak256("FdcHub") ? hub : address(0);
    }
}

/// @title The watch pool (v0.14, reworked in v0.15 after an adversarial review) — SPEC §8.4
contract WatchPoolTest is Test {
    MandateRegistry reg;
    AnchorLog anchorLog;
    Vault bond;
    JudgeEvm judge;
    JudgeXrpl xjudge;
    AgentRefs refs;
    MockProtocolsV2 rounds;
    HubStub hub;

    address principal = makeAddr("principal");
    address agent = makeAddr("agent");
    address watcher = makeAddr("watcher");
    address copier = makeAddr("copier");
    address insurer = makeAddr("insurer");
    address constant USDC = address(0x5DC0);
    address constant FLARE_REGISTRY = 0xaD67FE66660Fb8dFE9d6b1b4240d8650e30F6019;
    bytes32 constant TRANSFER = keccak256("Transfer(address,address,uint256)");
    bytes32 constant SALT = keccak256("salt");
    uint256 constant EACH = 1_000_000;
    uint256 constant BUDGET = 4_000_000;
    uint256 constant RATE = 0.01 ether;
    uint256 constant FEE = 0.001 ether;

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
        hub = new HubStub();
        vm.etch(FLARE_REGISTRY, address(new RegistryStub()).code);
        vm.store(FLARE_REGISTRY, bytes32(0), bytes32(uint256(uint160(address(hub)))));
        vm.deal(principal, 100 ether);
        vm.deal(agent, 100 ether);
        vm.deal(insurer, 100 ether);
        vm.deal(watcher, 10 ether);
        vm.deal(copier, 10 ether);
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

    function _tx(uint256 i, uint256 v) internal pure returns (IEVMTransaction.Proof memory p) {
        p.data.attestationType = bytes32("EVMTransaction");
        p.data.sourceId = bytes32("testFLR");
        p.data.votingRound = 500;
        p.data.requestBody.transactionHash = bytes32(uint256(0x1000 + i));
        p.data.requestBody.requiredConfirmations = 1;
        p.data.requestBody.listEvents = true;
        p.data.responseBody.timestamp = 1_800_000_060; // inside the window, whenever it is filed
        p.data.responseBody.status = 1;
        p.data.responseBody.events = new IEVMTransaction.Event[](1);
        p.data.responseBody.events[0] = _ev(uint32(i), address(0xA9E47), v);
    }

    function _txs(uint256 from, uint256 k, uint256 v) internal view returns (IEVMTransaction.Proof[] memory pr) {
        pr = new IEVMTransaction.Proof[](k);
        for (uint256 i = 0; i < k; i++) {
            pr[i] = _tx(from + i, v);
            pr[i].data.responseBody.events[0] = _ev(uint32(from + i), agent, v);
        }
    }

    /// The request bytes a verifier would return for this proof: type ‖ source ‖ MIC ‖ body.
    function _requestOf(IEVMTransaction.Proof memory p) internal pure returns (bytes memory) {
        return abi.encodePacked(p.data.attestationType, p.data.sourceId, keccak256("mic"), abi.encode(p.data.requestBody));
    }

    function _pay(address who, IEVMTransaction.Proof[] memory pr) internal {
        for (uint256 i = 0; i < pr.length; i++) {
            vm.prank(who);
            bond.requestAttestation{value: FEE}(_requestOf(pr[i]));
        }
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

    function _arm(address who, IEVMTransaction.Proof[] memory pr, bytes32 salt) internal {
        bytes32[] memory ids = new bytes32[](pr.length);
        for (uint256 i = 0; i < pr.length; i++) ids[i] = pr[i].data.requestBody.transactionHash;
        uint64 t = uint64(block.timestamp);
        vm.warp(t - 10 minutes);
        bond.commitChallenge(bond.commitmentFor(who, id, bond.KIND_ERC20_OUTFLOW(), bond.deedsDigest(ids), salt));
        vm.warp(t);
        rounds.setRoundStart(500, t);
    }

    // ------------------------------------------------------------------ the requester is paid

    /// An agent that behaves: three deeds under a budget of four. The watcher that paid for their
    /// attestations is paid a stipend per deed, whoever files.
    function test_recordingPaysWhoeverPaidForTheAttestations() public {
        _terms(RATE, 0, 1 ether);
        IEVMTransaction.Proof[] memory pr = _txs(0, 3, EACH);
        _pay(watcher, pr);
        assertEq(hub.requests(), 3, "fees forwarded to FdcHub");
        _file(watcher, pr, bytes32(0));
        assertEq(bond.owed(watcher), 3 * RATE);
        assertEq(bond.watchPool(id), 1 ether - 3 * RATE);
    }

    /// v0.14's hole (adversarial review, HIGH): a copier lifted the watcher's proofs, filed first
    /// and took every stipend. Since v0.15 the copier only pays the gas to deliver them.
    function test_aCopierCannotTakeTheStipends() public {
        _terms(RATE, 0, 1 ether);
        IEVMTransaction.Proof[] memory pr = _txs(0, 3, EACH);
        _pay(watcher, pr);
        _file(copier, pr, bytes32(0));
        assertEq(bond.owed(copier), 0);
        assertEq(bond.owed(watcher), 3 * RATE);
    }

    /// The first payer of a request holds it. A second watcher can read `requesterOf` before buying
    /// the same attestation — the race §10 described, closed without a separate claim.
    function test_theFirstPayerHoldsTheDeed() public {
        _terms(RATE, 0, 1 ether);
        IEVMTransaction.Proof[] memory pr = _txs(0, 1, EACH);
        _pay(watcher, pr);
        bytes32 key = bond.deedKey(pr[0].data.attestationType, pr[0].data.sourceId, keccak256(abi.encode(pr[0].data.requestBody)));
        assertEq(bond.requesterOf(key), watcher);
        _pay(copier, pr); // paid, but too late: FdcHub gets the fee, the stipend stays the watcher's
        assertEq(bond.requesterOf(key), watcher);
        _file(copier, pr, bytes32(0));
        assertEq(bond.owed(watcher), RATE);
    }

    /// A deed whose attestation nobody paid for through the Vault is recorded and earns nothing.
    function test_attestationsBoughtElsewhereEarnNothing() public {
        _terms(RATE, 0, 1 ether);
        _file(watcher, _txs(0, 3, EACH), bytes32(0));
        assertEq(judge.erc20Docket(id), 3 * EACH);
        assertEq(bond.owed(watcher), 0);
        assertEq(bond.watchPool(id), 1 ether);
    }

    /// Anyone can make a standard token emit Transfer(agent, x, 0) by calling transferFrom(agent,
    /// x, 0): provable, and not the agent's act. It earns nothing.
    function test_zeroValueTransfersEarnNothing() public {
        _terms(RATE, 0, 1 ether);
        IEVMTransaction.Proof[] memory pr = _txs(0, 5, 0);
        _pay(copier, pr);
        _file(copier, pr, bytes32(0));
        assertEq(bond.owed(copier), 0);
        assertEq(bond.watchPool(id), 1 ether);
    }

    /// The minimum is the principal's defence against dust and against one act split into many.
    function test_deedsBelowTheMinimumEarnNothing() public {
        _terms(RATE, EACH / 2, 1 ether);
        IEVMTransaction.Proof[] memory pr = _txs(0, 3, EACH);
        pr[1].data.responseBody.events[0] = _ev(1, agent, 1); // dust
        _pay(watcher, pr);
        _file(watcher, pr, bytes32(0));
        assertEq(bond.owed(watcher), 2 * RATE);
    }

    /// The pool pays what it has and never makes a filing fail.
    function test_anEmptyPoolNeverBlocksAFiling() public {
        _terms(RATE, 0, RATE + RATE / 2);
        IEVMTransaction.Proof[] memory pr = _txs(0, 3, EACH);
        _pay(watcher, pr);
        _file(watcher, pr, bytes32(0));
        assertEq(bond.owed(watcher), RATE + RATE / 2);
        assertEq(bond.watchPool(id), 0);
        assertEq(judge.erc20Docket(id), 3 * EACH);
    }

    /// The crossing: stipends to whoever paid for the attestations, the challenger's reward to the
    /// filer that committed. Here the same watcher did both.
    function test_theCrossingFilingIsPaidTwice() public {
        _terms(RATE, 0, 1 ether);
        IEVMTransaction.Proof[] memory first = _txs(0, 3, EACH);
        _pay(watcher, first);
        _file(watcher, first, bytes32(0));
        IEVMTransaction.Proof[] memory pr = _txs(3, 2, EACH);
        _arm(watcher, pr, SALT);
        _pay(watcher, pr);
        _file(watcher, pr, SALT);
        assertTrue(bond.slashed(id));
        assertEq(bond.owed(watcher), 5 * RATE + (bond.slashedAmount(id) * 1000) / 10_000);
    }

    // ------------------------------------------------------------------ who funds, who sets

    /// v0.14's second hole (adversarial review, MEDIUM): the agent funded, the principal raised the
    /// rate to the whole pool, a sock puppet filed one deed. Since v0.15 only the principal funds,
    /// so a raised rate can only spend the principal's own money.
    function test_revert_onlyThePrincipalFunds() public {
        vm.prank(agent);
        vm.expectRevert(DelictiErrors.NotPrincipal.selector);
        bond.fundWatch{value: 1 ether}(id);
        vm.prank(insurer);
        vm.expectRevert(DelictiErrors.NotPrincipal.selector);
        bond.fundWatch{value: 1 ether}(id);
    }

    function test_revert_onlyThePrincipalSetsTerms() public {
        vm.prank(agent);
        vm.expectRevert(DelictiErrors.NotPrincipal.selector);
        bond.setWatchTerms(id, RATE, 0);
    }

    /// Once offered, terms only get better for watchers.
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

    // ------------------------------------------------------------------ closing

    /// The pool stays open while deeds can still be filed: a bond is left and the XRPL verifier
    /// still remembers the window's last deeds (`WATCH_TAIL` after the cooling window).
    function test_refundWaitsForTheTailWhileABondRemains() public {
        _terms(RATE, 0, 3 ether);
        IEVMTransaction.Proof[] memory pr = _txs(0, 3, EACH);
        _pay(watcher, pr);
        _file(watcher, pr, bytes32(0));
        vm.prank(principal);
        vm.expectRevert(DelictiErrors.MandateStillLive.selector);
        bond.refundWatch(id, payable(principal));
        vm.warp(block.timestamp + 1 days + 1 days + 1); // dead, cooled, but inside the tail
        vm.prank(principal);
        vm.expectRevert(DelictiErrors.CoolingWindow.selector);
        bond.refundWatch(id, payable(principal));
        vm.warp(block.timestamp + 14 days);
        uint256 p0 = principal.balance;
        vm.prank(principal);
        bond.refundWatch(id, payable(principal));
        assertEq(principal.balance - p0, 3 ether - 3 * RATE);
        assertTrue(bond.watchClosed(id));
        // closed: a late filing records, pays nothing
        IEVMTransaction.Proof[] memory late = _txs(3, 1, EACH / 4);
        _pay(watcher, late);
        _file(watcher, late, bytes32(0));
        assertEq(bond.owed(watcher), 3 * RATE);
        vm.prank(principal);
        vm.expectRevert(DelictiErrors.WatchClosed.selector);
        bond.fundWatch{value: 1}(id);
    }

    /// With no bond left nothing more can be filed, so the pool may close as soon as the mandate is dead.
    function test_refundAtOnceWhenNoBondIsLeft() public {
        _terms(RATE, 0, 1 ether);
        vm.warp(block.timestamp + 2 days + 1);
        vm.prank(principal);
        bond.withdraw(id, payable(principal));
        assertEq(bond.bondOf(id), 0);
        vm.prank(principal);
        bond.refundWatch(id, payable(principal));
        assertEq(bond.watchPool(id), 0);
    }

    function test_revert_onlyThePrincipalIsRefunded() public {
        _terms(RATE, 0, 1 ether);
        vm.warp(block.timestamp + 30 days);
        vm.prank(agent);
        vm.expectRevert(DelictiErrors.NotPrincipal.selector);
        bond.refundWatch(id, payable(agent));
    }

    // ------------------------------------------------------------------ a crossing that takes nothing

    /// Adversarial review, LOW: a later crossing whose proportional penalty is still under the 10 %
    /// floor already taken took nothing, and spent its filer's commitment for it. Since v0.15 the
    /// judge asks `Vault.wouldTake` first: such a filing records, and the commitment stays unspent.
    function test_aCrossingThatWouldTakeNothingRecordsAndKeepsTheCommitment() public {
        _file(watcher, _txs(0, 4, EACH), bytes32(0)); // exactly the budget
        IEVMTransaction.Proof[] memory one = _txs(4, 1, 1); // 1 unit over: the 10 % floor
        _arm(watcher, one, SALT);
        _file(watcher, one, SALT);
        uint256 s1 = bond.slashedAmount(id);
        assertEq(s1, 1 ether);
        IEVMTransaction.Proof[] memory two = _txs(5, 1, 1); // 2 over: proportional 5e12 < floor
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = two[0].data.requestBody.transactionHash;
        bytes32 c = bond.commitmentFor(copier, id, bond.KIND_ERC20_OUTFLOW(), bond.deedsDigest(ids), SALT);
        _arm(copier, two, SALT);
        assertEq(bond.wouldTake(bond.KIND_ERC20_OUTFLOW(), id, BUDGET, 2), 0);
        _file(copier, two, SALT);
        assertEq(judge.erc20Docket(id), 4 * EACH + 2, "recorded");
        assertEq(bond.slashedAmount(id), s1, "nothing taken");
        assertGt(bond.committedAt(c), 0, "and the commitment was not spent for nothing");
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
            pr[i].data.attestationType = bytes32("BalanceDecreasingTransaction");
            pr[i].data.sourceId = bytes32("testXRP");
            pr[i].data.requestBody.transactionId = bytes32(uint256(0x100 + i));
            pr[i].data.requestBody.sourceAddressIndicator = ref;
            pr[i].data.responseBody.sourceAddressHash = ref;
            pr[i].data.responseBody.blockTimestamp = uint64(block.timestamp);
            pr[i].data.responseBody.spentAmount = int256(1_000_012);
            vm.prank(watcher);
            bond.requestAttestation{value: FEE}(
                abi.encodePacked(pr[i].data.attestationType, pr[i].data.sourceId, bytes32(0), abi.encode(pr[i].data.requestBody))
            );
        }
        pr[1].data.responseBody.spentAmount = -5_000_000; // somebody paid the agent
        vm.prank(copier);
        xjudge.fileXrpOutflow(x, pr, bytes32(0));
        assertEq(bond.owed(watcher), 2 * RATE);
        assertEq(bond.owed(copier), 0);
    }

    /// Requests shorter than a header and a body are refused before any fee moves.
    function test_revert_malformedRequest() public {
        vm.prank(watcher);
        vm.expectRevert(DelictiErrors.BadRequest.selector);
        bond.requestAttestation{value: FEE}(hex"00");
    }
}
