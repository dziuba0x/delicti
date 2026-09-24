import type { Address, PublicClient } from "viem";
import { vaultAbi } from "../abi.js";
import type { DelictiNetwork } from "../networks.js";
import type { MandateInfo } from "./discover.js";

/** What a watcher saw of one mandate: the chain's own account of its deeds, next to the docket. */
export interface Observation {
  mandateId: string;
  cls: MandateInfo["cls"];
  account?: string;
  /** Outflow the watcher found inside the window, in the mandate's unit. */
  seen: string;
  /** Of which not yet on the docket. */
  unfiled: string;
  /** Deeds past the verifier's memory that nobody filed: lost to any case, for ever. */
  lost: number;
  docket: string;
  budget: string;
  plan: string;
  checkedAt: number;
}

export type Standing = "convicted" | "breach-unjudged" | "clean" | "unbonded" | "unobserved";

export interface AgentScore {
  agent: Address;
  xrplAccounts: string[];
  standing: Standing;
  mandates: number;
  acknowledged: number;
  exclusive: number;
  /** Bond still at stake across its mandates, wei. */
  bonded: string;
  verdicts: number;
  /** Taken from its bonds by verdicts, wei, across every Vault. */
  taken: string;
  /** The highest share of a budget its proven or observed outflow reached, in basis points. */
  worstUseBps: number;
  /** Mandates whose watching is paid for (a watch pool with terms), and those the agent funded itself. */
  watched: number;
  selfWatched: number;
  flags: string[];
}

/**
 * A public score (SPEC §11), computed from state and the source chains alone. Deliberately not a
 * single number: a composite hides its weights, and weights are exactly what a counterparty should
 * choose for itself. Each facet here is a fact anyone can recompute:
 *
 * - `standing` is the headline. "breach-unjudged" is the alarm: the chain shows more outflow than
 *   the budget, and no verdict yet. It exists because the watcher counts what the docket does not.
 * - `worstUseBps` is headroom: how close the agent has come to a budget, proven or not.
 * - `selfWatched` counts mandates whose watch pool the agent funded itself (v0.14): an agent
 *   paying strangers to catch it is a statement no prose can make.
 */
export async function scoreAgents(pc: PublicClient, n: DelictiNetwork, mandates: MandateInfo[], obs: Map<string, Observation>): Promise<AgentScore[]> {
  const byAgent = new Map<string, MandateInfo[]>();
  for (const m of mandates) {
    const k = m.agent.toLowerCase();
    (byAgent.get(k) ?? byAgent.set(k, []).get(k)!).push(m);
  }
  const vaults = [n.contracts.vault, ...n.history.map((d) => d.vault)];
  const out: AgentScore[] = [];
  for (const [, ms] of byAgent) {
    const agent = ms[0].agent;
    const acks = ms.filter((m) => m.acknowledged);
    let verdicts = 0;
    let taken = 0n;
    for (const v of vaults) {
      const [c, t] = await Promise.all([
        pc.readContract({ address: v, abi: vaultAbi, functionName: "verdictsAgainst", args: [agent] }).catch(() => 0n),
        pc.readContract({ address: v, abi: vaultAbi, functionName: "takenFrom", args: [agent] }).catch(() => 0n),
      ]);
      verdicts += Number(c);
      taken += t as bigint;
    }
    let worst = 0;
    let breach = false;
    const flags: string[] = [];
    const accounts = new Set<string>();
    for (const m of acks) {
      const o = obs.get(m.id.toString());
      if (o?.account) accounts.add(o.account);
      const used = o ? BigInt(o.seen) : 0n;
      const docket = o ? BigInt(o.docket) : 0n;
      const top = used > docket ? used : docket;
      if (m.budget > 0n) worst = Math.max(worst, Number((top * 10_000n) / m.budget));
      if (top > m.budget && !m.slashed) breach = true;
      if (o && o.lost > 0) flags.push(`#${m.id}: ${o.lost} deed(s) lost past the verifier's memory`);
      if (o && BigInt(o.unfiled) > 0n) flags.push(`#${m.id}: ${o.unfiled} of outflow not yet on the docket`);
    }
    const bonded = acks.reduce((s, m) => s + m.bond, 0n);
    const watched = acks.filter((m) => (m.stipendPerDeed ?? 0n) > 0n && (m.watchPool ?? 0n) > 0n).length;
    const selfWatched = acks.filter((m) => (m.agentFundedWatch ?? 0n) > 0n).length;
    const standing: Standing =
      verdicts > 0 ? "convicted" : breach ? "breach-unjudged" : acks.length === 0 ? "unobserved" : bonded === 0n ? "unbonded" : "clean";
    out.push({
      agent, xrplAccounts: [...accounts], standing, mandates: ms.length, acknowledged: acks.length,
      exclusive: acks.filter((m) => m.exclusive).length, bonded: bonded.toString(), verdicts, taken: taken.toString(),
      worstUseBps: worst, watched, selfWatched, flags,
    });
  }
  const rank: Record<Standing, number> = { "breach-unjudged": 0, convicted: 1, unbonded: 2, clean: 3, unobserved: 4 };
  return out.sort((a, b) => rank[a.standing] - rank[b.standing] || b.worstUseBps - a.worstUseBps);
}
