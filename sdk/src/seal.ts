import { keccak256, type Account, type Address, type Chain, type Hex, type PublicClient, type Transport, type WalletClient } from "viem";
import { vaultAbi } from "./abi.js";
import { commitmentFor, randomSalt } from "./commit.js";
import type { Fdc } from "./fdc.js";
import type { Deployment } from "./networks.js";

/**
 * Watch pool v2 (v0.16, SPEC §8.4, docs/v2/watch-pool.md): a stipend is paid to whoever SEALED and
 * paid for the exact attestation that a filed proof answers.
 *
 *   claimKey = keccak256(request)                 the exact bytes: type ‖ source ‖ MIC ‖ abi.encode(body)
 *   seal     = commitmentFor(watcher, 0, KIND_CLAIM, claimKey, salt), committed with `commitChallenge`
 *   then, at least `commitLead` later: Vault.requestAttestation(request, salt), which pays FdcHub
 *
 * A copier learns the key only when the sealed request reaches the mempool: `commitLead` too late to
 * hold a seal of its own. No judge passes verdicts of kind 0, so a seal and a challenge commitment
 * can never spend each other.
 */
export const KIND_CLAIM = 0;

const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000";
const ZERO_SALT = `0x${"0".repeat(64)}` as Hex;

/** `Vault.claimKeyOf(request)`: the hash of the exact request bytes. */
export function claimKeyOf(request: Hex): Hex {
  return keccak256(request);
}

/** The seal a watcher commits for one request. */
export function sealOf(watcher: Address, request: Hex, salt: Hex): Hex {
  return commitmentFor(watcher, 0n, KIND_CLAIM, claimKeyOf(request), salt);
}

/** How each request will be paid for:
 *  - `sealed`: sealed here, paid through the Vault with its salt (v0.16);
 *  - `held`: this watcher already holds the key (a round that failed to attest it), re-sent through the Vault;
 *  - `taken`: someone else holds the key, so the request goes straight to FdcHub (the proof is the same, the stipend is theirs);
 *  - `unsealed`: a v0.15 Vault, paid through it without a seal (watch pool v1);
 *  - `fdcHub`: a Vault from before the watch pool. */
export type ClaimRoute = "sealed" | "held" | "taken" | "unsealed" | "fdcHub";

export interface ClaimPlan {
  vault: Address;
  entries: { request: Hex; route: ClaimRoute; salt?: Hex }[];
  /** The earliest block time at which every seal is at least `commitLead` old (0 when nothing was sealed). */
  payableAt: bigint;
}

type Clients = { publicClient: PublicClient; wallet: WalletClient<Transport, Chain, Account>; say?: (m: string) => void };

/**
 * Seal every request the Vault of `dep` would pay a stipend for, without waiting. Seal before a
 * challenge's own commitment and one wait (`commitAndWait`) covers both.
 */
export async function sealClaims(o: Clients & { dep: Deployment; requests: readonly Hex[] }): Promise<ClaimPlan> {
  const { publicClient: pc, wallet, dep } = o;
  if (!dep.features.includes("sealedClaims")) {
    const route: ClaimRoute = dep.features.includes("paidRequests") ? "unsealed" : "fdcHub";
    return { vault: dep.vault, entries: o.requests.map((request) => ({ request, route })), payableAt: 0n };
  }
  const me = wallet.account.address.toLowerCase();
  const holders = await Promise.all(
    o.requests.map((r) => pc.readContract({ address: dep.vault, abi: vaultAbi, functionName: "claimantOf", args: [claimKeyOf(r)] })),
  );
  const entries: ClaimPlan["entries"] = [];
  let last = 0n;
  for (let i = 0; i < o.requests.length; i++) {
    const request = o.requests[i];
    const holder = String(holders[i]).toLowerCase();
    if (holder === me) { entries.push({ request, route: "held" }); continue; }
    if (holder !== ZERO_ADDRESS) { entries.push({ request, route: "taken" }); continue; }
    const salt = randomSalt();
    const seal = sealOf(wallet.account.address, request, salt);
    const tx = await wallet.writeContract({ address: dep.vault, abi: vaultAbi, functionName: "commitChallenge", args: [seal] });
    const rc = await pc.waitForTransactionReceipt({ hash: tx });
    if (rc.status !== "success") throw new Error(`commitChallenge (seal) reverted: ${tx}`);
    const at = BigInt(await pc.readContract({ address: dep.vault, abi: vaultAbi, functionName: "committedAt", args: [seal] }));
    if (at > last) last = at;
    entries.push({ request, route: "sealed", salt });
  }
  let payableAt = 0n;
  if (last !== 0n) {
    const lead = BigInt(await pc.readContract({ address: dep.vault, abi: vaultAbi, functionName: "commitLead" }));
    payableAt = last + lead + 2n;
    o.say?.(`sealed ${entries.filter((e) => e.route === "sealed").length} request(s); they can be paid for from t=${payableAt} (commitLead ${lead} s)`);
  }
  return { vault: dep.vault, entries, payableAt };
}

/**
 * Wait until the seals are old enough, then pay for every request along its route. Returns the
 * voting round each request landed in, in order. A sealed request that someone else paid for in
 * the meantime (`AlreadyClaimed`) goes to FdcHub instead: the proof is what the filing needs.
 */
export async function payClaims(o: Clients & { fdc: Fdc; plan: ClaimPlan; sleep?: (ms: number) => Promise<void> }): Promise<bigint[]> {
  const { publicClient: pc, wallet, fdc, plan } = o;
  const sleep = o.sleep ?? ((ms: number) => new Promise<void>((ok) => setTimeout(ok, ms)));
  for (;;) {
    const now = (await pc.getBlock()).timestamp;
    if (now >= plan.payableAt) break;
    await sleep(Number(plan.payableAt - now > 30n ? 30n : plan.payableAt - now) * 1000);
  }
  const rounds: bigint[] = [];
  for (const e of plan.entries) {
    if (e.route === "fdcHub" || e.route === "taken") { rounds.push(await fdc.request(wallet, e.request)); continue; }
    if (e.route === "unsealed") { rounds.push(await fdc.request(wallet, e.request, plan.vault)); continue; }
    try {
      rounds.push(await fdc.request(wallet, e.request, { vault: plan.vault, salt: e.salt ?? ZERO_SALT }));
    } catch (err) {
      if (!String((err as Error).message).includes("AlreadyClaimed")) throw err;
      o.say?.(`someone else paid for ${claimKeyOf(e.request)} first; requesting it from FdcHub directly`);
      e.route = "taken";
      rounds.push(await fdc.request(wallet, e.request));
    }
  }
  return rounds;
}

/** Seal, wait and pay in one step: for a filing that needs no challenge commitment of its own. */
export async function requestAttestations(
  o: Clients & { fdc: Fdc; dep: Deployment; requests: readonly Hex[]; sleep?: (ms: number) => Promise<void> },
): Promise<{ plan: ClaimPlan; rounds: bigint[] }> {
  const plan = await sealClaims(o);
  return { plan, rounds: await payClaims({ ...o, plan }) };
}
