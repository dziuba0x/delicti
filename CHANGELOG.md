# Changelog

## Unreleased (v0.5.0-dev)
- **Live (2026-09-09):** the whole loop through a **running flario MCP server** — five paid MCP calls, receipts emitted by the effector process itself, FDC proofs with `Transfer` events, `challengeBudgetOverrunERC20` slash `0x118bc48692b986875c2153492ff81757da9d9bf18e4201341cb2711f50d922f0` (327,144 gas, mandate #8).
- **Live (2026-09-09):** the effector-side brake (SPEC §7) — live mandate pays; missing, revoked and borrowed mandates refused before funds move, token balance unchanged on every refusal (mandates #5–#7).
- `scripts/mcp-structuring.sh`, `scripts/brake-test.sh`.
- Depends on the flario fix that routes both effector paths (MCP stdio, HTTP hub) through one receipt constructor and one mandate gate — before it, a receipt from the MCP server carried no `mandate_ref` and `tools/delicti.py normalize` rejected it outright.

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
