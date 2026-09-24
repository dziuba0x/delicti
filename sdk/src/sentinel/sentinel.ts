import { existsSync, readFileSync, writeFileSync } from "node:fs";
import type { Account, Chain, PublicClient, Transport, WalletClient } from "viem";
import { Erc20OutflowWatcher } from "../erc20/watcher.js";
import { ExplorerLogSource } from "../erc20/logs.js";
import type { Fdc } from "../fdc.js";
import type { DelictiNetwork } from "../networks.js";
import { XrplOutflowWatcher } from "../xrpl/watcher.js";
import type { XrplHistory } from "../xrpl/history.js";
import { actionable, discoverMandates, type MandateInfo } from "./discover.js";
import { quote, type Quote } from "./economics.js";
import { scoreAgents, type AgentScore, type Observation } from "./score.js";

/**
 * - `observe`: look at everything, act on nothing, publish the report. Needs no key.
 * - `profit`: act where the stipends and the reward cover the attestations and the gas.
 * - `altruist`: act on every breach and keep every docket current, whatever it costs — what the
 *   protocol's own reference sentinel does (docs/research/watchers.md: somebody has to).
 */
export type Policy = "observe" | "profit" | "altruist";

export interface SentinelOptions {
  network: DelictiNetwork;
  publicClient: PublicClient;
  wallet?: WalletClient<Transport, Chain, Account>;
  fdc: Fdc;
  xrpl: XrplHistory;
  policy: Policy;
  statePath?: string;
  /** Only these mandates (ids), e.g. for a demonstration; everything by default. */
  only?: bigint[];
  log?: (m: string) => void;
}

export interface Decision {
  mandateId: string;
  cls: string;
  plan: string;
  quote?: Record<string, string | boolean | number>;
  acted: boolean;
  why: string;
  txs?: string[];
  error?: string;
}

export interface RoundReport {
  network: string;
  at: string;
  policy: Policy;
  mandates: { id: string; cls: string; why: string; vault: string; version?: string; live: boolean; bond: string; slashed: boolean; budget: string }[];
  observations: Observation[];
  decisions: Decision[];
  agents: AgentScore[];
}

interface Persisted {
  mandates: Record<string, { account?: string; fromBlock?: string }>;
}

/**
 * The sentinel: every mandate, every round. It discovers mandates from state, sorts them by what a
 * third party can do about them, observes each watchable one against its source chain, prices
 * the work, acts according to its policy, and publishes what it saw as a score.
 *
 * It holds no privileges and no state the protocol depends on: kill it and start another anywhere,
 * and it reaches the same conclusions from the same chains. That is the whole of its
 * decentralisation story, and it is enough — security needs one honest watcher, and anyone can be
 * one (docs/research/watchers.md).
 */
export class Sentinel {
  private erc20 = new Map<string, Erc20OutflowWatcher>();
  private xrp = new Map<string, XrplOutflowWatcher>();
  private persisted: Persisted = { mandates: {} };

  constructor(readonly o: SentinelOptions) {
    if (o.statePath && existsSync(o.statePath)) this.persisted = JSON.parse(readFileSync(o.statePath, "utf8"));
  }

  private say(m: string) {
    (this.o.log ?? console.log)(`[sentinel] ${m}`);
  }

  private save() {
    if (this.o.statePath) writeFileSync(this.o.statePath, JSON.stringify(this.persisted, null, 2));
  }

  private watcherFor(m: MandateInfo): Erc20OutflowWatcher | XrplOutflowWatcher {
    const k = m.id.toString();
    const saved = this.persisted.mandates[k] ?? {};
    const base = { network: this.o.network, publicClient: this.o.publicClient, wallet: this.o.wallet as any, fdc: this.o.fdc, mandateId: m.id, deployment: m.deployment, log: (x: string) => this.say(x) };
    if (m.cls === "erc20-outflow") {
      if (!this.erc20.has(k)) {
        this.erc20.set(k, new Erc20OutflowWatcher({ ...base, logs: new ExplorerLogSource(this.o.network.explorerApi), fromBlock: saved.fromBlock ? BigInt(saved.fromBlock) : undefined }));
      }
      return this.erc20.get(k)!;
    }
    if (!this.xrp.has(k)) this.xrp.set(k, new XrplOutflowWatcher({ ...base, history: this.o.xrpl, account: saved.account }));
    return this.xrp.get(k)!;
  }

  async round(): Promise<RoundReport> {
    const { network: n, publicClient: pc } = this.o;
    let all = await discoverMandates(pc, n);
    if (this.o.only) all = all.filter((m) => this.o.only!.includes(m.id));
    const watchable = all.filter(actionable);
    this.say(`${all.length} mandate(s); ${watchable.length} watchable (bond left, §6.10/§6.11)`);
    const [feeEvm, feeBdt] = await Promise.all([this.o.fdc.feeFor("EVMTransaction", n.fdcSource), this.o.fdc.feeFor("BalanceDecreasingTransaction", n.xrpl.fdcSource)]);
    const observations = new Map<string, Observation>();
    const decisions: Decision[] = [];

    for (const m of watchable) {
      const k = m.id.toString();
      const d: Decision = { mandateId: k, cls: m.cls, plan: "idle", acted: false, why: "" };
      try {
        const w = this.watcherFor(m);
        let planAction: string;
        let proofs = 0;
        let eligible = 0;
        let severityAfter: bigint | undefined;
        const minV = m.stipendMinValue ?? 0n;
        if (w instanceof XrplOutflowWatcher) {
          const ob = await w.observe();
          this.persisted.mandates[k] = { ...this.persisted.mandates[k], account: ob.account };
          const inWindow = ob.moves.filter((mv) => mv.spent > 0n && mv.timestamp >= m.validFrom && mv.timestamp <= m.validUntil);
          const p = ob.plan;
          planAction = p.action;
          if (p.action !== "idle") {
            proofs = p.txIds.length;
            const ids = new Set(p.txIds.map((x) => x.toLowerCase()));
            eligible = inWindow.filter((mv) => ids.has(mv.txId.toLowerCase()) && mv.spent >= minV).length;
            if (p.action === "convict") severityAfter = p.docketAfter - m.budget;
          } else d.why = p.reason;
          observations.set(k, {
            mandateId: k, cls: m.cls, account: ob.account, seen: inWindow.reduce((s, mv) => s + mv.spent, 0n).toString(),
            unfiled: p.action === "idle" ? "0" : p.adds.toString(), lost: p.lost.length, docket: ob.s.docket.toString(), budget: m.budget.toString(),
            plan: p.action, checkedAt: Math.floor(Date.now() / 1000),
          });
        } else {
          const ob = await w.observe();
          const inWindow = ob.logs.filter((l) => l.timestamp >= m.validFrom && l.timestamp <= m.validUntil);
          const p = ob.plan;
          planAction = p.action;
          if (p.action !== "idle") {
            proofs = p.filings.length;
            eligible = p.filings.filter((f) => f.value > 0n && f.value >= minV).length;
            if (p.action === "convict") severityAfter = p.docketAfter - m.budget;
          } else d.why = p.reason;
          observations.set(k, {
            mandateId: k, cls: m.cls, seen: inWindow.reduce((s, l) => s + l.value, 0n).toString(),
            unfiled: p.action === "idle" ? "0" : p.adds.toString(), lost: 0, docket: ob.s.docket.toString(), budget: m.budget.toString(),
            plan: p.action, checkedAt: Math.floor(Date.now() / 1000),
          });
        }
        d.plan = planAction;
        if (planAction === "idle") {
          decisions.push(d);
          continue;
        }
        const q: Quote = await quote(pc, n.contracts.bondLens, m, { action: planAction as "record" | "convict", proofs, eligible, severityAfter }, m.cls === "xrp-outflow" ? feeBdt : feeEvm);
        d.quote = { proofs: q.proofs, cost: q.cost.toString(), stipends: q.stipends.toString(), take: q.take.toString(), reward: q.reward.toString(), worthIt: q.worthIt };
        const go = this.o.policy === "altruist" || (this.o.policy === "profit" && q.worthIt);
        if (!go || !this.o.wallet) {
          d.why = this.o.policy === "observe" || !this.o.wallet ? "observe only" : `not worth it: income ${q.income} < cost ${q.cost}`;
          decisions.push(d);
          continue;
        }
        const r = await w.tick();
        d.acted = true;
        d.txs = r.txs;
        const o = observations.get(k)!;
        observations.set(k, { ...o, unfiled: "0", docket: (r.docket ?? 0n).toString(), plan: `${planAction} (done)` });
        d.why = `${r.plan.action}: docket ${r.docket}, bond ${r.bond}, slashed ${r.slashed}`;
      } catch (e) {
        d.error = (e as Error).message.slice(0, 300);
        this.say(`#${k}: ${d.error}`);
      }
      decisions.push(d);
      this.save();
    }
    this.save();
    const refreshed = await discoverMandates(pc, n);
    const agents = await scoreAgents(pc, n, refreshed.filter((m) => !this.o.only || this.o.only.includes(m.id)), observations);
    return {
      network: n.name,
      at: new Date().toISOString(),
      policy: this.o.policy,
      mandates: refreshed
        .filter((m) => !this.o.only || this.o.only.includes(m.id))
        .map((m) => ({ id: m.id.toString(), cls: m.cls, why: m.why, vault: m.vault, version: m.deployment?.version, live: m.live, bond: m.bond.toString(), slashed: m.slashed, budget: m.budget.toString() })),
      observations: [...observations.values()],
      decisions,
      agents,
    };
  }
}
