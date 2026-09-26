# Watch pool v2: the seal — a stipend is paid for sealed work

*Prior tempore, potior iure*: first in time is stronger in right. Here, time is measured by the seal, not by the gas bid.

**What this is: v2 of the watch pool (SPEC §8.4), v1 for everything else.** §14 freezes the rule "a stipend per new value-moving deed paid to whoever paid for its attestation through the Vault" and the `deedKey` encoding. This document changes that rule, so by §14's own terms it cannot be an amendment. It is v2 of that one section (P.6).

**Status: implemented, tested, not deployed, unaudited.**
- Implemented in `src/Vault.sol` (v0.16), `src/Deeds.sol`, and the three judges (`JudgeEvm`, `JudgeXrpl`, `JudgeSumma`).
- Tests: the full suite passes, the invariant campaign seals every attestation it buys, and `test/FdcKey.t.sol` pins the new key to real Flare verifier data.
- Nothing is deployed. Every mandate bonded in a v0.15 Vault keeps the v1 pool for ever (§8.2).

---

## P.0 Why: two holes in the v1 pool, both proven

Both were confirmed against `5fd2925` with proof-of-concept tests before any fix was written (claude/58 H1, claude/59).

1. **The mempool copier.** Flare orders transactions by a priority gas auction run by the block proposer (dev.flare.network, *Network → Consensus mechanism*). A copier who sees a watcher's pending `requestAttestation(request)` and bids higher is recorded as `requesterOf` first. The watcher's own call still goes through and pays FdcHub again, for nothing.
   - PoC: three deeds, the copier first; all three stipends to the copier; the watcher lost three fees.
2. **The made-up MIC, with no mempool needed.** `deedKey` leaves the message integrity code out.
   - So a request with *any* MIC claims the key of the valid request. Such a request can never be attested. It can be sent the moment the deed exists, before the verifier has even indexed it, so it wins every race against an honest watcher who has to wait for `prepareRequest`.
   - PoC: one stipend paid for an attestation that never existed.

Both are the v0.8 problem, a parasite with no cost of discovery, moved from the challenger's reward down to the stipend. The watch pool exists to pay the honest watcher. In v0.15 it paid whoever was quicker at the auction, or lazier about the verifier.

## P.1 The rule

In a v0.16 Vault, a filed proof's stipend is paid to the first address that did both of the following:

1. **sealed** the exact request that proof answers, at least `commitLead` and at most `COMMIT_TTL` before
2. **paying** for it through `Vault.requestAttestation(request, salt)`.

Nobody else is paid: not the filer, not a payer of some other request for the same deed, and not a payer without a seal.

## P.2 The claim key, and why a proof can name its own request

```
request  = attestationType ‖ sourceId ‖ MIC ‖ abi.encode(requestBody)
claimKey = keccak256(request)
MIC      = keccak256(abi.encode(response with votingRound = 0, "Flare"))
```

**The MIC formula is measured, not assumed.** It reproduces bit for bit the MIC in the requests Flare's testnet verifier returned for:
- `EVMTransaction` (the proof served in round 1464335);
- `BalanceDecreasingTransaction` (round 1464433).

`test/FdcKey.t.sol` pins both: the request rebuilt from the proof equals the verifier's request byte for byte.

`Payment` uses the same formula but is **not yet pinned on real data**.

**The consequence.** A proof carries everything its request was made of, so the judge rebuilds the exact bytes from the proof it verifies (`Deeds.requestEvm`, `requestBdt`, `requestPayment`).
- Only the request that produced the proof can hold its stipend.
- A made-up MIC holds a key that no proof will ever name.

## P.3 The seal

```
seal = commitmentFor(watcher, 0, KIND_CLAIM = 0, claimKey, salt)      committed with commitChallenge
```

- **The same gate as the challenges (§6.7):** the same storage, `commitLead`, `COMMIT_TTL` and one use. A seal is a commitment like any other.
- **Kind 0** is used by no judge. So a claim can never be spent as a challenge, and a challenge commitment can never be spent as a claim.
- **Mandate 0**, because an attestation belongs to no mandate: one proof may serve several mandates in the same Vault.
- **The lead is measured to the block of the paying transaction,** because that is the moment the request becomes public. It is not measured to a round start.
- **A second sealed payer** of the same bytes is refused with `AlreadyClaimed` and keeps its fee. That removes the "second fee buys nothing" line of §10 for v0.16 Vaults.
- **Retrying a failed round:** the holder may re-send its own request through the Vault, with any salt. Anyone may also send the same bytes to FdcHub directly, and the proof still names the holder.

## P.4 What it closes

| Attempt | pool v1 (v0.15) | pool v2 (v0.16) |
|---|---|---|
| Mempool copier, same bytes | holds the key | `NoCommitment` without a seal; `CommittedTooLate` if it seals on sight |
| Made-up MIC | holds the key | holds a key that no proof names |
| A different valid request for the same deed (e.g. 2 confirmations instead of 1) | not modelled | its seal matures `commitLead` after the watcher's proof exists; by then the deed is on the docket, so the filing returns `NothingNew` |
| Two honest watchers, same bytes | the second fee is wasted | the second is refused and keeps its fee |
| Sealed, but never paid | — | holds nothing: the claim is made by paying |

Each row is a named test in `test/WatchPool.t.sol` (`test_poolV2_*`). `test/Summa.t.sol` covers the umbrella's two rails.

## P.5 What it does not claim

- **An honest watcher is `commitLead` slower:** seal, wait, pay. That is 10 minutes in production. Every paid watcher waits the same, so the market for stipends stays level, and XRPL's ~14-day horizon is not touched.
- **Two watchers who found the same deed independently and both sealed in time:** the first to *pay* wins. That is competition, not theft.
- **The agent knows its deeds first,** and can seal them through a sock puppet. That is self-recording, paid from its own principal's pool, and it is harmless for the reasons given in docs/research/watchers.md §3.
- **A filer chooses which valid proof of a deed to file, and the stipend follows the proof filed.**
  - A later request can only be filed first if nobody files the earlier one within `commitLead`.
  - Anyone can file it, and the first claimant's stipend does not depend on who files.
- **`Payment`'s MIC is not pinned on real data** (P.2).
- **The unsealed v1 entry point, `requestAttestation(request)`, does not exist in v0.16 Vaults.** Attestations bought directly from FdcHub, or through an older Vault, earn nothing here.

## P.6 Why v2, and what stays v1

§14 lets an amendment add beside the frozen text and sends any change of meaning to v2. This narrows a frozen rule: a v0.16 Vault pays only a payer who sealed the exact attestation, and `deedKey` stays defined (`Vault.deedKey`) with nothing paid by it. That is a change of meaning, so it is v2.

§14's recipe for v2 is a new registry plus a migration that each principal performs by committing new mandates.
- **Migration: the one §14 names.** A principal commits new mandates whose `Terms.bond` names a v0.16 Vault. Nothing changes under an existing mandate.
- **Registry: not replaced, the one departure from the recipe.** The registry holds mandates and leaves, and neither changes. A new registry would make every principal and agent re-anchor for a change that touches nothing it stores.
- **Still v1:** the mandate, the leaf, the kinds and their commitment encoding, the consequence rules, the surety rule and the docket semantics. A reader built against v1 reads a v0.16 Vault correctly, except for who is paid a stipend.

## P.7 Conformance

- **The rule and the attacks:**
  - `test/WatchPool.t.sol`: `test_theFirstSealedPayerHoldsTheDeed`, `test_poolV2_aMempoolCopierCannotHoldTheKey`, `test_poolV2_aMadeUpMicClaimsNothing`, `test_poolV2_aDifferentRequestForTheSameDeedComesTooLate`, `test_poolV2_theClaimantMayResendItsOwnRequest`, `test_poolV2_theSealKeepsTheGatesClock`;
  - every earlier stipend test rewritten to seal.
- **Real data:** `test/FdcKey.t.sol` pins the claim key on `EVMTransaction` and `BalanceDecreasingTransaction` requests and proofs from Flare's verifier and DA layer. The v1 `deedKey` pins stay as well.
- **Payment docket:** `test/Xrpl.t.sol` `test_paymentDocketPaysTheRequester` (sealed).
- **Umbrella:** `test/Summa.t.sol` `test_poolV2_umbrellaStipendsGoToTheSealedClaimant`, covering both rails.
- **Books:** the invariant handler rebuilds each request from the very proof it will file, seals it `commitLead` in the past, and pays. The deep-state canary still reaches paid stipends. 15 invariants hold.

## P.8 Deployment (prepared, not yet run)

**Contracts:** `script/DeployV016.s.sol` deploys, in one broadcast over the live core:
- a new consequence layer: `Vault` + `JudgeEvm` + `JudgeXrpl` (+ `BondLens`);
- for SUMMA: `VaultSumma` + `JudgeSumma` (the v0.15 price map, row for row), plus `SummaMeter`, `MandateFacilitator` and `SummaLens`, which point at `JudgeSumma` immutably.

It was rehearsed on a Coston2 fork held at Coston2's fees: 19.97 M gas, about 13 C2FLR at 650 gwei.

**SDK:**
- **The seal flow** (`sdk/src/seal.ts`): `commitChallenge(commitmentFor(watcher, 0, 0, keccak256(request), salt))`, wait `commitLead`, then `requestAttestation(request, salt)`.
  - The watchers seal before a challenge's own commitment, so one wait covers both.
  - A request someone else holds goes straight to FdcHub.
- **`claimantOf` replaces `requesterOf`.**
- **A new `sealedClaims` feature** in `networks.ts`.
- **ABIs:** `abi.ts` is regenerated from the v0.16 build. Mandates in v0.15 Vaults keep the unsealed call through the frozen `abi-v015.ts`, so the live v0.15 sentinel does not break.
- **Checked** against the v0.16 bytecode on the fork:
  - paying too early is refused (`CommittedTooLate`);
  - a copier's seal is refused (`AlreadyClaimed`);
  - the holder re-sends without a new seal.
