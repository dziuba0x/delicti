# DELICTI Specification — v0.5 (draft)

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
**Meter** — the cumulative tally a declared effector keeps on-chain against a mandate's budget. Read before a deed, written after it. The only part of DELICTI that acts in real time on the *sequence*.

## 2. Trust model

DELICTI trusts exactly two things: the consensus of the chain it runs on, and the decentralized attestation protocol enshrined in that chain (FDC). It does **not** trust the agent, the operator, the effector, the model vendor, or any single server.

What each party can and cannot do:

| Party | Can | Cannot |
|---|---|---|
| Agent | act; omit receipts; anchor false receipts | make a false receipt corroborate; anchor under a dead mandate; escape a challenge once anchored |
| Effector | sign false receipts | make the FDC confirm a payment that did not happen; forge a `Transfer` event inside an FDC proof |
| Principal | set the envelope; revoke; withdraw bond after expiry **and the cooling window** | rewrite a mandate after commit; withdraw while live; **shorten the challenger's runway by revoking early**; suppress a challenge |
| Challenger | anyone; bring proofs; earn 10 % | slash without both witnesses; slash twice; reuse a leaf; **choose who receives the remainder**; **burn a leaf under a mandate it does not name** |
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

All challenges are permissionless, require both witnesses, and pay 10 % of the slashed bond to the challenger and the remainder **to the mandate's principal** — the harmed party of §1. Neither is pushed: both are credited and pulled with `claim()`, so a recipient that reverts on receive cannot make a mandate unslashable. A mandate is slashed at most once; a leaf is consumed at most once **per mandate**.

Three invariants exist because their absence was exploitable, and each has a regression test:

- **The leaf must name the mandate being challenged** (`leaf.mandateId == mandateId`), in every challenge. Without it, and with a globally-keyed consumption set, anyone could anchor a copy of someone else's leaf under a throwaway mandate, slash themselves for 1 wei, and make that evidence permanently unusable against its real subject.
- **The remainder is not a parameter.** It used to be. A challenge carries its finished proofs in public calldata, so the whole transaction could be copied from the mempool with that one field changed and the bond returned in full to whoever posted it.
- **A nonexistence proof scoped to source addresses proves nothing here.** `ReferencedPaymentNonexistence` takes `checkSourceAddresses`/`sourceAddressesRoot`; scoped that way it truthfully says *those* addresses did not pay. A leaf carries no source address to compare against, so such a proof is refused rather than used to convict an agent who paid from elsewhere.
- **A cumulative budget only counts deeds inside the mandate's window.** Both budget challenges require the FDC-proven `timestamp` of each deed to fall in `[validFrom, validUntil]`.

### 6.1 False payment (`challengeFalsePayment`)
Kind-3 leaf in an anchored root + `ReferencedPaymentNonexistence` proof whose `(destinationAddressHash, amount, standardPaymentReference, sourceId)` equal the leaf's and whose proven window `[minimalBlockTimestamp, deadlineTimestamp]` contains `claimedTimestamp`, with the search having overflowed the deadline. *Executed live on Coston2.*

### 6.2 Budget overrun, native (`challengeBudgetOverrun`)
N kind-2 leaves, each in an anchored root, each with an `EVMTransaction` proof: tx hash equals `ref`, `sourceAddress` equals the mandated agent, `status == 1`, `value` and `receivingAddress` equal the leaf. Transaction hashes strictly increasing (dedup without storage). `Σ value > budget`. *Executed live on Coston2.*

### 6.3 Budget overrun, ERC-20 (`challengeBudgetOverrunERC20`)
As 6.2, but the deed is a `Transfer(agent → payee, value)` event emitted by the mandate's asset inside the proof (`listEvents = true`). This is the real x402 case: settlement is `transferWithAuthorization` on the token, native value is zero. *Executed live on Coston2 with genuine EIP-3009 settlements and genuine flario receipts.*

Why the sum: a pre-action gate sees one call at a time and passes each of five legal calls. Structuring — many small deeds each inside a limit — is the canonical way a constrained actor drains a budget, and it is the gap the pre-action standards themselves admit. DELICTI judges the sequence because the mandate is a budget, not a per-call limit.

### 6.4 Mandate-less deed (`accuseUnanchoredDeed` / `answerAccusation` / `resolveAccusation`)

An FDC-proven transaction from the mandate's agent, inside the mandate's window, with no anchored leaf behind it: a muscle moving with no signal. Every other challenge starts from an anchored leaf, which means consequence reached only agents that had already confessed — not anchoring was free, and an agent optimising its public corroboration rate should anchor the easy deeds and stay quiet about the rest. This is the challenge that reaches silence.

**Why it is shaped as an accusation.** Proving a negative on-chain would need a non-inclusion proof over every episode of the mandate — a sorted or sparse tree, and a proof per episode. Instead the burden is inverted the way an accusation is: the challenger names the deed, brings the FDC proof, and posts a stake; the agent has a `responseWindow` to produce the leaf it says it wrote; silence resolves against it. Anyone may answer, because it is the evidence that speaks, and anyone may resolve once the window closes — the challenger's 10 % follows the accusation, not the caller.

**What stops the obvious defences.**
- *Anchoring after the accusation.* The answering episode must have been anchored no later than `deedTime + anchorGrace`. Anchoring later is a cover story, not a receipt — and a revoked mandate cannot anchor at all.
- *Accusing an agent that never promised anything.* An address may legitimately do things outside one mandate, so the challenge applies only to mandates where the **agent itself** called `declareExclusive`: a promise that inside this window, this address acts only under this mandate. Only the agent can make it, and it is sticky — otherwise it would be withdrawn the moment the agent wanted to act unobserved.
- *Griefing.* A false accusation forfeits its stake to the principal.
- *Accusing faster than the agent can write.* Deeds inside `anchorGrace` cannot be accused at all.

`anchorGrace` (1 h) and `responseWindow` (24 h) are constructor immutables, so a testnet deployment can demonstrate the whole loop without waiting out production timers. Unlike the cooling window, `responseWindow` is not waiting on the FDC: the answer is data the agent already holds.

### 6.5 Under-reported spend (`challengeUnderReportedSpend`)

The meter (§7.1) is what makes structuring refusable while it is still happening, and an effector can defeat it simply by not writing. This is the challenge that makes silence expensive.

N FDC `EVMTransaction` proofs of deeds by the mandate's agent, inside the mandate's window, summing to more than the meter recorded. No anchored leaves are required: the meter is **witness 1 over the sequence** and the proofs are **witness 2 over the same sequence**, so §5 is not weakened — this is a class-A contradiction about a tally rather than about one deed. `asset = address(0)` sums native transaction value; otherwise it sums `Transfer` events out of the agent emitted by that asset (the x402 case).

**Scope is deliberately narrow.** The challenge runs only on a mandate that is both *metered* (§7.1) and *exclusive* (§6.4). Without exclusivity an outflow from the agent's address may be none of this mandate's business, and summing it would convict an honest agent — the same error as accepting a source-scoped nonexistence proof.

**Who is at fault, and who pays.** The effector keeps the tally, but the bond sits on the mandate and the remainder goes to the principal. That is the intended incentive: the principal chose the effector. Picking one that lies, or one that is not DELICTI-aware at all, is a decision with a price.

### 6.6 Roadmap challenges (specified, not implemented)
- **Wrong counterparty.** Proven effect to an address outside the envelope's disclosed allow-list (needs selective disclosure of that list — Merkle leaf per counterparty).
- **Class-B escalation.** Web2 effects via FDC `Web2Json` for allow-listed sources.
- **Under-reporting.** A second witness over the *tally* rather than over a single deed: an effector anchoring its own count of deeds performed for a mandate, so a divergence from the agent's `receiptCount` is itself challengeable.

### 6.7 Commit–reveal on every challenge (v0.8)

Everything above describes how a challenge is *proved*. This describes who is allowed to be *paid* for it, and it applies to all five challenge entry points plus the accusation of §6.4.

**The problem.** The challenger's 10 % goes to whoever lands the transaction, and the transaction is self-contained — the proofs are in public calldata and anyone can replay them. Worse, a challenge cannot be assembled in secret: `FdcHub.requestAttestation(requestBytes)` is an on-chain call carrying the deed's transaction hash or payment reference in the clear, and it precedes the reveal by the length of a voting round plus DA latency — minutes. A parasite that watches `FdcHub` therefore learns of every case minutes before it can be filed, and can copy the reveal out of the mempool and outbid the gas. The honest watcher pays for monitoring and analysis; the parasite pays for neither. The equilibrium number of real watchers is zero, and a consequence layer nobody watches is theatre.

**The rule.** Every challenge must first be committed:

```
commitment = keccak256(abi.encode(challenger, mandateId, kind, deedsDigest, salt))
deedsDigest = keccak256(abi.encode(deedIds))
```

`kind` is one of the five `Bond.KIND_*` constants. `deedIds` is the receipt leaf hash for `KIND_FALSE_PAYMENT`, the deed's transaction hash for `KIND_UNANCHORED_DEED`, and the deeds' transaction hashes in the exact ascending order the challenge supplies them for the three cumulative kinds. `commitChallenge(bytes32)` stores nothing but that hash and the timestamp, so the commitment leaks nothing at all.

At reveal, with `R` the **lowest** `votingRound` among the supplied proofs and `roundStart(R)` read live off Flare's `ProtocolsV2` (`firstVotingRoundStartTs`, `votingEpochDurationSeconds` — never hardcoded):

```
committedAt + commitLead  <=  roundStart(R)  <=  committedAt + COMMIT_TTL
roundStart(R)             <=  block.timestamp
```

and the commitment is deleted, single-use.

**Why each clause is there.**

- *Taking the lowest round, not the highest.* Otherwise one freshly requested proof would launder a commitment made after the rest of the case was already public.
- *`commitLead` (10 min, immutable).* Requiring only `committedAt < roundStart(R)` — the obvious rule — does **not** close the hole, and it looks as though it does. A parasite that sees the victim's request land in round R can commit inside R, request its own attestation for the same deed in round R+1, and reveal against that: its commitment honestly predates `roundStart(R+1)`. It pays one more attestation fee and one more round of latency, and then it is a race it wins whenever the honest challenger's proof happens to be the slow one — and measured DA latency on Coston2 spans ~100 s to ~500 s for the same request type, so that race is real. A lead of L means the parasite's earliest usable round starts L after it learned of the case, so it loses unless the honest proof is more than L slower than its own. Ten minutes is wider than the measured spread, which makes the defence deterministic rather than a coin flip.
- *`COMMIT_TTL` (1 h, constant).* `commitLead` alone leaves the other end open, and that end decides whether any of this means anything. Without an upper bound a commitment is a free, permanent option: the deed set is public on three of the five paths — one transaction hash, one published leaf, or the canonical "every deed so far, ascending" — so anyone can pre-commit to cases that have not been challenged yet, at one `SSTORE` each, and copy a reveal months later by changing the salt. The commitment would be old enough to satisfy any lead. The TTL turns that free option into rent: a squatter must re-commit every candidate, with a fresh salt, once per TTL, forever, for every mandate. An honest challenger pays once, for the case it actually found. It is a constant rather than a constructor argument because a deployer with discretion over it could set it just above `commitLead` and make honest challenges against its own agents nearly impossible to time.
- *A round cannot have begun in the future.* `roundStart(R)` extrapolates: it multiplies a round number that may be years old by the epoch length Flare reports *now*. If Flare lengthens the voting epoch or redeploys with a rebased `firstVotingRoundStartTs`, that product lands in the future and every commitment — including one made in the same block — clears the lead test. The gate would stop existing, silently, with nothing reverting to say so. A finalised round has necessarily started, so this check holds on a healthy chain and fails closed on an unhealthy one. The mirror-image drift (a shortened epoch pushing the product into the past) only refuses challenges, which is the direction to fail in; see §10.

**What the preimage binds, and what it deliberately does not.** `challenger` makes a commitment non-transferable; `mandateId` and `kind` stop a commitment for a cheap challenge type being spent on an expensive one; `deedsDigest` pins the exact ordered set, so a subset, a superset and a reordering are three different cases. The ERC-20 `asset` is **not** bound, because it is not a field a copier can vary to its advantage: naming the wrong asset sums the wrong `Transfer` events and the challenge fails on its own merits.

**Replaying a commitment is a no-op.** Commitments travel in public calldata, so if a second submission could refresh the stored timestamp, a parasite unable to steal a challenge could still grief it past `commitLead` by replaying the victim's own commitment bytes. `commitChallenge` therefore keeps the earliest submission; replaying it early merely registers it on the victim's behalf, since the preimage names the only address that can spend it.

**The accusation of §6.4 is gated, `resolveAccusation` is not.** The accusation is what publishes the case and its accuser is who earns the 10 %, so it carries the same salt and the same `kind = 4` gate. Resolution stays open to anyone, because the reward follows `a.challenger` rather than the caller.

**Cost.** One extra transaction per challenge (~31k gas) and one round-timing read at reveal, plus the wait between committing and requesting. The wait is affordable because `COOLING_WINDOW` keeps the bond in place for 24 h.

## 7. The effector-side brake (optional, recommended)

FDC finality is minutes; DELICTI is evidence after the fact. But the effector is the final common pathway and can read the chain in milliseconds. A DELICTI-aware effector therefore MAY, before producing the effect, check `MandateRegistry.isLive(mandateId)` and that the requesting agent *is* the mandated agent, and refuse otherwise. A deed with no mandate may be refused outright. flario implements this (`DELICTI_REGISTRY`, `DELICTI_REQUIRE_MANDATE`). The brake cannot see structuring — that remains the challenge's job — but it prevents the two cheapest failure modes: acting under a dead mandate and borrowing someone else's.

### 7.1 The meter — refusing structuring in real time

The brake above sees one call at a time, and every slice of a structuring attack is inside its own limit. It therefore cannot see the attack that §6.2 exists to punish. The gap is not patience, it is arithmetic: only a cumulative total can refuse the next slice.

`SpendMeter` closes it. The principal declares which effectors may keep the tally; each effector reads `wouldExceed(mandateId, amount)` before acting — an `eth_call`, so the payment path gains no attestation latency — and calls `note(mandateId, amount)` after the funds move. The fifth slice of a salami is refused in milliseconds instead of being slashed minutes later.

Three properties are deliberate:

- **The meter records past the budget.** A meter that refuses to record an overrun is a meter that lies about one. The overrun must stay publicly readable — that is what makes `exceeded()` meaningful to the next counterparty.
- **The meter alone never slashes.** It is one witness. Consequence still requires the divergence in §6.5, which carries both.
- **Not writing is not a loophole, it is the division of labour.** The fast path protects against a constrained agent; the slow path convicts the effector that lied about what it did. An effector that skips the meter is choosing to be judged by the FDC instead.

The read is free and instant; the write is one `SSTORE`. Against an FDC round of ~90 seconds, this is the difference between prevention and compensation.

## 8. Bond economics (v0.1, deliberately simple)

- Anyone may post bond under a mandate: the agent, the operator, an insurer. Bond is in the chain's native asset in v0.1.
- Sizing is a market question, not a protocol constant. A rational counterparty should require `bond ≥ budget × k` for some `k ≥ 1`; the protocol does not enforce it and exposes the ratio for anyone to read.
- Withdrawal only after the mandate is dead, nothing was slashed, and a **cooling window of 24 h** measured from `deathTime()` — the earliest death in the mandate's ancestry — has elapsed. The window is not decoration: a challenge is not instant (an on-chain FDC request, a voting round, a DA fetch, then the challenge), the principal is an authority in `revoke()`, and the FDC request itself announces the coming challenge minutes ahead. Without the window `revoke(); withdraw();` in one transaction emptied the bond, and measuring from the moment of death rather than from the withdrawal attempt is what stops an early revocation from shortening the runway.
- Challenger reward is 10 %. It must be large enough to pay for FDC fees and gas (trivial on Flare) and small enough that the victim is made mostly whole.

## 9. Privacy

Nothing sensitive is on-chain: mandate envelopes and receipts live off-chain; the chain sees hashes, roots, budgets, windows, and addresses. Selective disclosure of envelope fields is by Merkle inclusion against `mandateHash`. Payer identity in flario receipts is a Poseidon commitment (see flario's RECEIPT_SPEC and its honest caveat that EIP-3009 settlement reveals the payer on-chain anyway). Viewing keys and zero-knowledge proofs over the log are explicitly out of scope for v0.1.

## 10. What DELICTI does not claim

- It does not prove intent, alignment, or reasoning. It proves deeds — and the absence of claimed deeds.
- It does not replace receipts; it consumes them.
- It does not stop a deed in real time by itself. The brake in §7 does, for liveness and identity, and the meter in §7.1 does for the cumulative budget — but only where an effector chooses to keep the tally.
- It does not see effects the FDC cannot index (class B). It says so, per deed.
- It does not know that an envelope was *complete* — only that the deed exceeded the envelope that was committed.
- It protects the challenger's 10 % from a *reactive* copier (§6.7) but not from an unboundedly patient one. `COMMIT_TTL` prices pre-committing to cases nobody has found yet, it does not forbid it: a squatter willing to pay rent on every candidate deed set, forever, can still hold a live commitment when someone else's reveal appears. The defence is economic, not cryptographic, and it is the honest description.
- It cannot make the agent later than its own watchers. The party with the earliest knowledge of a violation is the one committing it, so an agent (or a fresh address belonging to it) can hold a commitment over its own deeds and self-slash the moment a real watcher's reveal appears, turning a 10 % loss into no loss and taking the reward off the only party the mechanism was written for. `slashed[mandateId]` is winner-take-all, which is what makes that final. Splitting the reward across all valid commitments for the same case would address it; that is a design decision, not a patch, and it is open.
- It assumes Flare's voting-round clock stays linear. `roundStart(R)` is extrapolated from the currently reported epoch length (§6.7); a lengthened epoch is caught and refused, but a *shortened* epoch, or a redeployed `FlareSystemsManager` with a rebased origin, pushes every computed round start into the past and refuses every challenge until the deployment is replaced. Bonds are not lost and nobody is wrongly slashed — the failure is liveness, chosen deliberately over a silent bypass.
- It does not bind the ERC-20 `asset` or the `sourceId` to the mandate on-chain; both live in the off-chain envelope. Until they do, a bond posted by a party other than the principal should be read with that in mind.
- The slash is all-or-nothing, which makes the penalty a step function and the deed's optimal size, conditional on breaching, the largest one available. Proportional slashing is a design decision, not an oversight, and is open.
- Silence is challengeable only for mandates whose agent declared exclusivity (§6.4). An agent that never makes that promise is still judged on what it anchors — the promise is the price of being trusted, not a protocol guarantee.

## 11. Metrics this makes possible

Because every judged deed has a class, an agent, a mandate, and a verdict, two new safety-relevant quantities become measurable across operators without trusting any of them:

- **coverage rate** — share of an agent's FDC-observable deeds that were anchored at all. Under an exclusivity declaration (§6.4) the denominator is public and outside the agent's control: every transaction from that address inside the window. This is the metric that matters first, because the two below are conditional on it;
- **corroboration rate** — share of an agent's claimed deeds that reach class A;
- **contradiction rate** — share of anchored receipts proven false or overrun. Weigh it by value, not by count: leaves are cheap, and an agent with one contradiction can otherwise dilute it with ten thousand dust deeds.

These are properties of *deeds*, not of models, and they can be computed by anyone from public data. That is the point.

## 12. Compatibility

- **Receipts:** flario `flario-receipt/2` (implemented); KYA-OS `_meta` proofs and ACTA/ASQAV receipts (adapter specified: `policy_digest`/`previousReceiptHash` map naturally; `mandate_ref` proposed as an extension claim).
- **Identity/reputation:** ERC-8004 — DELICTI verdicts are a natural input to a Reputation Registry: reputation from corroborated deeds, not declarations.
- **Chains:** any EVM with an FDC-equivalent second witness could host DELICTI; today only Flare has one enshrined in protocol, which is the entire reason it is built there.

---

*Changes to this document bump the version. Anything implemented but not specified here is a bug in the document; anything specified but not implemented is marked roadmap.*
