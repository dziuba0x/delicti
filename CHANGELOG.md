# Changelog

## v0.9.0 — unreleased — what the budget is made of, and who agreed to it

Written for the three floors that are meant to stand on this one — a public score, a risk market, credentials issued on XRPL — and for the rule that none of them may require redeploying the core.

### The mandate now says what its budget is made of

SPEC §10 admitted that the ERC-20 `asset` and the `sourceId` lived only in the off-chain envelope. That made a bond posted by anyone other than the principal worth less than it looked: an insurer could read *how much* a mandate allowed and not *of what*, and on the ERC-20 paths the challenger chose the asset in calldata.

- **`Mandate.sourceId`, `Mandate.assetKey`, `Mandate.agentRef`** — the FDC source the deeds happen on, what `budget` counts (`0` = that source's native asset; on an EVM source, the ERC-20 address left-padded), and the agent's identity on a non-EVM source (FDC standard address hash). Passed to `commit` as one `Terms` struct, appended to the *end* of `Mandate` so a reader compiled against the old nine-field tuple — flario's mandate gate — keeps decoding the prefix it knows.
- **Every challenge reads them from the mandate.** `challengeBudgetOverrunERC20` and `challengeUnderReportedSpend` lost their `asset` parameter; the native paths refuse a token mandate and the token path refuses a native one (`WrongAsset`), before any proof is verified. Every path compares the proof's `sourceId` with the mandate's (`WrongSource`).
- **That last check closed a hole nobody had written down.** `challengeUnderReportedSpend` has no leaves, so it had nothing to borrow a `sourceId` from, and it checked none. One key is one address on every EVM chain the FDC attests: a transfer by the agent on Sepolia would have been summed against a Coston2 tally that never promised to cover it. `accuseUnanchoredDeed` had the same gap — exclusivity is a promise about one address on one chain.
- **Monotonic narrowing covers the unit.** A child must keep its parent's `sourceId` and `assetKey` (`ChangesParentAsset`). Narrowing attenuates a quantity; a child in another asset is not a smaller share of the parent's budget, it is a different budget, and `budget <= parent.budget` would be comparing drops with wei. `agentRef` and `bond` are the child's own: they describe the child, not the unit.

### The agent has to say yes (`acknowledge`)

Not on the list for this release, and the reason pinning the asset was not enough. A principal writes the agent's address unilaterally, and principals may anchor. So a principal could name a stranger's busy address as "agent", anchor receipts for its ordinary transfers, and collect whatever a third party had posted as bond — and, once a public score exists, poison that stranger's contradiction rate for the price of gas. `MandateRegistry.acknowledge(id)` is callable only by the agent and is sticky; `declareExclusive` implies it; **`Bond.post` refuses collateral for a mandate its agent has not acknowledged** (`NotAcknowledged`). A score should ignore unacknowledged mandates for the same reason.

### The registry has no deployer (`Terms.bond`)

Also not on the list, and the precondition for "no redeploy of the core". Until v0.8 the registry had one set-once `bond`, chosen by whoever deployed it. Every new challenge type therefore needed a new Bond, a new Bond needed a new registry, and a new registry orphaned every mandate ever committed — this release would have been the sixth time. Each mandate now names its own consequence contract. That contract can revoke that mandate and nothing else, which is a power its principal already holds, so nothing is delegated that was not already there. `setBond`, the global `bond` and the deployer are gone: the registry has no privileged key at all. `Bond.post` refuses a mandate that names a different Bond (`NotThisBond`), because collateral there could never be slashed — `revokeByBond` would revert every time — and would only *look* like a bond to a counterparty reading the chain.

96 tests (was 82).

## v0.8.0 — 2026-09-14 — the reward belongs to whoever looked

Every challenge so far paid its 10 % to whoever landed the transaction. That is not the same as paying whoever found the violation, and the difference is not academic: a challenge cannot be assembled in secret, because `FdcHub.requestAttestation` is an on-chain call carrying the deed's transaction hash or payment reference in the clear, minutes ahead of the reveal. A parasite watching `FdcHub` therefore learns of every case before it can be filed, copies the finished calldata out of the mempool and outbids the gas — paying for no monitoring and no analysis. The honest watcher pays for both. The equilibrium number of real watchers is zero, and a consequence layer nobody watches is theatre.

- **`Bond.commitChallenge(bytes32)`** — a bare hash, leaking nothing: `keccak256(abi.encode(challenger, mandateId, kind, deedsDigest, salt))`. All five challenge entry points and the §6.4 accusation take a `salt` and spend that commitment once. `resolveAccusation` stays open to anyone, because the reward follows the accuser, not the caller.
- **The rule is about rounds, not about the request.** The commitment must predate the start of the FDC voting round that produced the evidence — the **lowest** round among the supplied proofs, so that one freshly requested proof cannot launder a commitment made after the rest of the case was public.
- **`commitLead` (10 min, immutable).** The obvious rule — commitment older than the round — looks sufficient and is not: a parasite that sees the victim's request land in round R commits inside R, requests its own attestation in R+1, and reveals against that, honestly. It then wins whenever the honest challenger's proof is the slow one, and measured Coston2 DA latency spans ~100–500 s, so that race is real. A lead wider than the latency spread makes the defence deterministic instead of a coin flip.
- **`COMMIT_TTL` (1 h, constant).** From the adversarial audit, and the more important half. Without an upper bound a commitment is a free permanent option: on three of the five paths the deed set is public and guessable — one transaction hash, one published leaf, or the canonical "every deed so far, ascending" — so anyone could pre-commit to cases nobody has found yet at one `SSTORE` each and copy a reveal months later. The TTL turns that option into rent. Constant rather than a constructor argument, because a deployer could otherwise set it just above `commitLead` and make honest challenges against its own agents impossible to time.
- **A voting round cannot have begun in the future.** Also from the audit. `roundStartTs` multiplies a round number that may be years old by the epoch length Flare reports *now*; if Flare lengthens the epoch or rebases `firstVotingRoundStartTs`, that product lands in the future and every commitment clears the lead test — the gate would stop existing, silently, with nothing reverting to say so. One comparison, fail-closed.
- **Replaying a commitment is a no-op.** `commitChallenge` keeps the earliest submission. Commitments are public calldata, so a refreshable timestamp would let a parasite grief a challenge it could not steal by replaying the victim's own bytes just before the reveal.
- **The voting-round clock is read live**, via `ContractRegistry.getProtocolsV2()` — `firstVotingRoundStartTs` / `votingEpochDurationSeconds` are declared on `ProtocolsV2Interface`, not on `IFlareSystemsManager`. Never hardcoded. A constructor override exists for unit tests, the same shape as `_fdcOverride`; the live resolution is asserted against Coston2 on a fork.
- `answerAccusation` now pins `leaf.kind`, the one place a leaf was read without it. No exploit followed from the gap — the agent controls its own leaves either way — but an invariant present in one path and absent in its twin is how this repo has grown holes before.
- **Scripts:** `scripts/lib/commit.sh`, sourced by all six challenge scripts, which now run deeds → anchors → commit → wait out `commitLead` → request attestations → reveal. The digest and the commitment preimage are computed by the contract's own pure helpers (`deedsDigest`, `commitmentFor`) rather than re-encoded in shell, and the salt comes from `openssl rand`, not `$RANDOM`. `scripts/structuring.sh SNIPE=1` additionally submits the copied challenge with a late commitment and leaves the refusal on-chain as a reverted transaction — that refusal is the release.
- SPEC v0.5: new §6.7 with the rule and the reasoning for each clause; §10 rewritten to state the two limits this does **not** close — a squatter paying rent forever can still hold a live commitment (the defence is economic, not cryptographic), and the agent, having the earliest knowledge of its own violation, can self-slash ahead of a real watcher.
- 81 tests (was 56). Slither at medium+: the same two false-positive classes as v0.7, nothing new.
- **Executed on Coston2.** Honest reveal [`0xdbf70a53…9a7628`](https://coston2-explorer.flare.network/tx/0xdbf70a53b738e793b558b9f09a412f1727ec3c49a8899cd6f6700ab7fa9a7628) (358,026 gas) → slashed; the copier's identical calldata with a commitment made 185 s after the evidence round opened, [`0xab529327…4da115`](https://coston2-explorer.flare.network/tx/0xab52932730be8db7a8da1ec37396e5124f2033ec0e92f0baf98388c5464da115), reverted with `0xc9e9ac51` = `CommittedTooLate()` after burning 271,152 gas on proof verification. Deployment and the full reading are in the README.

## v0.7.0 — 2026-09-14 — the fast half

Everything in DELICTI so far was evidence after the fact. An FDC attestation takes ~90 s per voting round and minutes end to end, so a structuring attack **succeeded** and was only punished later; the §7 brake could not see it, because it judges one call at a time and every slice is inside its own limit. The gap was never patience — it was arithmetic. Only a cumulative total can refuse the next slice.

- **`SpendMeter.sol`** — the running tally an effector keeps against a mandate's budget. `wouldExceed()` / `headroom()` are `eth_call`s read before the deed, so the payment path gains no attestation latency; `note()` is one `SSTORE` after it. The principal declares which effectors may write (`declareEffector`), and a dead mandate cannot accrue spend. The meter deliberately **records past the budget** — refusing to record an overrun is a way of lying about it — and deliberately **never slashes on its own**: it is one witness (§5).
- **`Bond.challengeUnderReportedSpend`** — an effector can defeat the meter by not writing, and this is what makes that expensive. FDC proofs summing to more than the tally admits convict, with no anchored leaves required: the meter is witness 1 over the *sequence*, the proofs are witness 2 over the same sequence. Runs only on mandates that are both metered and exclusive (§6.4), because without exclusivity an outflow from the agent may be none of this mandate's business.
- `scripts/spend-meter.sh` — `MODE=brake` (four slices fit, the fifth is refused by one `eth_call`, no FDC involved) and `MODE=underreport` (two of five settlements recorded, FDC proves five, slash).
- SPEC v0.4: §7.1 (the meter), §6.5 (under-reported spend), and §10 updated to say plainly that real-time prevention now exists but only where an effector keeps the tally.
- 56 tests (was 42). Slither at medium+: three findings, all false positives.

**Live on Coston2 (2026-09-14).** Deployment: `MandateRegistry` `0x3b53a646E5450F4b525e30F2aA59be95AF77657b`, `AnchorLog` `0xd5EECFAFE96fE9eec7E126F4B318DB139c9396bf`, `SpendMeter` `0xD64465B95A1E83DC292AcB1e5b66dD416ADeA55C`, `Bond` `0x3557Ae63bC3868165E605685b45506116E2CE1e6`.

- Structuring refused in real time (mandate #1): four slices fit, the fifth rejected by `wouldExceed` — no FDC round, no transaction, bond untouched.
- `challengeUnderReportedSpend` (mandate #2): tally said 0.02, the FDC proved 0.05 → slash `0x53664b9f186353821ae8be87e75279d0de6619fd3326f3751974a616fb0b20ff` (280,836 gas).
- The §6.4 accusation loop, finally demonstrated in both directions on the same deployment: silence → slash `0x432ca347481f7a279e377b648c5ad2b776f871b38ed0068b515383d63e72490b` (118,872 gas, mandate #5); answered in time → dismissed, accuser's stake forfeited, `0x1bbcaf3f0a371facd17b8922d522e59917120f0055a2cca6954c3d38ba6ae48b` (76,075 gas, mandate #4).

## Unreleased (v0.6.0-dev) — the deed nobody wrote down

Until now every challenge started from an anchored leaf, so the bond punished only agents that had already confessed: **not anchoring was free**, and the dominant strategy was to anchor the easy deeds and stay quiet about the rest. SPEC §6.4 called that roadmap; it was load-bearing.

- **`MandateRegistry.declareExclusive(id)`** — the agent, and only the agent, promises that inside this mandate's window its address acts under this mandate alone, so every FDC-observable deed from it is expected to be anchored. Sticky, like revocation.
- **`Bond.accuseUnanchoredDeed` / `answerAccusation` / `resolveAccusation`** — proving a negative on-chain would need a non-inclusion proof over every episode, so the burden is inverted: the challenger names the deed with an FDC proof and posts a 0.1 FLR stake, the agent has `responseWindow` to produce the leaf, and silence resolves against it. Anyone may answer (the evidence speaks, not the speaker) and anyone may resolve once the window closes — the challenger's 10 % follows the accusation, not the caller.
- Retroactive anchoring is not a defence: the answering episode must have been anchored by `deedTime + anchorGrace`. A false accusation forfeits its stake to the principal. Deeds still inside the grace cannot be accused at all.
- `anchorGrace` (1 h) and `responseWindow` (24 h) are constructor immutables so a testnet deployment can show the whole loop without waiting out production timers.
- `scripts/unanchored-deed.sh` — live end-to-end, `MODE=silence` (accuse → window closes → slash) or `MODE=answer` (accuse → receipt produced → dismissed).
- SPEC v0.3: §6.4 promoted from roadmap to implemented; §11 puts **coverage rate** first, since corroboration and contradiction rates are conditional on a denominator the agent used to choose for itself.
- 42 tests pass (was 31). Slither run over `src/` at medium+ severity: five findings, all false positives (Solidity zero-initialises locals; the `revokedAt == 0` sentinel is deliberate).

**Deployed on Coston2 (2026-09-11), live run pending.** `MandateRegistry` `0x401C07e28db3464ab2013C36Babf4701cD8dC6bd`, `AnchorLog` `0x2FbcF31FC3a66BbfbA30743aab932d7AE78FDf56`, `Bond` `0xc42A87F8E005B231819b16E46B119b90228b86A6` — a testnet deployment, so `responseWindow = 600 s` and `anchorGrace = 300 s` rather than the production 24 h / 1 h. `setBond` wired in the same script.

The accusation loop itself is **not yet demonstrated on-chain**: at the time of writing the FDC data-availability layer kept answering `attestation request not found` for the deed's voting round, well past the usual 2–4 minutes, with Coston2 gas sitting at 1500–2000 gwei instead of the usual ~25. That is a network condition, not a contract result, and nothing is claimed until the run completes.

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
