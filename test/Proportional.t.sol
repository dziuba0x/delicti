// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {StructuringTest} from "./Structuring.t.sol";
import {Bond} from "../src/Bond.sol";
import {BondLens} from "../src/BondLens.sol";
import {Receipts} from "../src/Receipts.sol";
import {IEVMTransaction} from "@flarenetwork/flare-periphery-contracts/coston2/IEVMTransaction.sol";

/// @dev Stand-ins for Flare's ContractRegistry and FdcRequestFeeConfigurations, etched at the real
///      registry address so `Bond.fdcCost` reads a fee the way it does on-chain.
contract MockFeeConfig {
    uint256 public fee;

    constructor(uint256 f) {
        fee = f;
    }

    function getRequestFee(bytes calldata) external view returns (uint256) {
        return fee;
    }
}

contract MockFlareRegistry {
    address public cfg;

    function set(address c) external {
        cfg = c;
    }

    function getContractAddressByName(string calldata) external view returns (address) {
        return cfg;
    }
}

/// @title v0.9 — the penalty follows the size of the breach (SPEC §8.1)
/// @notice Inherits the salami fixture: five anchored 1-ether deeds, budget 4, bond 10 ether.
contract ProportionalTest is StructuringTest {
    address constant FLARE_REGISTRY = 0xaD67FE66660Fb8dFE9d6b1b4240d8650e30F6019;
    address insurer = makeAddr("insurer");
    BondLens lens = new BondLens();

    function _challenge(address who, uint256 k) internal {
        (uint256[] memory idx, Receipts.Leaf[] memory ls, bytes32[][] memory paths, IEVMTransaction.Proof[] memory pr) = _bundle(k);
        _arm(bond.KIND_BUDGET_NATIVE(), who, pr);
        vm.prank(who);
        bond.challengeBudgetOverrun(mandateId, idx, ls, paths, pr, SALT);
    }

    /// @dev Re-issue the fixture with deeds of `each` instead of 1 ether.
    function _deedsOf(uint256 each, uint256 budget) internal {
        vm.prank(principal);
        mandateId = reg.commit(agent, keccak256("m"), 0, 0, budget, uint64(block.timestamp), uint64(block.timestamp + 1 days), _terms());
        vm.prank(agent);
        reg.acknowledge(mandateId);
        delete leaves;
        for (uint256 i = 0; i < N; i++) {
            Receipts.Leaf memory l = Receipts.Leaf(
                keccak256(abi.encode("r", i)), Receipts.KIND_EVM_TX, SRC, bytes32(uint256(uint160(merchant))), each,
                bytes32(uint256(0x1000 + i)), uint64(block.timestamp + i * 60), mandateId
            );
            leaves.push(l);
            vm.prank(agent);
            anchorLog.anchor(mandateId, Receipts.hashMem(l), 1);
        }
        vm.prank(principal);
        bond.post{value: 10 ether}(mandateId);
    }

    function _evmProofOf(uint256 i, uint256 each) internal view returns (IEVMTransaction.Proof memory p) {
        p = _evmProof(i);
        p.data.responseBody.value = each;
    }

    function _challengeValued(address who, uint256 k, uint256 each) internal {
        (uint256[] memory idx, Receipts.Leaf[] memory ls, bytes32[][] memory paths, IEVMTransaction.Proof[] memory pr) = _bundle(k);
        for (uint256 i = 0; i < k; i++) pr[i] = _evmProofOf(i, each);
        _arm(bond.KIND_BUDGET_NATIVE(), who, pr);
        vm.prank(who);
        bond.challengeBudgetOverrun(mandateId, idx, ls, paths, pr, SALT);
    }

    // ------------------------------------------------------------------ the shape of the penalty

    /// A breach of one wei is still a breach: it costs the floor, not a rounding error.
    function test_smallestOverrunCostsTheFloor() public {
        _deedsOf(1 ether, 5 ether - 1); // five deeds of 1 over a budget one wei short of 5
        _challengeValued(challenger, 5, 1 ether);
        assertEq(bond.slashedAmount(mandateId), 1 ether, "10% of a 10-ether bond");
        assertEq(bond.bondOf(mandateId), 9 ether);
        assertFalse(reg.isLive(mandateId), "the first proven breach ends the mandate, whatever its size");
    }

    /// Spending twice the budget takes everything: you cannot lose more than the bond.
    function test_overrunOfTheWholeBudgetTakesTheWholeBond() public {
        _deedsOf(2 ether, 5 ether); // 10 spent over a budget of 5: overrun == budget
        _challengeValued(challenger, 5, 2 ether);
        assertEq(bond.slashedAmount(mandateId), 10 ether);
        assertEq(bond.bondOf(mandateId), 0);
    }

    function testFuzz_penaltyIsMonotoneBoundedAndFloored(uint256 budget, uint256 each) public {
        budget = bound(budget, 1, 1_000 ether);
        each = bound(each, budget / 5 + 1, 1_000 ether); // five deeds always overrun
        _deedsOf(each, budget);
        (uint256 predicted,) = lens.penaltyFor(bond, mandateId, bond.KIND_BUDGET_NATIVE(), 5 * each - budget);
        _challengeValued(challenger, 5, each);
        uint256 taken = bond.slashedAmount(mandateId);
        assertEq(taken, predicted, "the lens and the Bond disagree about the same case");
        assertGe(taken, 1 ether, "below the floor");
        assertLe(taken, 10 ether, "more than the bond");
        assertEq(bond.owed(challenger) + bond.owed(principal), taken, "value created or destroyed in the split");
        assertEq(bond.bondOf(mandateId), 10 ether - taken);
    }

    // ------------------------------------------------------------------ a small verdict is not a shield

    /// The reason "slashed at most once" had to go. The agent convicts itself of the smallest case it
    /// can assemble; a real watcher then proves the whole one. The watcher is still paid — on the
    /// difference — and the agent's bond ends up exactly where the larger verdict alone would have
    /// left it.
    function test_selfSlashDoesNotShieldTheBond() public {
        _deedsOf(1.5 ether, 4 ether); // 3 deeds = 4.5 (overrun 0.5), 5 deeds = 7.5 (overrun 3.5)
        _challengeValued(agent, 3, 1.5 ether); // the agent's own cheap verdict
        assertEq(bond.slashedAmount(mandateId), 1.25 ether); // 0.5/4 of the bond
        uint256 ownReward = bond.owed(agent);

        (uint256[] memory idx, Receipts.Leaf[] memory ls, bytes32[][] memory paths, IEVMTransaction.Proof[] memory pr) = _bundle(5);
        for (uint256 i = 0; i < 5; i++) pr[i] = _evmProofOf(i, 1.5 ether);
        bytes32[] memory ids = new bytes32[](5);
        for (uint256 i = 0; i < 5; i++) ids[i] = pr[i].data.requestBody.transactionHash;
        uint64 t = uint64(block.timestamp);
        vm.warp(t - bond.commitLead());
        bond.commitChallenge(bond.commitmentFor(challenger, mandateId, bond.KIND_BUDGET_NATIVE(), bond.deedsDigest(ids), "w"));
        vm.warp(t);
        vm.prank(challenger);
        bond.challengeBudgetOverrun(mandateId, idx, ls, paths, pr, "w");

        assertEq(bond.slashedAmount(mandateId), 8.75 ether, "3.5/4 of the bond, as if the small verdict had never happened");
        assertEq(bond.owed(challenger), 0.75 ether, "10% of the 7.5 ether its verdict added");
        assertEq(bond.owed(agent), ownReward, "the first verdict earned nothing more");
        assertEq(bond.slashBase(mandateId), 10 ether, "measured on the bond as it stood at the FIRST verdict");
    }

    /// The same case again proves nothing new, and a transaction that changes nothing must not look
    /// like a verdict.
    function test_revert_sameOverrunTwice() public {
        _challenge(challenger, 5);
        (uint256[] memory idx, Receipts.Leaf[] memory ls, bytes32[][] memory paths, IEVMTransaction.Proof[] memory pr) = _bundle(5);
        _arm(bond.KIND_BUDGET_NATIVE(), challenger, pr);
        vm.prank(challenger);
        vm.expectRevert(Bond.NothingNew.selector);
        bond.challengeBudgetOverrun(mandateId, idx, ls, paths, pr, SALT);
    }

    // ------------------------------------------------------------------ whose money comes back

    /// Until v0.9 `post` did not record the depositor and `withdraw` paid the principal: a bond
    /// posted by an insurer was a free option for the agent's own side. Every depositor now bears
    /// the same fraction of every verdict and takes back its own remainder.
    function test_remainderGoesBackToWhoeverPostedIt_proRata() public {
        vm.deal(insurer, 100 ether);
        vm.prank(insurer);
        bond.post{value: 30 ether}(mandateId); // 10 (principal) + 30 (insurer)
        _challenge(challenger, 5); // 25% overrun: 10 of 40 taken
        assertEq(bond.bondOf(mandateId), 30 ether);

        vm.warp(block.timestamp + 25 hours); // the first verdict killed the mandate; cooling window over
        uint256 before = insurer.balance;
        vm.prank(insurer);
        bond.withdraw(mandateId, payable(insurer));
        assertEq(insurer.balance - before, 22.5 ether, "75% of 30");

        before = principal.balance;
        vm.prank(principal);
        bond.withdraw(mandateId, payable(principal));
        assertEq(principal.balance - before, 7.5 ether, "75% of 10");
        assertEq(bond.bondOf(mandateId), 0);

        vm.prank(principal);
        vm.expectRevert(Bond.NoDeposit.selector);
        bond.withdraw(mandateId, payable(principal)); // not twice
    }

    function test_revert_principalCannotWithdrawWhatItDidNotPost() public {
        vm.prank(principal);
        uint256 id = reg.commit(agent, keccak256("x"), 0, 0, 1 ether, uint64(block.timestamp), uint64(block.timestamp + 1 hours), _terms());
        vm.prank(agent);
        reg.acknowledge(id);
        vm.deal(insurer, 5 ether);
        vm.prank(insurer);
        bond.post{value: 5 ether}(id);
        vm.warp(block.timestamp + 26 hours);
        vm.prank(principal);
        vm.expectRevert(Bond.NoDeposit.selector);
        bond.withdraw(id, payable(principal));
        vm.prank(insurer);
        bond.withdraw(id, payable(insurer));
        assertEq(insurer.balance, 5 ether);
    }

    /// A verdict does not release the rest early: a larger breach may still be on its way.
    function test_revert_withdrawRightAfterAPartialSlash() public {
        _challenge(challenger, 5);
        vm.prank(principal);
        vm.expectRevert(Bond.CoolingWindow.selector);
        bond.withdraw(mandateId, payable(principal));
    }

    // ------------------------------------------------------------------ what proving it cost

    function _etchFee(uint256 fee) internal {
        vm.etch(FLARE_REGISTRY, address(new MockFlareRegistry()).code);
        MockFlareRegistry(FLARE_REGISTRY).set(address(new MockFeeConfig(fee)));
    }

    /// The challenger is made whole for its attestations first, then earns 10% of the rest. The fee
    /// is read from Flare's own fee configuration, not written down here: it is 20 FLR per request on
    /// mainnet today and was 1 FLR before FIP.16.
    function test_challengerIsReimbursedForItsAttestationsFirst() public {
        _etchFee(0.05 ether);
        assertEq(bond.fdcCost(bytes32("EVMTransaction"), SRC, 5), 0.25 ether);
        _challenge(challenger, 5); // takes 2.5
        assertEq(bond.owed(challenger), 0.25 ether + 0.225 ether, "5 x fee, plus 10% of the remaining 2.25");
        assertEq(bond.owed(principal), 2.025 ether);
    }

    /// When proving the case cost more than the case was worth, the challenger takes all of it and is
    /// still out of pocket. The protocol cannot pay out more than the verdict took — which is the
    /// honest limit of "the reward covers the cost": it does wherever the floor does, and a bond too
    /// small for its floor to cover five attestations is a bond nobody will watch.
    function test_costAboveTheVerdictTakesAllOfItAndNoMore() public {
        _etchFee(1 ether); // 5 proofs = 5 ether, verdict = 2.5
        _challenge(challenger, 5);
        assertEq(bond.owed(challenger), 2.5 ether);
        assertEq(bond.owed(principal), 0);
    }

    /// No registry (a unit test, or a chain that is not Flare), a registry without a fee contract, or
    /// a fee contract that reverts for this type: cost is zero and nothing reverts.
    function test_fdcCostFailsToZero() public {
        assertEq(bond.fdcCost(bytes32("EVMTransaction"), SRC, 5), 0);
        vm.etch(FLARE_REGISTRY, address(new MockFlareRegistry()).code); // cfg == address(0)
        assertEq(bond.fdcCost(bytes32("EVMTransaction"), SRC, 5), 0);
        MockFlareRegistry(FLARE_REGISTRY).set(address(this)); // has code, no getRequestFee
        assertEq(bond.fdcCost(bytes32("EVMTransaction"), SRC, 5), 0);
    }
}
