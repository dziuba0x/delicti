import { getAddress, type Account, type Address, type Chain, type Hex, type PublicClient, type Transport, type WalletClient } from "viem";
import { judgeEvmAbi, mandateRegistryAbi, vaultAbi } from "../abi.js";
import { Kind } from "../commit.js";
import { Fdc, type FdcProof } from "../fdc.js";
import { commitAndWait } from "../lead.js";
import { deploymentOf, type DelictiNetwork, type Deployment } from "../networks.js";
import type { LogSource, OutflowLog } from "./logs.js";
import { planErc20, type Plan, type TxFiling } from "./planner.js";

export interface WatcherOptions {
  network: DelictiNetwork;
  publicClient: PublicClient;
  wallet: WalletClient<Transport, Chain, Account>;
  fdc: Fdc;
  logs: LogSource;
  mandateId: bigint;
  /** The consequence layer the mandate is bonded in; found from the mandate's `bond` if omitted. */
  deployment?: Deployment;
  /** First block to scan; found by binary search on the mandate's `validFrom` if omitted. */
  fromBlock?: bigint;
  log?: (msg: string) => void;
}

export interface TickResult {
  plan: Plan;
  txs: Hex[];
  docket?: bigint;
  bond?: bigint;
  slashed?: boolean;
}

/**
 * The §6.11 watcher: the party the protocol's economics were written for. Each `tick` reads the
 * mandate, finds every outflow of its token from its agent, and either files what is new below
 * the budget (no commitment) or — when the new outflow takes the docket past the budget — commits,
 * waits out the lead, and files the conviction. Nothing it files rests on the explorer or the RPC:
 * every log reaches the judge inside an FDC proof, or not at all.
 */
export class Erc20OutflowWatcher {
  private fromBlock?: bigint;
  private dep?: Deployment;
  constructor(readonly o: WatcherOptions) {
    this.fromBlock = o.fromBlock;
    this.dep = o.deployment;
  }

  private say(m: string) {
    (this.o.log ?? console.log)(`[§6.11 #${this.o.mandateId}] ${m}`);
  }

  async state() {
    const { publicClient: pc, network: n, mandateId: id } = this.o;
    const m = await pc.readContract({ address: n.contracts.registry, abi: mandateRegistryAbi, functionName: "get", args: [id] });
    this.dep ??= deploymentOf(n, m.bond);
    if (!this.dep || getAddress(m.bond) !== getAddress(this.dep.vault)) throw new Error(`mandate #${id} names an unknown Vault ${m.bond}`);
    if (!this.dep.features.includes("erc20Docket")) throw new Error(`mandate #${id} is bonded in ${this.dep.version}, which has no §6.11 docket`);
    const d = this.dep;
    if (BigInt(m.assetKey) >> 160n !== 0n || BigInt(m.assetKey) === 0n) throw new Error(`mandate #${id} is not an ERC-20 mandate`);
    const token = getAddress(("0x" + m.assetKey.slice(26)) as Hex);
    const [exclusive, bond, docket, slashed] = await Promise.all([
      pc.readContract({ address: n.contracts.registry, abi: mandateRegistryAbi, functionName: "exclusive", args: [id] }),
      pc.readContract({ address: d.vault, abi: vaultAbi, functionName: "bondOf", args: [id] }),
      pc.readContract({ address: d.judgeEvm, abi: judgeEvmAbi, functionName: "erc20Docket", args: [id] }),
      pc.readContract({ address: d.vault, abi: vaultAbi, functionName: "slashed", args: [id] }),
    ]);
    return { m, token, exclusive, bond, docket, slashed };
  }

  /** First block with timestamp ≥ t, by binary search over the chain (~25 reads). */
  private async blockAt(t: bigint): Promise<bigint> {
    const pc = this.o.publicClient;
    let lo = 0n;
    let hi = await pc.getBlockNumber();
    while (lo < hi) {
      const mid = (lo + hi) / 2n;
      const b = await pc.getBlock({ blockNumber: mid });
      if (b.timestamp < t) lo = mid + 1n;
      else hi = mid;
    }
    return lo;
  }

  private async filed(logs: OutflowLog[]): Promise<Set<string>> {
    const { publicClient: pc, mandateId: id } = this.o;
    const flags = await Promise.all(
      logs.map((l) =>
        pc.readContract({ address: this.dep!.judgeEvm, abi: judgeEvmAbi, functionName: "eventFiled", args: [id, l.txHash, l.logIndex] }),
      ),
    );
    return new Set(logs.filter((_, i) => flags[i]).map((l) => `${l.txHash.toLowerCase()}:${l.logIndex}`));
  }

  /** Look and plan, without acting: what the sentinel and the score read. */
  async observe() {
    const s = await this.state();
    this.fromBlock ??= await this.blockAt(s.m.validFrom);
    const logs = await this.o.logs.outflows(s.token, s.m.agent, this.fromBlock, "latest");
    const done = await this.filed(logs);
    const plan = planErc20(logs, (l) => done.has(`${l.txHash.toLowerCase()}:${l.logIndex}`), {
      budget: s.m.budget,
      validFrom: Number(s.m.validFrom),
      validUntil: Number(s.m.validUntil),
      docket: s.docket,
      bond: s.bond,
      exclusive: s.exclusive,
    });
    return { s, logs, plan };
  }

  /** One cycle: look, plan, act. Safe to call on a timer; idle when there is nothing to do. */
  async tick(): Promise<TickResult> {
    const { s, logs, plan } = await this.observe();
    if (plan.action === "idle") {
      this.say(`idle: ${plan.reason} (docket ${s.docket} / budget ${s.m.budget}, ${logs.length} outflow logs seen)`);
      return { plan, txs: [], docket: s.docket, bond: s.bond, slashed: s.slashed };
    }
    this.say(`${plan.action}: ${plan.filings.length} new transaction(s), +${plan.adds} → docket ${s.docket + plan.adds} / budget ${s.m.budget}`);
    const txs = plan.action === "record" ? [await this.file(plan.filings, `0x${"0".repeat(64)}` as Hex)] : await this.convict(plan.filings);
    const after = await this.state();
    this.say(`docket ${after.docket}, bond ${after.bond}, slashed ${after.slashed}`);
    return { plan, txs, docket: after.docket, bond: after.bond, slashed: after.slashed };
  }

  /** Commit first — before any attestation makes the case public — then wait out the lead. */
  private async convict(filings: TxFiling[]): Promise<Hex[]> {
    const { publicClient, wallet, mandateId, fdc } = this.o;
    const { salt, commitTx } = await commitAndWait({
      publicClient, wallet, fdc, vault: this.dep!.vault, mandateId, kind: Kind.ERC20_OUTFLOW,
      ids: filings.map((f) => f.txHash), say: (m) => this.say(m),
    });
    return [commitTx, await this.file(filings, salt)];
  }

  private async prove(filings: TxFiling[]): Promise<FdcProof[]> {
    const { fdc, wallet } = this.o;
    const reqs: { req: Hex; round: bigint }[] = [];
    for (const f of filings) {
      const req = await fdc.prepareEvmTransaction(f.txHash, f.logIndices);
      reqs.push({ req, round: await fdc.request(wallet, req, this.dep!.features.includes("paidRequests") ? this.dep!.vault : undefined) });
      this.say(`attestation requested for ${f.txHash} (logs ${f.logIndices.join(",")})`);
    }
    return Promise.all(reqs.map(({ req, round }) => fdc.proof(round, req)));
  }

  private async file(filings: TxFiling[], salt: Hex): Promise<Hex> {
    const { network: n, wallet, mandateId: id } = this.o;
    const proofs = await this.prove(filings);
    const hash = await wallet.writeContract({ address: this.dep!.judgeEvm, abi: judgeEvmAbi, functionName: "fileErc20Outflow", args: [id, proofs as any, salt] });
    await this.mined(hash, "fileErc20Outflow");
    this.say(`filed: ${n.explorerUrl}/tx/${hash}`);
    return hash;
  }

  private async mined(hash: Hex, what: string) {
    const rc = await this.o.publicClient.waitForTransactionReceipt({ hash });
    if (rc.status !== "success") throw new Error(`${what} reverted: ${hash}`);
  }
}

export type { Address };
