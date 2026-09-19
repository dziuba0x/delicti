<div align="center">

<img src="assets/social-preview.png" alt="DELICTI — corpus delicti for AI agents" width="720">

# DELICTI

**Accountability for autonomous AI agents: a mandate before the act, an independent witness to the deed, and a bond that pays for the breach — without a court.**

[![test](https://github.com/dziuba0x/delicti/actions/workflows/test.yml/badge.svg)](https://github.com/dziuba0x/delicti/actions/workflows/test.yml)
[![release](https://img.shields.io/github/v/release/dziuba0x/delicti?color=c9d1d9&label=release)](https://github.com/dziuba0x/delicti/releases)
![tests](https://img.shields.io/badge/tests-140%20(12%20invariants)-2ea44f)
![Coston2](https://img.shields.io/badge/live%20on-Flare%20Coston2-e62058)
![status](https://img.shields.io/badge/status-testnet%20·%20unaudited-lightgrey)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

[How it works](#how-it-works) · [Proven on-chain](#proven-on-chain--click-any-of-them) · [Quickstart](#quickstart) · [Contracts](#contracts-v09-on-coston2) · [Limits](#limits-stated-up-front) · [SPEC](SPEC.md) · [Changelog](CHANGELOG.md)

</div>

---

An AI agent with a wallet can be told *"spend at most 4 FLR"* and then spend 1 FLR five times. Every call passes a per-action policy check. Every call gets a signed receipt. The receipts are all true, and the mandate was still broken.

DELICTI is the layer that catches this and makes it cost something. It runs on [Flare](https://flare.network), because Flare's **Data Connector (FDC)** can attest, from consensus, what actually happened on another chain — EVM or XRPL — without trusting the agent, its operator, or its tool server.

> When a mind becomes alien, its words stop being evidence. Its deeds, confirmed independently, remain. — the thesis, after J. Pachocki's *An Alien Mind*.

## How it works

DELICTI does not define another receipt format. It takes the signed receipts effectors already produce (flario `x402_receipt`, KYA-OS / Checkpoint `_meta` proofs, ACTA / ASQAV receipts) and adds the five things none of them have:

1. **Mandate before act.** A principal commits on-chain what the agent may do — budget, time window, the asset and chain the budget is counted in, a delegation tree where children can only narrow parents — and **the agent acknowledges it** before any bond is accepted.
2. **Two witnesses to the same deed.** The effector's receipt is witness one. An FDC attestation of the effect in the world is witness two. Agreement is evidence; disagreement is a *contradicted deed*.
3. **The sum, not the slice.** Violations are computed against the mandate's cumulative budget, so structuring ("salami") is caught even when every single action was allowed.
4. **A brake that sees the sequence.** A DELICTI-aware effector reads the running tally before it acts and refuses the fifth slice in one `eth_call` — milliseconds, no funds moved. An effector that skips the check is choosing to be judged by the FDC instead, minutes later.
5. **Consequence without a court.** On proof, the bond is slashed **in proportion to the breach** (a 25 % overrun takes 25 %, floor 10 %). The challenger is reimbursed its attestation fees, read live from Flare, and earns 10 % of the rest; the harmed party gets the remainder; depositors take back what is left, pro rata.

```mermaid
flowchart LR
    P[Principal] -- "commit(mandate)" --> MR[(MandateRegistry)]
    A[Agent] -- "acknowledge" --> MR
    A -- acts through --> E[Effector<br/>MCP server / x402]
    E -- "reads tally first" --> SM[(SpendMeter)]
    E -- "signed receipt<br/>(witness 1)" --> AL[(AnchorLog<br/>Merkle root)]
    W[World<br/>EVM / XRPL] -- "FDC attestation<br/>(witness 2)" --> B{Bond}
    AL --> B
    MR --> B
    B -- "witnesses agree" --> CL[(CorroborationLog<br/>evidence class A)]
    B -- "witnesses disagree<br/>or sum > budget" --> S[proportional slash<br/>challenger · victim · depositors]
```

## Why signed receipts are not enough

| | KYA-OS / Checkpoint | ACTA / ASQAV | AP2 mandates | OAP (pre-action) | Arbiter escrow (Kleros / UMA / LLM juries) | **DELICTI** |
|---|---|---|---|---|---|---|
| Effector-signed receipt | yes | gateway / operator | yes | gateway | – | consumes theirs |
| Commitment *before* the act | – | – | payments only | policy hash | deal terms | on-chain: budget, window, asset, delegation tree |
| Independent confirmation the effect happened | – | – | – | – | a judge decides | **FDC, from consensus** |
| Detects structuring across many small calls | – | – | – | admitted gap | – | **sum over the sequence** |
| Consequence | – | – | – | – | after a ruling | **on proof, proportional** |
| Survives the operator's bankruptcy | if they keep logs | Bitcoin / Rekor anchor | – | – | yes | neutral chain |

A receipt proves *registration* — "a false claim can be immutably registered". A court proves that someone was persuaded. DELICTI proves the *deed*, or proves the receipt lied.

## Proven on-chain — click any of them

Nothing below is a claim about what the contracts *would* do. Each line is a transaction on Flare's Coston2 testnet that anyone can open. The full record, with every deployment since v0.1, is in [docs/DEPLOYMENTS.md](docs/DEPLOYMENTS.md).

| What was proven | Transaction |
|---|---|
| **v0.9 — proportional: a 25 % overrun took 25 % of the bond, not all of it**; asset and source read from the mandate, agent acknowledged | [`0x7c4c3094…8d8123`](https://coston2-explorer.flare.network/tx/0x7c4c3094585a4a1b5f473415d5cc39146a1b38def01b03030f65e3af5d8d8123) |
| A copier that lifted a finished challenge out of the mempool — refused on-chain, because it had not committed in time | [`0xab529327…4da115`](https://coston2-explorer.flare.network/tx/0xab52932730be8db7a8da1ec37396e5124f2033ec0e92f0baf98388c5464da115) *(reverted, `CommittedTooLate`)* |
| …and the same calldata, revealed two blocks later by the address that committed first | [`0xdbf70a53…9a7628`](https://coston2-explorer.flare.network/tx/0xdbf70a53b738e793b558b9f09a412f1727ec3c49a8899cd6f6700ab7fa9a7628) |
| **Structuring refused while it was still happening** — four slices fit, the fifth was rejected by the meter with no FDC round and no transaction at all | [meter state, mandate #1](https://coston2-explorer.flare.network/address/0xD64465B95A1E83DC292AcB1e5b66dD416ADeA55C) |
| The effector recorded two settlements out of five; the FDC proved five, and the tally was convicted of the difference | [`0x53664b9f…0b20ff`](https://coston2-explorer.flare.network/tx/0x53664b9f186353821ae8be87e75279d0de6619fd3326f3751974a616fb0b20ff) |
| A deed with no receipt behind it: nobody answered, the window closed, the bond went | [`0x432ca347…72490b`](https://coston2-explorer.flare.network/tx/0x432ca347481f7a279e377b648c5ad2b776f871b38ed0068b515383d63e72490b) |
| The same accusation, answered in time with the anchored receipt — dismissed, and the accuser's stake forfeited | [`0x1bbcaf3f…6ae48b`](https://coston2-explorer.flare.network/tx/0x1bbcaf3f0a371facd17b8922d522e59917120f0055a2cca6954c3d38ba6ae48b) |
| The effector-side brake: a live mandate pays, while a missing, revoked or borrowed one is refused **before any funds move** | [`0x2b59d401…277664`](https://coston2-explorer.flare.network/tx/0x2b59d401f8819c24c8e6b89841f35b7df09a4282dd1b7607ad4db7505a277664) |
| The loop driven through a **running flario MCP server** — witness 1 emitted by the effector process, not hand-built | [`0x118bc486…d922f0`](https://coston2-explorer.flare.network/tx/0x118bc48692b986875c2153492ff81757da9d9bf18e4201341cb2711f50d922f0) |
| Structuring over x402: five genuine EIP-3009 settlements, genuine `flario-receipt/2`, FDC proofs carrying the `Transfer` event | [`0x19c73850…014ed1`](https://coston2-explorer.flare.network/tx/0x19c738500129ff4447802561a804b92620e47f3222fa70a76c6ad781ce014ed1) |
| Structuring, native: five 1-FLR deeds under a 4-FLR budget, each legal alone, each corroborated by FDC — the sum convicts | [`0xa547ebad…96557f`](https://coston2-explorer.flare.network/tx/0xa547ebada6b01953100ed2fad6abdead1b3122d3d280ad302040e69b3f96557f) |
| A receipt that lied: it claims an XRPL payment, FDC `ReferencedPaymentNonexistence` proves it never happened → slash | [`0x91bb1909…5fdc91`](https://coston2-explorer.flare.network/tx/0x91bb190933e9e0d5abbc8efc2816ba26d475c2fa3cfbfb2636ae656e3c5fdc91) |

Every challenge type defined up to v0.8 has been executed on Coston2, in both directions where it has two. **v0.9's XRPL `Payment` challenge has not been yet** — it is covered by tests only, and this line will say so until it is not.

## Quickstart

Requires [Foundry](https://book.getfoundry.sh/getting-started/installation) and Node 22.

```bash
git clone https://github.com/dziuba0x/delicti && cd delicti
npm ci                           # @flarenetwork/flare-periphery-contracts, OpenZeppelin
forge build
forge test                       # 140 tests with a mock FDC, 12 of them invariants (~30 s)
```

Longer runs:

```bash
FOUNDRY_INVARIANT_RUNS=1500 FOUNDRY_INVARIANT_DEPTH=200 \
  forge test --match-contract Invariants                          # the long campaign (~10 min)
forge test --fork-url coston2 --match-contract Coston2ForkTest -vv  # live Flare wiring
```

Replay a live case against the v0.9 deployment (needs `cast`, `curl`, `python3`):

```bash
cp .env.example .env             # throwaway key + Flare's public testnet verifier; v0.9 addresses prefilled
scripts/structuring.sh           # five deeds, commit, FDC proofs, proportional slash, copier refused (~10 min)
```

Or deploy your own: `forge script script/Deploy.s.sol --rpc-url coston2 --broadcast --private-key $PRIVATE_KEY`, then point `REG` / `LOG` / `METER` / `BOND` in `.env` at it.

The scripts in [`scripts/`](scripts) each reproduce one row of the table above: `structuring.sh`, `x402-structuring.sh`, `mcp-structuring.sh`, `brake-test.sh`, `spend-meter.sh`, `unanchored-deed.sh`, `contradicted-deed.sh`. Test funds: [Coston2 faucet](https://faucet.flare.network/coston2).

## Contracts (v0.9 on Coston2)

| Contract | Role | Address |
|---|---|---|
| `MandateRegistry` | mandates, delegation tree with monotonic narrowing, acknowledgement, revocation. No deployer, no admin key. | [`0x3Ac059b3…3D68474`](https://coston2-explorer.flare.network/address/0x3Ac059b38C872610Bc09f3fD80cd39a4a3D68474) |
| `AnchorLog` | per-mandate sequence of Merkle roots over receipts (witness 1), with `leavesURI` | [`0xD4007D70…4AC0c`](https://coston2-explorer.flare.network/address/0xD4007D70168E6feC23E483F34B3F1B4a94E4AC0c) |
| `SpendMeter` | the running tally an effector reads before it acts (SPEC §7.1) | [`0x375dBc0c…d7A6F5`](https://coston2-explorer.flare.network/address/0x375dBc0cC2b6dc973192a51810955134fFd7A6F5) |
| `Bond` | collateral, commit–reveal challenges, FDC verification, proportional verdicts, pull payments | [`0x3B6d9912…6f421`](https://coston2-explorer.flare.network/address/0x3B6d9912fE9ACa37ba13d8e25932EBe77a06f421) |
| `AgentRefs` | proof that an XRPL account accepted a mandate (payment with a memo) | [`0x2065c74F…A94fa`](https://coston2-explorer.flare.network/address/0x2065c74Fdce8E7Feefafd787C35F3577110A94fa) |
| `CorroborationLog` | records deeds whose two witnesses agreed — the data a public score needs | [`0x3106Aa38…b01bd`](https://coston2-explorer.flare.network/address/0x3106Aa38d8dA63bF2E8c075C7efd2F57eB2b01bd) |
| `BondLens` | stateless: what a case would take, before paying for a single attestation | [`0x61f4AE82…411FC`](https://coston2-explorer.flare.network/address/0x61f4AE8250Fb7Ec58dF1F979cA43c80A3e2411FC) |

Challenges on the `Bond`, each behind a commit–reveal gate so the reward belongs to whoever found the violation, not to whoever copied the calldata:

| Challenge | What it proves | FDC attestation | SPEC |
|---|---|---|---|
| `challengeFalsePayment` | the receipt claims a payment that never happened | `ReferencedPaymentNonexistence` | §6.1 |
| `challengeBudgetOverrun` | the sum of real deeds exceeds the budget (native or ERC-20, per the mandate) | `EVMTransaction` | §6.2–6.3 |
| `challengeBudgetOverrunPayment` | the same, for XRP payments on XRPL | `Payment` | §6.8 |
| `challengeUnderReportedSpend` | the effector's tally said less than the world shows | `EVMTransaction` | §6.5 |
| `accuseUnanchoredDeed` → `answerAccusation` / `resolveAccusation` | an exclusive agent acted and wrote nothing down | `EVMTransaction` | §6.4 |

## Who this is for

- **Teams giving agents wallets** (x402, MCP tools, trading agents) who need a spending limit that holds across calls, not per call.
- **Anyone who underwrites or lends to an agent.** A bond with a public mandate, a proportional penalty and a record that cannot be curated by the agent is something a counterparty can price.
- **Watchers.** Anyone can bring a case. Attestation fees come back first (up to what the verdict takes), then 10 % of the rest, and commit–reveal keeps that reward from being front-run.
- **Receipt and identity standards** (ERC-8004 reputation registries, KYA-OS, ACTA): DELICTI verdicts are an input they can consume — reputation from corroborated deeds, not declarations.

## Limits, stated up front

The section of the [SPEC](SPEC.md) to read first is §10, *what DELICTI does not claim*. The ones a reader deciding whether to rely on this should meet here:

- **Testnet only, not audited.** Everything runs on Coston2 and forks. Slither and a 300,000-call invariant campaign have run; an independent audit has not.
- **Consequence is after the fact; prevention is optional.** FDC finality is minutes. The brake refuses a dead or borrowed mandate and the slice that would break the budget — but only in effectors that choose to check.
- **On XRPL, DELICTI sees XRP `Payment`s and nothing else.** Offers, escrows, AMM deposits and issued currencies (RLUSD included) are outside what the FDC `Payment` attestation covers. SPEC §6.9 names the condition under which that changes.
- **Small bonds are not watched.** A verdict needs someone to bring it; the reward covers the cost of proving a case only when 10 % of the bond exceeds the attestation fees (20 FLR per request on mainnet).
- **Proportional up to the bond, not beyond.** Past an overrun equal to the budget, further units are free; only a larger bond moves that ceiling.
- **Deeds, not minds.** It proves what happened and whether it was permitted. It does not prove intent, alignment or reasoning.
- **Whitehat only.** Never run against mainnet funds that are not yours.

## Roadmap

In order. Nothing below is promoted before the item above it is live.

1. **XRPL, live.** `challengeBudgetOverrunPayment` and `AgentRefs.prove` executed on Coston2 against real testXRP payments — the flagship of v0.9 with no on-chain proof yet.
2. **Adversarial audit** of v0.9 and the long invariant campaign on the final code.
3. **Public score** — coverage, corroboration and contradiction rates per agent, computed from logs and state alone ([SPEC §11](SPEC.md#11-metrics-this-makes-possible)).
4. **Verdicts as native XRPL credentials** (XLS-70 / XLS-80), issued and deleted by a Protocol Managed Wallet under Flare Confidential Compute ([SPEC §13](SPEC.md#13-roadmap-delicti-verdicts-as-native-xrpl-credentials-specified-not-implemented), specified, not implemented).
5. **A risk market** priced on those scores.

## FAQ

**How do I cap an AI agent's total spending, not just each payment?**
Commit a mandate with a budget in `MandateRegistry`, have the effector read `SpendMeter.wouldExceed` before each settlement, and post a bond. The meter refuses the slice that would break the budget; if an effector does not check, the sum over FDC-attested deeds convicts after the fact.

**Why Flare?**
It is the only chain with a cross-chain attestation protocol enshrined in consensus. The second witness is not an oracle this project runs; it is the network.

**Does it work with MCP and x402?**
Yes. [flario](https://github.com/dziuba0x/flario), an MCP server for Flare, is the first effector that speaks DELICTI: it binds `mandate_ref` into its `flario-receipt/2`, and with `DELICTI_REGISTRY` set it refuses a payment before funds move when the mandate is dead or not the payer's.

**Is this a replacement for ERC-8004?**
No. ERC-8004 gives agents identity and a place to record reputation. DELICTI produces the kind of evidence that reputation should be built from.

**Who judges?**
Nobody. A verdict is a transaction that verifies FDC proofs against the Relay's Merkle root and applies a rule fixed in code. There are no jurors, no votes, no admin key.

## Witness 1 from a real effector

```
x402 payload  →  flario checks MandateRegistry.isLive + agent  →  settles  →  x402_receipt{mandate_ref, fdc_attestation_ref}
tools/delicti.py normalize receipt.json   →  leaf + leafHash (== Receipts.hash on-chain)
tools/delicti.py tree leaf*.json          →  root for AnchorLog.anchor + per-leaf proofs for Bond
```

The effector is the final common pathway — a deed with no mandate is a muscle moving with no signal, so the effector may simply not move.

## Evidence classes

- **A** — two witnesses agree (receipt + FDC attestation of the effect).
- **B** — one witness; the effect is not observable in the world (e.g. an email sent).
- **C** — self-report only.

## Documents

- [SPEC.md](SPEC.md) — v0.6 draft: vocabulary, trust model, challenge invariants, bond economics, non-claims, metrics, XRPL credentials roadmap.
- [CHANGELOG.md](CHANGELOG.md) — every release with the reasoning behind each decision, including the ones that went against the plan.
- [docs/DEPLOYMENTS.md](docs/DEPLOYMENTS.md) — every Coston2 deployment and live run since v0.1.
- [docs/proposals/kya-os-mandate-ref.md](docs/proposals/kya-os-mandate-ref.md) — `mandate_ref` proposed to the receipt ecosystems.
- [SECURITY.md](SECURITY.md) — how to report a vulnerability.

## Citing

If you use DELICTI in research, GitHub's *Cite this repository* button (from [CITATION.cff](CITATION.cff)) gives BibTeX and APA.

## License

MIT — [Dziuba Technology](https://github.com/dziuba0x). Built in Warsaw.
