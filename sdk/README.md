# @delicti/sdk

TypeScript for DELICTI, built on [viem](https://viem.sh). It has two parts:

- **`Delicti`**, the calls an integrator makes. A principal commits a mandate and bonds it, an agent accepts it or declares it exclusive, and anyone reads where a mandate stands.
- **`Erc20OutflowWatcher`** and the `delicti-watch` CLI, the party the protocol's economics were written for. It watches an exclusive stablecoin mandate and keeps its §6.11 docket current. When the agent's outflow crosses the budget, it commits, waits out the lead, proves the deeds through the FDC and files the conviction. It needs no receipts and no cooperation from the agent or the facilitator.

v0.13, Coston2 only. Not audited. Whitehat use on testnets.

## An agent under a mandate, in a few lines

```ts
import { Delicti, coston2 } from "@delicti/sdk";

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
npx delicti-watch erc20 12              # every 60 s
npx delicti-watch erc20 12 --once       # one cycle
npx delicti-watch status 12
```

Each cycle goes through these steps:

1. It reads the mandate. It must name this deployment's Vault, have an ERC-20 as its asset, be exclusive, and still have a bond.
2. It finds every `Transfer(from = agent)` of that token since `validFrom`. It uses the explorer's log index for this, because Flare RPCs serve 30 blocks per `eth_getLogs`. The explorer only finds candidates and is never a witness: nothing reaches the judge except inside an FDC proof.
3. It drops logs already on the docket (`eventFiled`) and logs outside the window. It groups the rest by transaction, in ascending hash order, with at most 50 logs per request (the FDC's cap). What is left over waits for the next cycle.
4. **Below the budget:** it requests one `EVMTransaction` attestation per transaction, listing exactly the logs it means to file, and files them. No commitment, no reward. This keeps the docket current.
5. **Past the budget:** it commits first (kind 8, 256-bit random salt), before any attestation makes the case public. It waits for the first voting round that starts `commitLead` after the commitment. Then it attests, files, and the Vault slashes.

The planner (`planErc20`) is pure and tested on its own (`test/planner.test.ts`).

## Tests

```sh
npm test                        # offline: planner, commitment encoding, decoding a real FDC proof
DELICTI_ONLINE=1 npm test       # + a round trip through the live JudgeEvm on Coston2
```

The commitment encoding is pinned to a value the v0.13 Vault computed on-chain. The online test sends a real proof from mandate #11 back to the live judge. The judge passes it through `FdcVerification` and every check, then refuses it with `NothingNew` because it is already filed. That round trip is the proof that the SDK's encoding is the contract's.

## Regenerating the ABIs

`forge build` at the repo root, then `npm run abi`. `src/abi.ts` is generated from the Foundry build and never edited by hand.
