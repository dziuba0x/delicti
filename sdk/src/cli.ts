#!/usr/bin/env node
/**
 * delicti-watch — run the §6.11 watcher against one mandate.
 *
 *   delicti-watch erc20 <mandateId> [--once] [--interval <seconds>] [--from-block <n>]
 *   delicti-watch status <mandateId>
 *
 * Env: PRIVATE_KEY (the watcher's key: it pays attestation fees and earns the reward),
 *      VERIFIER_URL, VERIFIER_API_KEY, DA_URL; optional COSTON2_RPC.
 */
import { createPublicClient, createWalletClient, defineChain, http, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { coston2 } from "./networks.js";
import { Fdc } from "./fdc.js";
import { Delicti } from "./client.js";
import { ExplorerLogSource } from "./erc20/logs.js";
import { Erc20OutflowWatcher } from "./erc20/watcher.js";

const need = (k: string) => process.env[k] ?? (console.error(`missing env ${k}`), process.exit(2));
const [cmd, idArg, ...rest] = process.argv.slice(2);
const flag = (f: string) => rest.includes(f);
const opt = (f: string) => (rest.includes(f) ? rest[rest.indexOf(f) + 1] : undefined);
if (!cmd || !idArg) {
  console.error("usage: delicti-watch erc20|status <mandateId> [--once] [--interval s] [--from-block n]");
  process.exit(2);
}

const net = { ...coston2, rpcUrl: process.env.COSTON2_RPC ?? coston2.rpcUrl };
const chain = defineChain({
  id: net.chainId,
  name: net.name,
  nativeCurrency: { name: "C2FLR", symbol: "C2FLR", decimals: 18 },
  rpcUrls: { default: { http: [net.rpcUrl] } },
});
const publicClient = createPublicClient({ chain, transport: http(net.rpcUrl) });
const id = BigInt(idArg);
const json = (x: unknown) => JSON.stringify(x, (_, v) => (typeof v === "bigint" ? v.toString() : v), 2);

if (cmd === "status") {
  console.log(json(await new Delicti(net, publicClient as any).status(id)));
  process.exit(0);
}
if (cmd !== "erc20") {
  console.error(`unknown command ${cmd}`);
  process.exit(2);
}

const wallet = createWalletClient({ account: privateKeyToAccount(need("PRIVATE_KEY") as Hex), chain, transport: http(net.rpcUrl) });
const fdc = new Fdc(net, { verifierUrl: need("VERIFIER_URL"), daUrl: need("DA_URL"), apiKey: need("VERIFIER_API_KEY") }, publicClient as any);
const fromBlock = opt("--from-block");
const watcher = new Erc20OutflowWatcher({
  network: net,
  publicClient: publicClient as any,
  wallet,
  fdc,
  logs: new ExplorerLogSource(net.explorerApi),
  mandateId: id,
  fromBlock: fromBlock ? BigInt(fromBlock) : undefined,
  log: (m) => console.log(`${new Date().toISOString()} ${m}`),
});

const interval = Number(opt("--interval") ?? 60) * 1000;
for (;;) {
  try {
    const r = await watcher.tick();
    if (flag("--once")) {
      console.log(json({ action: r.plan.action, txs: r.txs, docket: r.docket, bond: r.bond, slashed: r.slashed }));
      break;
    }
    if (r.bond === 0n) {
      console.log("bond is empty: nothing left to judge, watcher stops");
      break;
    }
  } catch (e) {
    console.error(`tick failed: ${(e as Error).message}`);
    if (flag("--once")) process.exit(1);
  }
  await new Promise((ok) => setTimeout(ok, interval));
}
