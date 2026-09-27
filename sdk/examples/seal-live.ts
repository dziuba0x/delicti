/**
 * Watch pool v2, live (v0.16, docs/v2/watch-pool.md): a stipend is paid for sealed work, and the two
 * holes of claude/58 H1 hold nothing.
 *
 *   1. An ERC-20 mandate in the v0.16 Vault: MockUSDT0, budget 10, exclusive (§6.11), bond 0.3 C2FLR,
 *      a watch pool of 0.3 C2FLR paying 0.05 per new deed that moves at least 0.1 USDT0.
 *   2. The agent pays three sellers 1 USDT0 each: three deeds below the budget.
 *   3. The watcher prepares the three EVMTransaction requests and SEALS them.
 *   4. Hole 2, the made-up MIC: an attacker seals the first deed's request with an invented MIC and,
 *      commitLead after its own seal, pays for it first. v0.15 keyed the stipend by (type, source, body):
 *      that request would have held it. Here it is a different claim key, which no proof will ever name.
 *   5. Hole 1, the mempool copier: as the watcher pays, a copier sends the watcher's own request bytes,
 *      once without a seal and once with a seal made that moment. Both are refused on-chain.
 *   6. The watcher pays (commitLead after sealing), waits for the FDC, files the docket. The stipends
 *      go to the watcher (StipendPaid), and the watcher claims them. By then the made-up request's round
 *      is final, and the FDC attested nothing for it.
 *
 * Run from sdk/:  PRIVATE_KEY=0x… npx tsx examples/seal-live.ts     (about 20 minutes; ~1 C2FLR spent)
 * The run's keys go to ../.run/seal-<time>.json (git-ignored) before anything is funded; what is left
 * goes back to the principal at the end, and on Ctrl-C.  Sweep a killed run: … seal-live.ts --sweep <file>
 */
import {
  createPublicClient, createTestClient, createWalletClient, defineChain, encodeAbiParameters, formatEther, http, pad, parseAbi, parseEther,
  parseEventLogs, stringToHex, toHex, type Address, type Hex,
} from "viem";
import { generatePrivateKey, privateKeyToAccount } from "viem/accounts";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { randomBytes } from "node:crypto";
import {
  coston2, Delicti, Erc20OutflowWatcher, ExplorerLogSource, Fdc, deploymentOf, judgeEvmAbi, vaultAbi,
  claimKeyOf, payClaims, sealClaims, sealOf, randomSalt,
} from "../src/index.js";

const RPC = process.env.COSTON2_RPC ?? coston2.rpcUrl;
/** A rehearsal on an anvil fork (lancea/scripts/coston2-fork-proxy.mjs): the FDC and the explorer do not see a
 *  fork, so the requests are built locally and the run stops once the watcher has paid; time is fast-forwarded. */
const FORK = process.env.FORK === "1";
const net = { ...coston2, rpcUrl: RPC };
const USDT0 = "0x9Eea43feA502609d0D88DAfd1d64B4e929BF18C2" as Address; // MockUSDT0 (EIP-3009, public mint)
const ZERO = `0x${"0".repeat(64)}` as Hex;
const chain = defineChain({ id: 114, name: "coston2", nativeCurrency: { name: "C2FLR", symbol: "C2FLR", decimals: 18 }, rpcUrls: { default: { http: [RPC] } } });
const pc = createPublicClient({ chain, transport: http(RPC) });
const w = (k: Hex) => createWalletClient({ account: privateKeyToAccount(k), chain, transport: http(RPC) });
const token = parseAbi(["function mint(address,uint256)", "function transfer(address,uint256) returns (bool)"]);
const log = (...a: unknown[]) => console.log(new Date().toISOString().slice(11, 19), ...a);
const C2 = (wei: bigint) => `${Number(formatEther(wei)).toFixed(4)} C2FLR`;
const json = (d: unknown, s?: number) => JSON.stringify(d, (_, v) => (typeof v === "bigint" ? v.toString() : v), s);
/** The contract's custom error, when viem decoded one: its short message ("… reverted.") leaves the name out. */
const revertName = (e: unknown): string | undefined => {
  for (let x = e as { cause?: unknown; data?: { errorName?: string } } | undefined, i = 0; x && i < 8; x = x.cause as typeof x, i++) {
    if (x.data?.errorName) return x.data.errorName;
  }
  return undefined;
};
const short = (e: unknown) => {
  const first = String((e as { shortMessage?: string })?.shortMessage ?? (e as Error)?.message ?? e).split("\n")[0].slice(0, 200);
  const name = revertName(e);
  return name && !first.includes(name) ? `${first} (${name})` : first;
};

/** Send everything a key holds, less the gas of sending it, to `to`. */
async function sweep(key: Hex, to: Address): Promise<bigint> {
  const from = w(key);
  const [balance, block, tip] = await Promise.all([pc.getBalance({ address: from.account.address }), pc.getBlock(), pc.estimateMaxPriorityFeePerGas()]);
  const maxFee = 2n * (block.baseFeePerGas ?? 0n) + tip, cost = 21_000n * maxFee;
  if (balance <= cost) return 0n;
  await pc.waitForTransactionReceipt({ hash: await from.sendTransaction({ to, value: balance - cost, gas: 21_000n, maxFeePerGas: maxFee, maxPriorityFeePerGas: tip }) });
  return balance - cost;
}

if (process.argv[2] === "--sweep") {
  const run = JSON.parse(readFileSync(process.argv[3], "utf8"));
  for (const [who, key] of Object.entries(run.keys as Record<string, Hex>)) log(`${who}: ${C2(await sweep(key, run.principal))} back`);
  process.exit(0);
}

// ------------------------------------------------------------------ keys, on disk before anything is funded
const principal = w(process.env.PRIVATE_KEY as Hex);
const keys = { agent: generatePrivateKey(), watcher: generatePrivateKey(), attacker: generatePrivateKey() };
const agent = w(keys.agent), watcher = w(keys.watcher), attacker = w(keys.attacker);
const RUN_DIR = new URL("../../.run/", import.meta.url).pathname;
mkdirSync(RUN_DIR, { recursive: true, mode: 0o700 });
const runPath = `${RUN_DIR}seal-${new Date().toISOString().replace(/[:.]/g, "-")}.json`;
const run: Record<string, unknown> = { started: new Date().toISOString(), rpc: RPC, principal: principal.account.address, keys };
const save = () => writeFileSync(runPath, json(run, 2), { mode: 0o600 });
save();

const results: Record<string, unknown> = {};
const failures: string[] = [];
let stopped = false;
async function stage(title: string, fn: () => Promise<void>, prerequisite = true) {
  if (stopped) { log(`== ${title}: skipped`); return; }
  log(`== ${title}`);
  try { await fn(); } catch (e) { failures.push(`${title}: ${short(e)}`); log(`   !! ${short(e)}`); if (prerequisite) stopped = true; }
}
let finished = false;
async function finish(code: number): Promise<never> {
  if (!finished) {
    finished = true;
    const swept: Record<string, string> = {};
    for (const [who, key] of Object.entries(keys)) {
      try { swept[who] = C2(await sweep(key, principal.account.address)); } catch (e) { swept[who] = `not swept: ${short(e)} (use --sweep)`; }
    }
    run.swept = swept; save();
    log(`== swept back to the principal: ${Object.entries(swept).map(([k, v]) => `${k} ${v}`).join(", ")}`);
    log(`== verdict: ${failures.length ? `${failures.length} stage(s) failed` : "every stage as designed"}`);
    for (const f of failures) log(`   ✗ ${f}`);
    console.log("SUMMARY " + json({ ...results, failures, runFile: runPath }));
  }
  process.exit(code);
}
let interruptedAt = 0;
for (const sig of ["SIGINT", "SIGTERM", "SIGHUP"] as const) {
  process.on(sig, () => {
    if (interruptedAt) { if (Date.now() - interruptedAt > 3000) process.exit(130); return; }
    interruptedAt = Date.now();
    log("!! interrupted: sweeping the run's keys back to the principal");
    void finish(130);
  });
}
process.stdout.on("error", () => {});

const delicti = new Delicti(net, pc as any);
const fdc = new Fdc(net, {
  verifierUrl: process.env.VERIFIER_URL ?? "https://fdc-verifiers-testnet.flare.network",
  daUrl: process.env.DA_URL ?? "https://ctn2-data-availability.flare.network",
  apiKey: process.env.VERIFIER_API_KEY ?? "00000000-0000-0000-0000-000000000000",
}, pc as any);
const dep = deploymentOf(net, net.contracts.vault)!;
/** Wait until block time `t`: polling on Coston2, fast-forwarded on a fork. */
const sleepOrWarp = async (ms: number) => {
  if (!FORK) return new Promise<void>((r) => setTimeout(r, ms));
  const t = createTestClient({ chain, mode: "anvil", transport: http(RPC) });
  await t.increaseTime({ seconds: Math.ceil(ms / 1000) });
  await t.mine({ blocks: 1 });
};
const mined = async (hash: Hex, what: string) => {
  const rc = await pc.waitForTransactionReceipt({ hash });
  if (rc.status !== "success") throw new Error(`${what} reverted: ${hash}`);
  return rc;
};

let id = 0n;
let requests: Hex[] = [];
let plan: Awaited<ReturnType<typeof sealClaims>>;
let fake: { request: Hex; salt: Hex; payableAt: bigint } | undefined;

await stage("1. the mandate: MockUSDT0 ≤ 10, exclusive, bonded in the v0.16 Vault, with a watch pool", async () => {
  const have = await pc.getBalance({ address: principal.account.address });
  if (have < parseEther("8")) throw new Error(`the principal has ${C2(have)}; this run needs 8 up front (about 1 is spent)`);
  log(`   keys: ${runPath.slice(runPath.indexOf(".run/"))} | Vault ${dep.vault} (${dep.features.includes("sealedClaims") ? "watch pool v2" : "!! not v0.16"})`);
  for (const [to, v] of [[agent.account.address, "0.5"], [watcher.account.address, "5"], [attacker.account.address, "1"]] as const) {
    await mined(await principal.sendTransaction({ to, value: parseEther(v) }), "fund");
  }
  const now = (await pc.getBlock()).timestamp;
  ({ id } = await delicti.commitMandate(principal as any, { agent: agent.account.address, terms: "watch pool v2 live: MockUSDT0 at most 10", budget: 10_000_000n, validFrom: now - 60n, validUntil: now + 86_400n, token: USDT0 }));
  await delicti.declareExclusive(agent as any, id);
  await delicti.post(principal as any, id, parseEther("0.3"));
  await delicti.setWatchTerms(principal as any, id, parseEther("0.05"), 100_000n);
  await delicti.fundWatch(principal as any, id, parseEther("0.3"));
  run.mandate = id.toString(); save();
  results.mandate = id;
  log(`   mandate #${id}: bond 0.3, watch pool 0.3 C2FLR at 0.05 per deed ≥ 0.1 USDT0`);
});

await stage("2. the agent pays three sellers 1 USDT0 each", async () => {
  await mined(await principal.writeContract({ address: USDT0, abi: token, functionName: "mint", args: [agent.account.address, 3_000_000n] }), "mint");
  const txs: Hex[] = [];
  for (let i = 1; i <= 3; i++) {
    const seller = `0x${String(i).repeat(40)}` as Address;
    txs.push((await mined(await agent.writeContract({ address: USDT0, abi: token, functionName: "transfer", args: [seller, 1_000_000n] }), "transfer")).transactionHash);
  }
  results.deeds = txs;
  log(`   ${txs.join(" ")}`);
});

await stage("3. the watcher prepares the three requests and seals them", async () => {
  if (FORK) { // the verifier cannot see a fork: requests of the real shape, one per deed
    const b32 = (x: string) => pad(stringToHex(x), { dir: "right", size: 32 });
    for (const tx of results.deeds as Hex[]) {
      requests.push(`${b32("EVMTransaction")}${b32("testFLR").slice(2)}${toHex(randomBytes(32)).slice(2)}${encodeAbiParameters(
        [{ type: "bytes32" }, { type: "uint16" }, { type: "bool" }, { type: "bool" }, { type: "uint32[]" }], [tx, 1, false, true, [0]]).slice(2)}` as Hex);
    }
    plan = await sealClaims({ publicClient: pc as any, wallet: watcher as any, dep, requests, say: (m) => log(`   ${m}`) });
    results.claimKeys = requests.map(claimKeyOf);
    return;
  }
  const watch = new Erc20OutflowWatcher({ network: net, publicClient: pc as any, wallet: watcher as any, fdc, logs: new ExplorerLogSource(net.explorerApi), mandateId: id, log: () => {} } as any);
  let filings: { txHash: Hex; logIndices: number[] }[] = [];
  for (let i = 0; i < 30 && filings.length < 3; i++) { // the explorer indexes within a minute or two
    const o = await watch.observe();
    filings = o.plan.action === "idle" ? [] : (o.plan as any).filings;
    if (filings.length < 3) await new Promise((r) => setTimeout(r, 10_000));
  }
  if (filings.length < 3) throw new Error(`the explorer shows ${filings.length} of 3 deeds after 5 minutes`);
  for (const f of filings) requests.push(await fdc.prepareEvmTransaction(f.txHash, f.logIndices));
  plan = await sealClaims({ publicClient: pc as any, wallet: watcher as any, dep, requests, say: (m) => log(`   ${m}`) });
  results.claimKeys = requests.map(claimKeyOf);
});

await stage("4. hole 2: an attacker seals the first deed with a made-up MIC", async () => {
  const r = requests[0];
  const request = `${r.slice(0, 2 + 128)}${toHex(randomBytes(32)).slice(2)}${r.slice(2 + 192)}` as Hex; // type ‖ source ‖ MIC' ‖ body
  const salt = randomSalt(), seal = sealOf(attacker.account.address, request, salt);
  // Coston2 put this seal 12 s after the watcher's first (2026-09-27); a fork mines at once, so its clock moves the same way
  if (FORK) await sleepOrWarp(12_000);
  await mined(await attacker.writeContract({ address: dep.vault, abi: vaultAbi, functionName: "commitChallenge", args: [seal] }), "attacker seal");
  // every payer waits out its OWN seal: this one is younger than the watcher's, so it matures later than plan.payableAt
  const [at, lead] = await Promise.all([
    pc.readContract({ address: dep.vault, abi: vaultAbi, functionName: "committedAt", args: [seal] }),
    pc.readContract({ address: dep.vault, abi: vaultAbi, functionName: "commitLead" }),
  ]);
  fake = { request, salt, payableAt: BigInt(at) + BigInt(lead) + 2n };
  log(`   same type, source and body as deed 1, a different MIC: claim key ${claimKeyOf(request)} (deed 1's is ${claimKeyOf(r)}); payable from t=${fake.payableAt}`);
}, false);

await stage("5. commitLead later: the attacker pays first; a mempool copier tries the watcher's own bytes", async () => {
  // wait out both parties' seals: the watcher's (payClaims waits the same way) and the attacker's, made after them
  const until = fake && fake.payableAt > plan.payableAt ? fake.payableAt : plan.payableAt;
  for (;;) { const now = (await pc.getBlock()).timestamp; if (now >= until) break; await sleepOrWarp(Number(until - now > 15n ? 15n : until - now) * 1000); }
  const wrong: string[] = [];
  if (fake) { // the attacker's payment and the copier's two tries are separate findings: one failing does not hide the others
    try {
      const round = await fdc.request(attacker as any, fake.request, { vault: dep.vault, salt: fake.salt });
      const holder = String(await pc.readContract({ address: dep.vault, abi: vaultAbi, functionName: "claimantOf", args: [claimKeyOf(fake.request)] }));
      results.attackerPaid = { claimKey: claimKeyOf(fake.request), round, claimant: holder };
      log(`   the attacker paid for its made-up request (round ${round}); claimantOf(that key) = ${holder.toLowerCase() === attacker.account.address.toLowerCase() ? "the attacker" : holder}, a key no proof will name`);
    } catch (e) {
      results.attackerPaid = { error: short(e) };
      wrong.push(`the attacker's payment: ${short(e)}`);
      log(`   !! the attacker's payment: ${short(e)}`);
    }
  }
  const [block, tip] = await Promise.all([pc.getBlock(), pc.estimateMaxPriorityFeePerGas()]);
  const fees = { gas: 300_000n, maxFeePerGas: 2n * (block.baseFeePerGas ?? 0n) + tip * 2n, maxPriorityFeePerGas: tip * 2n }; // a higher bid than the watcher's
  const copy = async (what: string, salt: Hex) => {
    const why = await pc.simulateContract({ account: attacker.account, address: dep.vault, abi: vaultAbi, functionName: "requestAttestation", args: [requests[0], salt], value: 1000n })
      .then(() => "none", (e) => revertName(e) ?? short(e));
    // sent anyway, with a set gas limit, so the refusal is on-chain for anyone to see
    const hash = await attacker.writeContract({ address: dep.vault, abi: vaultAbi, functionName: "requestAttestation", args: [requests[0], salt], value: 1000n, ...fees });
    const rc = await pc.waitForTransactionReceipt({ hash });
    log(`   copier, ${what}: ${rc.status === "reverted" ? `REVERTED (${why})` : "!! accepted"} ${hash}`);
    return { hash, status: rc.status, reason: why };
  };
  const bare = await copy("no seal", randomSalt());
  const salt = randomSalt();
  await mined(await attacker.writeContract({ address: dep.vault, abi: vaultAbi, functionName: "commitChallenge", args: [sealOf(attacker.account.address, requests[0], salt)] }), "copier seal");
  const fresh = await copy("a seal made this moment", salt);
  results.copier = { noSeal: bare, freshSeal: fresh };
  if (bare.status !== "reverted" || fresh.status !== "reverted") wrong.push("a copier's request was accepted");
  if (wrong.length) throw new Error(wrong.join("; "));
}, false);

await stage("6. the watcher pays, waits for the FDC and files the docket", async () => {
  const rounds = await payClaims({ publicClient: pc as any, wallet: watcher as any, fdc, plan, say: (m) => log(`   ${m}`), sleep: sleepOrWarp });
  log(`   paid through the Vault (${plan.entries.map((e) => e.route).join(", ")}), rounds ${rounds.join(", ")}; waiting for the proofs`);
  const holders = await Promise.all(requests.map((r) => pc.readContract({ address: dep.vault, abi: vaultAbi, functionName: "claimantOf", args: [claimKeyOf(r)] })));
  results.claimants = holders;
  if (holders.some((h) => String(h).toLowerCase() !== watcher.account.address.toLowerCase())) throw new Error(`claimantOf is not the watcher for every deed: ${holders.join(", ")}`);
  log(`   claimantOf(each deed) = the watcher`);
  if (FORK) { log("   (a fork: the FDC does not attest it, so the rehearsal stops here)"); return; }
  const proofs = await Promise.all(requests.map((req, i) => fdc.proof(rounds[i], req)));
  const rc = await mined(await watcher.writeContract({ address: dep.judgeEvm, abi: judgeEvmAbi, functionName: "fileErc20Outflow", args: [id, proofs as any, ZERO] }), "fileErc20Outflow");
  const paid = parseEventLogs({ abi: vaultAbi, eventName: "StipendPaid", logs: rc.logs });
  results.filing = rc.transactionHash;
  results.stipends = paid.map((e) => ({ claimKey: e.args.claimKey, to: e.args.claimant, paid: e.args.paid }));
  const toWatcher = paid.filter((e) => e.args.claimant.toLowerCase() === watcher.account.address.toLowerCase()).length;
  log(`   filed ${rc.transactionHash}: ${paid.length} stipend(s), ${toWatcher} to the watcher, ${paid.length - toWatcher} to anyone else`);
  const madeUp = results.attackerPaid as { round?: bigint } | undefined;
  let attested = false;
  if (fake && madeUp?.round !== undefined) { // its round is no later than the watcher's, so it is final by now: the DA layer answers at once
    attested = await fdc.proof(madeUp.round, fake.request, "EVMTransaction", 30_000).then(() => true, () => false);
    results.madeUpAttested = attested;
    log(`   the made-up request, round ${madeUp.round}: ${attested ? "!! the FDC attested it" : "the FDC attested nothing for it"}`);
  }
  if (fake) log(`   the made-up request's key was paid: ${paid.some((e) => e.args.claimKey === claimKeyOf(fake!.request)) ? "!! yes" : madeUp?.round !== undefined ? "no" : "no (the attacker never paid for it: see stage 5)"}`);
  const owed = await pc.readContract({ address: dep.vault, abi: vaultAbi, functionName: "owed", args: [watcher.account.address] });
  const claim = await mined(await watcher.writeContract({ address: dep.vault, abi: vaultAbi, functionName: "claim" }), "claim");
  results.claimed = { owed, tx: claim.transactionHash };
  log(`   the watcher claimed ${C2(owed as bigint)}: ${claim.transactionHash}`);
  if (toWatcher !== 3) throw new Error(`expected 3 stipends to the watcher, got ${toWatcher}`);
  if (attested) throw new Error("the FDC attested a request with a made-up MIC");
});

await finish(failures.length ? 1 : 0);
