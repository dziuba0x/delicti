# Changelog

## v0.15.0 — 2026-09-24 — v0.14, reviewed adversarially and fixed before it shipped

Before v0.14 left the sandbox, a fresh adversarial review was run against it: a separate agent with the diff, the sources, the SPEC and permission to write proof-of-concept tests. It found one high, two medium and one low issue, and confirmed three of them with working exploits. All are fixed here. v0.14 stays on Coston2 for mandate #13, is superseded, and was never pushed as a release on its own.

- **HIGH: a copier could take every watch-pool stipend.** Recordings below the budget need no commitment, and an FDC proof works for whoever submits it. A copier lifts a watcher's proofs from the mempool or the DA layer, files first, and the watcher's own filing reverts `NothingNew`. **Fix:** the stipend now goes to whoever *paid for the attestation*. `Vault.requestAttestation(request)` forwards the fee to FdcHub and records the first payer under a key the judge rebuilds from the proof, `keccak256(abi.encode(type, source, keccak256(abi.encode(requestBody))))`. `test/FdcKey.t.sol` pins the request-side and proof-side keys together on **real** verifier requests and DA proofs from 24.09. Copying a filing now only pays the gas to deliver someone else's stipends. Because the key is claimed on payment, a second watcher can read `requesterOf` before buying the same attestation, which removes the attestation-fee race §10 used to list.
- **MEDIUM: the principal could drain the agent's watch funding.** The agent funds, the principal raises `perDeed` to the whole pool, and a sock puppet files one deed. **Fix:** only the principal funds, and only the principal is refunded.
- **MEDIUM/LOW: one act split into many paid deeds** (an XRPL offer consumed in many fills). This is bounded by the terms, at most `perDeed / minValue` per unit of value, and each piece costs its requester an attestation fee. It is documented in SPEC §8.4, with guidance on setting the terms. It is not a code change.
- **LOW: a crossing could spend its commitment and take nothing.** This happened when a proportional increase was still under the 10 % floor already taken. **Fix:** docket judges ask `Vault.wouldTake` (the verdict's own arithmetic, read-only) and record without spending the commitment when it is zero. That check also subsumes v0.14's high-water check. Verdicts are strict again.
- **LOW: the pool could close while deeds were still provable.** **Fix:** it closes once no bond is left, or `WATCH_TAIL` (14 days) after the cooling window.
- Tests: `test/WatchPool.t.sol` was rewritten (17 tests: copier, first payer, bought elsewhere, zero value, minimum, empty pool, crossing paid twice, funding, terms, both closing paths, and wouldTake keeping the commitment). The §6.8 stipend is tested in `Xrpl.t.sol`, and FdcKey has 2 tests. The invariant handler buys attestations through the Vault (etched FdcHub stub) and runs a paid watcher; a canary confirms stipends are reached. Campaign: 15 × 1,500 × 200, 0 failures. **227 Solidity tests.**
- **Deployed** (production timers): `Vault` `0xB15f5041…9a24aF`, `JudgeEvm` `0x463042fb…4d42cFf2`, `JudgeXrpl` `0x9201272e…9d765940`, `BondLens` `0x960A0e68…89D3Bf3D`.
- **Live, mandate #14 (XRPL):** the watcher paid for four attestations through the Vault, and a **copier filed the watcher's proofs first**: [`0xc7c8620e…`](https://coston2-explorer.flare.network/tx/0xc7c8620ef0813c946511fea5cc4f48b59aef510055a123d26dbcb86fd4374283). Stipends: watcher +0.15 C2FLR, copier **+0**. `sdk/examples/copier-demo.ts` reproduces it. The sentinel then convicted #14 with every attestation bought through the Vault ([`0xb9e2d89a…`](https://coston2-explorer.flare.network/tx/0xb9e2d89a67b80fb89c8ddce06741fe55effb1b2ea0895fde51fe0eca31260896), `bondOf` 1 → 0.5832).
- SDK: watchers buy attestations through the Vault on v0.15+ (`paidRequests` feature), and `network.history` carries v0.14. The `selfWatched` facet is gone, because the agent can no longer fund.

## v0.14.0 — 2026-09-24 — who watches, and why they would · SPEC v1.0 frozen

Security in DELICTI needs one honest party to bring a case. This release is about that party: who it is, what it is paid, and how it sees. docs/research/watchers.md compares seven earlier watcher layers (Lightning watchtowers, Forta, keeper networks, UMA/Kleros, rollup challengers, liquidation bots, contributor-split oracles) and records what each learned the hard way. Every decision below cites that note.

### The watch pool (`Vault`, SPEC §8.4) — as first built; see v0.15 above for what an adversarial review changed

- A crossing bounty pays watchers nothing while the agent behaves: the watchtower *deterrence paradox*. Now the principal, and the agent if it wants to show confidence, can fund a pool, and the principal sets `perDeed` and `minValue`. Every docket judge pays the filer of each **new, value-moving** deed from it, on recordings and crossings alike.
- **Only principal and agent can fund.** An outsider's money in a pool whose rate the principal sets would be a prize for collusion (agent moves value to itself, sock puppet files, rate goes up). This was found in review before any deploy.
- **Terms only improve** for watchers once set. **Zero-value deeds earn nothing**: `transferFrom(agent, x, 0)` succeeds for anyone on a standard token, and anyone can send XRP *to* the agent. That also corrected §6.11's soundness text, which had called every `Transfer` out of the agent "the agent's act".
- Refund is pro rata once the mandate is dead past the cooling window, and the first refund closes the pool. `watchPool` is part of the Vault's balance invariant.
- 12 unit tests (`test/WatchPool.t.sol`); the invariant handler funds, sets terms and refunds; `refundExceededFunding` ghost.

### A docket that could not record (fixed in all three judges)

- Found by the new §6.8 invariant track. Once another path had convicted a mandate (the one-shot §6.8 challenge, or a receipted §6.3 case), a docket filing that went past the budget but not past that verdict's high-water mark reached `Vault.verdict`, which refused it `NothingNew`. The docket then could not record at all until a single filing outran the mark, and on XRPL a deed not filed within ~14 days is lost for ever.
- Now such a filing is a recording: no commitment, no reward. The crossing verdict is non-strict, so a crossing after the whole base is taken still records. `test_paymentDocketStillRecordsBelowAnotherPathsVerdict` fails on the v0.13 judges and passes on v0.14.

### The §6.8 path is fuzzed

- The last route to the Vault the campaign did not drive now runs on the same Vault as everything else: receipted XRP payments, kind-3 and kind-4 receipts anchored or not, the one-shot challenge and the payment docket interleaved. New invariant: `invariant_paymentDocketIsTheSumOfItsFiledPayments`.
- Campaign: 14 invariants × 1,500 runs × depth 200, with all eight kinds, three dockets, the surety rule and the watch pool on one Vault. 0 failures. 219 Solidity tests.

### Deployed: v0.14 on Coston2 (production timers)

`Vault` `0x9bF9e418…72566fE`, `JudgeEvm` `0x361730A0…d29a2C36`, `JudgeXrpl` `0xE9E6eD9E…4a14E688`, `BondLens` `0xA73f7403…5500BE1b`. Core and `AgentRefs` unchanged.

### SDK: the XRPL watcher, the sentinel, the public score

- **`XrplHistory`: reading an account's history the way the FDC will.** Public XRPL nodes keep little history; the testnet endpoint reachable here keeps ~1,300 ledgers. But every change to an account's XRP modifies its AccountRoot, which records the previous transaction that did (`PreviousTxnID`). The history is a linked list. The watcher walks it backwards through the **FDC verifier's own index** (~15 days of full transactions with metadata). What it finds is exactly what is still provable, including offers taken in other accounts' transactions.
- **`XrplOutflowWatcher` (§6.10).** It finds the XRPL account behind `agentRef` from the `ExclusiveProven` event: statement tx id → signer from the verifier's index → `keccak256(signer) == agentRef`. It then records or commits and convicts.
- **`Sentinel` + `delicti-watch sentinel`.** Discovers every mandate from state, classifies it (§6.11 / §6.10 watchable, receipted, unwatchable), observes, prices each plan (attestation fees + gas against stipends + `BondLens.penaltyFor`), and acts per policy (`observe`, `profit`, `altruist`). It knows every past Vault a mandate may name (`network.history` with per-version features).
- **Public score (SPEC §11.2)**, per agent and deliberately not one number. Facets: standing (`breach-unjudged` is the alarm), verdicts and value taken across every Vault, bond at stake, worst budget use, watched and self-watched mandates, and flags for unfiled and lost deeds. JSON plus a self-contained HTML report.
- `Delicti` gained `proveXrplStatement`, `setWatchTerms`, `fundWatch` and `refundWatch`; `status` shows both exclusivities and the watch pool. `Fdc` handles `EVMTransaction`, `BalanceDecreasingTransaction` and `Payment`, retries the XRP verifier's index lag, and reads fees the way the Vault does.
- Vitest: 28 offline plus 1 online. The online one sends a real proof from #12 back to its v0.13 judge (#11 no longer has a bond to judge against: the sentinel took it).

### Live (Coston2 + XRPL testnet), all by the sentinel

- **Deeds the humans missed (#8, #9).** Walking the AccountRoot chains, the sentinel found three outflows the 23.09 script never filed: a `TrustSet` fee, an `OfferCreate` fee, and the exclusivity statement payment itself. It convicted both mandates again, nested, taking exactly the quoted difference ([`0x45cb946a…`](https://coston2-explorer.flare.network/tx/0x45cb946affe9d96e91d207454b8437297ff8bf5444aac5e01f7a2a38af79e71e), [`0xcc2bc0ba…`](https://coston2-explorer.flare.network/tx/0xcc2bc0bacec2cbf14ef5bbda6c94872a685745c08a4c042ca18ad45878cade41)).
- **Two exclusive promises over one token (#11).** #11 and #12 were declared exclusive by the same address over the same token with overlapping windows. The sentinel counted #12's settlements against #11 too, as SPEC §10 says it must, and took the rest of #11's bond ([`0x79bd7b9f…`](https://coston2-explorer.flare.network/tx/0x79bd7b9ffee8520e0f9e794feeb4d0fadd3d6b0f40190040fabc75834c36667d)).
- **The watch pool, end to end (#13, XRPL).** The sentinel recorded three payments and was paid 0.15 C2FLR in stipends ([`0x950d5acb…`](https://coston2-explorer.flare.network/tx/0x950d5acb7f8afe6ed8122bdcee2369d7e22f09c047a4ce6ff527bdb05cd93583)). After an offer taken by the counterparty and one more payment, it committed and convicted: `bondOf` 1 → 0.5832 ([`0x7a83ce5f…`](https://coston2-explorer.flare.network/tx/0x7a83ce5fd73e185d63e95d4f3a432c8dc2528afd05aa4ab61a3580e9609001be)), with 2 more stipends and the reward. It then claimed 0.2917 C2FLR. docs/DEPLOYMENTS.md has the full run and the sentinel's books.

### SPEC v1.0 — frozen

§14 says what is bound (the mandate, the leaf, kinds 1–8 and the commitment encoding, the consequence rules, the docket semantics) and how it may change: numbered additive amendments only, v2 for anything else, nothing ever changed under an existing mandate. It also says what freezing is not: an audit. New sections: §8.4 (watch pool) and §11.2 (sentinel and score). §6.11's soundness text is corrected, and §10 is updated.

### SDK and the §6.11 watcher (merged after v0.13.0, shipped in 0026)

- **`sdk/` — `@delicti/sdk` and the `delicti-watch` bot.** TypeScript on viem. `Delicti` covers commit, acknowledge/declareExclusive, post/postFor, withdraw, claim and status. `Fdc` covers prepare, request (with the fee), the voting-round clock, and DA polling with decoding. `ExplorerLogSource` exists because Flare's RPC serves 30 blocks per `eth_getLogs`. `planErc20` is a pure planner: window, already-filed per log, ascending hashes, 50 logs per request, and record vs convict. `Erc20OutflowWatcher` runs one cycle: look, plan, and either record or commit → wait for the round past `commitLead` → attest → file. ABIs are generated from the Foundry build.
- **Live, mandate #12:** the watcher recorded three payments, then committed, waited and convicted on the next two by itself (`bondOf` 1 → 0.75). Its books are in docs/DEPLOYMENTS.md: 0.78 C2FLR spent, mostly testnet gas at 650 gwei, against 0.025 earned. A 1-C2FLR bond is not worth watching at testnet prices, which is the "small bonds are not watched" limit, now measured.
- **Tests (vitest, 17):** the planner (11 cases); the commitment encoding pinned to a value the live Vault computed; a real FDC proof from mandate #11, decoded and, with `DELICTI_ONLINE=1`, sent back to the live judge, which runs `FdcVerification` and every check and answers `NothingNew`.

## v0.13.0 — 2026-09-24 — stablecoins: the agent that signs and never sends

BlackRock's thesis of the week is that AI agents will drive demand for stablecoins and blockchain payments. The agent that thesis describes pays in USDC or USDT0 by x402. It signs an EIP-3009 authorisation, a facilitator sends it, and it writes no receipt. Until now DELICTI reached that agent only through a staked accusation, one deed at a time (§6.4).

### §6.11 — gross ERC-20 outflow on a docket (`JudgeEvm.fileErc20Outflow`, kind 8)

- **Applies to** exclusive mandates whose asset is an ERC-20. Every live `Transfer(agent → anyone)` of that token inside the window counts, **whoever sent the transaction**, burns included (FXRP redeemed to XRPL). Proven by FDC `EVMTransaction` with events. No receipt, no meter.
- **Keyed per log, not per transaction.** The FDC lets a requester list any subset of a transaction's logs, including none. A per-transaction docket could be buried: file a transaction with no logs listed and its outflow is counted at zero for ever. `eventFiled[mandate][tx][logIndex]` closes that; a filing that shows no new log reverts `NothingNew`.
- Below the budget a filing only records, needs no commitment and pays nothing. The crossing filing is committed and convicts. Nested in the budget bucket with §6.2, §6.3, §6.8 and §6.10.
- **Reimbursement counts proofs, not logs.** Found while writing the docs: the first draft passed the number of new logs to the Vault, which reimburses per attestation, so one proof carrying five logs would have paid the filer for five. Fixed before any deploy; `test_reimbursementCountsProofsNotLogs`.
- **Confirmations:** `minConfirmations` is 64 on Ethereum (a reorged block would convict an agent of an outflow that never happened) and 1 on Flare.
- The FDC's EVM verifier has no lower timestamp limit on Flare and Songbird, so here the docket is not about the verifier's memory. It exists for the receipt-less conviction and the anti-burial rule.
- **Executed on Coston2, mandate #11:** five facilitator-sent x402 settlements, no receipts. Three filed uncommitted (docket 3), then the committed crossing (docket 5 > 4): `bondOf` 1 → 0.75. Crossing [`0x75d51613…`](https://coston2-explorer.flare.network/tx/0x75d51613fed7a4d69fc84fce28654cfdc43e91cccfdf557a3a60326506071dea), docs/DEPLOYMENTS.md.
- **Tests:** 16 unit tests (`test/Erc20Outflow.t.sol`), including a 512-run fuzz that splits and repeats the same logs across filings. The invariant handler now drives a third track on the same Vault: token moves with 1–3 logs each, filings listing all or some of them, and committed crossings. New invariant: `invariant_tokenDocketIsTheSumOfItsFiledEvents`. Campaign: 14 invariants × 1,500 runs × depth 200, 0 failures. 205 tests.
- **Stated in SPEC §10:** the FDC indexes Ethereum, Flare and Songbird only. Base, where most x402 settles today, is outside every DELICTI challenge. So is RLUSD on XRPL.

### Also deployed with v0.13 (merged after v0.12.0): kind-4 receipts, the §6.8 docket, the invariant tracks

- **The invariant campaign now drives both judges on one Vault.** Until now the fuzzer only called JudgeEvm, so every value invariant (the balance equals bonds + credits + unsettled remainders + open stakes; per mandate, posted = bonded + taken + withdrawn; verdicts never take more than the base) had only ever been checked on a Vault that one judge had touched. The handler now also opens exclusive outflow mandates, moves XRP in and out of their accounts (including slightly outside the window), and files runs of those moves on the §6.10 docket. It covers overlapping runs, uncommitted filings that must stay below the budget, and committed crossings, all interleaved with every EVM path on the same Vault. New invariant `invariant_docketIsTheSumOfWhatItFiled`: after any sequence, the docket equals a from-scratch recount of the positive outflow over the transactions it has filed; no filing adds anything other than its new outflow; nothing outside the window is ever filed. A canary run confirmed that XRPL verdicts are reached within the first 10 runs. Campaign: 13 invariants × 1,500 runs × depth 200 (300,000 calls each), 0 failures. 188 tests.
- **§6.8 on a docket:** `JudgeXrpl.fileBudgetPayments` works like §6.10's docket (record below the budget without commitment, convict on the committed crossing, skip already-filed payments, one receipt per payment across filings). The verifier's ~14-day memory no longer bounds a receipted XRPL case. Five tests.
- **XLS-56 Batch, measured on devnet:** the XRP leaves in the inner transactions (own hashes, fee 0, unsigned, `ParentBatchID`), not in the outer one. Whether the FDC verifier attests an inner transaction is unknown until the testnet enables `BatchV1_1`. This is a possible §6.10 blind spot, stated in SPEC §10. `tools/xrpl_testnet.py batch` is the probe to rerun.
- Mutation testing (mewt, Trail of Bits) on the v0.12 code: in the first 24 mutants, 23 were caught. The one that survived was the removal of the receipt-kind check on the XRPL payment path, a test gap rather than a code bug. `test_revert_receiptOfAnotherKind` now kills it, confirmed by re-applying the mutant.
- `testFuzz_docketIsTheSumOverDistinctTransactions`: however filings are ordered, batched and repeated, the docket equals the positive outflow over distinct transactions (512 runs).
- **Kind-4 receipts: an XRPL payment named by its transaction id** (SPEC §4, §6.8). x402 on XRPL binds payments with `InvoiceID`, which no FDC type returns, so memo-referenced receipts could never match a real x402-XRPL settlement. `JudgeXrpl.challengeBudgetOverrunPayment` now also accepts kind 4, matched on `requestBody.transactionId`. Three tests. 180 tests.
- `test/halmos/VaultMath.t.sol`: bounded symbolic checks of the Vault's arithmetic (penalty bounded and monotone; the surety split conserves value). The conservation check does not finish at 600 s over 64-bit inputs; it is recorded, not claimed.
- **Tooling trap, found by mutation testing:** the npm distribution of `forge` (`@foundry-rs/forge`, a Node shim) exits **0 when tests fail**, setUp failures included. The native binary exits 1. Every result in this repo's history was read from the output, not the exit code. Scripts now judge a run by its summary line (`scripts/lib/green.sh`).

## v0.12.0 — 2026-09-23 — the surety rule and the docket

Two open problems from v0.11's §10, both economic, both closed by changing who is owed what rather than by adding a check.

### Executed on Coston2 (2026-09-23)

Mandate #9: the first two deeds were filed on the docket below the budget, with no commitment ([`0xb4aac39e…`](https://coston2-explorer.flare.network/tx/0xb4aac39e872a1263963bf6c450213cca218993b9233304d3e2907cbcaa73e654)). Then an offer consumed by the counterparty and a payment went on in a committed crossing filing over those two only ([`0x639f368d…`](https://coston2-explorer.flare.network/tx/0x639f368dcb08830c186d1cdab42553ffd9027c919f9b31ddb5938dbf79126a59)). `bondOf` went 2 → 1.6667 (1 principal + 1 insurer), and after `settle` **the insurer is owed its half of the remainder, 0.15 C2FLR**, which v0.11 would have paid the principal. Addresses and the run in the README and docs/DEPLOYMENTS.md.

### The surety rule — a deposit compensates whom its depositor names (SPEC §8.3)

Until now the remainder of every verdict went to the principal, whoever had posted the money. Principal and agent could agree on a fake overrun, paid to an address the principal controls, and the verdict handed the principal an insurer's collateral. Under an outflow budget (§6.10), which has no list of counterparties, this was easier than anywhere else. The protocol cannot tell a principal from its sock puppet, so it asks the party that bears the risk:

- `post` by the principal or the agent → the remainder goes to the principal, as before. `post` by **anyone else** → the remainder of its share goes to **itself**. `postFor(mandateId, beneficiary)` names anyone. The name is fixed per depositor per mandate.
- Principal-side shares are credited at the verdict. Every other share accrues per unit of deposit and is credited by the permissionless `settle`, so verdict gas does not grow with the number of depositors. `withdraw` settles first. `unsettled[mandateId]` keeps the books exact.
- **What colluders can still take from an outsider's plain deposit is its share of the challenger's reward:** 3 FLR of an insurer's 30 in the test case, where it used to be 30. `test_collusionCannotHarvestAnOutsidersDeposit`.
- The balance invariant now includes `unsettled`, and the handler posts for other beneficiaries and settles.

### The docket — outflow cases outlive the verifier's memory (SPEC §6.10)

The FDC's XRP verifier remembers about 14 days, so a case that had to prove every deed at once died with its oldest deed. `challengeXrpOutflow` becomes `fileXrpOutflow`:

- Each proven transaction goes on the mandate's docket once (`filed`, `docket`). Below the budget a filing only records: no commitment, no verdict, no pay. The filing that crosses the budget is the conviction, committed like every other challenge (kind 7), and a later one that raises the docket takes the difference.
- Already-filed proofs are skipped, not refused, so a copier who front-runs part of an honest crossing filing as a plain recording cannot kill it or take its reward (`test_frontRunSubsetDoesNotStealTheCase`). A filing that adds nothing reverts `NothingNew`.
- `test_docketConvictsAcrossTheVerifiersMemory`: most of the budget spent on day 1, the overrun on day 20, and the conviction needs proofs of day 20's deeds only.
- Stated, not solved: filing below the budget is unpaid.

### Also

`Deploy.s.sol` can reuse an `AgentRefs` (`REUSE_REFS`) so XRPL statements already made stay valid. Vault 9,385 B. 177 tests. Long invariant campaign on this code: 12/12 × 1500 × 200 = 300,000 calls, clean (949 s).

## v0.11.0 — 2026-09-23 — the Vault and its judges; the agent convicted for a deed it never signed

### Executed on Coston2 (2026-09-23)

Vault, both judges and the new AgentRefs deployed over the v0.10 core (addresses in the README and docs/DEPLOYMENTS.md). `scripts/xrpl-outflow.sh`, mandate #7, budget 12 XRP of outflow: the XRPL key declared exclusivity; 3 + 3 XRP paid; an offer selling 5 XRP left resting and **consumed by the counterparty's own OfferCreate** (`9AF0A89C…3F3325` — the agent signed nothing); 3 XRP paid. Four `BalanceDecreasingTransaction` proofs, one of them for the counterparty's transaction (`spentAmount` 5,000,000, no fee). Reveal [`0xa0c2ab11…20fcfd2`](https://coston2-explorer.flare.network/tx/0xa0c2ab11d362f8eecded2712874ca55dec4842d7d724711ecd98f343f20fcfd2) (424,399 gas): outflow 14,000,030 drops, severity 2,000,030, `bondOf` 1 → **0.8333**. No receipt was ever written. 169 tests.

### Bond → Vault + judges (SPEC §8.2)

`forge build --sizes` after v0.10: Bond 24,334 B, **242 B** under EIP-170. The outflow challenge did not fit, and neither would any after it. Split once:

- **`Vault`** — every wei (bonds, credited proceeds, accusation stakes), post/withdraw/claim, pro rata, proportional slashing, the one commit–reveal gate, and `verdict`, callable only by the judges given to its constructor. No admin, no setter, no upgrade; the constructor refuses a judge that names another Vault, and `judges()` tells a depositor, before it posts, every piece of code that can ever take from its deposit.
- **`JudgeEvm`** (§6.1–6.5) and **`JudgeXrpl`** (§6.8, §6.10) — no funds; verify, then ask the Vault.
- **Deployment without a set-once step:** judges first, at the Vault's predicted address (`vm.computeCreateAddress`), then the Vault. `Deploy.s.sol` reuses the v0.10 registry, anchor log, meter and corroboration log (`REG`/`LOG`/`METER`/`CORROBORATION_LOG`); old mandates stay with the old Bond.
- **Errors in one interface** (`DelictiErrors`), so every selector is the one v0.10 had.
- **The proof that nothing changed:** all 146 tests migrated by changing who is called, never what is asserted. The one exception is where an event is expected *from* — `DeedJudged` now comes from the judge that summed the deeds.
- Sizes: Vault 7,644 B, JudgeEvm 14,253 B, JudgeXrpl 6,801 B.
- Slither flagged one new write-after-call (`consumedLeaf` after `vault.consumeCommitment`); not exploitable — the Vault is fixed code and calls back into no judge — but moved before any external call anyway.

### §6.10 — gross XRP outflow, no receipts

- The measure is the mandate's: `assetKey = bytes32("XRP/outflow")` promises a budget of XRP that *left* the account, fees included; `0` keeps §6.8's delivered amount. No change to the registry. The two challenges refuse each other's mandates; §6.1 accepts both.
- **Exclusivity from the XRPL key:** `AgentRefs.proveExclusive` — a payment from `agentRef` whose one 32-byte memo is `keccak256(abi.encode("DELICTI/exclusive", chainid, registry, mandateId))`. Sticky, implies `proven`. `declareExclusive` (the EVM key) does not count.
- `challengeXrpOutflow`: N `BalanceDecreasingTransaction` proofs; `sourceAddressIndicator` and `sourceAddressHash` both equal `agentRef`; inside the window; ids strictly increasing; sum of **positive** `spentAmount`; kind 7; nested with the other budget kinds.
- Fees count under this measure, so §10's "an agent can burn fees without limit" no longer holds for outflow mandates.
- **Rehearsal, XRPL testnet, 2026-09-23:** agent `rDNVcWzofk1mVYk3Q3HZen3M5VEN7Kuikr`; its offer `30E0E8717AD779EAAB9BD4AD917330FF5710CF2FF5CC60DC92EA245BFFFCB2E9` (BDT for the agent: `VALID`, `spentAmount` 10 = the fee); consumed by the counterparty's `8D26EFE24B17FE2A183442458A84A66D3F179A2790C617A9AA090F973058AF8E` (BDT for the agent: `VALID`, `spentAmount` **5,000,000**). `tools/xrpl_testnet.py` gained `trust`, `offer`, `take`.

### Stated, not solved (SPEC §10)

- **The verifier's memory is ~14 days.** A cumulative XRPL case over a longer window may be unprovable when the overrun comes late. `JudgeXrpl.fullyEnforceable` / `PROOF_HORIZON` make it readable; recording proven outflow progressively is the v0.12 design.
- Judges are fixed for ever: a bug in one is fixed by a new Vault, and deposits already posted stay exposed until withdrawn.

### Scripts

`BOND` is now the Vault; challenges go to `JUDGE_EVM` / `JUDGE_XRPL`. `unanchored-deed.sh` reads the seven-field `Accusation` (the getter string had not followed v0.9's `value`).

### Not done in this release

A full `delicti-audit` pass, and a handler that drives §6.10 and the `Payment` path. The long invariant campaign did run on the refactored code: **12/12 invariants × 1500 runs × depth 200 = 300,000 calls, clean (1,028 s)** — the Vault's balance, pro rata, claims, accusations and verdict bounds hold exactly as they did on the Bond.

## v0.10.0 — 2026-09-22 — the first deeds judged on XRPL, and the tally judged at the time of the deed

An adversarial pass over v0.9 (Slither at medium+, a 300,000-call invariant campaign on the final code, and a read of every path against the list of attack classes this repo has already suffered). Slither: the same three false-positive classes as v0.9, nothing new. The campaign: clean. The read found two openings, both reachable from outside the contracts, neither a Solidity bug — one a binding missing in *time*, one missing in *scope*. Both have a regression test in `test/Audit.t.sol` that fails against v0.9.

### Executed on Coston2 (2026-09-22)

Deployed (addresses in the README and docs/DEPLOYMENTS.md). **The XRPL path is no longer tests-only.** `scripts/xrpl-structuring.sh` (new), mandate #6: the agent's XRPL account confirmed the mandate with a payment carrying `AgentRefs.challengeFor(6)` as its one 32-byte memo → `AgentRefs.prove` `0xa5c17d21…63cd8f`; five payments of 1 XRP under a 4-XRP budget, five anchored kind-3 receipts, five FDC `Payment` proofs → reveal `0xb6856090222fb3083d425bb22126f88fd35e66f14641a8b03c2cd2c4862bcb89` (514,785 gas): `bondOf` 1 → **0.75**. Fees (10 drops a payment) were not summed, as §6.8 says.

`tools/xrpl_testnet.py` (new) does the XRPL side — faucet accounts, payments with exactly one 32-byte memo, which is the only shape for which `Payment` reports a reference. The run is resumable: state goes to `.run/` after every costly step, and `RESUME=1` re-commits over the same deeds if the commitment has aged past `COMMIT_TTL`.

It needed that. The first runs sent the verifier transaction ids as `0x0x…`, the refusals were read as indexer lag, and the first commitment aged out; the deeds, leaves and mandate were still good, so only the commitment was redone. Recorded here because the script's own comments had briefly blamed the verifier.

**SPEC §6.9's condition is met, and the blind spot it named does not exist.** A `BalanceDecreasingTransaction` proof for an `OfferCreate` — and not the agent's own: another account took the agent's resting offer — was requested (`0xc5a32b7b…067b47`, round 1461000) and verified by `FdcVerification` (`true`, `spentAmount` 9,000,000 drops). SPEC v0.7 rewrites §6.9 around what that means: a challenge over every XRP outflow of an exclusive XRPL account, with no receipt required, is v0.11.

Not executed live on this deployment: the §6.5 historical-tally fix and the per-agent corroboration key (both covered by `test/Audit.t.sol`), `CorroborationLog` in general, a second incremental verdict, pro-rata withdrawal after a slash.

### The effector could destroy the case against itself, after seeing it (HIGH)

`challengeUnderReportedSpend` convicted on `proven > meter.spent(mandateId)`, read at the moment of the reveal. But `note()` belongs to the effector, stays open while the mandate lives, and takes any amount — and the challenger is *forced to announce the case first*: `FdcHub.requestAttestation` carries the deeds' transaction hashes in the clear, and the reveal cannot land before that round finalises and `commitLead` (10 min) has elapsed (§6.7). So an effector colluding with the agent had ~13 minutes to note exactly what it had hidden, and the challenge then reverted `TallyAgrees` against a tally that had been true for about a minute. Commit–reveal does not help here: it protects who *owns* a reward, not whether a case exists at all. One transaction, and §6.5 was gone.

- `SpendMeter` now keeps the tally as checkpoints `(timestamp, total)` — one per second, since several settlements in one block are one moment — and answers `spentAt(mandateId, ts)` by binary search, zero before the first note.
- `Bond.meterGrace` (immutable, 5 minutes in production) and the verdict reads `spentAt(lastDeed + meterGrace)`, `lastDeed` being the newest deed among the supplied proofs. What the tally said when it should have said it is a fact; nothing written later can change it.
- Why a grace at all, and why this one: the meter is written in the same payment path that reads it, seconds around the deed, so five minutes is two orders of magnitude of slack for an honest effector — and it is far below the earliest moment any challenger can reveal, which is the number that closes the race. Zero would convict an effector for a slow block. SPEC §10 states what the window still allows.
- Regressions: `test_effectorCannotCatchUpTheTallyOnceTheCaseIsPublic`, `test_effectorMayBeLateWithinTheGrace` (the limit, stated), `test_controlUntouchedTallyStillConvicts`, plus two on the history itself.

### One deed could be counted many times in an agent's public record (MEDIUM)

`CorroborationLog` keyed `corroborated` and `deedRecorded` per mandate, which is right for a mandate's own episode — but `countOfAgent` crosses mandates. Anyone may commit a mandate naming any agent, an agent may acknowledge its own, and the same FDC proof verifies under every one of them. So one real transaction could be entered into an agent's record as many times as someone was willing to pay gas for: a second mandate over the same window and source, one anchor, one call. §10 admitted this log cannot tell a deed from a wash — but a wash costs a transaction on the source chain, and this cost none. It matters because the next floor is a public score.

- `deedRecordedForAgent[agent][deedId]`, checked alongside the per-mandate keys. Each deed enters an agent's record once, whatever mandate it is claimed under.
- Regression: `test_oneDeedIsCountedOncePerAgentAcrossMandates`.

### Checked and sound

`_penalty` arithmetic and its bounds; severity accumulation across kinds and buckets; pro-rata `withdraw` (rounding favours the contract, the last depositor out takes the rest); `post` refusing unacknowledged mandates, unproven `agentRef`s, foreign Bonds and slashed mandates; the commitment gate's three clauses and `ClockDrift`; `fdcCost` failing to zero rather than reverting on `resolveAccusation`'s path; `Deeds` as the single definition of agreement. The one thing a depositor can still do is withdraw its share before a *later* verdict lands during the cooling window, which is inherent in a first-come withdrawal and is bounded by the window itself.

Slither after the fixes: the same false-positive classes plus two more of the same kind — `uninitialized-state` on `SpendMeter._history` (a mapping of arrays is written by `push`, which the detector does not follow) and `incorrect-equality` on `h[n-1].at == block.timestamp` (the deliberate "same second, same moment" collapse).

146 tests (was 140), 12 of them invariants.

## v0.9.0 — 2026-09-19 — what the budget is made of, and who agreed to it

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

### Invariants and fuzzing — and what they found

The repo had 82 unit tests and no property-based ones. A unit test says "this attack, which we thought of, fails"; every hole this project has had was an *ordering* nobody had thought of. `test/invariant/` drives the four contracts through a handler that can do everything a participant can — commit, delegate (deliberately unclamped, so most attempts to widen must be refused), acknowledge, post, act, anchor or stay silent, commit to a challenge, replay someone else's commitment bytes, reveal early, reveal on time, accuse, answer, resolve, revoke, withdraw, claim, wait — against an FDC that verifies everything, because the handler only builds proofs of deeds it really simulated. After every call:

- the Bond's balance equals bonds + credits + open accusation stakes, to the wei, and nothing ever leaves that did not come in;
- `claim()` pays exactly `owed`, zeroes it, and cannot be repeated on the same balance;
- a live commitment keeps the timestamp of its first submission whoever replays it, and a spent one is gone;
- a mandate is never slashed for more than the bond it was slashed from; a slashed mandate is dead; a mandate dead for good never comes back and never anchors;
- a live child has a live parent all the way up, dies no later than its parent, and is never wider in budget, window or unit;
- every accusation whose window has closed can be closed by someone; an open accusation always has collateral behind it.

`test_handlerReachesEveryDeepState` exists because a handler is code and can be wrong in the boring direction — every call refused, every invariant vacuously true. The first version of this one was: a getter in an argument list ate the `vm.prank` and no accusation ever landed (the same pitfall `claude/22` lists). `test/Fuzz.t.sol` adds two stateless if-and-only-if properties: a child mandate is accepted iff it only narrows, and the commit gate opens iff `at + lead <= roundStart <= at + TTL` and `roundStart <= now`. Default campaign 256 × 80 (~25 s, runs in CI); 1500 × 200 = 300,000 calls run clean before this commit.

**Found by the campaign: an accuser's stake could be stranded for ever.** `resolveAccusation` reverted `AlreadySlashed` when the mandate had been slashed by another path while the response window was open — two watchers accusing two silent deeds is enough. `answerAccusation` needs a leaf that by hypothesis does not exist, so nothing could ever close the second accusation and its 0.1 FLR stayed in the contract. Shrunk by the fuzzer to: accuse, under-reported-spend slash, wait, resolve → `0x37233762`. Resolution now always closes, always returns the stake, and slashes only if there is still something to slash. Regression: `test_secondAccusersStakeIsNotStrandedByTheFirstSlash`.

**Found while fixing it, not by the fuzzer: collateral could walk out from under an open accusation.** The response window (24 h) is as long as the cooling window (24 h). An accusation filed in the last hour of the cooling window was still open when `withdraw` became legal; the principal withdrew, resolution reverted `NothingToSlash`, the agent walked, and the stake was stranded on top. `withdraw` now refuses while `openAccusations[mandateId] != 0`. The random campaign did not reach this ordering on its own, which is worth saying: the handler was taught it (`lateAccusationThenWithdraw`), and with the fix removed the invariant now fails within one default run. Regression: `test_revert_withdrawWhileAnAccusationIsOpen`. What this costs is stated in SPEC §10: an accuser can hold a bond for one response window per real, unanchored deed, at 0.1 FLR and one attestation each.

112 tests, 11 of them invariants.

### Deeds on XRPL can be summed (`challengeBudgetOverrunPayment`, `proveAgentRef`)

Every cumulative challenge needed `EVMTransaction` proofs and compared `sourceAddress` with an EVM address. The only XRPL challenge was the negative one — a payment that did not happen. A deed actually done on XRPL could not be counted against a budget at all, which disqualified DELICTI as infrastructure for the ledger it is supposed to serve.

- **`challengeBudgetOverrunPayment`** — positive FDC `Payment` attestations against kind-3 leaves: the payment exists, succeeded, came from the account the mandate names (`agentRef`, standard address hash), inside the window, to the destination, for the amount and with the reference the receipt claims; the sum convicts. Commitment kind 6.
- **`receivedAmount` is summed, not `spentAmount`.** On XRPL the latter includes the fee. Counting it would let an agent be convicted by twelve drops while delivering exactly its budget; the EVM paths ignore gas for the same reason.
- **Leaves must be pairwise distinct**, a check the EVM paths do not need: there the leaf's `ref` is the transaction hash, here it is the payment reference, so two transactions can match one receipt.
- **`proveAgentRef`** — `agentRef` is written by the principal, and `acknowledge` is the EVM key speaking. The XRPL account confirms a mandate by making any payment whose memo is `agentRefChallenge(mandateId)`; `post` refuses collateral until it has. Without it, naming a stranger's busy XRPL account was the same attack as naming a stranger's EVM address.
- **Checked before designing, as asked.** `Payment` covers XRPL transactions of type `Payment` only — confirmed in the FDC specification. For `BalanceDecreasingTransaction` the interface does not restrict the type, the documentation's wording implies other types are attested, and the reference client's `balanceDecreasingSummary` has no type check where `paymentSummary` has one. That is three indications and zero live attestations, so nothing is built on it: SPEC §6.9 is a roadmap entry whose condition is named — a verified `BalanceDecreasingTransaction` proof for a non-`Payment` XRPL transaction on Coston2 — together with the blind spot no attestation type closes (a resting offer taken inside someone else's transaction).
- Live checks made while designing: `verifyPayment` and the newer `verifyXRPPayment` both answer on Coston2's `FdcVerification`; mainnet `FdcRequestFeeConfigurations` returns **20 FLR per request** for `Payment`, `BalanceDecreasingTransaction`, `XRPPayment` and `EVMTransaction` alike. A five-deed challenge therefore costs its challenger 100 FLR in attestations before gas — the number the next section is sized against.

129 tests.

### Proportional slashing — and why "slashed at most once" had to go with it

SPEC §10 admitted the slash was a step function: conditional on breaching at all, the optimal breach was the largest one available, and loss-given-default was 100 %, which no insurer will write. **The parameters first, as asked, and then what the list got wrong.**

```
P(S) = clamp( base × S / budget ,  base × 10 % ,  base )      taken = P(S_after) − already taken
```

- **Slope `base / budget`: no new constant.** It is the collateralisation ratio `k` the market already chooses (§8). Each unit of overrun costs `k` units of bond; with `k ≥ 1`, which §8 already tells a counterparty to demand, no overrun up to 100 % of the budget pays for itself. Any protocol-chosen slope would either be redundant with `k` or fight it.
- **Ceiling = the bond**, reached at `overrun = budget`. Past that every further unit is free again — the step function is gone from the bottom of the curve and still there at the top, and only a larger bond moves it. SPEC §10 says so.
- **Floor = 10 % of the bond.** Three of five verdicts are about a lie, and a lie about a small amount is not a small lie. 10 % because it is what the challenger's *entire* reward used to be: the smallest verdict still moves as much value as the smallest reward did.
- **Challenger: attestation cost first, then 10 % of the rest.** "Make sure the reward still covers FDC and gas" cannot be met by a percentage alone once penalties shrink: read live from mainnet `FdcRequestFeeConfigurations` on 2026-09-19, **every attestation type this protocol uses costs 20 FLR per request**, so a five-deed salami costs its challenger 100 FLR before gas. The Bond reads that fee on-chain (`fdcCost`) — never hardcoded, same reasoning as the voting-round clock — and credits `n × fee`, capped at what the verdict took. The honest limit: the reward covers the cost *iff the verdict does*, i.e. iff `10 % × bond ≥ n × fee`. A 100-FLR bond is not worth watching, and now the chain says so in advance.

**Where the list was wrong: proportional + "slashed at most once" is worse than the step function it replaces.** The agent convicts itself of the smallest case it can assemble, pays the floor, and the rest of the bond is shielded from the real case for ever. So severity *accumulates* and each verdict takes the difference. Nested kinds (overrun, under-reported) keep a high-water mark — the same five deeds plus a sixth is one overrun, not two; additive kinds (false payment, unanchored deed) sum, because `consumedLeaf` and `accused` already guarantee each is about a different receipt or transaction. The first verdict still revokes the mandate. A direct challenge that would take nothing reverts `NothingNew`. This also softens one of the two open limits of §6.7: a self-slash no longer takes the whole reward off the real watcher, only the floor's share of it (`test_selfSlashDoesNotShieldTheBond`).

**Also not on the list, and forced by it: `depositOf`, pro-rata withdrawal.** A partial slash leaves a remainder. `post` did not record who paid and `withdraw` paid the principal, so a bond posted by an insurer was a free option for the agent's own side — `claude/22` had this as the precondition for the insurer story, and proportional slashing turns it from a corner case into the normal case. Each depositor now bears the same fraction of every verdict and takes back its own remainder after the cooling window; rounding favours the contract, and the last one out gets exactly the rest.

**One loop where there were two.** `challengeBudgetOverrunERC20` is gone: once the asset is the mandate's there is nothing left for the caller to choose, so `challengeBudgetOverrun` reads what a deed's value *is* from the mandate (native `value`, or the token's `Transfer(agent → payee)`). Two copies of a loop is how `answerAccusation` came to miss a check its twin had — and the Bond was 78 bytes over EIP-170 with both. The commitment `kind` still distinguishes the two (2 native, 3 ERC-20).

New: `BondLens` (stateless; `penaltyFor` — what a case would take, before paying for a single attestation), event `Verdict` on every verdict of every kind. Invariants updated: per mandate `posted = bonded + taken + withdrawn`; verdicts never exceed the bond they were measured on; a depositor never withdraws more than it posted, and exactly that if no verdict touched the mandate.

### What a score can count — added now, because later it is a redeploy

The next floor is a public score: coverage, corroboration, contradiction (SPEC §11). The test applied to every event and view: *can an indexer compute the three from logs and current state alone — no archive node, no re-decoding of challenge calldata — and can a contract, which cannot read events at all, check the parts a risk market needs?*

- **Corroboration had a definition and no data.** A deed whose two witnesses agreed left no trace on-chain; only convictions did. `CorroborationLog` records agreement — permissionless, one receipt and one source transaction at most once, acknowledged mandates only. It holds no funds and no privileges, so it is deliberately *not* part of the core: it could have been added a year later without touching anything, and a better one still can be. What made it safe to write now is `Deeds`: the checks that define evidence class A moved out of the Bond's loops into one internal library that both use, so "agree" cannot come to mean two things.
- **Contradiction by value needed the deeds, not just the total.** `Verdict` — one shape for every verdict of every kind — and `DeedJudged` per deed summed. Before, which deeds a verdict was about lived only in calldata.
- **Coverage needs leaves, and the chain holds roots.** `AnchorLog.anchor(…, leavesURI)` publishes where an episode's leaves are; `Anchored` now carries `anchoredAt` and indexes `by`; `receiptCountOf` is readable by contracts. Leaves nobody can fetch count for nothing and can still convict — the right asymmetry.
- **A record that is complete or provably not.** `MandateRegistry.mandateCountOf / mandateOf(agent, i)`, appended at *acknowledgement* (by the agent) rather than at commit (by anyone): an outsider cannot bury an agent's record under spam and the agent cannot leave the bad mandates out. `Bond.verdictsAgainst(agent)` and `takenFrom(agent)` for the same reason — a record only an indexer can see is one a risk market takes on trust.
- `AgentRefs` — proof of control over `agentRef` moved out of the Bond into its own contract. The confirmation is a fact about the mandate, not about one consequence contract, so a future Bond over the same registry does not make agents prove their accounts again. (It also bought back the bytes: the Bond sits 416 bytes under EIP-170, which SPEC §10 now treats as a constraint on what can still be added to it.)
- `BondWithdrawn` names the depositor.

Test count, honestly: v0.8's "81" counted eight tests twice, because `StructuringERC20Test` inherited `StructuringTest` and re-ran it. The fixture is now abstract. **140 distinct tests** (comparable v0.8 figure: 74), 12 of them invariants.

### Documents

- README said "adds the four things" above a list of five — the fifth, the meter, arrived in v0.7 and the sentence was never recounted.
- README's threat model still said DELICTI "is evidence after the fact, not a real-time brake". That stopped being true twice: v0.5 (the effector refuses dead and borrowed mandates before funds move) and v0.7 (`SpendMeter` refuses the slice that breaks the budget). Rewritten to say what is now true — consequence is after the fact, prevention is not, and both hold only where an effector chooses to check. Three limits added that a reader deciding whether to rely on this should meet on the front page, not in §10: XRPL means XRP `Payment`s only; small bonds are not watched; verdicts need someone to bring them.
- README pointed at "SPEC.md (v0.1 draft)"; the SPEC was at v0.5 and is now v0.6.
- SPEC §3 rewritten around the new mandate fields, acknowledgement and per-mandate consequence contracts; §6.3 folded into §6.2's entry point; §6.8–6.9, §8.1, §11.1 new; §10 gained an entry for every mechanism above that leaves something open, and lost the two it closed.
- **SPEC §13 (roadmap, no code): DELICTI verdicts as native XRPL credentials** — XLS-70 Credentials issued and, more to the point, *deleted* by a Protocol Managed Wallet under Flare Confidential Compute, from an eligibility function over public state. Written with its trust assumptions (FCC is a new and larger one than §2's, and the section says so), what the credential does not prove (not identity, not KYC, not that anyone was watching, nothing about non-`Payment` deeds), and the condition for leaving the roadmap: one credential issued and deleted end to end on testnet from a Flare-side verdict.

### Slither (0.11.6, medium and above, `src/` only)

One real finding, fixed: `reentrancy-no-eth` in `_verdict` — `registry.revokeByBond` was called before `bondOf`, `slashedAmount` and `owed` were written. The registry is this project's own code and calls nothing back, so nothing was exploitable; but the mandate now names its consequence contract, which makes "the registry is trusted" an assumption about a pairing rather than about a deployment, and effects-before-interactions costs nothing. The call moved to the end. Remaining, all false positives: `incorrect-equality` on `revokedAt[id] == 0` (a deliberate never-revoked sentinel); `uninitialized-local` ×5 (`spent`, `proven`, `lastTx` — Solidity zero-initialises locals, and zero is the intended start); `unused-return` on `Deeds.requireAnchored` in the EVM overrun loop (it returns the leaf hash for `CorroborationLog`; the Bond's loop needs only the revert).

### Executed on Coston2 (2026-09-19)

Deployed (addresses in the README; no `setBond` step exists any more). `scripts/structuring.sh` against it: the v0.8 salami, reveal `0x7c4c3094585a4a1b5f473415d5cc39146a1b38def01b03030f65e3af5d8d8123` (531,447 gas) → `bondOf` 1 → **0.75**: a 25 % overrun, a 25 % penalty. Copier `0xe736229aac815212cee41b17df61af6d3bf812aba05ffaaaeec8c62728e2ef27` reverted `CommittedTooLate`. **Not executed live:** the XRPL `Payment` challenge, `AgentRefs.prove`, `CorroborationLog`, incremental verdicts, pro-rata withdrawal, and every other script against this deployment. The README says so in the same words.

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
