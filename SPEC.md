# DELICTI Specification — v0.1 (draft)

*Corpus delicti for autonomous agents: prove the deed happened before anyone is judged.*

Status: draft, implemented on Flare Coston2 (see README for addresses and live transactions). This document fixes the vocabulary, the trust model, and the invariants. Anything not stated here is not promised.

---

## 0. The problem this solves, in one paragraph

Every existing standard for agent accountability signs a *claim*: the operator's platform (ASQAV), a policy gateway (ACTA, OAP), the tool server (KYA-OS), or the payment network (AP2) attests that something was decided or done. A signed claim proves registration, not truth; a false claim can be immutably registered. When the acting mind is opaque, its words and its self-reports are not evidence. DELICTI adds what none of them have: an independent second witness to the *effect in the world*, a commitment of the *permitted envelope* made before the act, a delta computed over the *sequence* rather than per action, and an economic *consequence* that fires on proof without any court, operator, or model vendor in the loop. The legal ancestor is the two-witness rule for overt acts: for the gravest charges, law does not try to read the mind; it requires two independent witnesses to the same deed.

## 1. Terms

**Principal** — the party granting authority; posts or arranges the bond; is harmed by a breach.
**Agent** — the address bound by a mandate; the party whose deeds are judged. A model, a runtime, a human — DELICTI does not care.
**Effector** — anything through which an agent produces an effect in the world: an MCP server, a payment facilitator, an API gateway, a robot controller. Effectors are the *final common pathway*: whatever the agent's internal state, every world effect passes through a finite, enumerable set of effectors. DELICTI observes there.
**Mandate** — an on-chain commitment, made *before* an episode, of what an agent may do: a hash of the off-chain envelope, a cumulative budget, a validity window, an authority reference, and a parent (for delegation).
**Deed** — an effect in the world attributed to an agent. Not a message, not a plan, not a tool *call*: the *effect*.
**Receipt** — a third-party artifact produced by an effector describing a deed (KYA-OS proof, ACTA receipt, flario `x402_receipt`). DELICTI never defines a receipt format. **Witness 1.**
**Corroboration** — an attestation by a decentralized protocol that the effect occurred as described, independent of agent and effector. On Flare this is the FDC. **Witness 2.**
**Leaf** — the normalized, format-agnostic projection of a receipt that DELICTI anchors and judges (§4).
**Episode** — a batch of leaves anchored under one mandate as one Merkle root.
**Challenge** — a permissionless on-chain proof that a mandate was breached (§6).
**Bond** — value staked under a mandate, slashed on a successful challenge.

## 2. Trust model

DELICTI trusts exactly two things: the consensus of the chain it runs on, and the decentralized attestation protocol enshrined in that chain (FDC). It does **not** trust the agent, the operator, the effector, the model vendor, or any single server.

What each party can and cannot do:

| Party | Can | Cannot |
|---|---|---|
| Agent | act; omit receipts; anchor false receipts | make a false receipt corroborate; anchor under a dead mandate; escape a challenge once anchored |
| Effector | sign false receipts | make the FDC confirm a payment that did not happen; forge a `Transfer` event inside an FDC proof |
| Principal | set the envelope; revoke; withdraw bond after expiry | rewrite a mandate after commit; withdraw while live; suppress a challenge |
| Challenger | anyone; bring proofs; earn 10 % | slash without both witnesses; slash twice; reuse a leaf |
| FDC | attest facts on supported chains and allow-listed Web2 sources | attest facts it does not index (see class B) |

An omitted receipt is not invisible: a mandate whose budget is drawn down on-chain without matching leaves is itself evidence (§6.4, roadmap).

## 3. Mandates

A mandate `M` is `(principal, agent, mandateHash, authorityRef, parentId, budget, validFrom, validUntil, revoked)`.

- `mandateHash` commits to an off-chain envelope (canonical JSON): allowed effectors, counterparties, per-action limits, purpose text. The envelope is disclosed selectively; only its hash is public.
- `budget` is cumulative over the mandate's lifetime, in the unit the envelope names (drops, wei, token base units). It is the quantity challenges sum against.
- `authorityRef` is the hash of the authority proof for the delegation — typically a W3C Verifiable Credential chain (KYA-OS style). DELICTI does not implement delegation credentials; it anchors their hash and enforces the on-chain shape.
- **Monotonic narrowing.** A child mandate must satisfy `budget ≤ parent.budget`, `validFrom ≥ parent.validFrom`, `validUntil ≤ parent.validUntil`, and can only be committed by the parent's agent. Capability semantics: authority can be attenuated, never amplified.
- **Liveness is transitive.** `isLive(M)` is true iff `M` and every ancestor are unrevoked and inside their windows. Killing a root kills the tree.
- **Revocation is sticky** and may be performed by any ancestor principal, or by the Bond on a successful challenge.

Non-goal in v0.1: budgets across several assets under one mandate. One mandate, one unit.

## 4. Leaves and anchoring

A leaf is `(receiptHash, kind, sourceId, destinationAddressHash, amount, ref, claimedTimestamp, mandateId)`, hashed as `keccak256(abi.encode(leaf))`.

- `receiptHash` binds the leaf to the effector's own signed artifact, so an auditor can always walk back to witness 1 in its native format.
- `kind` ∈ {1 tool call, 2 EVM transaction, 3 external payment (XRPL/BTC/DOGE)}.
- `sourceId` is the FDC source identifier (`testFLR`, `FLR`, `testXRP`, …).
- `destinationAddressHash` is the FDC standard address hash for kind 3, and the left-padded address for kind 2.
- `ref` is the payment reference (kind 3) or the transaction hash (kind 2).
- `mandateId` must name a mandate that was live when the deed was claimed.

Leaves are batched into a sorted-pair Merkle tree; only the root, a count, and the anchoring party are written to `AnchorLog`, sequenced per mandate. **A leaf with no `mandate_ref` in its receipt is not a leaf; it is an alarm** (roadmap §6.4).

Anchoring under a mandate that is not live is refused on-chain. This is deliberate: a dead mandate must not be able to accumulate a plausible-looking record after the fact.

## 5. Evidence classes

DELICTI names what it can prove. Every judged deed carries a class.

- **Class A — two witnesses agree.** The receipt is anchored, and an FDC attestation confirms the effect (transaction exists, `sourceAddress` is the agent, `Transfer` event matches, or payment exists). This is the only class that can trigger consequence.
- **Class B — one witness, effect not observable.** The receipt is anchored, but the effect leaves no trace the FDC can index (an email sent, a file written, a Web2 call to a source not on the allow-list). DELICTI records it, orders it, and makes it survivable; it does not claim it happened.
- **Class C — self-report.** No anchored receipt. Whatever the agent says.

A **contradicted deed** is a class-A *negative*: the receipt is anchored and the FDC proves the effect did **not** happen (`ReferencedPaymentNonexistence`), or happened differently (value, counterparty, sender). Contradicted deeds are the strongest evidence DELICTI produces, and the one thing no receipt-only standard can produce at all.

## 6. Challenges (v0.1)

All challenges are permissionless, require both witnesses, and pay 10 % of the slashed bond to the challenger and the remainder to a named victim. A mandate is slashed at most once; a leaf is consumed at most once.

### 6.1 False payment (`challengeFalsePayment`)
Kind-3 leaf in an anchored root + `ReferencedPaymentNonexistence` proof whose `(destinationAddressHash, amount, standardPaymentReference, sourceId)` equal the leaf's and whose proven window `[minimalBlockTimestamp, deadlineTimestamp]` contains `claimedTimestamp`, with the search having overflowed the deadline. *Executed live on Coston2.*

### 6.2 Budget overrun, native (`challengeBudgetOverrun`)
N kind-2 leaves, each in an anchored root, each with an `EVMTransaction` proof: tx hash equals `ref`, `sourceAddress` equals the mandated agent, `status == 1`, `value` and `receivingAddress` equal the leaf. Transaction hashes strictly increasing (dedup without storage). `Σ value > budget`. *Executed live on Coston2.*

### 6.3 Budget overrun, ERC-20 (`challengeBudgetOverrunERC20`)
As 6.2, but the deed is a `Transfer(agent → payee, value)` event emitted by the mandate's asset inside the proof (`listEvents = true`). This is the real x402 case: settlement is `transferWithAuthorization` on the token, native value is zero. *Executed live on Coston2 with genuine EIP-3009 settlements and genuine flario receipts.*

Why the sum: a pre-action gate sees one call at a time and passes each of five legal calls. Structuring — many small deeds each inside a limit — is the canonical way a constrained actor drains a budget, and it is the gap the pre-action standards themselves admit. DELICTI judges the sequence because the mandate is a budget, not a per-call limit.

### 6.4 Roadmap challenges (specified, not implemented)
- **Mandate-less deed.** An FDC-proven transaction from a bonded agent's address with no anchored leaf referencing it: a muscle moving with no signal. Requires the agent to bond an *address*, not only a mandate.
- **Wrong counterparty.** Proven effect to an address outside the envelope's disclosed allow-list (needs selective disclosure of that list — Merkle leaf per counterparty).
- **Class-B escalation.** Web2 effects via FDC `Web2Json` for allow-listed sources.

## 7. The effector-side brake (optional, recommended)

FDC finality is minutes; DELICTI is evidence after the fact. But the effector is the final common pathway and can read the chain in milliseconds. A DELICTI-aware effector therefore MAY, before producing the effect, check `MandateRegistry.isLive(mandateId)` and that the requesting agent *is* the mandated agent, and refuse otherwise. A deed with no mandate may be refused outright. flario implements this (`DELICTI_REGISTRY`, `DELICTI_REQUIRE_MANDATE`). The brake cannot see structuring — that remains the challenge's job — but it prevents the two cheapest failure modes: acting under a dead mandate and borrowing someone else's.

## 8. Bond economics (v0.1, deliberately simple)

- Anyone may post bond under a mandate: the agent, the operator, an insurer. Bond is in the chain's native asset in v0.1.
- Sizing is a market question, not a protocol constant. A rational counterparty should require `bond ≥ budget × k` for some `k ≥ 1`; the protocol does not enforce it and exposes the ratio for anyone to read.
- Withdrawal only after the mandate is dead and nothing was slashed. A cooling window after expiry (to let late challenges land) is a v0.2 item and is the most important hardening gap today.
- Challenger reward is 10 %. It must be large enough to pay for FDC fees and gas (trivial on Flare) and small enough that the victim is made mostly whole.

## 9. Privacy

Nothing sensitive is on-chain: mandate envelopes and receipts live off-chain; the chain sees hashes, roots, budgets, windows, and addresses. Selective disclosure of envelope fields is by Merkle inclusion against `mandateHash`. Payer identity in flario receipts is a Poseidon commitment (see flario's RECEIPT_SPEC and its honest caveat that EIP-3009 settlement reveals the payer on-chain anyway). Viewing keys and zero-knowledge proofs over the log are explicitly out of scope for v0.1.

## 10. What DELICTI does not claim

- It does not prove intent, alignment, or reasoning. It proves deeds — and the absence of claimed deeds.
- It does not replace receipts; it consumes them.
- It does not stop a deed in real time by itself; the brake in §7 does, and only for liveness and identity.
- It does not see effects the FDC cannot index (class B). It says so, per deed.
- It does not know that an envelope was *complete* — only that the deed exceeded the envelope that was committed.

## 11. Metrics this makes possible

Because every judged deed has a class, an agent, a mandate, and a verdict, two new safety-relevant quantities become measurable across operators without trusting any of them:

- **corroboration rate** — share of an agent's claimed deeds that reach class A;
- **contradiction rate** — share of anchored receipts proven false or overrun.

These are properties of *deeds*, not of models, and they can be computed by anyone from public data. That is the point.

## 12. Compatibility

- **Receipts:** flario `flario-receipt/2` (implemented); KYA-OS `_meta` proofs and ACTA/ASQAV receipts (adapter specified: `policy_digest`/`previousReceiptHash` map naturally; `mandate_ref` proposed as an extension claim).
- **Identity/reputation:** ERC-8004 — DELICTI verdicts are a natural input to a Reputation Registry: reputation from corroborated deeds, not declarations.
- **Chains:** any EVM with an FDC-equivalent second witness could host DELICTI; today only Flare has one enshrined in protocol, which is the entire reason it is built there.

---

*Changes to this document bump the version. Anything implemented but not specified here is a bug in the document; anything specified but not implemented is marked roadmap.*
