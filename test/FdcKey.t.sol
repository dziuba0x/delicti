// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Deeds} from "../src/Deeds.sol";
import {IEVMTransaction} from "@flarenetwork/flare-periphery-contracts/coston2/IEVMTransaction.sol";
import {IBalanceDecreasingTransaction} from
    "@flarenetwork/flare-periphery-contracts/coston2/IBalanceDecreasingTransaction.sol";

/// @notice The watch pool pays whoever paid for an attestation (SPEC §8.4). The Vault records the
///         payer under a key built from the REQUEST bytes; the judge rebuilds it from the PROOF.
///         If the two ever disagreed, every stipend would silently go unpaid. These pin them
///         together on real data: request bytes from Flare's testnet verifier and the proofs the
///         DA layer served for them on 2026-09-24 (mandates #12 and #13).
contract FdcKeyTest is Test {
    /// Mirrors `Vault.requestAttestation`: type ‖ source ‖ MIC ‖ abi.encode(requestBody).
    function _vaultKey(bytes memory request) internal pure returns (bytes32) {
        bytes32 t;
        bytes32 s;
        assembly {
            t := mload(add(request, 32))
            s := mload(add(request, 64))
        }
        bytes memory body = new bytes(request.length - 96);
        for (uint256 i = 0; i < body.length; i++) body[i] = request[96 + i];
        return keccak256(abi.encode(t, s, keccak256(body)));
    }

    function _load(string memory f) internal view returns (bytes memory request, bytes memory response) {
        string memory json = vm.readFile(string.concat(vm.projectRoot(), "/test/fixtures/", f));
        request = vm.parseJsonBytes(json, ".request");
        response = vm.parseJsonBytes(json, ".response_hex");
    }

    /// EVMTransaction, whose request body is dynamic (logIndices): the verifier encodes it with
    /// its own head offset after the 96-byte header.
    function test_evmTransactionKeyFromRequestEqualsKeyFromProof() public view {
        (bytes memory request, bytes memory response) = _load("fdc-evm-12.json");
        IEVMTransaction.Response memory r = abi.decode(response, (IEVMTransaction.Response));
        assertEq(r.requestBody.logIndices.length, 1);
        assertEq(_vaultKey(request), Deeds.deedKey(r.attestationType, r.sourceId, abi.encode(r.requestBody)));
    }

    /// Watch pool v2: the judge rebuilds the WHOLE request from the proof — MIC included — and it is
    /// byte for byte what Flare's verifier returned. The MIC is keccak256(abi.encode(response with
    /// votingRound = 0, "Flare")); if this ever broke, every sealed stipend would silently go unpaid.
    function test_evmTransactionClaimKeyFromRequestEqualsClaimKeyFromProof() public view {
        (bytes memory request, bytes memory response) = _load("fdc-evm-12.json");
        IEVMTransaction.Response memory r = abi.decode(response, (IEVMTransaction.Response));
        assertEq(keccak256(Deeds.requestEvm(r)), keccak256(request), "the request, rebuilt");
        assertEq(Deeds.claimKeyEvm(r), keccak256(request));
        assertEq(r.votingRound, 1464335, "the caller's struct is left as it was");
    }

    function test_balanceDecreasingClaimKeyFromRequestEqualsClaimKeyFromProof() public view {
        (bytes memory request, bytes memory response) = _load("fdc-bdt-13.json");
        IBalanceDecreasingTransaction.Response memory r = abi.decode(response, (IBalanceDecreasingTransaction.Response));
        assertEq(keccak256(Deeds.requestBdt(r)), keccak256(request), "the request, rebuilt");
        assertEq(Deeds.claimKeyBdt(r), keccak256(request));
    }

    /// BalanceDecreasingTransaction, a static request body.
    function test_balanceDecreasingKeyFromRequestEqualsKeyFromProof() public view {
        (bytes memory request, bytes memory response) = _load("fdc-bdt-13.json");
        IBalanceDecreasingTransaction.Response memory r = abi.decode(response, (IBalanceDecreasingTransaction.Response));
        assertEq(_vaultKey(request), Deeds.deedKey(r.attestationType, r.sourceId, abi.encode(r.requestBody)));
    }
}
