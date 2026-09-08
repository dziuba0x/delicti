#!/usr/bin/env python3
"""DELICTI normalizer / anchorer (witness-1 side).

Turns third-party receipts into DELICTI leaves, hashes them exactly as
`Receipts.hash` does on-chain, builds the sorted-pair Merkle tree AnchorLog
expects, and emits inclusion proofs for Bond challenges.

Supported receipt formats: flario `x402_receipt` (flario-receipt/2, needs
`mandate_ref`). KYA-OS / ACTA adapters: TODO (same shape, different fields).

Usage:
  delicti.py normalize receipt.json            -> leaf JSON (+ leafHash)
  delicti.py tree leaf1.json leaf2.json ...     -> root + per-leaf proofs
  delicti.py classify receipt.json              -> evidence class A/B/C

Requires foundry `cast` on PATH (abi-encode + keccak, so the hash is bit-identical
to Solidity; no python keccak dependency).
"""
import json, subprocess, sys

SOURCE_ID = {"coston2": "testFLR", "mainnet": "FLR", "songbird": "SGB", "coston": "testSGB"}
LEAF_SIG = "f((bytes32,uint8,bytes32,bytes32,uint256,bytes32,uint64,uint256))"
KIND_TOOL_CALL, KIND_EVM_TX, KIND_EXTERNAL_PAYMENT = 1, 2, 3


def cast(*args):
    return subprocess.check_output(["cast", *args], text=True).strip()


def pad32(s: str) -> str:
    return "0x" + s.encode().hex().ljust(64, "0")


def addr32(a: str) -> str:
    return "0x" + "0" * 24 + a[2:].lower()


def leaf_tuple(l):
    return f"({l['receiptHash']},{l['kind']},{l['sourceId']},{l['destinationAddressHash']},{l['amount']},{l['ref']},{l['claimedTimestamp']},{l['mandateId']})"


def leaf_hash(l) -> str:
    return cast("keccak", cast("abi-encode", LEAF_SIG, leaf_tuple(l)))


def normalize_flario(r):
    if r.get("schema_version") not in ("flario-receipt/2",):
        raise SystemExit(f"unsupported receipt schema {r.get('schema_version')} (need flario-receipt/2 with mandate_ref)")
    if not r.get("mandate_ref"):
        raise SystemExit("receipt has no mandate_ref — a deed without a mandate is not a DELICTI leaf (it is an alarm)")
    leaf = {
        "receiptHash": r["receipt_hash"],
        "kind": KIND_EVM_TX,
        "sourceId": pad32(SOURCE_ID[r["network"]]),
        "destinationAddressHash": addr32(r["payee_address"]),
        "amount": str(int(r["amount"])),
        "ref": r["settlement_tx_hash"].lower(),
        "claimedTimestamp": int(r["timestamp"]),
        "mandateId": str(int(r["mandate_ref"]["mandate_id"])),
        # not part of the on-chain leaf, kept for the challenger:
        "_asset": r["asset"],
        "_chainId": r["mandate_ref"]["chain_id"],
        "_registry": r["mandate_ref"]["registry"],
    }
    leaf["leafHash"] = leaf_hash(leaf)
    leaf["_tuple"] = leaf_tuple(leaf)
    return leaf


def classify(r):
    """Evidence class per README: A two witnesses, B one witness (effect not observable), C self-report."""
    if r.get("fdc_attestation_ref"):
        return "A"  # effector receipt + FDC attestation of the settlement
    if r.get("settlement_tx_hash"):
        return "B+"  # effect observable on-chain; FDC corroboration pending (request EVMTransaction)
    return "C"


def hpair(a: str, b: str) -> str:
    a, b = a.lower(), b.lower()
    return cast("keccak", cast("concat-hex", *(sorted([a, b]))))


def tree(hashes):
    """Sorted-pair Merkle (OpenZeppelin layout, matches src/Merkle.sol). Odd node promoted."""
    level = [h.lower() for h in hashes]
    proofs = [[] for _ in level]
    idx = list(range(len(level)))
    while len(level) > 1:
        nxt, nidx = [], []
        for i in range(0, len(level), 2):
            if i + 1 < len(level):
                for j in idx[i] if isinstance(idx[i], list) else [idx[i]]:
                    proofs[j].append(level[i + 1])
                for j in idx[i + 1] if isinstance(idx[i + 1], list) else [idx[i + 1]]:
                    proofs[j].append(level[i])
                nxt.append(hpair(level[i], level[i + 1]))
                a = idx[i] if isinstance(idx[i], list) else [idx[i]]
                b = idx[i + 1] if isinstance(idx[i + 1], list) else [idx[i + 1]]
                nidx.append(a + b)
            else:
                nxt.append(level[i]); nidx.append(idx[i] if isinstance(idx[i], list) else [idx[i]])
        level, idx = nxt, nidx
    return level[0], proofs


def main():
    if len(sys.argv) < 3:
        print(__doc__); sys.exit(1)
    cmd, files = sys.argv[1], sys.argv[2:]
    if cmd == "normalize":
        print(json.dumps(normalize_flario(json.load(open(files[0]))), indent=2))
    elif cmd == "classify":
        print(classify(json.load(open(files[0]))))
    elif cmd == "tree":
        leaves = [json.load(open(f)) for f in files]
        hs = [l["leafHash"] if "leafHash" in l else leaf_hash(l) for l in leaves]
        root, proofs = tree(hs)
        print(json.dumps({"root": root, "receiptCount": len(hs), "leaves": [{"leafHash": h, "proof": p} for h, p in zip(hs, proofs)]}, indent=2))
    else:
        raise SystemExit(f"unknown command {cmd}")


if __name__ == "__main__":
    main()
