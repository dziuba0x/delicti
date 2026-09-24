import { getAddress, type Account, type Address, type Chain, type Hex, type PublicClient, type Transport, type WalletClient } from "viem";
import { judgeEvmAbi, mandateRegistryAbi, vaultAbi } from "../abi.js";
import { commitmentFor, deedsDigest, Kind, randomSalt } from "../commit.js";
import { Fdc, type EvmTransactionProof } from "../fdc.js";
import type { DelictiNetwork } from "../networks.js";
import type { LogSource, OutflowLog } from "./logs.js";
import { planErc20, type Plan, type TxFiling } from "./planner.js";

export interface WatcherOptions {
  network: DelictiNetwork;
  publicClient: PublicClient;
  wallet: WalletClient<Transport, Chain, Account>;
  fdc: Fdc;
  logs: LogSource;
  mandateId: bigint;
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
  constructor(readonly o: WatcherOptions) {
    this.fromBlock = o.fromBlock;
  }

  private say(m: string) {
    (this.o.log ?? console.log)(`[§6.11 #${this.o.mandateId}] ${m}`);
  }

  async state() {
    const { publicClient: pc, network: n, mandateId: id } = this.o;
    const m = await pc.readContract({ address: n.contracts.registry, abi: mandateRegistryAbi, functionName: "get", args: [id] });
    if (getAddress(m.bond) !== getAddress(n.contracts.vault)) {
      throw new Error(`mandate #${id} names Vault ${m.bond}, this watcher is configured for ${n.contracts.vault}`);
    }
    if (BigInt(m.assetKey) >> 160n !== 0n || BigInt(m.assetKey) === 0n) throw new Error(`mandate #${id} is not an ERC-20 mandate`);
    const token = getAddress(("0x" + m.assetKey.slice(26)) as Hex);
    const [exclusive, bond, docket, slashed] = await Promise.all([
      pc.readContract({ address: n.contracts.registry, abi: mandateRegistryAbi, functionName: "exclusive", args: [id] }),
      pc.readContract({ address: n.contracts.vault, abi: vaultAbi, functionName: "bondOf", args: [id] }),
      pc.readContract({ address: n.contracts.judgeEvm, abi: judgeEvmAbi, functionName: "erc20Docket", args: [id] }),
      pc.readContract({ address: n.contracts.vault, abi: vaultAbi, functionName: "slashed", args: [id] }),
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
    const { publicClient: pc, network: n, mandateId: id } = this.o;
    const flags = await Promise.all(
      logs.map((l) =>
        pc.readContract({ address: n.contracts.judgeEvm, abi: judgeEvmAbi, functionName: "eventFiled", args: [id, l.txHash, l.logIndex] }),
      ),
    );
    return new Set(logs.filter((_, i) => flags[i]).map((l) => `${l.txHash.toLowerCase()}:${l.logIndex}`));
  }

  /** One cycle: look, plan, act. Safe to call on a timer; idle when there is nothing to do. */
  async tick(): Promise<TickResult> {
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
    const { publicClient: pc, network: n, wallet, mandateId: id, fdc } = this.o;
    const salt = randomSalt();
    const c = commitmentFor(wallet.account.address, id, Kind.ERC20_OUTFLOW, deedsDigest(filings.map((f) => f.txHash)), salt);
    const commitTx = await wallet.writeContract({ address: n.contracts.vault, abi: vaultAbi, functionName: "commitChallenge", args: [c] });
    await this.mined(commitTx, "commitChallenge");
    const [at, lead, clock] = await Promise.all([
      pc.readContract({ address: n.contracts.vault, abi: vaultAbi, functionName: "committedAt", args: [c] }),
      pc.readContract({ address: n.contracts.vault, abi: vaultAbi, functionName: "commitLead" }),
      fdc.clock(),
    ]);
    // the first round that starts at or after committedAt + commitLead; requests must land in it or later
    const r = (BigInt(at) + BigInt(lead) - clock.t0 + clock.duration - 1n) / clock.duration;
    const target = clock.t0 + r * clock.duration + 10n;
    this.say(`committed ${c} at ${at}; attestations wait until t=${target} (round ${r})`);
    for (;;) {
      const now = (await pc.getBlock()).timestamp;
      if (now >= target) break;
      await new Promise((ok) => setTimeout(ok, Math.min(30, Number(target - now)) * 1000));
    }
    return [commitTx, await this.file(filings, salt)];
  }

  private async prove(filings: TxFiling[]): Promise<EvmTransactionProof[]> {
    const { fdc, wallet } = this.o;
    const reqs: { req: Hex; round: bigint }[] = [];
    for (const f of filings) {
      const req = await fdc.prepareEvmTransaction(f.txHash, f.logIndices);
      reqs.push({ req, round: await fdc.request(wallet, req) });
      this.say(`attestation requested for ${f.txHash} (logs ${f.logIndices.join(",")})`);
    }
    return Promise.all(reqs.map(({ req, round }) => fdc.proof(round, req)));
  }

  private async file(filings: TxFiling[], salt: Hex): Promise<Hex> {
    const { network: n, wallet, mandateId: id } = this.o;
    const proofs = await this.prove(filings);
    const hash = await wallet.writeContract({ address: n.contracts.judgeEvm, abi: judgeEvmAbi, functionName: "fileErc20Outflow", args: [id, proofs as any, salt] });
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
