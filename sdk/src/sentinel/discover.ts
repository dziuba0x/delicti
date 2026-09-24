import { getAddress, pad, toHex, type Address, type Hex, type PublicClient } from "viem";
import { agentRefsAbi, mandateRegistryAbi, vaultAbi } from "../abi.js";
import { deploymentOf, type DelictiNetwork, type Deployment } from "../networks.js";
import { pad32 } from "../fdc.js";

export type MandateClass =
  /** §6.11: exclusive, ERC-20 on this EVM chain — a watcher needs nothing but the chain. */
  | "erc20-outflow"
  /** §6.10: gross XRP outflow of an exclusive XRPL account — a watcher needs nothing but the ledger. */
  | "xrp-outflow"
  /** Receipted cases (§6.2, §6.3, §6.8): a third party can judge them only with the agent's leaves. */
  | "receipted"
  /** Outside what this sentinel can watch: unacknowledged, another Vault, a source it does not know. */
  | "unwatchable";

export interface MandateInfo {
  id: bigint;
  principal: Address;
  agent: Address;
  budget: bigint;
  validFrom: number;
  validUntil: number;
  revoked: boolean;
  sourceId: Hex;
  assetKey: Hex;
  agentRef: Hex;
  vault: Address;
  deployment?: Deployment;
  acknowledged: boolean;
  exclusive: boolean;
  live: boolean;
  deathTime: number;
  bond: bigint;
  slashed: boolean;
  severity: bigint;
  taken: bigint;
  cls: MandateClass;
  why: string;
  watchPool?: bigint;
  stipendPerDeed?: bigint;
  stipendMinValue?: bigint;
  agentFundedWatch?: bigint;
}

const XRP_OUTFLOW_KEY = pad(toHex("XRP/outflow"), { dir: "right", size: 32 }).toLowerCase();

/**
 * Every mandate the registry holds, read from state (not logs: `nextId` and `get` are enough, and
 * need no index), classified by what a third party can do about it. Unacknowledged mandates are
 * ignored, as SPEC §11.1 says: anyone can commit a mandate naming any address.
 */
export async function discoverMandates(pc: PublicClient, n: DelictiNetwork, from = 1n, concurrency = 8): Promise<MandateInfo[]> {
  const next = await pc.readContract({ address: n.contracts.registry, abi: mandateRegistryAbi, functionName: "nextId" });
  const ids: bigint[] = [];
  for (let i = from; i < next; i++) ids.push(i);
  const out: MandateInfo[] = [];
  for (let k = 0; k < ids.length; k += concurrency) {
    out.push(...(await Promise.all(ids.slice(k, k + concurrency).map((id) => readMandate(pc, n, id)))));
  }
  return out;
}

export async function readMandate(pc: PublicClient, n: DelictiNetwork, id: bigint): Promise<MandateInfo> {
  const reg = n.contracts.registry;
  const r = (functionName: string) => (pc.readContract as (x: unknown) => Promise<any>)({ address: reg, abi: mandateRegistryAbi, functionName, args: [id] });
  const [m, acknowledged, exclusiveEvm, live, death] = await Promise.all([r("get"), r("acknowledged"), r("exclusive"), r("isLive"), r("deathTime")]);
  const dep = deploymentOf(n, m.bond);
  const info: MandateInfo = {
    id, principal: m.principal, agent: m.agent, budget: m.budget, validFrom: Number(m.validFrom), validUntil: Number(m.validUntil),
    revoked: m.revoked, sourceId: m.sourceId, assetKey: m.assetKey, agentRef: m.agentRef, vault: getAddress(m.bond), deployment: dep,
    acknowledged, exclusive: exclusiveEvm, live, deathTime: death >= 2n ** 63n ? Number.MAX_SAFE_INTEGER : Number(death),
    bond: 0n, slashed: false, severity: 0n, taken: 0n, cls: "unwatchable", why: "",
  };
  if (!dep) return { ...info, why: "names a Vault this sentinel does not know" };
  const v = (functionName: string, args: unknown[] = [id]) =>
    (pc.readContract as (x: unknown) => Promise<any>)({ address: dep.vault, abi: vaultAbi, functionName, args });
  // older consequence contracts lack some getters; a missing one reads as zero
  const z = (p: Promise<any>, d: any = 0n) => p.catch(() => d);
  [info.bond, info.slashed, info.severity, info.taken] = await Promise.all([z(v("bondOf")), z(v("slashed"), false), z(v("severityOf")), z(v("slashedAmount"))]);
  if (dep.features.includes("watchPool")) {
    [info.watchPool, info.stipendPerDeed, info.stipendMinValue, info.agentFundedWatch] = await Promise.all([
      v("watchPool"), v("stipendPerDeed"), v("stipendMinValue"), v("watchFunded", [id, m.agent]),
    ]);
  }
  if (!acknowledged) return { ...info, why: "not acknowledged by its agent (SPEC §11.1): not the agent's record" };

  const key = (m.assetKey as string).toLowerCase();
  const isToken = key !== "0x" + "0".repeat(64) && BigInt(key) >> 160n === 0n;
  if (key === XRP_OUTFLOW_KEY) {
    if (!dep.features.includes("xrpDocket")) return { ...info, why: `${dep.version} has no §6.10 docket` };
    const excl = await pc.readContract({ address: n.contracts.agentRefs, abi: agentRefsAbi, functionName: "exclusive", args: [id] });
    if (!excl) return { ...info, cls: "unwatchable", why: "XRP outflow mandate without an exclusivity statement from the XRPL key" };
    return { ...info, exclusive: true, cls: "xrp-outflow", why: "§6.10 gross XRP outflow" };
  }
  if (isToken && (m.sourceId as string).toLowerCase() === pad32(n.fdcSource).toLowerCase()) {
    if (!dep.features.includes("erc20Docket")) return { ...info, cls: "receipted", why: `${dep.version} has no §6.11 docket: receipts only` };
    if (!exclusiveEvm) return { ...info, cls: "receipted", why: "token mandate not declared exclusive: judged on receipts" };
    return { ...info, cls: "erc20-outflow", why: "§6.11 gross ERC-20 outflow" };
  }
  return { ...info, cls: "receipted", why: m.agentRef !== "0x" + "0".repeat(64) ? "§6.8 receipted XRP payments" : "§6.2/§6.3 receipted EVM deeds" };
}

/** Whether a watcher can still do anything for this mandate. The judges ask only that a bond be
 *  left: deeds inside the window can be filed after the mandate dies, until the bond is withdrawn. */
export function actionable(m: MandateInfo): boolean {
  return m.bond > 0n && (m.cls === "erc20-outflow" || m.cls === "xrp-outflow");
}
