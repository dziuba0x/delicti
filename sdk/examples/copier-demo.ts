/**
 * Why a copier earns nothing (v0.15, SPEC §8.4) — live.
 *
 *   tsx examples/copier-demo.ts <mandateId>
 *
 * A watcher pays for the attestations of an XRPL mandate's new outflows THROUGH THE VAULT, and
 * fetches the proofs. A copier — who paid for nothing — files those very proofs first. In v0.14 the
 * copier would have taken every stipend; since v0.15 the stipends go to the watcher, who paid, and
 * the copier has only paid the gas to deliver them.
 *
 * Env: PRIVATE_KEY (the watcher), COPIER_KEY (optional; a fresh one is made and funded), VERIFIER_*, DA_URL.
 */
import { createPublicClient, createWalletClient, defineChain, http, parseEther, type Hex } from "viem";
import { generatePrivateKey, privateKeyToAccount } from "viem/accounts";
import { coston2, Fdc, XrplHistory, XrplOutflowWatcher, judgeXrplAbi, vaultAbi } from "../src/index.js";

const id = BigInt(process.argv[2] ?? "0");
const net = { ...coston2, rpcUrl: process.env.COSTON2_RPC ?? coston2.rpcUrl };
const chain = defineChain({ id: 114, name: "coston2", nativeCurrency: { name: "C2FLR", symbol: "C2FLR", decimals: 18 }, rpcUrls: { default: { http: [net.rpcUrl] } } });
const pc = createPublicClient({ chain, transport: http(net.rpcUrl) });
const watcher = createWalletClient({ account: privateKeyToAccount(process.env.PRIVATE_KEY as Hex), chain, transport: http(net.rpcUrl) });
const copier = createWalletClient({ account: privateKeyToAccount((process.env.COPIER_KEY as Hex) ?? generatePrivateKey()), chain, transport: http(net.rpcUrl) });
const fdc = new Fdc(net, { verifierUrl: process.env.VERIFIER_URL!, daUrl: process.env.DA_URL!, apiKey: process.env.VERIFIER_API_KEY! }, pc as any);
const history = new XrplHistory(net.xrpl.rpcUrl, process.env.VERIFIER_URL!, process.env.VERIFIER_API_KEY!);
const vault = net.contracts.vault;
const owed = (a: Hex) => pc.readContract({ address: vault, abi: vaultAbi, functionName: "owed", args: [a] });

const w = new XrplOutflowWatcher({ network: net, publicClient: pc as any, wallet: watcher, fdc, history, mandateId: id });
const { s, plan } = await w.observe();
if (plan.action !== "record") throw new Error(`expected new outflow below the budget, got ${plan.action}`);
const agentRef = s.m.agentRef as Hex;
console.log(`mandate #${id}: ${plan.txIds.length} new outflow(s), +${plan.adds} drops, below the budget`);

const reqs: { req: Hex; round: bigint }[] = [];
for (const tx of plan.txIds) {
  const req = await fdc.prepareBalanceDecrease(tx, agentRef);
  reqs.push({ req, round: await fdc.request(watcher, req, vault) }); // paid THROUGH the Vault
  console.log(`watcher ${watcher.account.address} paid for ${tx}`);
}
const proofs = await Promise.all(reqs.map(({ req, round }) => fdc.proof(round, req, "BalanceDecreasingTransaction")));

if ((await pc.getBalance({ address: copier.account.address })) < parseEther("0.3")) {
  await pc.waitForTransactionReceipt({ hash: await watcher.sendTransaction({ to: copier.account.address, value: parseEther("0.5") }) });
}
const [w0, c0] = await Promise.all([owed(watcher.account.address), owed(copier.account.address)]);
const hash = await copier.writeContract({ address: net.contracts.judgeXrpl, abi: judgeXrplAbi, functionName: "fileXrpOutflow", args: [id, proofs as any, `0x${"0".repeat(64)}`] });
await pc.waitForTransactionReceipt({ hash });
const [w1, c1] = await Promise.all([owed(watcher.account.address), owed(copier.account.address)]);
console.log(`copier ${copier.account.address} filed the watcher's proofs first: ${net.explorerUrl}/tx/${hash}`);
console.log(`stipends: watcher +${w1 - w0} wei, copier +${c1 - c0} wei`);
