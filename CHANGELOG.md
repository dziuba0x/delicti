# Changelog

## v0.4.0 — 2026-09-08
- **Live:** real x402 salami on Coston2 — five genuine EIP-3009 settlements, genuine `flario-receipt/2` receipts with `mandate_ref`, FDC `EVMTransaction` proofs carrying `Transfer` events, `challengeBudgetOverrunERC20` slashes.
- `Bond.challengeBudgetOverrunERC20` — deeds read from `Transfer` events inside FDC proofs (the real x402 case; native path deliberately rejects token txs).
- `tools/delicti.py` — normalize flario receipts to leaves (hash bit-identical to `Receipts.hash`), evidence class, sorted-pair Merkle tree + proofs.
- `src/mocks/MockUSDT0.sol` — EIP-3009 token with public mint for Coston2 demos.
- `SPEC.md` v0.1 — vocabulary, trust model, evidence classes, challenge invariants, non-claims.

## v0.2.0 — 2026-09-08
- **Live:** first contradicted deed (FDC `ReferencedPaymentNonexistence` vs anchored receipt) and native structuring (5 × 1 C2FLR > 4) on Coston2.
- `MandateRegistry` (delegation tree, monotonic narrowing, transitive liveness), `AnchorLog`, `Receipts`, `Bond` (`challengeFalsePayment`, `challengeBudgetOverrun`), `Merkle`.
- CI, LICENSE, loop diagram, comparison table.
