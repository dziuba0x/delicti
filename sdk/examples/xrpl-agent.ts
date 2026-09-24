/**
 * An XRPL agent under a DELICTI outflow mandate, set up with the SDK, with a paid watch pool.
 *
 *   tsx examples/xrpl-agent.ts new            fund an agent and a counterparty on XRPL testnet;
 *                                             commit a 12-XRP gross-outflow mandate (v0.14 Vault);
 *                                             the XRPL key declares exclusivity by a memo payment;
 *                                             bond 1 C2FLR; principal sets watch terms and funds a
 *                                             pool; agent tops it up. Prints the state to reuse.
 *   tsx examples/xrpl-agent.ts pay <n>        n payments of 3 XRP from the agent
 *   tsx examples/xrpl-agent.ts offer          the agent rests an offer of 5 XRP, the counterparty
 *                                             takes it in its own transaction
 *
 * XRPL signing goes through tools/xrpl_testnet.py (xrpl-py); Flare through viem. State lives in
 * .run/xrpl-agent.json. Env: PRIVATE_KEY (principal = agent's EVM key), VERIFIER_*, DA_URL.
 */
import { execFileSync } from "node:child_process";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { createPublicClient, createWalletClient, defineChain, http, keccak256, parseEther, toHex, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { coston2, Delicti, Fdc, XRP_OUTFLOW_KEY, xrplAddressHash } from "../src/index.js";

const TOOL = new URL("../../tools/xrpl_testnet.py", import.meta.url).pathname;
const STATE = ".run/xrpl-agent.json";
const x = (...args: string[]) => JSON.parse(execFileSync("python3", [TOOL, ...args], { encoding: "utf8" }).trim().split("\n").pop()!);

const net = { ...coston2, rpcUrl: process.env.COSTON2_RPC ?? coston2.rpcUrl };
const chain = defineChain({ id: 114, name: "coston2", nativeCurrency: { name: "C2FLR", symbol: "C2FLR", decimals: 18 }, rpcUrls: { default: { http: [net.rpcUrl] } } });
const pc = createPublicClient({ chain, transport: http(net.rpcUrl) });
const me = createWalletClient({ account: privateKeyToAccount(process.env.PRIVATE_KEY as Hex), chain, transport: http(net.rpcUrl) });
const fdc = new Fdc(net, { verifierUrl: process.env.VERIFIER_URL!, daUrl: process.env.DA_URL!, apiKey: process.env.VERIFIER_API_KEY! }, pc as any);
const delicti = new Delicti(net, pc as any);
const memo = (s: string) => keccak256(toHex(s));

type State = { mandateId: string; agent: { address: string; seed: string }; cp: { address: string; seed: string } };
const load = (): State => JSON.parse(readFileSync(STATE, "utf8"));

const [cmd, arg] = process.argv.slice(2);
if (cmd === "new") {
  const agent = x("fund");
  const cp = x("fund");
  console.log(`XRPL agent ${agent.address}, counterparty ${cp.address}`);
  const now = BigInt(Math.floor(Date.now() / 1000));
  const { id } = await delicti.commitMandate(me, {
    agent: me.account.address,
    terms: `DELICTI: gross XRP outflow of ${agent.address} at most 12 XRP`,
    budget: 12_000_000n,
    validFrom: now - 120n,
    validUntil: now + 7n * 86_400n,
    source: net.xrpl.fdcSource,
    assetKey: XRP_OUTFLOW_KEY,
    agentRef: xrplAddressHash(agent.address),
  });
  console.log(`mandate #${id} committed`);
  mkdirSync(".run", { recursive: true });
  writeFileSync(STATE, JSON.stringify({ mandateId: id.toString(), agent, cp }, null, 1));
  await delicti.acknowledge(me, id);
  const ref = await delicti.xrplStatementRef(id, true);
  const stmt = x("pay", agent.seed, cp.address, "1000", ref);
  console.log(`exclusivity statement ${stmt.txid} (memo ${ref})`);
  await delicti.proveXrplStatement(me, fdc, id, `0x${stmt.txid.toLowerCase()}` as Hex, true);
  await delicti.post(me, id, parseEther("1"));
  await delicti.setWatchTerms(me, id, parseEther("0.05"), 100_000n); // 0.05 C2FLR per deed moving ≥ 0.1 XRP
  await delicti.fundWatch(me, id, parseEther("0.5"));
  console.log(`bonded 1 C2FLR; watch pool 0.5 C2FLR at 0.05 per deed ≥ 0.1 XRP`);
  console.log(JSON.stringify(await delicti.status(id), (_, v) => (typeof v === "bigint" ? v.toString() : v), 1));
} else if (cmd === "pay") {
  const s = load();
  for (let i = 0; i < Number(arg ?? 1); i++) {
    const p = x("pay", s.agent.seed, s.cp.address, "3000000", memo(`outflow ${s.mandateId}/${Date.now()}/${i}`));
    console.log(`payment 3 XRP ${p.txid}`);
  }
} else if (cmd === "offer") {
  const s = load();
  x("trust", s.agent.seed, s.cp.address, "USD", "1000");
  const o = x("offer", s.agent.seed, "5000000", "5", "USD", s.cp.address);
  const t = x("take", s.cp.seed, "5", "USD", "5000000");
  console.log(`offer ${o.txid} resting; TAKEN by the counterparty in ${t.txid} — the agent signed nothing there`);
} else {
  console.error("usage: xrpl-agent.ts new | pay <n> | offer");
  process.exit(2);
}
