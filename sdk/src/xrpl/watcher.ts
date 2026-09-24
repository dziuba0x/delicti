import { getAddress, type Account, type Chain, type Hex, type PublicClient, type Transport, type WalletClient } from "viem";
import { agentRefsAbi, judgeXrplAbi, mandateRegistryAbi, vaultAbi } from "../abi.js";
import { Kind } from "../commit.js";
import { explorerLogs } from "../explorer.js";
import type { Fdc, FdcProof } from "../fdc.js";
import { commitAndWait } from "../lead.js";
import { deploymentOf, type DelictiNetwork, type Deployment } from "../networks.js";
import { XrplHistory, xrplAddressHash, type XrplMove } from "./history.js";
import { planXrpl, type XrplPlan } from "./planner.js";
import { keccak256, pad, toHex } from "viem";

const XRP_OUTFLOW_KEY = pad(toHex("XRP/outflow"), { dir: "right", size: 32 });
const EXCLUSIVE_PROVEN = keccak256(toHex("ExclusiveProven(uint256,bytes32,bytes32,address)"));

export interface XrplWatcherOptions {
  network: DelictiNetwork;
  publicClient: PublicClient;
  wallet: WalletClient<Transport, Chain, Account>;
  fdc: Fdc;
  history: XrplHistory;
  mandateId: bigint;
  deployment?: Deployment;
  /** The agent's classic address, if known; otherwise discovered from its exclusivity statement. */
  account?: string;
  log?: (msg: string) => void;
}

export interface XrplTickResult {
  plan: XrplPlan;
  txs: Hex[];
  account?: string;
  docket?: bigint;
  bond?: bigint;
  slashed?: boolean;
  walk?: string;
}

/**
 * The §6.10 watcher. A mandate on XRPL names its account only by hash (`agentRef`), so the first
 * thing it does is find the account: the exclusivity statement (`AgentRefs.proveExclusive`) left
 * its XRPL transaction id in an event, the verifier's index says who signed that transaction, and
 * keccak256(signer) must equal `agentRef` — or the mandate is not watched. Then it walks the
 * account's balance history through the verifier's index (see `XrplHistory`) and files: a
 * recording below the budget, the committed conviction past it.
 */
export class XrplOutflowWatcher {
  private dep?: Deployment;
  private account?: string;
  constructor(readonly o: XrplWatcherOptions) {
    this.dep = o.deployment;
    this.account = o.account;
  }

  private say(m: string) {
    (this.o.log ?? console.log)(`[§6.10 #${this.o.mandateId}] ${m}`);
  }

  /** Find the XRPL account behind `agentRef`, from the statement that made the mandate exclusive. */
  async discoverAccount(agentRef: Hex): Promise<string> {
    const { network: n, mandateId } = this.o;
    const logs = await explorerLogs(n.explorerApi, n.contracts.agentRefs, { topic0: EXCLUSIVE_PROVEN, topic1: pad(toHex(mandateId), { size: 32 }) });
    for (const l of logs) {
      const txId = l.data.slice(0, 66) as Hex; // bytes32 transactionId (the only non-indexed field before `by`)
      const signer = await this.o.history.signerOf(txId);
      if (signer && xrplAddressHash(signer).toLowerCase() === agentRef.toLowerCase()) return signer;
    }
    throw new Error(`no exclusivity statement for mandate #${mandateId} whose signer hashes to ${agentRef} is still in the verifier's index`);
  }

  async state() {
    const { publicClient: pc, network: n, mandateId: id } = this.o;
    const m = await pc.readContract({ address: n.contracts.registry, abi: mandateRegistryAbi, functionName: "get", args: [id] });
    this.dep ??= deploymentOf(n, m.bond);
    if (!this.dep || getAddress(m.bond) !== getAddress(this.dep.vault)) throw new Error(`mandate #${id} names an unknown Vault ${m.bond}`);
    if (!this.dep.features.includes("xrpDocket")) throw new Error(`mandate #${id} is bonded in ${this.dep.version}, which has no §6.10 docket`);
    if (m.assetKey.toLowerCase() !== XRP_OUTFLOW_KEY.toLowerCase()) throw new Error(`mandate #${id} is not an XRP-outflow mandate`);
    const d = this.dep;
    const [exclusive, bond, docket, slashed] = await Promise.all([
      pc.readContract({ address: n.contracts.agentRefs, abi: agentRefsAbi, functionName: "exclusive", args: [id] }),
      pc.readContract({ address: d.vault, abi: vaultAbi, functionName: "bondOf", args: [id] }),
      pc.readContract({ address: d.judgeXrpl, abi: judgeXrplAbi, functionName: "docket", args: [id] }),
      pc.readContract({ address: d.vault, abi: vaultAbi, functionName: "slashed", args: [id] }),
    ]);
    return { m, exclusive, bond, docket, slashed };
  }

  /** Look and plan, without acting: what the sentinel and the score read. */
  async observe() {
    const s = await this.state();
    if (!s.exclusive) {
      const plan = planXrpl([], () => false, { budget: s.m.budget, validFrom: 0, validUntil: 0, docket: s.docket, bond: s.bond, exclusive: false }, 0);
      return { s, plan, moves: [] as XrplMove[], stoppedAt: "not-exclusive", account: undefined as string | undefined };
    }
    this.account ??= await this.discoverAccount(s.m.agentRef);
    const walk = await this.o.history.walk(this.account, Number(s.m.validFrom));
    const filed = await this.filed(walk.moves);
    const now = Math.floor(Date.now() / 1000);
    const plan = planXrpl(walk.moves, (id) => filed.has(id.toLowerCase()), {
      budget: s.m.budget, validFrom: Number(s.m.validFrom), validUntil: Number(s.m.validUntil), docket: s.docket, bond: s.bond, exclusive: s.exclusive,
    }, now);
    return { s, plan, moves: walk.moves.filter((mv) => mv.timestamp <= Number(s.m.validUntil)), stoppedAt: walk.stoppedAt as string, account: this.account };
  }

  async tick(): Promise<XrplTickResult> {
    const { s, plan, moves, stoppedAt } = await this.observe();
    if (plan.lost.length) this.say(`${plan.lost.length} move(s) are past the verifier's ~14-day memory and can no longer be proven by anyone`);
    const seen = `${moves.length} balance change(s) walked (${stoppedAt})`;
    const walk = { stoppedAt };
    if (plan.action === "idle") {
      this.say(`idle: ${plan.reason} — account ${this.account}, ${seen}, docket ${s.docket} / budget ${s.m.budget}`);
      return { plan, txs: [], account: this.account, docket: s.docket, bond: s.bond, slashed: s.slashed, walk: walk.stoppedAt };
    }
    this.say(`${plan.action}: ${plan.txIds.length} new outflow(s), +${plan.adds} drops → docket ${s.docket + plan.adds} / budget ${s.m.budget} (${seen})`);
    let txs: Hex[];
    if (plan.action === "record") {
      txs = [await this.file(plan.txIds, s.m.agentRef, `0x${"0".repeat(64)}` as Hex)];
    } else {
      const { salt, commitTx } = await commitAndWait({
        publicClient: this.o.publicClient, wallet: this.o.wallet, fdc: this.o.fdc, vault: this.dep!.vault,
        mandateId: this.o.mandateId, kind: Kind.XRP_OUTFLOW, ids: plan.txIds, say: (m) => this.say(m),
      });
      txs = [commitTx, await this.file(plan.txIds, s.m.agentRef, salt)];
    }
    const after = await this.state();
    this.say(`docket ${after.docket}, bond ${after.bond}, slashed ${after.slashed}`);
    return { plan, txs, account: this.account, docket: after.docket, bond: after.bond, slashed: after.slashed, walk: walk.stoppedAt };
  }

  private async filed(moves: XrplMove[]): Promise<Set<string>> {
    const { publicClient: pc, mandateId: id } = this.o;
    const flags = await Promise.all(
      moves.map((mv) => pc.readContract({ address: this.dep!.judgeXrpl, abi: judgeXrplAbi, functionName: "filed", args: [id, mv.txId] })),
    );
    return new Set(moves.filter((_, i) => flags[i]).map((mv) => mv.txId.toLowerCase()));
  }

  private async file(txIds: Hex[], agentRef: Hex, salt: Hex): Promise<Hex> {
    const { fdc, wallet, mandateId: id, publicClient: pc, network: n } = this.o;
    const reqs: { req: Hex; round: bigint }[] = [];
    for (const txId of txIds) {
      const req = await fdc.prepareBalanceDecrease(txId, agentRef);
      reqs.push({ req, round: await fdc.request(wallet, req) });
      this.say(`BalanceDecreasingTransaction requested for ${txId}`);
    }
    const proofs: FdcProof[] = await Promise.all(reqs.map(({ req, round }) => fdc.proof(round, req, "BalanceDecreasingTransaction")));
    const hash = await wallet.writeContract({ address: this.dep!.judgeXrpl, abi: judgeXrplAbi, functionName: "fileXrpOutflow", args: [id, proofs as any, salt] });
    const rc = await pc.waitForTransactionReceipt({ hash });
    if (rc.status !== "success") throw new Error(`fileXrpOutflow reverted: ${hash}`);
    this.say(`filed: ${n.explorerUrl}/tx/${hash}`);
    return hash;
  }
}
