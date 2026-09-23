# DELICTI Specification — v0.9 (draft)

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

A mandate `M` is `(principal, agent, mandateHash, authorityRef, parentId, budget, validFrom, validUntil, revoked, sourceId, assetKey, agentRef, bond)`. The last four are v0.9 and are appended, so a reader compiled against the first nine keeps decoding them.

- `mandateHash` commits to an off-chain envelope (canonical JSON): allowed effectors, counterparties, per-action limits, purpose text. The envelope is disclosed selectively; only its hash is public.
- `budget` is cumulative over the mandate's lifetime, in base units of the asset the mandate names. It is the quantity challenges sum against.
- **`sourceId` and `assetKey` say what the budget is made of** (v0.9). `sourceId` is the FDC source the deeds happen on (`testFLR`, `XRP`, …) and may not be zero. `assetKey` is `0` for that source's native asset and, on an EVM source, the ERC-20 address left-padded to 32 bytes. Every challenge reads both from the mandate; none accepts them from calldata. Until v0.9 they lived only in the envelope, so whoever posted collateral could read *how much* it insured and not *of what*.
- **`agentRef`** is the agent's identity on a non-EVM source: the FDC standard address hash (for XRPL, `keccak256` of the r-address). Zero on EVM sources, where `agent` is the identity. See §6.8.
- **`bond`** is the one consequence contract allowed to revoke this mandate on proof — since v0.11 a `Vault` (§8.2). The registry has no deployer, no owner and no global Bond: each mandate names its own. That contract can revoke that mandate and nothing else — a power its principal already holds — so new consequence contracts, with new challenge types, can be deployed over the same registry, log and meter without orphaning a single mandate. A Bond refuses collateral for a mandate that names a different one, because it could never carry out the slash.
- **Acknowledgement.** A principal writes the agent's address unilaterally, and principals may anchor. Until the agent calls `acknowledge(id)` — only it can; sticky; implied by `declareExclusive` — a mandate is a claim *about* an address, not a commitment *by* it. Bonds refuse collateral for unacknowledged mandates and scores must ignore them (§11.1); otherwise naming a stranger's busy address collects a third party's bond and poisons the stranger's record. Acknowledged mandates are enumerable per agent (`mandateCountOf`, `mandateOf`).
- `authorityRef` is the hash of the authority proof for the delegation — typically a W3C Verifiable Credential chain (KYA-OS style). DELICTI does not implement delegation credentials; it anchors their hash and enforces the on-chain shape.
- **Monotonic narrowing.** A child mandate must satisfy `budget ≤ parent.budget`, `validFrom ≥ parent.validFrom`, `validUntil ≤ parent.validUntil`, **`sourceId = parent.sourceId` and `assetKey = parent.assetKey`**, and can only be committed by the parent's agent. Narrowing attenuates a quantity; a child in another asset is not a smaller share of its parent's budget, it is a different budget. `agentRef` and `bond` are the child's own. Capability semantics: authority can be attenuated, never amplified.
- **Liveness is transitive.** `isLive(M)` is true iff `M` and every ancestor are unrevoked and inside their windows. Killing a root kills the tree.
- **Revocation is sticky** and may be performed by any ancestor principal, or by the Bond on a successful challenge.

Non-goal: budgets across several assets under one mandate. One mandate, one unit — since v0.9, enforced rather than assumed.

## 4. Leaves and anchoring

A leaf is `(receiptHash, kind, sourceId, destinationAddressHash, amount, ref, claimedTimestamp, mandateId)`, hashed as `keccak256(abi.encode(leaf))`.

- `receiptHash` binds the leaf to the effector's own signed artifact, so an auditor can always walk back to witness 1 in its native format.
- `kind` ∈ {1 tool call, 2 EVM transaction, 3 external payment named by its payment reference (XRPL/BTC/DOGE), 4 external payment named by its transaction id (v0.12, §6.8)}.
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

All challenges are permissionless and require both witnesses. What a verdict takes is proportional to the size of the breach (§8.1); of that, the challenger is first made whole for its attestations and then earns 10 % of the rest, and the remainder goes **to the mandate's principal** — the harmed party of §1. Neither is pushed: both are credited and pulled with `claim()`, so a recipient that reverts on receive cannot make a mandate unslashable. The first verdict revokes the mandate; later verdicts can still take more, up to the bond as it stood at the first (§8.1). A leaf is consumed at most once **per mandate**.

Three invariants exist because their absence was exploitable, and each has a regression test:

- **The leaf must name the mandate being challenged** (`leaf.mandateId == mandateId`), in every challenge. Without it, and with a globally-keyed consumption set, anyone could anchor a copy of someone else's leaf under a throwaway mandate, slash themselves for 1 wei, and make that evidence permanently unusable against its real subject.
- **The remainder is not a parameter.** It used to be. A challenge carries its finished proofs in public calldata, so the whole transaction could be copied from the mempool with that one field changed and the bond returned in full to whoever posted it.
- **A nonexistence proof scoped to source addresses proves nothing here.** `ReferencedPaymentNonexistence` takes `checkSourceAddresses`/`sourceAddressesRoot`; scoped that way it truthfully says *those* addresses did not pay. A leaf carries no source address to compare against, so such a proof is refused rather than used to convict an agent who paid from elsewhere.
- **A cumulative budget only counts deeds inside the mandate's window.** Both budget challenges require the FDC-proven `timestamp` of each deed to fall in `[validFrom, validUntil]`.

### 6.1 False payment (`challengeFalsePayment`)
Kind-3 leaf in an anchored root + `ReferencedPaymentNonexistence` proof whose `(destinationAddressHash, amount, standardPaymentReference, sourceId)` equal the leaf's and whose proven window `[minimalBlockTimestamp, deadlineTimestamp]` contains `claimedTimestamp`, with the search having overflowed the deadline. *Executed live on Coston2.*

### 6.2 Budget overrun, native (`challengeBudgetOverrun`)
N kind-2 leaves, each in an anchored root, each with an `EVMTransaction` proof: tx hash equals `ref`, `sourceAddress` equals the mandated agent, `status == 1`, `value` and `receivingAddress` equal the leaf. Transaction hashes strictly increasing (dedup without storage). `Σ value > budget`. *Executed live on Coston2.*

### 6.3 Budget overrun, ERC-20 (same entry point since v0.9)
There is no separate function any more: `challengeBudgetOverrun` reads what a deed's value *is* from the mandate's `assetKey` (the commitment `kind` is still 3). As 6.2, but the deed is a `Transfer(agent → payee, value)` event emitted by the mandate's asset inside the proof (`listEvents = true`). This is the real x402 case: settlement is `transferWithAuthorization` on the token, native value is zero. *Executed live on Coston2 with genuine EIP-3009 settlements and genuine flario receipts.*

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

N FDC `EVMTransaction` proofs of deeds by the mandate's agent, inside the mandate's window, summing to more than the meter recorded. No anchored leaves are required: the meter is **witness 1 over the sequence** and the proofs are **witness 2 over the same sequence**, so §5 is not weakened — this is a class-A contradiction about a tally rather than about one deed. What is summed follows the mandate's `assetKey`: native transaction value, or `Transfer` events out of the agent emitted by that token (the x402 case). Each proof's `sourceId` must be the mandate's — until v0.9 this path, having no leaves to borrow one from, checked none.

**Scope is deliberately narrow.** The challenge runs only on a mandate that is both *metered* (§7.1) and *exclusive* (§6.4). Without exclusivity an outflow from the agent's address may be none of this mandate's business, and summing it would convict an honest agent — the same error as accepting a source-scoped nonexistence proof.

**The tally is read as of the deed, not as of the verdict (v0.10).** Until v0.10 the comparison was against `meter.spent()` at the moment of the reveal, and that was a hole rather than a detail: `note()` is the effector's own call, open for as long as the mandate lives, and the challenger has to publish the case ~13 minutes early — the attestation request carries the deeds' hashes in the clear and the reveal cannot land before the round finalises and `commitLead` has passed (§6.7). A colluding effector watched `FdcHub`, noted exactly what it had hidden, and the challenge died on `TallyAgrees`; commit–reveal could not help, because it protects who owns a reward, not whether a case exists. The verdict now compares against `SpendMeter.spentAt(mandateId, lastDeed + meterGrace)` — what the tally said when it should have said it. `meterGrace` is an immutable of the consequence contract (5 minutes in production): the meter is written in the same payment path that reads it, seconds around the deed, and the grace is an honest effector's slack, not a defendant's. §10 states the limit it leaves.

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

`kind` is one of the seven `Vault.KIND_*` constants (6 = `KIND_BUDGET_PAYMENT`, §6.8; 7 = `KIND_XRP_OUTFLOW`, §6.10). Kinds are unique across every judge of a Vault, so one gate serves them all (§8.2). `deedIds` is the receipt leaf hash for `KIND_FALSE_PAYMENT`, the deed's transaction hash for `KIND_UNANCHORED_DEED`, and the deeds' transaction hashes in the exact ascending order the challenge supplies them for the cumulative kinds. `commitChallenge(bytes32)` stores nothing but that hash and the timestamp, so the commitment leaks nothing at all.

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

**What the preimage binds, and what it deliberately does not.** `challenger` makes a commitment non-transferable; `mandateId` and `kind` stop a commitment for a cheap challenge type being spent on an expensive one; `deedsDigest` pins the exact ordered set, so a subset, a superset and a reordering are three different cases. The ERC-20 asset is not in the preimage and since v0.9 does not need to be: it is no longer a parameter at all.

**Replaying a commitment is a no-op.** Commitments travel in public calldata, so if a second submission could refresh the stored timestamp, a parasite unable to steal a challenge could still grief it past `commitLead` by replaying the victim's own commitment bytes. `commitChallenge` therefore keeps the earliest submission; replaying it early merely registers it on the victim's behalf, since the preimage names the only address that can spend it.

**The accusation of §6.4 is gated, `resolveAccusation` is not.** The accusation is what publishes the case and its accuser is who earns the 10 %, so it carries the same salt and the same `kind = 4` gate. Resolution stays open to anyone, because the reward follows `a.challenger` rather than the caller.

**Cost.** One extra transaction per challenge (~31k gas) and one round-timing read at reveal, plus the wait between committing and requesting. The wait is affordable because `COOLING_WINDOW` keeps the bond in place for 24 h.

### 6.8 Deeds on XRPL (`proveAgentRef`, `challengeBudgetOverrunPayment`) (v0.9)

Until v0.9 every cumulative challenge required `EVMTransaction` proofs and compared `sourceAddress` with `m.agent`, an EVM address. The only XRPL challenge was the negative one (§6.1): a payment that did *not* happen. A deed actually done on XRPL could not be summed against a budget at all.

**Who the agent is on XRPL.** A mandate on a non-EVM source carries `agentRef`: the FDC *standard address hash* of the agent's account — for XRPL, `keccak256` of the r-address string. Like `agent`, it is written by the principal, and `acknowledge` (§3) is the EVM key speaking; it shows nothing about who holds the XRPL key. `proveAgentRef(mandateId, proof)` closes that: an FDC `Payment` attestation of a successful payment *from* that account whose standard payment reference (one memo, 32 bytes) equals

```
agentRefChallenge(mandateId) = keccak256(abi.encode("DELICTI/agentRef", chainid, registry, mandateId))
```

Any amount, any destination; permissionless, because the proof speaks and not the caller. The reference binds chain, registry and mandate, so a confirmation cannot be replayed for another mandate or another deployment. **`post` refuses collateral for a mandate with an `agentRef` until this has been done** — otherwise a principal with a sock-puppet `agent` names a stranger's busy account, anchors leaves mirroring its ordinary payments, and is paid out of a third party's bond.

**The challenge.** N kind-3 leaves, each in an anchored root, each with a *positive* `Payment` proof: `sourceId` equals the mandate's and the leaf's; `sourceAddressHash == agentRef`; `status == 0`; `oneToOne`; `blockTimestamp` inside the mandate's window; `receivingAddressHash`, `receivedAmount` and `standardPaymentReference` equal the leaf's destination, amount and `ref`. Transaction ids strictly increasing. `Σ receivedAmount > budget`. Commitment kind `6`, deed ids = the transaction ids in that order.

**Receipts keyed by transaction (v0.12, kind 4).** x402 on XRPL, live on mainnet through facilitators such as t54, binds a payment to its request with the transaction's `InvoiceID` field (SHA-256 of the invoice id), not with a memo. No FDC payment type returns `InvoiceID`, and `Payment` reports a reference only for exactly one 32-byte memo. So an x402-on-XRPL receipt cannot be matched by reference. It can be matched by what the facilitator does return: the transaction hash. A kind-4 leaf carries that hash as `ref`, and the proof must be of that very transaction (`requestBody.transactionId == leaf.ref`) with the leaf's destination and amount. This is positive corroboration only. A payment that never happened cannot be proven absent without a reference (§6.1). The outflow challenge (§6.10) covers these payments with no receipt at all.

Three choices that are not obvious:

- **`receivedAmount` is summed, not `spentAmount`.** On XRPL `spentAmount` is `Amount + Fee`. The EVM paths sum `value` and ignore gas; a budget an agent can overrun by twelve drops of fee while delivering exactly what it was allowed to is a trap, not a limit. Fees are therefore *not* counted, and §10 says so.
- **Leaves must be pairwise distinct.** On the EVM paths the leaf's `ref` *is* the transaction hash, so strictly increasing hashes imply distinct leaves. Here `ref` is the payment reference, so two different transactions can match one receipt. One receipt accounts for one payment: the agent's claim is what it wrote down, and no more.
- **`oneToOne` is required.** Always true on XRPL. On the UTXO sources the same attestation type serves, a transaction can have several funders and "the source" is whichever input the requester pointed at; this path refuses those rather than reason about them. It is designed for, and tested against, XRPL semantics only.

**Executed on Coston2 (v0.10, mandate #6):** `AgentRefs.prove` and a five-payment challenge that took 25 % of the bond for a 25 % overrun — docs/DEPLOYMENTS.md.

**What this does not see, stated exactly.** The `Payment` attestation type covers XRPL transactions of type `Payment` and nothing else (FDC specification: *"The payment summary on XRPL is applicable only for transactions of type `Payment`"*). `OfferCreate`, `EscrowCreate`, `AMMDeposit`, `CheckCash`, and every issued-currency (IOU) movement — RLUSD included — are invisible to this challenge. An agent whose XRPL deeds are payments in XRP is covered; an agent that trades is not. See §6.9.

### 6.9 XRPL deeds that are not payments — the condition that was met

`BalanceDecreasingTransaction` (BDT) is the FDC type that covers the rest: for XRPL it attests that a given account's XRP balance fell in a given transaction, *or* that the account signed it, and reports the signed balance difference. Until v0.10 this section waited on one condition — *a BDT proof for a non-`Payment` XRPL transaction, obtained on Coston2 and verified by `FdcVerification`*. It has been met (2026-09-20, docs/DEPLOYMENTS.md), and what it showed is larger than the condition:

- **Any transaction type.** The verifier answers `VALID` for `OfferCreate` as it does for `Payment`; `Payment` and `XRPPayment` refuse the same `OfferCreate` (`NOT NATIVE PAYMENT TRANSACTION`).
- **Keyed by (transaction, account), not by "the agent's transactions".** An account's resting offer was consumed by another account's `OfferCreate`; BDT requested for *that other* transaction and the first account returned `spentAmount = 9,000,000` drops, and `verifyBalanceDecreasingTransaction` returned `true`. Requested for the taker, the same transaction returned a negative `spentAmount` (an inflow, net of its fee). An account whose balance did not move in the transaction is refused (`INVALID SOURCE ADDRESS`), so there is no conviction to be had from an unrelated transaction.
- **Fees follow the payer.** In the agent's own transaction `spentAmount` includes the fee; in someone else's it does not. Under XLS-75 delegation (checked on devnet; the amendment is not enabled on the testnet the FDC indexes) the owning `Account` pays the amount and the `Delegate` pays the fee — so attribution by balance goes to the account whose funds moved, and nothing the FDC returns names the delegate. A mandate that wants to judge an agent rather than its principal must give the agent its own XRPL account.

The earlier text of this section called the counterparty-taken offer a blind spot "no request keyed to the agent's own transactions will ever return". That was wrong: BDT requests are not keyed to the agent's own transactions. A watcher finds such a transaction with `account_tx`, which lists every transaction that touched the account, including the ones it did not sign.

**Consequence for the design (implemented in v0.11 as §6.10).** A cumulative challenge over BDT proofs covers *every* decrease of the agent's XRP balance — payments, offers crossed or taken later, escrows, AMM deposits, checks — and needs no receipt at all if the agent's XRPL account has declared exclusivity for the mandate. That declaration must come from the XRPL key (a memo statement proven like `AgentRefs`), not from the EVM key. The budget it enforces is **gross XRP outflow including the fees the agent paid**, a different quantity from §6.8's delivered amount, so a mandate has to say which one it promises. Still invisible: issued currencies (RLUSD included), because BDT measures the XRP balance only.

**XRPPayment (`0x08`).** Also verified against the verifier (not yet on-chain by this project): it returns the first memo's bytes whatever their length, and the destination tag, which `Payment` does not — `Payment` reports a reference only for exactly one memo of exactly 32 bytes. FAssets' direct minting consumes `IXRPPayment.Proof`, so this is the type Flare's own XRP rails now use.

### 6.10 Gross XRP outflow (`AgentRefs.proveExclusive`, `JudgeXrpl.fileXrpOutflow`) (v0.11; docket v0.12)

The challenge §6.9 called for. It needs no receipt at all, and it reaches a deed the agent did not sign.

**The measure is the mandate's.** A mandate on XRPL promises one of two quantities, and says which in `assetKey` without any change to the registry:

| `assetKey` | budget counts | judged by |
|---|---|---|
| `0` | XRP *delivered* by `Payment` transactions the agent wrote receipts for, fees excluded | §6.8 |
| `bytes32("XRP/outflow")` | gross XRP that *left* the account, by any transaction, **fees included** | §6.10 |

Each challenge refuses the other's mandates. The key has high bits set, so no EVM path can mistake it for a token (`Deeds.erc20Of`). §6.1 (a receipt for a payment that never existed) accepts both: the unit is drops either way, and a lie is a lie whichever quantity the budget promised.

**Exclusivity, from the XRPL key.** With no receipts, the only thing that makes an outflow the mandate's business is the account's own promise that, inside the window, *everything* leaving it is. `MandateRegistry.declareExclusive` is the EVM key speaking and does not count here. `AgentRefs.proveExclusive(mandateId, proof)` takes an FDC `Payment` proof of a successful payment from `agentRef` whose standard payment reference is

```
exclusiveFor(mandateId) = keccak256(abi.encode("DELICTI/exclusive", chainid, registry, mandateId))
```

It is sticky, permissionless (the proof speaks), and implies `proven` (§6.8). The statement payment itself leaves the account; inside the window it counts toward the outflow like anything else. Exempting it would be an exemption keyed on a memo, reusable by whoever holds the key.

**The challenge.** N `BalanceDecreasingTransaction` proofs. Each: `verifyBalanceDecreasingTransaction`; `sourceId` is the mandate's; `requestBody.sourceAddressIndicator == agentRef` **and** `responseBody.sourceAddressHash == agentRef`; `blockTimestamp` inside the window; transaction ids strictly increasing (one account, so one id is one deed). The outflow is the sum of **positive** `spentAmount`s. `outflow > budget` convicts; severity `outflow − budget`, in the budget bucket (§8.1: nested, high-water mark). Commitment kind `7`, deed ids = the transaction ids in that order.

**The docket (v0.12).** The FDC's XRP verifier remembers about 14 days. A case that had to prove every deed at once therefore died with its oldest deed: an agent that spends 90 % of a 30-day budget on day 1 and overruns on day 20 was out of reach. So the case is a file that grows. `fileXrpOutflow(mandateId, proofs, salt)` verifies each proof not yet on the mandate's docket, marks its transaction id as filed, and adds its outflow to `docket[mandateId]`:

- **Below the budget a filing only records.** No commitment is needed, no verdict follows, and nothing is paid. Anyone can keep a docket current while its deeds are still provable.
- **The filing that takes the docket past the budget is the conviction,** gated exactly like every other challenge: kind `7`, digest over every transaction id it supplies (ascending), the lowest voting round taken over the proofs it newly verified. Severity is `docket − budget`, nested (§8.1), so a later filing that raises the docket takes the difference.
- **Proofs already on the docket are skipped, not refused.** A copier who sees an honest crossing filing in the mempool can front-run part of it as a non-crossing filing, which needs no commitment. The honest transaction still lands: its digest is over what it supplied, the skipped proofs count through the docket, and the crossing, which is the only thing that pays, happens in its transaction. A filing that adds nothing reverts `NothingNew`.
- **The crossing filer is reimbursed for the attestations it supplied itself,** then earns 10 % of the rest. Filers below the budget are not paid (§10).

**Why only positive amounts.** A budget of outflow limits what left. XRP that came back does not un-spend what went: selling and buying back is two deeds, and netting would let a round trip hide what it lost to fees and spread.

**Why a conviction for a transaction the agent never signed is sound.** On XRPL nothing but an account's own keys can make its XRP balance fall. Every path by which someone else's transaction moves it — an offer taken, a check cashed, an escrow finished, a delegated transaction (XLS-75) — starts from an object the account created or a permission it granted; clawback exists only for issued currencies. The offer consumed in the counterparty's transaction is the agent's own standing order, executed later.

**What it covers:** Payment, OfferCreate (crossed at once or consumed later), escrow, AMM deposits, checks, AccountDelete, fees. **What it does not:** issued currencies, RLUSD included — BDT measures the XRP balance only. And the verifier's memory (§10).

**Rehearsed** on XRPL testnet on 2026-09-23 with `tools/xrpl_testnet.py` against the verifier's `prepareResponse`: an offer of 5 XRP consumed by the counterparty's `OfferCreate` returns `VALID`, `spentAmount = 5,000,000` for the offer's owner; the owner's own `OfferCreate` returns `10` (the fee). **Executed on Coston2 (v0.11, mandate #7, 2026-09-23, before the docket):** 3 + 3 + 3 XRP paid and a 5-XRP offer consumed in the counterparty's transaction, against a 12-XRP outflow budget; four BDT proofs; severity 2,000,030 drops, a sixth of the bond taken — docs/DEPLOYMENTS.md.

## 7. The effector-side brake (optional, recommended)

FDC finality is minutes; DELICTI is evidence after the fact. But the effector is the final common pathway and can read the chain in milliseconds. A DELICTI-aware effector therefore MAY, before producing the effect, check `MandateRegistry.isLive(mandateId)` and that the requesting agent *is* the mandated agent, and refuse otherwise. A deed with no mandate may be refused outright. flario implements this (`DELICTI_REGISTRY`, `DELICTI_REQUIRE_MANDATE`). The brake cannot see structuring — that remains the challenge's job — but it prevents the two cheapest failure modes: acting under a dead mandate and borrowing someone else's.

### 7.1 The meter — refusing structuring in real time

The brake above sees one call at a time, and every slice of a structuring attack is inside its own limit. It therefore cannot see the attack that §6.2 exists to punish. The gap is not patience, it is arithmetic: only a cumulative total can refuse the next slice.

`SpendMeter` closes it. The principal declares which effectors may keep the tally; each effector reads `wouldExceed(mandateId, amount)` before acting — an `eth_call`, so the payment path gains no attestation latency — and calls `note(mandateId, amount)` after the funds move. The fifth slice of a salami is refused in milliseconds instead of being slashed minutes later.

Three properties are deliberate:

- **The tally is a sequence of moments, not a number.** Every `note` appends a checkpoint `(timestamp, total)`, collapsed per second, and `spentAt(mandateId, ts)` answers what the tally said at any past moment — zero before the first note. §6.5 judges that, so nothing written after a case becomes public can erase it.
- **The meter records past the budget.** A meter that refuses to record an overrun is a meter that lies about one. The overrun must stay publicly readable — that is what makes `exceeded()` meaningful to the next counterparty.
- **The meter alone never slashes.** It is one witness. Consequence still requires the divergence in §6.5, which carries both.
- **Not writing is not a loophole, it is the division of labour.** The fast path protects against a constrained agent; the slow path convicts the effector that lied about what it did. An effector that skips the meter is choosing to be judged by the FDC instead.

The read is free and instant; the write is one `SSTORE`. Against an FDC round of ~90 seconds, this is the difference between prevention and compensation.

## 8. Bond economics (v0.1, deliberately simple)

- Anyone may post bond under a mandate: the agent, the operator, an insurer — provided the agent has acknowledged the mandate (§3), its `agentRef`, if any, has been proven (§6.8), and the mandate names this Bond. Bond is in the chain's native asset. **Deposits are recorded per depositor** and come back to whoever posted them, pro rata to what the verdicts left (§8.1).
- Sizing is a market question, not a protocol constant. A rational counterparty should require `bond ≥ budget × k` for some `k ≥ 1`; the protocol does not enforce it and exposes the ratio for anyone to read.
- Withdrawal only after the mandate is dead, no accusation against it is open, and a **cooling window of 24 h** measured from `deathTime()` — the earliest death in the mandate's ancestry — has elapsed. The window is not decoration: a challenge is not instant (an on-chain FDC request, a voting round, a DA fetch, then the challenge), the principal is an authority in `revoke()`, and the FDC request itself announces the coming challenge minutes ahead. Without the window `revoke(); withdraw();` in one transaction emptied the bond, and measuring from the moment of death rather than from the withdrawal attempt is what stops an early revocation from shortening the runway.
- Challenger reward: the cost of its attestations, then 10 % of the rest of what the verdict took (§8.1).

### 8.1 Proportional slashing (v0.9)

Until v0.9 any proven breach took the whole bond. A step function makes the deed's optimal size, conditional on breaching at all, the largest one available, and makes loss-given-default 100 %, which nobody will insure.

```
P(S) = clamp( base × S / budget ,  base × 10 % ,  base )
taken by a verdict = P(S_after) − (already taken)
```

`base` is the bond as it stood at the mandate's **first** verdict; `S` is the mandate's total proven severity, in the mandate's own unit (§3 pins it). Severity per verdict: the overrun (`spent − budget`); what the tally hid (`proven − recorded`); the amount of the payment that never existed; the value the unanchored deed moved.

- **The slope is not a protocol constant.** It is `bond / budget` — the collateralisation ratio `k` the market already chose. Each unit of overrun costs `k` units of bond, so with `k ≥ 1`, which is what §8 tells a counterparty to require, no overrun up to 100 % of the budget pays for itself. At `S ≥ budget` the penalty is the whole bond: you cannot lose more than what is there, and beyond that point the step function is back (§10).
- **The floor is 10 % of `base`.** Three of the five verdicts are about a *lie* — a payment that never existed, a deed nobody wrote down, a tally that under-reported — and a lie about a small amount is not a small lie. The floor is what that costs. It equals the challenger's whole reward under v0.8.
- **Severity accumulates; a verdict is not a shield.** "Slashed at most once" plus a proportional penalty would have been worse than what it replaced: an agent could convict itself of the smallest case it could assemble, pay the floor, and thereby protect the rest of the bond from the real case. Instead every verdict takes the *difference* between the penalty for the new total and what was already taken. How severities combine depends on whether two verdicts can be about the same thing: **nested** kinds (overrun, under-reported spend) keep a high-water mark — five deeds and then the same five plus a sixth is one overrun, not two; **additive** kinds (false payment, unanchored deed) sum, because `consumedLeaf` and `accused` guarantee each verdict is about a different receipt or transaction. A direct challenge that would take nothing reverts `NothingNew`; resolving an accusation never reverts.
- **The challenger is reimbursed for its attestations first.** Since FIP.16 an FDC request costs **20 FLR on mainnet** for every type this protocol uses (read from `FdcRequestFeeConfigurations` on 2026-09-19), so a five-deed case costs its challenger 100 FLR before gas. The Vault reads the current fee for the case's attestation type and source from Flare's own fee contract — the same way it reads the voting-round clock, and for the same reason: a constant would be wrong after the next governance vote — multiplies by the number of proofs supplied, and credits that (capped at what the verdict took) before the 10 %. Where the fee cannot be read the cost is zero and nothing reverts.
- **What that does and does not guarantee.** The reward covers the cost of proving a case *iff the verdict does*: `min-slash = 10 % × bond ≥ n × fee`. A 1,000-FLR bond is worth watching for a five-deed salami; a 100-FLR bond is not, and the chain says so before anyone spends a wei (`BondLens.penaltyFor`, `Vault.fdcCost`). The protocol cannot pay out more than a verdict takes, so it does not pretend to.
- **The remainder goes back to whoever posted it**, each depositor bearing the same fraction of every verdict (`deposit × bondOf / totalDeposits`, rounded down; the last one out gets exactly the rest). Until v0.9 `post` did not record the depositor and `withdraw` paid the principal, so a bond posted by an insurer was a free option for the agent's own side.

### 8.2 The Vault and its judges (v0.11)

Until v0.11 one contract held the collateral and verified every kind of evidence, and it ended 242 bytes under EIP-170: no further challenge type fitted. It is now split once:

- **`Vault`** holds every wei — bonds, credited proceeds, accusation stakes — so the protocol's balance is one invariant in one contract. It keeps the books of §8 and §8.1, the single commit–reveal gate of §6.7, and `verdict(...)`, the only function through which value leaves a bond.
- **Judges** hold no funds. Each verifies one family of evidence and, when it stands, calls `Vault.verdict` and `Vault.consumeCommitment` (passing its own caller as the challenger). `JudgeEvm`: §6.1, §6.2–6.3, §6.4, §6.5. `JudgeXrpl`: §6.8, §6.10. A judge keeps only the memory its judgement needs (`consumedLeaf`, `accused`, `accusations`).
- **The set of judges is fixed at the Vault's construction.** No admin, no setter, no upgrade. Judges are deployed first, at the address the Vault is about to have; the Vault's constructor refuses any judge that does not name it. A depositor can read `judges()` before posting and knows every piece of code that can ever take from its deposit — what EigenLayer calls *unique stake* (ELIP-002), here obtained by immutability rather than by allocation.
- **A new challenge type is a new Vault** over (the existing judges + the new one). Mandates already bonded stay with the Vault they name; new mandates name the new one in `Terms.bond`. Registry, anchor log and meter do not change — which is what `Mandate.bond` was added for in v0.9.

The split changed no rule: every one of the 146 tests of v0.10 passes against it with the same assertions.

### 8.3 The surety rule — a deposit compensates whom its depositor names (v0.12)

Until v0.12 the remainder of every verdict, after the challenger's share, went to the principal, whoever had posted the money. That made a third party's deposit the prize in the one fraud no challenge can see: principal and agent agree, the agent "overruns" by paying an address the principal controls, and the verdict hands the principal the insurer's collateral. With `k = bond / budget ≥ 1`, every unit of fake overrun was worth at least a unit of someone else's money.

The protocol cannot tell a principal from its sock puppet, so it stops pretending to know who was harmed. It asks the party that bears the risk. Each depositor names a **beneficiary** once per mandate, and the name cannot change:

| how | beneficiary |
|---|---|
| `post` by the principal or the agent | the principal (as before) |
| `post` by anyone else | **the depositor itself** |
| `postFor(mandateId, b)` | `b`: the venue it insures, a merchant, the principal if it means to, a burn address |

A verdict still takes the same fraction of every deposit (§8.1) and still pays the challenger first. What changes is where the rest of each deposit's share goes: to that deposit's beneficiary. Principal-side shares are credited at the verdict, as before. Every other share accrues per unit of deposit (`remainderPerUnit`, scaled 1e36) and is credited by `settle(mandateId, depositor)`, which is permissionless and idempotent; `withdraw` settles first. A verdict therefore costs the same gas however many depositors there are, and `unsettled[mandateId]` holds what has accrued and not been credited yet, a few wei of rounding included.

**What it achieves, exactly.** Colluders can take from an outsider who posted with `post` only that deposit's share of the challenger's reward: the attestation fees they really paid, plus `CHALLENGER_BPS` (10 %) of the rest. Under v0.11 it was all of it. Measured on the test case: a 30-FLR insurer deposit next to a 10-FLR principal deposit, a fake 100 % overrun, self-challenged by the principal. The principal nets **3 FLR** (10 % of the insurer's 30) instead of 30. The insurer can price that as a fixed, known leak. What it does not do: an outsider who names the principal, or a beneficiary the principal controls, has chosen to be exposed.

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
- A child's budget is bounded by its parent's, but the children of one parent are **not summed**: an agent with a budget of 10 can delegate ten children of 10 each. Each child answers for its own budget under its own bond; nothing on-chain makes the parent answer for the total.
- The penalty is proportional only up to the bond (§8.1). Past `overrun ≥ budget` every further unit is free, so the step function v0.9 removed at the bottom is still there at the top; the only thing that moves it is a larger bond. And the penalty's unit is the chain's native asset while the breach's unit is the mandate's: `bond / budget` is a ratio of two different things, and what it is worth is a market question the protocol does not answer.
- The challenger's reward covers the cost of proving a case only where the verdict does (§8.1). Small bonds are not watched, and nothing here makes them so.
- Reimbursement is `n × current fee`, not what the challenger paid: a fee change between request and verdict, or proofs bought at a testnet's price, make the two differ. Supplying superfluous proofs moves value from the principal's share to the challenger's only by what those proofs cost to obtain.
- An accusation freezes withdrawal of a dead mandate's bond for one response window (§6.4). Each costs its accuser a stake, an attestation, and a real unanchored deed to point at, and an answered one forfeits the stake — but for that window the depositors wait.
- Under a *delivered* XRPL budget (§6.8) transaction fees are not summed, and an agent can burn fees without limit. Under an *outflow* budget (§6.10) they are, and it cannot.
- **XRPL deeds must be proven within ~14 days of happening.** The FDC's XRP verifier indexes about 15 days. Under an outflow budget the docket (§6.10, v0.12) carries a deed once it is filed, so long windows are enforceable if somebody keeps filing. §6.8's delivered-payment challenge has no docket yet, and over a window longer than `PROOF_HORIZON` a late overrun may be unprovable there (`JudgeXrpl.fullyEnforceable`).
- **Principal–agent collusion still takes the challenger's reward** from an outsider's deposit (§8.3): 10 % of its share of a verdict plus the fees actually paid, down from all of it before v0.12. An outsider who names the principal, or a beneficiary the principal controls, as its deposit's beneficiary is exposed to the whole of it, by its own choice.
- Keeping a docket below the budget (§6.10) is unpaid. Filers pay for attestations that are reimbursed only if their filing is the one that crosses. Until a market for corroboration pays for it, a long mandate is only as enforceable as somebody's willingness to file for it inside the verifier's ~14 days.
- An XRPL account may declare exclusivity for two overlapping mandates. Each is then judged on the same outflow; the account made two promises it cannot both keep, and that is its doing.
- An effector that is merely late — writing the deed into the tally within `meterGrace` of it (§6.5) — is not convicted of under-reporting, and neither is one colluding with the agent that manages to write inside that window. The grace is two orders of magnitude above the honest write's latency and well below the earliest possible reveal, so the window is real but narrow; making it zero would convict effectors for a slow block.
- `CorroborationLog` counts each deed once per agent (v0.10), so the same transaction cannot be entered into an agent's record under several mandates. It still counts what somebody chose to prove. It is a floor on corroboration, never the rate: an agent pays for the attestations it wants on its record and not for the others, and nothing obliges anyone to corroborate anything. It also cannot tell a deed from a wash: an agent can pay dust to itself and corroborate it all day, which is why §11 says to weigh by value — and a score should weigh by counterparty as well.
- `acknowledge` shows that the EVM key accepted the mandate, and `AgentRefs.prove` that an XRPL account made one payment with one memo. Neither shows that the two are the same party, that either is the model that will act, or that the account was not lent for the occasion.
- A Vault's judges are fixed for ever (§8.2). A bug in a judge is fixed by a new Vault, and deposits already posted stay exposed to the old judge until they are withdrawn. Judges are trusted to name their own caller as the challenger; they are code, fixed at construction, and that is the whole of their privilege.
- `leavesURI` is not verified, pinned or guaranteed to resolve. The root is the commitment; the URI is a courtesy.
- Each mandate names its own consequence contract, and the registry does not vet it. A Bond that is not this code can behave in any way at all; `Mandate.bond` tells a counterparty *which* code to read, not that it is sound.
- Silence is challengeable only for mandates whose agent declared exclusivity (§6.4). An agent that never makes that promise is still judged on what it anchors — the promise is the price of being trusted, not a protocol guarantee.

## 11. Metrics this makes possible

Because every judged deed has a class, an agent, a mandate, and a verdict, three safety-relevant quantities become measurable across operators without trusting any of them:

- **coverage rate** — share of an agent's FDC-observable deeds that were anchored at all. Under an exclusivity declaration (§6.4) the denominator is public and outside the agent's control: every transaction from that address inside the window. This is the metric that matters first, because the two below are conditional on it;
- **corroboration rate** — share of an agent's claimed deeds that reach class A;
- **contradiction rate** — share of anchored receipts proven false or overrun. Weigh it by value, not by count: leaves are cheap, and an agent with one contradiction can otherwise dilute it with ten thousand dust deeds.

These are properties of *deeds*, not of models, and they can be computed by anyone from public data. That is the point.

### 11.1 What an indexer reads, and from where (v0.9)

The score is the next floor, and it must be computable from **logs and current state alone** — no archive node, no re-decoding of challenge calldata, no change to the core. v0.9 went through the three metrics asking what was missing, and added it while adding was free.

| Needed for | Source | Note |
|---|---|---|
| which mandates count at all | `MandateAcknowledged`, `MandateCommitted`, `MandateTerms` | **Ignore unacknowledged mandates.** Anyone can commit a mandate naming any address and anchor under it as principal; only acknowledgement makes the record the agent's. |
| an agent's *complete* record, on-chain | `MandateRegistry.mandateCountOf / mandateOf` | appended at acknowledgement by the agent, so an outsider cannot bury it and the agent cannot omit from it. A contract cannot read events; this is what lets a risk market check completeness. |
| coverage — numerator | `Anchored(…, receiptCount, by, anchoredAt, leavesURI)`, `AnchorLog.receiptCountOf` | the chain holds roots; counting leaves against deeds needs the leaves. `leavesURI` says where they are. **Leaves nobody can fetch count for nothing** — they can still convict. `by` distinguishes what the agent wrote down from what its principal did. |
| coverage — denominator | the source chain itself, plus `ExclusiveDeclared` | outside DELICTI by construction |
| corroboration | `DeedCorroborated` from `CorroborationLog`; `countOf`, `valueOf`, `countOfAgent` | the good case used to leave no trace on-chain at all — this metric had a definition and no data. Same definition of agreement as the Bond's (`Deeds`). |
| contradiction, by value | `Verdict(mandateId, challenger, kind, severity, severityTotal, budget, taken, reward, slashedTotal)`; `DeedJudged(mandateId, kind, deedId, value)` per deed summed; `FalsePaymentProven`, `UnanchoredDeedProven`, `UnderReportedSpendProven`, `BudgetOverrunProven` | one shape for every verdict; per-deed events so that "which deeds" is not only in calldata |
| contradiction, on-chain | `Vault.verdictsAgainst(agent)`, `Vault.takenFrom(agent)`, `severityOf`, `slashedAmount` | this Vault's history only |
| accusations, both outcomes | `DeedAccused`, `AccusationAnswered`, `UnanchoredDeedProven`; `openAccusations` | an answered accusation is evidence *for* the agent |
| who is exposed | `BondPosted(by)`, `BondWithdrawn(by)`, `depositOf` | |

`CorroborationLog`, `AgentRefs` and `BondLens` hold no funds and have no privileges. They are listed here as part of the surface, but they are *outside* the core on purpose: each could have been deployed a year after it, and a better one still can be.

## 12. Compatibility

- **Receipts:** flario `flario-receipt/2` (implemented); KYA-OS `_meta` proofs and ACTA/ASQAV receipts (adapter specified: `policy_digest`/`previousReceiptHash` map naturally; `mandate_ref` proposed as an extension claim).
- **Identity/reputation:** ERC-8004 — DELICTI verdicts are a natural input to a Reputation Registry: reputation from corroborated deeds, not declarations.
- **Chains:** any EVM with an FDC-equivalent second witness could host DELICTI; today only Flare has one enshrined in protocol, which is the entire reason it is built there.

## 13. Roadmap: DELICTI verdicts as native XRPL credentials (specified, not implemented)

*No code exists for this section. It fixes the mechanism and its trust assumptions so that the floors below it are built to carry it.*

**The idea.** XRPL now has an on-ledger permission system, live on mainnet: **Credentials** (XLS-70) — an issuer account writes a typed credential about a subject account (`CredentialCreate`: `Subject`, `CredentialType`, optional `Expiration`, `URI`), the subject accepts it (`CredentialAccept`), either can delete it (`CredentialDelete`); and **Permissioned Domains** (XLS-80) — a domain is a list of accepted `(Issuer, CredentialType)` pairs, and venues such as the permissioned DEX admit only accounts holding one. Today every such credential means *"an issuer vouches"* — KYC by declaration. DELICTI can make one mean *"this account has been acting under a bonded mandate, and no verdict stands against it"* — compliance by proof. The subject is exactly the account `agentRef` names, and `AgentRefs` already proves its holder accepted the mandate.

**Mechanism.**

1. *Eligibility is a pure function of public state on Flare:* mandate acknowledged; `AgentRefs.proven`; live; `bondOf ≥` a published floor; `slashed == false`; no open accusation; optionally minimum `CorroborationLog.valueOf` and mandate age. An `Issuer` contract evaluates it and emits a signing instruction — issue, or delete.
2. *The issuer account on XRPL is a Protocol Managed Wallet.* Its key is generated and held inside Flare Confidential Compute enclaves and signs only what a Flare contract instructed; no operator, including this project, holds it. The PMW submits `CredentialCreate(Subject = the agent's r-address, CredentialType = "DELICTI/bonded/v1", Expiration = min(validUntil, now + TTL), URI → the mandate on Flare)`.
3. *The agent accepts* with `CredentialAccept`, from the same key that made the `AgentRefs` payment.
4. *Revocation is the point.* Any `Verdict`, revocation, expiry, or the bond falling under the floor makes the account ineligible; anyone may then call `revoke(mandateId)` on the `Issuer`, which instructs the PMW to `CredentialDelete`. Short `Expiration` with renewal bounds the damage when the revocation path is slow: a credential the protocol cannot delete still dies on its own.
5. *Closing the loop (optional).* An FDC attestation that the credential object exists, or no longer does, lets Flare-side contracts act on the XRPL-side fact.
6. *Domains* are created by venues, not by DELICTI: a venue lists `(DELICTI issuer, "DELICTI/bonded/v1")` among its accepted credentials.

**What this construction trusts, beyond §2.**

- *Flare Confidential Compute*: the TEE hardware vendors and their attestation, Flare's enclave code, and the honesty threshold of whoever operates the enclaves. This is a **new and larger** assumption than §2's "consensus plus FDC", and it is the price of writing to XRPL instead of only reading it. Everything in §§3–8 remains valid without it.
- *XRPL amendments*: Credentials and Permissioned Domains staying enabled with their present semantics.
- *The eligibility function*: it is code, it will have thresholds, and those are judgement calls. They must be immutable per credential type (`…/v1`, `…/v2`), never tunable in place — otherwise the issuer is an admin key with extra steps.
- *Liveness of revocation*: between a verdict on Flare and `CredentialDelete` on XRPL the agent holds a credential it no longer merits. The window is FDC latency (the verdict itself) plus FCC signing plus XRPL close; the expiry is the backstop.

**What the credential does NOT prove** — and venues must be told so:

- Not identity, not KYC, not sanctions screening. It says nothing about who controls the account, only that whoever does has collateral at risk under a public mandate.
- Not good behaviour in general: only that no verdict stands under *this* mandate, for deeds the FDC can see. On XRPL that means **`Payment` transactions in XRP** under a delivered budget (§6.8), and **every movement of XRP** under an outflow budget (§6.10); issued currencies — RLUSD included — stay outside DELICTI's sight, credential or not.
- Not that the agent was watched. Absence of a verdict is absence of a *successful challenge*: nobody may have looked, or the bond may have been too small to be worth watching (§8.1). A venue should read `bondOf`, the mandate's age and `CorroborationLog` alongside the credential, not instead of them.
- Not that a delegated transaction belongs to the agent: under XLS-75 who FDC attributes a delegated transaction to is unestablished (§6.9).
- Not solvency. The bond is in FLR on Flare and the budget is in XRP on XRPL; `bond / budget` is a ratio of two different things.

**Condition for moving this out of the roadmap:** FCC/PMW generally available on Coston2 with a documented instruction interface, and one credential issued *and deleted* end to end on XRPL testnet from a Flare-side verdict. Until both, this section describes an intention.

---

*Changes to this document bump the version. Anything implemented but not specified here is a bug in the document; anything specified but not implemented is marked roadmap.*
