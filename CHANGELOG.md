# Changelog

## v0.5.0 — 2026-09-09 — hardening

Five holes, found by an adversarial pass over the deployed code, each with a regression test. 31 tests pass; the loop was re-run live on Coston2 against the new deployment.

- **`withdraw` cooling window (24 h from `deathTime()`).** `revoke(); withdraw();` in one transaction emptied the bond before any challenge could exist. Measured from the mandate's death, not from the withdrawal attempt, so revoking early does not shorten the challenger's runway. Live: revert `CoolingWindow()` (`0x3f93322d`) immediately after revocation.
- **The slash remainder is no longer a parameter.** It was challenger-supplied, so a challenge could be copied out of the mempool with that one field changed and the bond returned in full to whoever posted it. It now goes to the mandate's principal, and both shares are credited and pulled with `claim()` instead of pushed.
- **`revokeByBond` access control.** It was permissionless. A revoked mandate cannot anchor, so anyone could silence any agent's evidence layer for the price of one transaction. Live: revert `NotBond()` (`0x799e4159`) from a stranger.
- **`challengeFalsePayment` now binds `leaf.mandateId`, and leaf consumption is scoped per mandate.** Otherwise a copy of someone's leaf could be anchored under a throwaway mandate, self-slashed for 1 wei, and that evidence burned permanently.
- **Source-scoped nonexistence proofs are refused** (`checkSourceAddresses`), and both budget challenges require each deed's FDC-proven timestamp to fall inside the mandate window.
- `MandateRegistry`: `isLive` fails closed past its 64-ancestor guard (65 self-delegations previously produced a mandate its own root could not kill); new `revokedAt` and `deathTime()`; `setBond` (set once, by the deployer).
- `Bond.post` refuses an already-slashed mandate.
- SPEC bumped to v0.2: the new invariants, and an honest list of what is still open (challenger front-running, unbound `asset`/`sourceId`, all-or-nothing slash, anchored-leaf dependency).

**v0.5 deployment (Coston2):** `MandateRegistry` `0x1e85be1CD6D499f5E8AE12C6Fa1336949188FbB7`, `AnchorLog` `0x14E65D83032b85241B764f5fbbEE532a90403D23`, `Bond` `0x9bDFE9C95980E7676E64779Cabe1948Ce6F04ae8`, `MockUSDT0` unchanged. Live salami through the flario MCP server: `0xc3ec30648c7e9869cc101a0b58b041d8260103cf4f9b49f8645fe842a48c5fc4` (361,940 gas), `claim()` `0x458855019abfa0511329e3e5891febdeae9e0d940b51266a28dde129008a0bf3`.

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
