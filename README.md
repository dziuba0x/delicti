# DELICTI

**Corpus delicti for AI agents.** Before anyone is judged, prove the deed happened.

DELICTI is a corroboration-and-consequence layer for the actions of autonomous AI agents, anchored on [Flare](https://flare.network). It does not define yet another receipt format. It takes the signed receipts that effectors already produce (KYA-OS / Checkpoint `_meta` proofs, ACTA / ASQAV receipts, flario `x402_receipt`s) and adds the four things none of them have:

1. **Mandate before act** — a principal commits, on-chain, what the agent may do (budget, window, delegation chain) *before* the episode. Children can only narrow parents.
2. **Two witnesses to the same overt act** — the effector's receipt is witness one; Flare's Data Connector (FDC) attesting the effect in the world is witness two. Agreement is evidence. Disagreement is a *contradicted deed*.
3. **Delta over the sequence** — violations are computed against the cumulative budget of the mandate, not per action, so structuring ("salami") is caught.
4. **Consequence without a court** — a bond is slashed on proof, pattern lifted from FAssets' challenger role. Challenger gets 10%, the harmed party gets the rest.

> When a mind becomes alien, its words stop being evidence. Its deeds, confirmed independently, remain. — the thesis, after J. Pachocki's *An Alien Mind*.

## Status — Sprint 0 (Coston2)

| Piece | State |
|---|---|
| `MandateRegistry.sol` — commitments, delegation tree, monotonic narrowing, revocation | tests pass |
| `AnchorLog.sol` — per-mandate sequence of Merkle roots over receipts; refuses dead mandates | tests pass |
| `Bond.sol` — `challengeFalsePayment`: anchored receipt × FDC `ReferencedPaymentNonexistence` → slash | tests pass (mock FDC); live `FdcVerification` resolution verified on a Coston2 fork |
| `Receipts.sol` — normalized "overt act" leaf bound to the original third-party receipt | done |
| FDC request script (testXRP nonexistence → proof → challenge) | next |
| flario: `mandate_ref` in `x402_receipt` | next |
| Budget-overrun challenge via FDC `EVMTransaction` (structuring demo) | next |

Verified on Coston2 (chain 114): `FdcVerification` `0x906507E0B64bcD494Db73bd0459d1C667e14B933`, `Relay` `0xa10B672D1c62e5457b17af63d4302add6A99d7dE`, FDC protocol id `200`.

## Build & test

```bash
npm install                      # pulls @flarenetwork/flare-periphery-contracts
forge build
forge test                       # unit tests with a mock FDC
forge test --fork-url coston2 --match-contract Coston2ForkTest -vv   # live wiring
```

Deploy to Coston2: `forge script script/Deploy.s.sol --rpc-url coston2 --broadcast --private-key $PK`

## Evidence classes

DELICTI names what it can and cannot prove:

- **A** — two witnesses agree (receipt + FDC attestation of the effect).
- **B** — one witness; the effect is not observable in the world (e.g. an email sent).
- **C** — self-report only.

## Threat model, honestly

- A compromised effector can sign false receipts. That is exactly why witness two exists: FDC does not trust the effector.
- FDC finality is minutes, not seconds. DELICTI is evidence after the fact, not a real-time brake (a mandate check hook is left in the spec for effectors that want one).
- Web2 effects need allow-listed sources on FDC; Sprint 0 corroborates on-chain and XRPL/BTC/DOGE effects only.
- Whitehat only. Everything runs on Coston2 / forks. Never real mainnet with other people's funds.

## License

MIT — Dziuba Technology.
