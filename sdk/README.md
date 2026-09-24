# @delicti-protocol/sdk

TypeScript for DELICTI, built on [viem](https://viem.sh). It has three parts:

- **`Delicti`**, the calls an integrator makes. A principal commits a mandate and bonds it, an agent accepts it or declares it exclusive, and anyone reads where a mandate stands.
- **`Erc20OutflowWatcher`** and the `delicti-watch` CLI, the party the protocol's economics were written for. It watches an exclusive stablecoin mandate and keeps its §6.11 docket current. When the agent's outflow crosses the budget, it commits, waits out the lead, proves the deeds through the FDC and files the conviction. It needs no receipts and no cooperation from the agent or the facilitator. `XrplOutflowWatcher` does the same for §6.10 on XRPL.
- **`Sentinel`** (`delicti-watch sentinel`) runs across the whole protocol. It discovers every mandate, watches every one a third party can (§6.11 stablecoins on Flare, §6.10 XRP outflow on XRPL), prices each piece of work before buying a single attestation, acts according to its policy, and publishes a per-agent public score (SPEC §11.2).

v0.15, Coston2 and XRPL testnet only. Not audited. Whitehat use on testnets.

## Install

```sh
npm i @delicti-protocol/sdk viem                          # the library (ESM, Node ≥ 22, types included)
npx -p @delicti-protocol/sdk delicti sentinel             # the command line, without installing anything
```

Once installed, the CLI is `delicti` (alias `delicti-watch`).

## An agent under a mandate, in a few lines

```ts
import { Delicti, coston2 } from "@delicti-protocol/sdk";

const delicti = new Delicti(coston2, publicClient);
const { id } = await delicti.commitMandate(principal, {
  agent: agent.account.address,
  terms: "may pay up to 4 USDT0 for data, via x402",
  budget: 4_000_000n,                        // token units (6 decimals)
  validFrom: now, validUntil: now + 86_400n,
  token: USDT0,                              // omit for the native asset
});
await delicti.declareExclusive(agent, id);   // "everything my address does in the window is this mandate's"
await delicti.post(principal, id, parseEther("100"));
// …the agent pays by x402 as usual (it signs, a facilitator sends). Nothing else changes for it.
console.log(await delicti.status(id));       // live, bond, severity, dockets
```

## The watcher

```sh
export PRIVATE_KEY=0x…        # the watcher's own key: pays attestation fees, earns the reward
export VERIFIER_URL=… VERIFIER_API_KEY=… DA_URL=…
npx delicti erc20 12              # every 60 s
npx delicti erc20 12 --once       # one cycle
npx delicti status 12
```

Each cycle goes through these steps:

1. It reads the mandate. It must name this deployment's Vault, have an ERC-20 as its asset, be exclusive, and still have a bond.
2. It finds every `Transfer(from = agent)` of that token since `validFrom`. It uses the explorer's log index for this, because Flare RPCs serve 30 blocks per `eth_getLogs`. The explorer only finds candidates and is never a witness: nothing reaches the judge except inside an FDC proof.
3. It drops logs already on the docket (`eventFiled`) and logs outside the window. It groups the rest by transaction, in ascending hash order, with at most 50 logs per request (the FDC's cap). What is left over waits for the next cycle.
4. **Below the budget:** it requests one `EVMTransaction` attestation per transaction, listing exactly the logs it means to file, and files them. No commitment, no reward. This keeps the docket current.
5. **Past the budget:** it commits first (kind 8, 256-bit random salt), before any attestation makes the case public. It waits for the first voting round that starts `commitLead` after the commitment. Then it attests, files, and the Vault slashes.

The planner (`planErc20`) is pure and tested on its own (`test/planner.test.ts`).

## The XRPL watcher: reading history the way the FDC will

A mandate names its XRPL account only by hash (`agentRef`). The watcher finds the account from the mandate's exclusivity statement: the `ExclusiveProven` event holds the statement's XRPL transaction id, the FDC verifier's index says who signed it, and `keccak256(signer)` must equal `agentRef`.

Reading the account's history takes more care than it seems. `account_tx` over a real window needs a full-history XRPL server; the public testnet endpoint reachable here keeps about 1,300 ledgers, under an hour and a half. But every transaction that moves an account's XRP modifies its AccountRoot, and each modification records the previous transaction that did (`PreviousTxnID`). So the balance history is a linked list, anchored at `account_info`. `XrplHistory.walk` follows it backwards through **the FDC verifier's own index**, about 15 days of full transactions with metadata. It finds exactly what can still be proven, offers taken in other accounts' transactions included, and a balance change that is not on the list did not happen.

```sh
npx delicti xrpl 13 --once          # one mandate
```

## The sentinel

```sh
npx delicti sentinel                                   # observe everything, act on nothing, no key needed
npx delicti sentinel --policy profit --interval 300    # act where stipends + reward cover the cost
npx delicti sentinel --policy altruist --html report.html --out report.json --state sentinel.json
```

Each round goes through five steps:

1. **Discover** every mandate from state (`nextId`, `get`), not from logs.
2. **Classify** each one:
   - §6.11 and §6.10 are watchable by anyone.
   - Receipted cases (§6.2, §6.3, §6.8) are listed. Judging them needs the agent's leaves.
   - Unacknowledged mandates are ignored, as SPEC §11.1 requires.
   - A mandate bonded in an older Vault is watched by that Vault's judges, as far as they can go (`network.history`).
3. **Observe** each watchable mandate against its source chain.
4. **Price** each plan. The cost is attestation fees plus gas. The income is the watch pool's stipends (§8.4, v0.14) plus the reward from `BondLens.penaltyFor`.
5. **Act** according to the policy:
   - `observe`: act on nothing.
   - `profit`: act only where the income covers the cost.
   - `altruist`: act on everything. Somebody has to, and the protocol's own sentinel is altruist (docs/research/watchers.md).

The score it publishes is per agent and deliberately not a single number. The facets are:

- **standing**, where `breach-unjudged` is the alarm: the chain shows more outflow than the budget, and no verdict exists yet;
- verdicts and value taken, across every Vault;
- bond at stake;
- worst budget use;
- watched and self-watched mandates;
- unfiled and lost deeds.

## The watch pool (v0.14, reworked in v0.15)

```ts
await delicti.setWatchTerms(principal, id, parseEther("0.05"), 100_000n); // per new deed moving ≥ 0.1 XRP
await delicti.fundWatch(principal, id, parseEther("0.5"));                // the principal only
```

A stipend is paid to whoever **paid for the deed's attestation through the Vault**
(`Vault.requestAttestation`, which forwards the fee to FdcHub), not to whoever files it. The
watchers do this automatically on v0.15+ deployments. A copier who files someone else's proofs
only pays the gas to deliver their stipends.

## Tests

```sh
npm test                        # offline: both planners, the XRPL history reader on a real taken offer,
                                # the score, commitment encoding, decoding a real FDC proof
DELICTI_ONLINE=1 npm test       # + a round trip through the live JudgeEvm on Coston2
```

The commitment encoding is pinned to a value the v0.13 Vault computed on-chain. The online test sends a real proof from mandate #12 back to its live v0.13 judge. The judge passes it through `FdcVerification` and every check, then refuses it with `NothingNew` because it is already filed. That round trip is the proof that the SDK's encoding is the contract's.

## Regenerating the ABIs

`forge build` at the repo root, then `npm run abi`. `src/abi.ts` is generated from the Foundry build and never edited by hand.
