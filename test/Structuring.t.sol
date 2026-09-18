// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {MandateRegistry} from "../src/MandateRegistry.sol";
import {AnchorLog} from "../src/AnchorLog.sol";
import {Bond} from "../src/Bond.sol";
import {SpendMeter} from "../src/SpendMeter.sol";
import {Receipts} from "../src/Receipts.sol";
import {IFdcVerification} from "@flarenetwork/flare-periphery-contracts/coston2/IFdcVerification.sol";
import {IEVMTransaction} from "@flarenetwork/flare-periphery-contracts/coston2/IEVMTransaction.sol";
import {ProtocolsV2Interface} from "@flarenetwork/flare-periphery-contracts/coston2/ProtocolsV2Interface.sol";
import {MockProtocolsV2} from "./Rounds.sol";

contract MockFdcEvm {
    bool public verdict = true;

    function setVerdict(bool v) external {
        verdict = v;
    }

    function verifyEVMTransaction(IEVMTransaction.Proof calldata) external view returns (bool) {
        return verdict;
    }
}

/// The salami: five 1-FLR transfers under a 4-FLR budget. Each one alone is fine.
contract StructuringTest is Test {
    MandateRegistry reg;
    AnchorLog anchorLog;
    Bond bond;
    SpendMeter meter;
    MockFdcEvm mock;
    MockProtocolsV2 rounds;

    address principal = makeAddr("principal");
    address agent = makeAddr("agent");
    address merchant = makeAddr("merchant");
    address challenger = makeAddr("challenger");
    address payable victim = payable(makeAddr("victim"));

    bytes32 constant SRC = bytes32("testFLR");
    uint256 constant N = 5;
    uint256 constant EACH = 1 ether;
    uint256 constant BUDGET = 4 ether;

    uint64 constant COMMIT_LEAD = 10 minutes;
    bytes32 constant SALT = keccak256("the watcher's salt");

    uint256 mandateId;
    Receipts.Leaf[] leaves;
    bytes32[] hashes;

    function setUp() public {
        reg = new MandateRegistry();
        anchorLog = new AnchorLog(reg);
        mock = new MockFdcEvm();
        meter = new SpendMeter(reg);
        rounds = new MockProtocolsV2();
        bond = new Bond(
            reg, anchorLog, IFdcVerification(address(mock)), 24 hours, 1 hours, meter,
            COMMIT_LEAD, ProtocolsV2Interface(address(rounds))
        );
        vm.warp(1_800_000_000);

        _setUpMandate(bytes32(0));
    }

    bytes32 assetKey_;

    function _terms() internal view returns (MandateRegistry.Terms memory) {
        return MandateRegistry.Terms({sourceId: SRC, assetKey: assetKey_, agentRef: bytes32(0), bond: address(bond)});
    }

    /// @dev Since v0.9 the asset is part of the mandate, so the native and the ERC-20 salami can no
    ///      longer share one. Same five receipts, re-issued under a mandate in the asset named.
    bytes32 leafSource_ = SRC;

    function _setUpMandateWithLeafSource(bytes32 leafSource) internal {
        leafSource_ = leafSource;
        _setUpMandate(bytes32(0));
    }

    function _setUpMandate(bytes32 assetKey) internal {
        assetKey_ = assetKey;
        delete leaves;
        delete hashes;
        vm.prank(principal);
        mandateId = reg.commit(
            agent, keccak256("may spend up to 4 at merchant"), 0, 0, BUDGET,
            uint64(block.timestamp), uint64(block.timestamp + 1 days), _terms()
        );
        vm.prank(agent);
        reg.acknowledge(mandateId);

        // five receipts, each 1 unit, tx hashes strictly increasing
        for (uint256 i = 0; i < N; i++) {
            Receipts.Leaf memory l = Receipts.Leaf({
                receiptHash: keccak256(abi.encode("x402_receipt", i)),
                kind: Receipts.KIND_EVM_TX,
                sourceId: leafSource_,
                destinationAddressHash: bytes32(uint256(uint160(merchant))),
                amount: EACH,
                ref: bytes32(uint256(0x1000 + i)), // tx hash
                claimedTimestamp: uint64(block.timestamp + i * 60),
                mandateId: mandateId
            });
            leaves.push(l);
            hashes.push(Receipts.hashMem(l));
        }
        // one episode per receipt (each anchored alone: proof path is empty, root == leaf)
        for (uint256 i = 0; i < N; i++) {
            vm.prank(agent);
            anchorLog.anchor(mandateId, hashes[i], 1);
        }
        vm.deal(principal, 100 ether);
        vm.prank(principal);
        bond.post{value: 10 ether}(mandateId);
    }

    function _evmProof(uint256 i) internal view returns (IEVMTransaction.Proof memory p) {
        p.data.attestationType = bytes32("EVMTransaction");
        p.data.sourceId = SRC;
        p.data.requestBody.transactionHash = leaves[i].ref;
        p.data.requestBody.requiredConfirmations = 1;
        p.data.responseBody.blockNumber = uint64(100 + i);
        p.data.responseBody.timestamp = leaves[i].claimedTimestamp;
        p.data.responseBody.sourceAddress = agent;
        p.data.responseBody.receivingAddress = merchant;
        p.data.responseBody.value = EACH;
        p.data.responseBody.status = 1;
    }

    function _bundle(uint256 k)
        internal
        view
        returns (
            uint256[] memory idx,
            Receipts.Leaf[] memory ls,
            bytes32[][] memory paths,
            IEVMTransaction.Proof[] memory proofs
        )
    {
        idx = new uint256[](k);
        ls = new Receipts.Leaf[](k);
        paths = new bytes32[][](k);
        proofs = new IEVMTransaction.Proof[](k);
        for (uint256 i = 0; i < k; i++) {
            idx[i] = i;
            ls[i] = leaves[i];
            paths[i] = new bytes32[](0);
            proofs[i] = _evmProof(i);
        }
    }

    /// @dev Put `who`'s commitment over this exact bundle `commitLead` in the past and start its
    ///      lowest voting round NOW — the tightest arrangement the reveal accepts. A finalised
    ///      round cannot begin in the future (`ClockDrift`), and time ends where it started, so
    ///      the deeds stay inside the mandate window.
    function _arm(uint8 kind, address who, IEVMTransaction.Proof[] memory pr) internal {
        bytes32[] memory ids = new bytes32[](pr.length);
        uint64 minRound = type(uint64).max;
        for (uint256 i = 0; i < pr.length; i++) {
            ids[i] = pr[i].data.requestBody.transactionHash;
            if (pr[i].data.votingRound < minRound) minRound = pr[i].data.votingRound;
        }
        uint64 t = uint64(block.timestamp);
        vm.warp(t - bond.commitLead());
        bond.commitChallenge(bond.commitmentFor(who, mandateId, kind, bond.deedsDigest(ids), SALT));
        vm.warp(t);
        rounds.setRoundStart(minRound, t);
    }

    function test_salami_fiveSmallDeedsExceedBudget_slash() public {
        (uint256[] memory idx, Receipts.Leaf[] memory ls, bytes32[][] memory paths, IEVMTransaction.Proof[] memory pr) =
            _bundle(5);
        _arm(bond.KIND_BUDGET_NATIVE(), challenger, pr);
        vm.prank(challenger);
        bond.challengeBudgetOverrun(mandateId, idx, ls, paths, pr, SALT);
        assertTrue(bond.slashed(mandateId));
        // v0.9: 5 spent under a budget of 4 is a 25% overrun: a quarter of the 10-ether bond
        assertEq(bond.slashedAmount(mandateId), 2.5 ether);
        assertEq(bond.bondOf(mandateId), 7.5 ether);
        assertEq(bond.owed(principal), 2.25 ether);
        assertEq(bond.owed(challenger), 0.25 ether);
        assertFalse(reg.isLive(mandateId));
    }

    function test_fourDeeds_withinBudget_revert() public {
        (uint256[] memory idx, Receipts.Leaf[] memory ls, bytes32[][] memory paths, IEVMTransaction.Proof[] memory pr) =
            _bundle(4);
        _arm(bond.KIND_BUDGET_NATIVE(), challenger, pr);
        vm.prank(challenger);
        vm.expectRevert(Bond.WithinBudget.selector);
        bond.challengeBudgetOverrun(mandateId, idx, ls, paths, pr, SALT);
    }

    function test_revert_duplicateDeedSmuggledIn() public {
        (uint256[] memory idx, Receipts.Leaf[] memory ls, bytes32[][] memory paths, IEVMTransaction.Proof[] memory pr) =
            _bundle(5);
        // replay deed #3 as #4 to fake the sum
        idx[4] = 3;
        ls[4] = leaves[3];
        pr[4] = _evmProof(3);
        vm.prank(challenger);
        vm.expectRevert(Bond.UnorderedTxs.selector);
        bond.challengeBudgetOverrun(mandateId, idx, ls, paths, pr, SALT);
    }

    function test_revert_txNotByAgent() public {
        (uint256[] memory idx, Receipts.Leaf[] memory ls, bytes32[][] memory paths, IEVMTransaction.Proof[] memory pr) =
            _bundle(5);
        pr[2].data.responseBody.sourceAddress = makeAddr("someone-else");
        vm.prank(challenger);
        vm.expectRevert(Bond.NotAgentTx.selector);
        bond.challengeBudgetOverrun(mandateId, idx, ls, paths, pr, SALT);
    }

    function test_revert_worldDisagreesWithReceipt() public {
        (uint256[] memory idx, Receipts.Leaf[] memory ls, bytes32[][] memory paths, IEVMTransaction.Proof[] memory pr) =
            _bundle(5);
        pr[1].data.responseBody.value = EACH / 2; // chain says half of what the receipt claims
        vm.prank(challenger);
        vm.expectRevert(Bond.ProofDoesNotMatchClaim.selector);
        bond.challengeBudgetOverrun(mandateId, idx, ls, paths, pr, SALT);
    }

    /// A cumulative budget covers the mandate's life. Deeds from before it must not count,
    /// or old activity convicts a fresh mandate.
    function test_revert_deedOutsideMandateWindow() public {
        (uint256[] memory idx, Receipts.Leaf[] memory ls, bytes32[][] memory paths, IEVMTransaction.Proof[] memory pr) =
            _bundle(5);
        pr[2].data.responseBody.timestamp = uint64(block.timestamp - 1);
        vm.prank(challenger);
        vm.expectRevert(Bond.ClaimOutsideProvenRange.selector);
        bond.challengeBudgetOverrun(mandateId, idx, ls, paths, pr, SALT);
    }

    // --- commit–reveal (SPEC 6.7) on the flagship path: the salami challenge ---

    /// The structuring challenge is the one whose calldata is worth copying: five proofs, a proven
    /// overrun, and a 10% reward for whoever lands it. A parasite that lifts it out of the mempool
    /// and commits only once the case is public gets nothing.
    function test_revert_copiedSalamiCalldataWithALateCommitment() public {
        address parasite = makeAddr("mempool parasite");
        (uint256[] memory idx, Receipts.Leaf[] memory ls, bytes32[][] memory paths, IEVMTransaction.Proof[] memory pr) =
            _bundle(5);
        _arm(bond.KIND_BUDGET_NATIVE(), challenger, pr);

        bytes32[] memory ids = new bytes32[](5);
        for (uint256 i = 0; i < 5; i++) ids[i] = pr[i].data.requestBody.transactionHash;
        // the attestation requests have landed, so the case is public: the best a copier can do is
        // commit now, and now is the moment the evidence round began
        bond.commitChallenge(
            bond.commitmentFor(parasite, mandateId, bond.KIND_BUDGET_NATIVE(), bond.deedsDigest(ids), SALT)
        );

        vm.prank(parasite);
        vm.expectRevert(Bond.CommittedTooLate.selector);
        bond.challengeBudgetOverrun(mandateId, idx, ls, paths, pr, SALT);

        vm.prank(challenger);
        bond.challengeBudgetOverrun(mandateId, idx, ls, paths, pr, SALT);
        assertEq(bond.owed(challenger), 0.25 ether);
        assertEq(bond.owed(parasite), 0);
    }

    /// A native-path commitment is not an ERC-20-path commitment, even over the same deeds.
    function test_revert_commitmentFromTheOtherBudgetPath() public {
        (uint256[] memory idx, Receipts.Leaf[] memory ls, bytes32[][] memory paths, IEVMTransaction.Proof[] memory pr) =
            _bundle(5);
        _arm(bond.KIND_BUDGET_ERC20(), challenger, pr); // committed to the wrong kind
        vm.prank(challenger);
        vm.expectRevert(Bond.NoCommitment.selector);
        bond.challengeBudgetOverrun(mandateId, idx, ls, paths, pr, SALT);
    }

}

/// x402 reality: the settlement tx calls the token, native value is 0, the deed is a Transfer event.
contract StructuringERC20Test is StructuringTest {
    address token = makeAddr("usdt0");

    function _erc20Proof(uint256 i) internal view returns (IEVMTransaction.Proof memory p) {
        p = _evmProof(i);
        p.data.responseBody.receivingAddress = token; // tx target is the token contract
        p.data.responseBody.value = 0; // no native value moved
        p.data.responseBody.events = new IEVMTransaction.Event[](1);
        bytes32[] memory topics = new bytes32[](3);
        topics[0] = keccak256("Transfer(address,address,uint256)");
        topics[1] = bytes32(uint256(uint160(agent)));
        topics[2] = bytes32(uint256(uint160(merchant)));
        p.data.responseBody.events[0] = IEVMTransaction.Event({
            logIndex: uint32(i), emitterAddress: token, topics: topics, data: abi.encode(EACH), removed: false
        });
    }

    function _bundleErc20(uint256 k)
        internal
        view
        returns (uint256[] memory idx, Receipts.Leaf[] memory ls, bytes32[][] memory paths, IEVMTransaction.Proof[] memory proofs)
    {
        (idx, ls, paths,) = _bundle(k);
        proofs = new IEVMTransaction.Proof[](k);
        for (uint256 i = 0; i < k; i++) proofs[i] = _erc20Proof(i);
    }

    function test_erc20_salami_slash() public {
        _setUpMandate(bytes32(uint256(uint160(token))));
        (uint256[] memory idx, Receipts.Leaf[] memory ls, bytes32[][] memory paths, IEVMTransaction.Proof[] memory pr) = _bundleErc20(5);
        _arm(bond.KIND_BUDGET_ERC20(), challenger, pr);
        vm.prank(challenger);
        bond.challengeBudgetOverrun(mandateId, idx, ls, paths, pr, SALT);
        assertTrue(bond.slashed(mandateId));
    }

    function test_erc20_revert_nativePathRejectsTokenTx() public {
        // the native-value path must NOT be fooled by a token tx (value == 0 != leaf.amount)
        // — on a native mandate, where it is allowed to run at all
        (uint256[] memory idx, Receipts.Leaf[] memory ls, bytes32[][] memory paths, IEVMTransaction.Proof[] memory pr) = _bundleErc20(5);
        vm.prank(challenger);
        vm.expectRevert(Bond.ProofDoesNotMatchClaim.selector);
        bond.challengeBudgetOverrun(mandateId, idx, ls, paths, pr, SALT);
    }

    /// v0.9 — the asset used to be the challenger's to name. It is now the mandate's, so the
    /// old attack surface ("pass another token") no longer exists as calldata; what remains is
    /// the same five settlements presented against a mandate in a DIFFERENT token.
    function test_erc20_revert_wrongTokenEmitter() public {
        _setUpMandate(bytes32(uint256(uint160(makeAddr("other-token")))));
        (uint256[] memory idx, Receipts.Leaf[] memory ls, bytes32[][] memory paths, IEVMTransaction.Proof[] memory pr) = _bundleErc20(5);
        vm.prank(challenger);
        vm.expectRevert(Bond.ProofDoesNotMatchClaim.selector);
        bond.challengeBudgetOverrun(mandateId, idx, ls, paths, pr, SALT);
    }

    /// v0.9 — there is one entry point, and what counts as a deed's value follows the mandate.
    /// Native transfers presented against a token mandate carry no `Transfer` event of that token,
    /// so they match no receipt; a garbage `assetKey` is refused outright.
    function test_revert_deedsInTheWrongAssetForTheMandate() public {
        _setUpMandate(bytes32(uint256(uint160(token))));
        (uint256[] memory idx, Receipts.Leaf[] memory ls, bytes32[][] memory paths, IEVMTransaction.Proof[] memory pr) = _bundle(5);
        vm.prank(challenger);
        vm.expectRevert(Bond.ProofDoesNotMatchClaim.selector);
        bond.challengeBudgetOverrun(mandateId, idx, ls, paths, pr, SALT); // native proofs, token mandate

        _setUpMandate(keccak256("not an address: some other source's asset id"));
        (idx, ls, paths, pr) = _bundle(5);
        vm.prank(challenger);
        vm.expectRevert(Bond.WrongAsset.selector);
        bond.challengeBudgetOverrun(mandateId, idx, ls, paths, pr, SALT);
    }

    /// v0.9 — a deed on another chain is not a deed under this mandate, whatever the leaf says.
    function test_revert_deedOnAnotherSource() public {
        (uint256[] memory idx, Receipts.Leaf[] memory ls, bytes32[][] memory paths, IEVMTransaction.Proof[] memory pr) = _bundle(5);
        // the agent anchored a leaf naming another source, and the proof agrees with the leaf
        _setUpMandateWithLeafSource(bytes32("testETH"));
        (idx, ls, paths, pr) = _bundle(5);
        for (uint256 i = 0; i < 5; i++) pr[i].data.sourceId = bytes32("testETH");
        vm.prank(challenger);
        vm.expectRevert(Bond.WrongSource.selector);
        bond.challengeBudgetOverrun(mandateId, idx, ls, paths, pr, SALT);
    }

    function test_erc20_revert_transferFromSomeoneElse() public {
        _setUpMandate(bytes32(uint256(uint160(token))));
        (uint256[] memory idx, Receipts.Leaf[] memory ls, bytes32[][] memory paths, IEVMTransaction.Proof[] memory pr) = _bundleErc20(5);
        pr[2].data.responseBody.events[0].topics[1] = bytes32(uint256(uint160(makeAddr("stranger"))));
        vm.prank(challenger);
        vm.expectRevert(Bond.ProofDoesNotMatchClaim.selector);
        bond.challengeBudgetOverrun(mandateId, idx, ls, paths, pr, SALT);
    }
}
