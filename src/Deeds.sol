// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IFdcVerification} from "@flarenetwork/flare-periphery-contracts/coston2/IFdcVerification.sol";
import {IEVMTransaction} from "@flarenetwork/flare-periphery-contracts/coston2/IEVMTransaction.sol";
import {IPayment} from "@flarenetwork/flare-periphery-contracts/coston2/IPayment.sol";
import {IBalanceDecreasingTransaction} from
    "@flarenetwork/flare-periphery-contracts/coston2/IBalanceDecreasingTransaction.sol";
import {MandateRegistry} from "./MandateRegistry.sol";
import {AnchorLog} from "./AnchorLog.sol";
import {Receipts} from "./Receipts.sol";
import {Merkle} from "./Merkle.sol";

/// @title Deeds — what makes one deed class A, written down once
/// @notice "The receipt is anchored and the FDC confirms the effect it describes" is the definition
///         of evidence class A (SPEC §5). Until v0.9 that definition lived inside the Bond's
///         challenge loops, so only a CONVICTION ever exercised it: a deed whose two witnesses agreed
///         left no trace on-chain at all. The checks live here so that the Bond (which punishes
///         disagreement and excess) and the CorroborationLog (which records agreement) cannot drift
///         apart about what agreement means. Internal functions: inlined into each user, no
///         deployment, no linking.
/// @dev    The errors repeat the Bond's by name and signature, so the selectors are identical and a
///         caller cannot tell — and need not care — which file a refusal was written in.
library Deeds {
    error WrongReceiptKind();
    error ProofDoesNotMatchClaim();
    error LeafNotAnchored();
    error FdcProofInvalid();
    error WrongSource();
    error WrongAsset();
    error TxNotSuccessful();
    error ClaimOutsideProvenRange();
    error NotAgentTx();

    /// @dev Witness 1: a leaf of the expected kind, naming this mandate, in an anchored root of it.
    function requireAnchored(AnchorLog log, uint256 mandateId, uint256 episodeIndex, Receipts.Leaf calldata leaf, bytes32[] calldata path, uint8 kind)
        internal
        view
        returns (bytes32 leafHash)
    {
        if (leaf.kind != kind) revert WrongReceiptKind();
        if (leaf.mandateId != mandateId) revert ProofDoesNotMatchClaim();
        leafHash = Receipts.hash(leaf);
        if (!Merkle.verify(path, log.episode(mandateId, episodeIndex).root, leafHash)) revert LeafNotAnchored();
    }

    /// @dev One attested EVM transaction against one receipt. Returns the value it moved.
    function evm(
        IFdcVerification fdc,
        IEVMTransaction.Proof calldata pr,
        Receipts.Leaf calldata leaf,
        MandateRegistry.Mandate memory m,
        address asset
    ) internal view returns (uint256 v) {
        if (!fdc.verifyEVMTransaction(pr)) revert FdcProofInvalid();
        if (pr.data.requestBody.transactionHash != leaf.ref || pr.data.sourceId != leaf.sourceId) {
            revert ProofDoesNotMatchClaim();
        }
        if (pr.data.sourceId != m.sourceId) revert WrongSource();
        IEVMTransaction.ResponseBody calldata rb = pr.data.responseBody;
        if (rb.status != 1) revert TxNotSuccessful();
        // A budget is cumulative over the mandate's life, so only deeds inside its window
        // may be summed against it — otherwise older activity convicts a fresh mandate.
        if (rb.timestamp < m.validFrom || rb.timestamp > m.validUntil) revert ClaimOutsideProvenRange();

        if (asset == address(0)) {
            if (rb.sourceAddress != m.agent) revert NotAgentTx();
            if (bytes32(uint256(uint160(rb.receivingAddress))) != leaf.destinationAddressHash) {
                revert ProofDoesNotMatchClaim();
            }
            v = rb.value;
        } else {
            // the Transfer(agent → payee) emitted by the mandate's asset. The transaction's own
            // sender is the facilitator, not the agent, so `sourceAddress` is not compared.
            v = erc20TransferValue(rb.events, asset, m.agent, address(uint160(uint256(leaf.destinationAddressHash))));
            if (v == 0) revert ProofDoesNotMatchClaim();
        }
        if (v != leaf.amount) revert ProofDoesNotMatchClaim();
    }

    /// @dev One attested payment against one receipt. Returns what it delivered.
    function payment(IFdcVerification fdc, IPayment.Proof calldata pr, Receipts.Leaf calldata leaf, MandateRegistry.Mandate memory m)
        internal
        view
        returns (uint256)
    {
        if (!fdc.verifyPayment(pr)) revert FdcProofInvalid();
        if (pr.data.sourceId != leaf.sourceId) revert ProofDoesNotMatchClaim();
        if (pr.data.sourceId != m.sourceId) revert WrongSource();
        IPayment.ResponseBody calldata rb = pr.data.responseBody;
        if (rb.sourceAddressHash != m.agentRef) revert NotAgentTx();
        if (rb.status != 0 || !rb.oneToOne) revert TxNotSuccessful();
        if (rb.blockTimestamp < m.validFrom || rb.blockTimestamp > m.validUntil) revert ClaimOutsideProvenRange();
        if (
            rb.receivedAmount <= 0 || uint256(rb.receivedAmount) != leaf.amount
                || rb.receivingAddressHash != leaf.destinationAddressHash || !_names(pr, leaf)
        ) revert ProofDoesNotMatchClaim();
        return uint256(rb.receivedAmount);
    }

    /// @dev Whether the receipt names this payment: by memo reference (kind 3) or, since v0.12, by
    ///      transaction id (kind 4 — x402 on XRPL binds with `InvoiceID`, which no FDC type returns).
    function _names(IPayment.Proof calldata pr, Receipts.Leaf calldata leaf) private pure returns (bool) {
        if (leaf.kind == Receipts.KIND_EXTERNAL_TX) return pr.data.requestBody.transactionId == leaf.ref;
        return pr.data.responseBody.standardPaymentReference == leaf.ref;
    }

    /// @dev Every `Transfer` out of `from` emitted by `asset`, whoever the counterparty is.
    ///      Sound only under an exclusivity declaration — see the note above.
    function erc20OutflowFrom(IEVMTransaction.Event[] calldata events, address asset, address from)
        internal
        pure
        returns (uint256 total)
    {
        for (uint256 i = 0; i < events.length; i++) {
            IEVMTransaction.Event calldata e = events[i];
            if (e.removed || e.emitterAddress != asset || e.topics.length != 3) continue;
            if (e.topics[0] != TRANSFER_SIG) continue;
            if (address(uint160(uint256(e.topics[1]))) != from) continue;
            total += abi.decode(e.data, (uint256));
        }
    }

    /// @dev The mandate's ERC-20, or a refusal. `assetKey` is a left-padded address on an EVM source;
    ///      anything with high bits set is some other source's asset identifier and not ours to guess.
    function erc20Of(MandateRegistry.Mandate memory m) internal pure returns (address) {
        if (m.assetKey == bytes32(0) || uint256(m.assetKey) >> 160 != 0) revert WrongAsset();
        return address(uint160(uint256(m.assetKey)));
    }

    /// @dev The v1.0 key (SPEC §8.4): type, source, and the hash of the ABI-encoded request body. It
    ///      leaves the MIC out, which is why watch pool v2 pays by `claimKey*`. Kept for readers of
    ///      earlier Vaults; test/FdcKey.t.sol pins it on real data.
    function deedKey(bytes32 attestationType, bytes32 sourceId, bytes memory encodedRequestBody) internal pure returns (bytes32) {
        return keccak256(abi.encode(attestationType, sourceId, keccak256(encodedRequestBody)));
    }

    // -----------------------------------------------------------------------------------
    // Claim keys (watch pool v2): the exact request an attestation answered, rebuilt from its proof.
    //
    // The FDC's message integrity code is keccak256(abi.encode(response with votingRound = 0,
    // "Flare")) — measured bit for bit against Flare's testnet verifier on EVMTransaction and
    // BalanceDecreasingTransaction (test/FdcKey.t.sol). So a proof carries everything its request
    // was made of, type ‖ source ‖ MIC ‖ abi.encode(requestBody), and the stipend can follow the
    // request that produced the proof rather than any request that merely shares its body. The
    // round is zeroed for the hash and put back, so a caller's memory struct is left as it was.
    // -----------------------------------------------------------------------------------

    function _request(bytes32 aType, bytes32 source, bytes32 mic, bytes memory encodedBody) private pure returns (bytes memory) {
        return bytes.concat(abi.encode(aType, source, mic), encodedBody);
    }

    /// @dev The exact request bytes behind an `EVMTransaction` proof, and their hash, the claim key.
    function requestEvm(IEVMTransaction.Response memory r) internal pure returns (bytes memory) {
        uint64 round = r.votingRound;
        r.votingRound = 0;
        bytes32 mic = keccak256(abi.encode(r, "Flare"));
        r.votingRound = round; // the caller's struct is left as it was
        return _request(r.attestationType, r.sourceId, mic, abi.encode(r.requestBody));
    }

    function claimKeyEvm(IEVMTransaction.Response memory r) internal pure returns (bytes32) {
        return keccak256(requestEvm(r));
    }

    /// @dev The same for `BalanceDecreasingTransaction` (§6.10, SUMMA's XRP rail).
    function requestBdt(IBalanceDecreasingTransaction.Response memory r) internal pure returns (bytes memory) {
        uint64 round = r.votingRound;
        r.votingRound = 0;
        bytes32 mic = keccak256(abi.encode(r, "Flare"));
        r.votingRound = round;
        return _request(r.attestationType, r.sourceId, mic, abi.encode(r.requestBody));
    }

    function claimKeyBdt(IBalanceDecreasingTransaction.Response memory r) internal pure returns (bytes32) {
        return keccak256(requestBdt(r));
    }

    /// @dev The same for `Payment` (§6.8).
    function requestPayment(IPayment.Response memory r) internal pure returns (bytes memory) {
        uint64 round = r.votingRound;
        r.votingRound = 0;
        bytes32 mic = keccak256(abi.encode(r, "Flare"));
        r.votingRound = round;
        return _request(r.attestationType, r.sourceId, mic, abi.encode(r.requestBody));
    }

    function claimKeyPayment(IPayment.Response memory r) internal pure returns (bytes32) {
        return keccak256(requestPayment(r));
    }

    /// @dev Shrink a memory array to its first `n` elements.
    function trim(bytes32[] memory a, uint256 n) internal pure returns (bytes32[] memory) {
        // memory-safe: shortening an array's length in place writes only its own length slot
        assembly ("memory-safe") {
            mstore(a, n)
        }
        return a;
    }

    /// @dev A live `Transfer(from, *, v)` emitted by `asset`.
    function isTransferFrom(IEVMTransaction.Event calldata e, address asset, address from) internal pure returns (bool) {
        return !e.removed && e.emitterAddress == asset && e.topics.length == 3 && e.topics[0] == TRANSFER_SIG
            && address(uint160(uint256(e.topics[1]))) == from;
    }

    bytes32 private constant TRANSFER_SIG = keccak256("Transfer(address,address,uint256)");

    function erc20TransferValue(IEVMTransaction.Event[] calldata events, address asset, address from, address to)
        internal
        pure
        returns (uint256 total)
    {
        for (uint256 i = 0; i < events.length; i++) {
            IEVMTransaction.Event calldata e = events[i];
            if (e.removed || e.emitterAddress != asset || e.topics.length != 3) continue;
            if (e.topics[0] != TRANSFER_SIG) continue;
            if (address(uint160(uint256(e.topics[1]))) != from) continue;
            if (address(uint160(uint256(e.topics[2]))) != to) continue;
            total += abi.decode(e.data, (uint256));
        }
    }

}
