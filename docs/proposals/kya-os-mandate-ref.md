# Proposal: a `mandate_ref` claim in KYA-OS proofs and ACTA receipts

**To:** DIF Trusted Agents WG (KYA-OS), ACTA/ASQAV authors
**From:** DELICTI (github.com/dziuba0x/delicti)
**Status:** draft for discussion

## Problem
A signed receipt proves that an effector registered a claim about a deed. It cannot, by itself, say whether the deed was *permitted*, and a third party cannot check it against anything committed *before* the deed. `policy_digest` (ACTA/ASQAV) binds a receipt to a policy hash, but the policy lives with the operator; nobody else can verify liveness, budget, or delegation without the operator's cooperation.

## Proposal
Add one optional claim to the signed payload:

```json
"mandate_ref": { "chain_id": 114, "registry": "0x…", "mandate_id": "42" }
```

- `registry` is a contract exposing `isLive(uint256) → bool` and `get(uint256) → (principal, agent, mandateHash, authorityRef, parentId, budget, validFrom, validUntil, revoked)`.
- The claim is signed with the rest of the receipt, so the effector attests *which authority it believed it was acting under*.
- Verifiers that do not know DELICTI ignore the claim. Verifiers that do can: check the mandate was live at `issued_at`; check the signer/agent binding; sum receipts against `budget`; and, with an independent attestation of the effect (Flare FDC today), prove a receipt false or a budget exceeded.

## What this buys the receipt ecosystems
- A receipt becomes checkable against a pre-commitment nobody can rewrite, without adopting a new receipt format.
- Delegation credentials (KYA-OS VC chains) get an on-chain anchor via `authorityRef = hash(VC chain)`, so a revoked root visibly kills every downstream receipt.
- An effector MAY refuse to act when `isLive` is false or the requester is not the mandated agent — a 20-line brake at the final common pathway (reference implementation: flario `src/x402/mandate.ts`).

## Reference
- flario `flario-receipt/2` implements the claim (RECEIPT_SPEC.md).
- DELICTI SPEC.md §3–§7; three live challenges on Flare Coston2 in README.
