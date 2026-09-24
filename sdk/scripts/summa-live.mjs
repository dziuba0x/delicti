// SUMMA live rehearsal (SPEC amendment v1.1, S.12.8) on Flare Coston2 + XRPL testnet.
//
//   One principal, one agent, two rails, one dollar budget over both:
//     rail A  XRPL testnet: gross XRP outflow of the agent's account (§6.10), exclusive by its XRPL key
//     rail B  Flare Coston2: MockUSDT0 outflow of the agent's EVM address (§6.11), paid x402-style
//             (the agent signs EIP-3009, a facilitator sends)
//     umbrella: at most $10 across both, bonded in VaultSumma
//   Each rail stays well inside its own budget. The sum does not, and kind 9 convicts:
//     3 × 2 XRP on XRPL  → filed as a recording (≈ $9, below the umbrella)
//     2 × 1 mUSDT0 on Flare → committed, attested, filed: the crossing
//   Every deed is priced at the FTSO anchor value of the round it happened in, proven on-chain.
//
// Run from sdk/:  PRIVATE_KEY=0x… node scripts/summa-live.mjs      (RESUME=1 continues from .run/summa-live.json)
// Needs: python3 + xrpl-py (tools/xrpl_testnet.py), forge build output in ../out.
import {
  createPublicClient, createWalletClient, defineChain, http, parseEther, keccak256, toHex, stringToHex, pad,
  decodeAbiParameters, encodeAbiParameters, formatEther, getAddress,
} from "viem";
import { privateKeyToAccount, generatePrivateKey } from "viem/accounts";
import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync, existsSync, mkdirSync } from "node:fs";
import { randomBytes } from "node:crypto";

const ROOT = new URL("../../", import.meta.url).pathname;
const abi = (f, c) => JSON.parse(readFileSync(`${ROOT}out/${f}/${c}.json`, "utf8")).abi;
const env = (k, d) => process.env[k] ?? d ?? (() => { throw new Error(`missing env ${k}`); })();

const RPC = env("COSTON2_RPC", "https://coston2-api.flare.network/ext/C/rpc");
const VERIFIER = env("VERIFIER_URL", "https://fdc-verifiers-testnet.flare.network");
const VKEY = env("VERIFIER_API_KEY", "00000000-0000-0000-0000-000000000000");
const DA = env("DA_URL", "https://ctn2-data-availability.flare.network");
const A = {
  reg: env("REG", "0x2c58fb0504377fef325DceB66219bC6302263AA3"),
  refs: env("REFS", "0x6036B279d6Fe4aB5DAcbea97162C5394B6E0fca0"),
  railVault: env("BOND", "0xB15f5041F4aA2bc212832dfb0e59CD6c0e9a24aF"),
  summa: env("JUDGE_SUMMA", "0x211EB7d798F528B4E66201496bE4Cf7f6A62f644"),
  summaVault: env("VAULT_SUMMA", "0x8Dd62BE6Ee0689e3Eb5960F08a5356a57bD2F354"),
  usdt0: env("USDT0", "0x9Eea43feA502609d0D88DAfd1d64B4e929BF18C2"),
};
const FLARE_REG = "0xaD67FE66660Fb8dFE9d6b1b4240d8650e30F6019";
const XRP_USD = "0x015852502f55534400000000000000000000000000";
const USDT_USD = "0x01555344542f555344000000000000000000000000";
const b32 = (s) => pad(stringToHex(s), { dir: "right", size: 32 });

const chain = defineChain({ id: 114, name: "coston2", nativeCurrency: { name: "C2FLR", symbol: "C2FLR", decimals: 18 }, rpcUrls: { default: { http: [RPC] } } });
const pc = createPublicClient({ chain, transport: http(RPC) });
const principal = createWalletClient({ account: privateKeyToAccount(env("PRIVATE_KEY")), chain, transport: http(RPC) });
const ME = principal.account.address;

const regAbi = abi("MandateRegistry.sol", "MandateRegistry");
const refsAbi = abi("AgentRefs.sol", "AgentRefs");
const vaultAbi = abi("Vault.sol", "Vault");
const summaAbi = abi("JudgeSumma.sol", "JudgeSumma");
const hubAbi = [{ type: "function", name: "requestAttestation", stateMutability: "payable", inputs: [{ type: "bytes" }], outputs: [] }];
const feeAbi = [{ type: "function", name: "getRequestFee", stateMutability: "view", inputs: [{ type: "bytes" }], outputs: [{ type: "uint256" }] }];
const nameAbi = [{ type: "function", name: "getContractAddressByName", stateMutability: "view", inputs: [{ type: "string" }], outputs: [{ type: "address" }] }];
const clockAbi = [
  { type: "function", name: "firstVotingRoundStartTs", stateMutability: "view", inputs: [], outputs: [{ type: "uint64" }] },
  { type: "function", name: "votingEpochDurationSeconds", stateMutability: "view", inputs: [], outputs: [{ type: "uint64" }] },
];
const tokenAbi = [
  { type: "function", name: "mint", stateMutability: "nonpayable", inputs: [{ type: "address" }, { type: "uint256" }], outputs: [] },
  { type: "function", name: "transferWithAuthorization", stateMutability: "nonpayable", inputs: [
    { type: "address", name: "from" }, { type: "address", name: "to" }, { type: "uint256", name: "value" }, { type: "uint256", name: "validAfter" },
    { type: "uint256", name: "validBefore" }, { type: "bytes32", name: "nonce" }, { type: "uint8", name: "v" }, { type: "bytes32", name: "r" }, { type: "bytes32", name: "s" }], outputs: [] },
];

// the Response tuples, straight from the compiled ABI, so the decoder can never drift from the judge
const fnIn = (a, name, i) => a.find((x) => x.type === "function" && x.name === name).inputs[i];
const BDT_RESPONSE = fnIn(summaAbi, "fileXrp", 2).components.find((c) => c.name === "data");
const EVM_RESPONSE = fnIn(summaAbi, "fileErc20", 2).components.find((c) => c.name === "data");
const PAY_RESPONSE = fnIn(refsAbi, "proveExclusive", 1).components.find((c) => c.name === "data");

const sleep = (s) => new Promise((r) => setTimeout(r, s * 1000));
const log = (...a) => console.log(new Date().toISOString().slice(11, 19), ...a);
const STATE = `${ROOT}.run/summa-live.json`;
mkdirSync(`${ROOT}.run`, { recursive: true });
const S = process.env.RESUME === "1" && existsSync(STATE) ? JSON.parse(readFileSync(STATE, "utf8")) : {};
const save = () => writeFileSync(STATE, JSON.stringify(S, (_, v) => (typeof v === "bigint" ? v.toString() : v), 2));

async function send(w, address, abi_, functionName, args = [], value) {
  const hash = await w.writeContract({ address, abi: abi_, functionName, args, value });
  const rc = await pc.waitForTransactionReceipt({ hash });
  if (rc.status !== "success") throw new Error(`${functionName} reverted: ${hash}`);
  return rc;
}
const read = (address, abi_, functionName, args = []) => pc.readContract({ address, abi: abi_, functionName, args });
const xrpl = (...args) => JSON.parse(execFileSync("python3", [`${ROOT}tools/xrpl_testnet.py`, ...args], { encoding: "utf8" }));

// ------------------------------------------------------------------ FDC
const HUB = await read(FLARE_REG, nameAbi, "getContractAddressByName", ["FdcHub"]);
const FEES = await read(FLARE_REG, nameAbi, "getContractAddressByName", ["FdcRequestFeeConfigurations"]);
const FSM = await read(FLARE_REG, nameAbi, "getContractAddressByName", ["FlareSystemsManager"]);
const T0 = await read(FSM, clockAbi, "firstVotingRoundStartTs");
const DUR = await read(FSM, clockAbi, "votingEpochDurationSeconds");

async function prepare(chainPath, type, source, requestBody) {
  const body = { attestationType: b32(type), sourceId: b32(source), requestBody };
  for (let i = 0; i < 45; i++) {
    const r = await fetch(`${VERIFIER}/verifier/${chainPath}/${type}/prepareRequest`, {
      method: "POST", headers: { "X-API-KEY": VKEY, "Content-Type": "application/json" }, body: JSON.stringify(body) });
    const j = await r.json().catch(() => ({}));
    if (j.status === "VALID") return j.abiEncodedRequest;
    await sleep(10); // the verifier's index trails the ledger
  }
  throw new Error(`verifier never VALID for ${type} ${JSON.stringify(requestBody)}`);
}
async function request(req) {
  const fee = await read(FEES, feeAbi, "getRequestFee", [req]);
  const rc = await send(principal, HUB, hubAbi, "requestAttestation", [req], fee);
  const blk = await pc.getBlock({ blockNumber: rc.blockNumber });
  return Number((blk.timestamp - T0) / DUR);
}
async function proof(req, round, responseType) {
  for (let i = 0; i < 45; i++) {
    const r = await fetch(`${DA}/api/v1/fdc/proof-by-request-round-raw`, {
      method: "POST", headers: { "X-API-KEY": VKEY, "Content-Type": "application/json" },
      body: JSON.stringify({ votingRoundId: round, requestBytes: req }) });
    const j = await r.json().catch(() => ({}));
    if (j.response_hex) {
      const [data] = decodeAbiParameters([responseType], j.response_hex);
      return { merkleProof: j.proof, data };
    }
    await sleep(20);
  }
  throw new Error(`no proof for round ${round}`);
}
async function price(feedId, ts) {
  const round = Number((BigInt(ts) - T0) / DUR);
  for (let i = 0; i < 40; i++) {
    const r = await fetch(`${DA}/api/v0/ftso/anchor-feeds-with-proof?voting_round_id=${round}`, {
      method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ feed_ids: [feedId] }) });
    const j = await r.json().catch(() => null);
    if (Array.isArray(j) && j[0]?.proof) return { proof: j[0].proof, body: j[0].body };
    if (i === 0) log(`   (FTSO round ${round} for ts ${ts} not served yet: ${JSON.stringify(j).slice(0, 120)})`);
    await sleep(15); // the round is not finalized yet
  }
  throw new Error(`no FTSO proof for round ${round}`);
}

// ------------------------------------------------------------------ the run
if (!S.agentKey) {
  S.agentKey = generatePrivateKey();
  save();
}
const agentW = createWalletClient({ account: privateKeyToAccount(S.agentKey), chain, transport: http(RPC) });
const AGENT = agentW.account.address;
log(`principal ${ME}  agent ${AGENT}  (JudgeSumma ${A.summa}, VaultSumma ${A.summaVault})`);

if (!S.xrplAgent) {
  log("== 1. XRPL testnet: the agent's account and a counterparty");
  S.xrplAgent = xrpl("fund");
  S.xrplCp = xrpl("fund");
  S.agentRef = keccak256(toHex(S.xrplAgent.address));
  const h = await principal.sendTransaction({ to: AGENT, value: parseEther("1") });
  await pc.waitForTransactionReceipt({ hash: h });
  save();
  log(`   agent XRPL ${S.xrplAgent.address}  agentRef ${S.agentRef}; agent EVM funded 1 C2FLR`);
}

const now = () => BigInt(Math.floor(Date.now() / 1000));
async function commitMandate(budget, sourceId, assetKey, agentRef, bond, text) {
  const t = now();
  const rc = await send(principal, A.reg, regAbi, "commit", [
    AGENT, keccak256(toHex(text)), `0x${"0".repeat(64)}`, 0n, budget, t - 120n, t + 7n * 86400n,
    { sourceId, assetKey, agentRef, bond },
  ]);
  const ev = rc.logs.find((l) => l.address.toLowerCase() === A.reg.toLowerCase());
  return BigInt(ev.topics[1]);
}

if (!S.umbrella) {
  log("== 2. mandates: two rails, one umbrella");
  S.xrpMember = await commitMandate(10_000_000n, b32("testXRP"), b32("XRP/outflow"), S.agentRef, A.railVault,
    `DELICTI rail A: gross XRP outflow of ${S.xrplAgent.address} at most 10 XRP`);
  await send(agentW, A.reg, regAbi, "acknowledge", [S.xrpMember]);
  S.usdtMember = await commitMandate(10_000_000n, b32("testFLR"), pad(A.usdt0, { size: 32 }), `0x${"0".repeat(64)}`, A.railVault,
    `DELICTI rail B: MockUSDT0 outflow of ${AGENT} at most 10`);
  await send(agentW, A.reg, regAbi, "declareExclusive", [S.usdtMember]);
  S.umbrella = await commitMandate(10_000_000n, b32("SUMMA"), b32("USD/1e6"), `0x${"0".repeat(64)}`, A.summaVault,
    "DELICTI umbrella: at most $10, across XRPL and Flare");
  await send(agentW, A.reg, regAbi, "acknowledge", [S.umbrella]);
  await send(principal, A.summaVault, vaultAbi, "post", [S.umbrella], parseEther("2"));
  save();
  log(`   rail A #${S.xrpMember} (10 XRP)  rail B #${S.usdtMember} (10 mUSDT0)  umbrella #${S.umbrella} ($10, bond 2 C2FLR)`);
}

if (!S.exclusiveProven) {
  log("== 3. the XRPL key declares exclusivity for rail A");
  const ref = await read(A.refs, refsAbi, "exclusiveFor", [BigInt(S.xrpMember)]);
  const st = xrpl("pay", S.xrplAgent.seed, S.xrplCp.address, "1000", ref);
  const req = await prepare("xrp", "Payment", "testXRP", { transactionId: `0x${st.txid.toLowerCase()}`, inUtxo: "0", utxo: "0" });
  const round = await request(req);
  log(`   statement ${st.txid} requested in round ${round}`);
  const p = await proof(req, round, PAY_RESPONSE);
  await send(principal, A.refs, refsAbi, "proveExclusive", [BigInt(S.xrpMember), p]);
  S.exclusiveProven = true;
  save();
  log(`   exclusive = ${await read(A.refs, refsAbi, "exclusive", [BigInt(S.xrpMember)])}`);
}

if (!S.linked) {
  log("== 4. the umbrella's agent links both rails");
  await send(agentW, A.summa, summaAbi, "link", [BigInt(S.umbrella), BigInt(S.xrpMember)]);
  await send(agentW, A.summa, summaAbi, "link", [BigInt(S.umbrella), BigInt(S.usdtMember)]);
  S.linked = true;
  save();
  log(`   members: ${(await read(A.summa, summaAbi, "members", [BigInt(S.umbrella)])).join(", ")}`);
  await sleep(5); // deeds strictly after linkedAt
}

if (!S.xrpDeeds) {
  log("== 5. rail A: three payments of 2 XRP (each rail stays inside its own 10)");
  S.xrpDeeds = [];
  for (let i = 0; i < 3; i++) {
    const t = xrpl("pay", S.xrplAgent.seed, S.xrplCp.address, "2000000", keccak256(toHex(`summa ${S.umbrella}/xrp/${i}/${Date.now()}`)));
    S.xrpDeeds.push(`0x${t.txid.toLowerCase()}`);
    log(`   ${t.txid}`);
  }
  save();
}

if (!S.xrpFiled) {
  log("== 6. file rail A on the umbrella's docket: a recording, below $10, no commitment");
  const ids = [...S.xrpDeeds].sort((a, b) => (BigInt(a) < BigInt(b) ? -1 : 1));
  if (!S.xrpReqs) {
    S.xrpReqs = [];
    for (const id of ids) {
      const req = await prepare("xrp", "BalanceDecreasingTransaction", "testXRP", { transactionId: id, sourceAddressIndicator: S.agentRef });
      S.xrpReqs.push([req, await request(req)]);
    }
    save();
  }
  const reqs = S.xrpReqs;
  const proofs = [], prices = [];
  for (const [req, round] of reqs) {
    const p = await proof(req, round, BDT_RESPONSE);
    proofs.push(p);
    prices.push(await price(XRP_USD, p.data.responseBody.blockTimestamp));
    log(`   spent ${p.data.responseBody.spentAmount} drops at ${p.data.responseBody.blockTimestamp}, XRP/USD ${prices.at(-1).body.value / 10 ** prices.at(-1).body.decimals}`);
  }
  const rc = await send(principal, A.summa, summaAbi, "fileXrp", [BigInt(S.umbrella), BigInt(S.xrpMember), proofs, prices, `0x${"0".repeat(64)}`]);
  S.xrpFiledTx = rc.transactionHash;
  S.xrpFiled = true;
  save();
  log(`   filed ${rc.transactionHash}: docket = $${Number(await read(A.summa, summaAbi, "docket", [BigInt(S.umbrella)])) / 1e6}`);
}

if (!S.usdtDeeds) {
  log("== 7. rail B: two x402 settlements of 1 mUSDT0 (agent signs, facilitator sends)");
  await send(principal, A.usdt0, tokenAbi, "mint", [AGENT, 2_000_000n]);
  S.usdtDeeds = [];
  const payee = getAddress("0x2222222222222222222222222222222222222222");
  for (let i = 0; i < 2; i++) {
    const nonce = toHex(randomBytes(32));
    const validBefore = now() + 3600n;
    const sig = await agentW.signTypedData({
      domain: { name: "Mock USDT0", version: "1", chainId: 114, verifyingContract: A.usdt0 },
      types: { TransferWithAuthorization: [
        { name: "from", type: "address" }, { name: "to", type: "address" }, { name: "value", type: "uint256" },
        { name: "validAfter", type: "uint256" }, { name: "validBefore", type: "uint256" }, { name: "nonce", type: "bytes32" }] },
      primaryType: "TransferWithAuthorization",
      message: { from: AGENT, to: payee, value: 1_000_000n, validAfter: 0n, validBefore, nonce },
    });
    const r = `0x${sig.slice(2, 66)}`, s = `0x${sig.slice(66, 130)}`, v = parseInt(sig.slice(130, 132), 16);
    const rc = await send(principal, A.usdt0, tokenAbi, "transferWithAuthorization", [AGENT, payee, 1_000_000n, 0n, validBefore, nonce, v, r, s]);
    S.usdtDeeds.push(rc.transactionHash);
    log(`   ${rc.transactionHash}`);
  }
  save();
}

const sortedUsdt = () => [...S.usdtDeeds].sort((a, b) => (BigInt(a) < BigInt(b) ? -1 : 1));
if (!S.salt) {
  log("== 8. commit kind 9 over the crossing deeds, then wait out commitLead");
  S.salt = keccak256(toHex(randomBytes(32)));
  const digest = await read(A.summaVault, vaultAbi, "deedsDigest", [sortedUsdt()]);
  const c = await read(A.summaVault, vaultAbi, "commitmentFor", [ME, BigInt(S.umbrella), 9, digest, S.salt]);
  await send(principal, A.summaVault, vaultAbi, "commitChallenge", [c]);
  S.commitTs = Number(await read(A.summaVault, vaultAbi, "committedAt", [c]));
  save();
}
{
  const lead = Number(await read(A.summaVault, vaultAbi, "commitLead"));
  const r = Math.ceil((S.commitTs + lead - Number(T0)) / Number(DUR));
  const target = Number(T0) + r * Number(DUR);
  const wait = target - Number(now()) + 10;
  if (wait > 0 && !S.usdtRequests) { log(`   sleeping ${wait}s until round ${r} starts`); await sleep(wait); }
}

if (!S.usdtRequests) {
  log("== 9. EVMTransaction attestations for the crossing deeds");
  S.usdtRequests = [];
  for (const h of sortedUsdt()) {
    const req = await prepare("flr", "EVMTransaction", "testFLR", { transactionHash: h, requiredConfirmations: "1", provideInput: false, listEvents: true, logIndices: [] });
    S.usdtRequests.push([req, await request(req)]);
  }
  save();
}

log("== 10. the crossing filing");
const proofs = [], prices = [];
for (const [req, round] of S.usdtRequests) {
  const p = await proof(req, round, EVM_RESPONSE);
  proofs.push(p);
  prices.push(await price(USDT_USD, p.data.responseBody.timestamp));
  log(`   tx at ${p.data.responseBody.timestamp}, USDT/USD ${prices.at(-1).body.value / 10 ** prices.at(-1).body.decimals}`);
}
const rc = await send(principal, A.summa, summaAbi, "fileErc20", [BigInt(S.umbrella), BigInt(S.usdtMember), proofs, prices, S.salt]);
S.verdictTx = rc.transactionHash;
save();

const U = BigInt(S.umbrella);
log(`== verdict ${rc.transactionHash}  gas ${rc.gasUsed}`);
log(`   docket   $${Number(await read(A.summa, summaAbi, "docket", [U])) / 1e6}  (budget $10)`);
log(`   slashed  ${await read(A.summaVault, vaultAbi, "slashed", [U])}   taken ${formatEther(await read(A.summaVault, vaultAbi, "slashedAmount", [U]))} C2FLR of 2`);
log(`   umbrella live ${await read(A.reg, regAbi, "isLive", [U])};  rails live ${await read(A.reg, regAbi, "isLive", [BigInt(S.xrpMember)])} / ${await read(A.reg, regAbi, "isLive", [BigInt(S.usdtMember)])}`);
