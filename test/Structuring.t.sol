// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {MandateRegistry} from "../src/MandateRegistry.sol";
import {AnchorLog} from "../src/AnchorLog.sol";
import {Bond} from "../src/Bond.sol";
import {Receipts} from "../src/Receipts.sol";
import {IFdcVerification} from "@flarenetwork/flare-periphery-contracts/coston2/IFdcVerification.sol";
import {IEVMTransaction} from "@flarenetwork/flare-periphery-contracts/coston2/IEVMTransaction.sol";

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
    MockFdcEvm mock;

    address principal = makeAddr("principal");
    address agent = makeAddr("agent");
    address merchant = makeAddr("merchant");
    address challenger = makeAddr("challenger");
    address payable victim = payable(makeAddr("victim"));

    bytes32 constant SRC = bytes32("testFLR");
    uint256 constant N = 5;
    uint256 constant EACH = 1 ether;
    uint256 constant BUDGET = 4 ether;

    uint256 mandateId;
    Receipts.Leaf[] leaves;
    bytes32[] hashes;

    function setUp() public {
        reg = new MandateRegistry();
        anchorLog = new AnchorLog(reg);
        mock = new MockFdcEvm();
        bond = new Bond(reg, anchorLog, IFdcVerification(address(mock)), 24 hours, 1 hours);
        reg.setBond(address(bond));
        vm.warp(1_800_000_000);

        vm.prank(principal);
        mandateId = reg.commit(
            agent, keccak256("may spend up to 4 FLR at merchant"), 0, 0, BUDGET,
            uint64(block.timestamp), uint64(block.timestamp + 1 days)
        );

        // five receipts, each 1 FLR, tx hashes strictly increasing
        for (uint256 i = 0; i < N; i++) {
            Receipts.Leaf memory l = Receipts.Leaf({
                receiptHash: keccak256(abi.encode("x402_receipt", i)),
                kind: Receipts.KIND_EVM_TX,
                sourceId: SRC,
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

    function test_salami_fiveSmallDeedsExceedBudget_slash() public {
        (uint256[] memory idx, Receipts.Leaf[] memory ls, bytes32[][] memory paths, IEVMTransaction.Proof[] memory pr) =
            _bundle(5);
        vm.prank(challenger);
        bond.challengeBudgetOverrun(mandateId, idx, ls, paths, pr);
        assertTrue(bond.slashed(mandateId));
        assertEq(bond.owed(principal), 9 ether);
        assertEq(bond.owed(challenger), 1 ether);
        assertFalse(reg.isLive(mandateId));
    }

    function test_fourDeeds_withinBudget_revert() public {
        (uint256[] memory idx, Receipts.Leaf[] memory ls, bytes32[][] memory paths, IEVMTransaction.Proof[] memory pr) =
            _bundle(4);
        vm.prank(challenger);
        vm.expectRevert(Bond.WithinBudget.selector);
        bond.challengeBudgetOverrun(mandateId, idx, ls, paths, pr);
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
        bond.challengeBudgetOverrun(mandateId, idx, ls, paths, pr);
    }

    function test_revert_txNotByAgent() public {
        (uint256[] memory idx, Receipts.Leaf[] memory ls, bytes32[][] memory paths, IEVMTransaction.Proof[] memory pr) =
            _bundle(5);
        pr[2].data.responseBody.sourceAddress = makeAddr("someone-else");
        vm.prank(challenger);
        vm.expectRevert(Bond.NotAgentTx.selector);
        bond.challengeBudgetOverrun(mandateId, idx, ls, paths, pr);
    }

    function test_revert_worldDisagreesWithReceipt() public {
        (uint256[] memory idx, Receipts.Leaf[] memory ls, bytes32[][] memory paths, IEVMTransaction.Proof[] memory pr) =
            _bundle(5);
        pr[1].data.responseBody.value = EACH / 2; // chain says half of what the receipt claims
        vm.prank(challenger);
        vm.expectRevert(Bond.ProofDoesNotMatchClaim.selector);
        bond.challengeBudgetOverrun(mandateId, idx, ls, paths, pr);
    }

    /// A cumulative budget covers the mandate's life. Deeds from before it must not count,
    /// or old activity convicts a fresh mandate.
    function test_revert_deedOutsideMandateWindow() public {
        (uint256[] memory idx, Receipts.Leaf[] memory ls, bytes32[][] memory paths, IEVMTransaction.Proof[] memory pr) =
            _bundle(5);
        pr[2].data.responseBody.timestamp = uint64(block.timestamp - 1);
        vm.prank(challenger);
        vm.expectRevert(Bond.ClaimOutsideProvenRange.selector);
        bond.challengeBudgetOverrun(mandateId, idx, ls, paths, pr);
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
        (uint256[] memory idx, Receipts.Leaf[] memory ls, bytes32[][] memory paths, IEVMTransaction.Proof[] memory pr) = _bundleErc20(5);
        vm.prank(challenger);
        bond.challengeBudgetOverrunERC20(mandateId, token, idx, ls, paths, pr);
        assertTrue(bond.slashed(mandateId));
    }

    function test_erc20_revert_nativePathRejectsTokenTx() public {
        // the native-value path must NOT be fooled by a token tx (value == 0 != leaf.amount)
        (uint256[] memory idx, Receipts.Leaf[] memory ls, bytes32[][] memory paths, IEVMTransaction.Proof[] memory pr) = _bundleErc20(5);
        vm.prank(challenger);
        vm.expectRevert(Bond.ProofDoesNotMatchClaim.selector);
        bond.challengeBudgetOverrun(mandateId, idx, ls, paths, pr);
    }

    function test_erc20_revert_wrongTokenEmitter() public {
        (uint256[] memory idx, Receipts.Leaf[] memory ls, bytes32[][] memory paths, IEVMTransaction.Proof[] memory pr) = _bundleErc20(5);
        vm.prank(challenger);
        vm.expectRevert(Bond.ProofDoesNotMatchClaim.selector);
        bond.challengeBudgetOverrunERC20(mandateId, makeAddr("other-token"), idx, ls, paths, pr);
    }

    function test_erc20_revert_transferFromSomeoneElse() public {
        (uint256[] memory idx, Receipts.Leaf[] memory ls, bytes32[][] memory paths, IEVMTransaction.Proof[] memory pr) = _bundleErc20(5);
        pr[2].data.responseBody.events[0].topics[1] = bytes32(uint256(uint160(makeAddr("stranger"))));
        vm.prank(challenger);
        vm.expectRevert(Bond.ProofDoesNotMatchClaim.selector);
        bond.challengeBudgetOverrunERC20(mandateId, token, idx, ls, paths, pr);
    }
}
