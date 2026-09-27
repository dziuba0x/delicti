import {
  keccak256,
  parseEventLogs,
  toHex,
  zeroHash,
  pad,
  type Account,
  type Address,
  type Chain,
  type Hex,
  type PublicClient,
  type Transport,
  type WalletClient,
} from "viem";
import { agentRefsAbi, judgeEvmAbi, judgeXrplAbi, mandateRegistryAbi, vaultAbi } from "./abi.js";
import { pad32, type Fdc } from "./fdc.js";
import { deploymentOf, type DelictiNetwork } from "./networks.js";
import { SUMMA_SOURCE, Summa, summaStackOf, type UmbrellaState } from "./summa.js";

type Wallet = WalletClient<Transport, Chain, Account>;

/** `bytes32("XRP/outflow")`: a mandate on XRPL whose budget is gross XRP outflow, fees included (§6.10). */
export const XRP_OUTFLOW_KEY = pad(toHex("XRP/outflow"), { dir: "right", size: 32 });

export interface NewMandate {
  agent: Address;
  /** The human-readable terms; only their hash goes on-chain. */
  terms: string;
  budget: bigint;
  validFrom: bigint;
  validUntil: bigint;
  /** An ERC-20 address for a token budget; omit for the chain's native asset. */
  token?: Address;
  /** Any other asset key, e.g. `XRP_OUTFLOW_KEY` for a §6.10 gross-outflow budget. Wins over `token`. */
  assetKey?: Hex;
  /** Defaults to the network's FDC source (e.g. `testFLR`). */
  source?: string;
  /** XRPL account hash for XRPL mandates; zero on EVM. */
  agentRef?: Hex;
  parentId?: bigint;
  /** The Vault that holds the bond. Defaults to this network's current Vault; a SUMMA umbrella names `network.summa.vault`. */
  bond?: Address;
}

/**
 * The few calls an integrator makes: a principal commits a mandate and bonds it, an agent accepts
 * it (or declares it exclusive), and anyone reads where a mandate stands. Everything else — the
 * evidence, the verdicts — is the watchers' business (`Erc20OutflowWatcher`).
 */
export class Delicti {
  constructor(readonly network: DelictiNetwork, readonly publicClient: PublicClient) {}

  private async mined(hash: Hex) {
    const rc = await this.publicClient.waitForTransactionReceipt({ hash });
    if (rc.status !== "success") throw new Error(`reverted: ${this.network.explorerUrl}/tx/${hash}`);
    return rc;
  }

  /** The Vault a mandate is bonded in: its own `Terms.bond`, whichever version that is. */
  async vaultOf(id: bigint): Promise<Address> {
    const m = (await this.publicClient.readContract({ address: this.network.contracts.registry, abi: mandateRegistryAbi, functionName: "get", args: [id] })) as { bond: Address };
    return m.bond;
  }

  /** Principal: commit a mandate naming this network's Vault (or `n.bond`). Returns its id. */
  async commitMandate(principal: Wallet, n: NewMandate): Promise<{ id: bigint; tx: Hex }> {
    const hash = await principal.writeContract({
      address: this.network.contracts.registry,
      abi: mandateRegistryAbi,
      functionName: "commit",
      args: [
        n.agent,
        keccak256(toHex(n.terms)),
        zeroHash,
        n.parentId ?? 0n,
        n.budget,
        n.validFrom,
        n.validUntil,
        {
          sourceId: pad32(n.source ?? this.network.fdcSource),
          assetKey: n.assetKey ?? (n.token ? pad(n.token, { size: 32 }) : zeroHash),
          agentRef: n.agentRef ?? zeroHash,
          bond: n.bond ?? this.network.contracts.vault,
        },
      ],
    });
    const rc = await this.mined(hash);
    const [ev] = parseEventLogs({ abi: mandateRegistryAbi, eventName: "MandateCommitted", logs: rc.logs });
    return { id: ev.args.id, tx: hash };
  }

  /** Agent: accept the mandate. Its deeds are then judged on what it anchors. */
  async acknowledge(agent: Wallet, id: bigint): Promise<Hex> {
    const h = await agent.writeContract({ address: this.network.contracts.registry, abi: mandateRegistryAbi, functionName: "acknowledge", args: [id] });
    await this.mined(h);
    return h;
  }

  /** Agent: accept AND promise that everything its address does in the window is this mandate's.
   *  The price of being trusted without receipts: §6.4 silence and §6.11 outflow then apply. */
  async declareExclusive(agent: Wallet, id: bigint): Promise<Hex> {
    const h = await agent.writeContract({ address: this.network.contracts.registry, abi: mandateRegistryAbi, functionName: "declareExclusive", args: [id] });
    await this.mined(h);
    return h;
  }

  /** Bond the mandate. With `beneficiary`, name whom this deposit's remainder compensates (§8.3). */
  async post(from: Wallet, id: bigint, value: bigint, beneficiary?: Address): Promise<Hex> {
    const v = await this.vaultOf(id);
    const h = beneficiary
      ? await from.writeContract({ address: v, abi: vaultAbi, functionName: "postFor", args: [id, beneficiary], value })
      : await from.writeContract({ address: v, abi: vaultAbi, functionName: "post", args: [id], value });
    await this.mined(h);
    return h;
  }

  async withdraw(from: Wallet, id: bigint, to?: Address): Promise<Hex> {
    const h = await from.writeContract({ address: await this.vaultOf(id), abi: vaultAbi, functionName: "withdraw", args: [id, to ?? from.account.address] });
    await this.mined(h);
    return h;
  }

  /** Collect what a Vault owes you (rewards, stipends, remainders). Defaults to the current Vault. */
  async claim(from: Wallet, vault?: Address): Promise<Hex> {
    const h = await from.writeContract({ address: vault ?? this.network.contracts.vault, abi: vaultAbi, functionName: "claim" });
    await this.mined(h);
    return h;
  }

  /**
   * The XRPL account speaks for itself: `exclusive` = it promises that everything leaving it in the
   * window is this mandate's business (§6.10); otherwise it only accepts the mandate (§6.8). The
   * account makes a payment carrying the reference (`exclusiveFor` / `challengeFor`) in a memo;
   * this proves that payment through the FDC and records it. Returns the proof's round.
   */
  async proveXrplStatement(from: Wallet, fdc: Fdc, id: bigint, statementTxId: Hex, exclusive: boolean): Promise<Hex> {
    const req = await fdc.preparePayment(statementTxId);
    const round = await fdc.request(from, req);
    const proof = await fdc.proof(round, req, "Payment");
    const h = await from.writeContract({
      address: this.network.contracts.agentRefs, abi: agentRefsAbi, functionName: exclusive ? "proveExclusive" : "prove", args: [id, proof as any],
    });
    await this.mined(h);
    return h;
  }

  /** The reference an XRPL statement payment must carry in its memo. */
  async xrplStatementRef(id: bigint, exclusive: boolean): Promise<Hex> {
    return this.publicClient.readContract({
      address: this.network.contracts.agentRefs, abi: agentRefsAbi, functionName: exclusive ? "exclusiveFor" : "challengeFor", args: [id],
    }) as Promise<Hex>;
  }

  /** Principal: what watchers are paid per new, value-moving deed they file, and the least value a
   *  deed must move to earn it (§8.4). Once set, terms can only get better for watchers. */
  async setWatchTerms(principal: Wallet, id: bigint, perDeed: bigint, minValue: bigint): Promise<Hex> {
    const h = await principal.writeContract({ address: await this.vaultOf(id), abi: vaultAbi, functionName: "setWatchTerms", args: [id, perDeed, minValue] });
    await this.mined(h);
    return h;
  }

  /** Principal: pay into the mandate's watch pool (§8.4). Nobody else can (since v0.15). */
  async fundWatch(from: Wallet, id: bigint, value: bigint): Promise<Hex> {
    const h = await from.writeContract({ address: await this.vaultOf(id), abi: vaultAbi, functionName: "fundWatch", args: [id], value });
    await this.mined(h);
    return h;
  }

  /** Principal: what the pool has left, once no bond remains or `WATCH_TAIL` after the cooling window. */
  async refundWatch(from: Wallet, id: bigint, to?: Address): Promise<Hex> {
    const h = await from.writeContract({ address: await this.vaultOf(id), abi: vaultAbi, functionName: "refundWatch", args: [id, to ?? from.account.address] });
    await this.mined(h);
    return h;
  }

  /**
   * Where a mandate stands: is it live, how much is bonded, what has been proven against it. Read
   * from the mandate's own Vault and its judges, whichever version it names (`Terms.bond`); for a
   * SUMMA umbrella, also its meter: the tally in µUSD and the tripwire (amendment v1.2).
   */
  async status(id: bigint) {
    const c = this.network.contracts;
    const pc = this.publicClient;
    const read = (address: Address, abi: any, functionName: string, args: any[] = [id]) =>
      pc.readContract({ address, abi, functionName, args }).catch(() => undefined) as Promise<any>;
    const m = (await pc.readContract({ address: c.registry, abi: mandateRegistryAbi, functionName: "get", args: [id] })) as any;
    const vault = m.bond as Address;
    const dep = deploymentOf(this.network, vault);
    const stack = summaStackOf(this.network, vault);
    const [live, exclusive, exclusiveXrpl, acknowledged, bond, slashed, severity, taken, watchPool, perDeed, erc20Docket, xrpDocket, paymentDocket] = await Promise.all([
      read(c.registry, mandateRegistryAbi, "isLive"),
      read(c.registry, mandateRegistryAbi, "exclusive"),
      read(c.agentRefs, agentRefsAbi, "exclusive"),
      read(c.registry, mandateRegistryAbi, "acknowledged"),
      read(vault, vaultAbi, "bondOf"),
      read(vault, vaultAbi, "slashed"),
      read(vault, vaultAbi, "severityOf"),
      read(vault, vaultAbi, "slashedAmount"),
      read(vault, vaultAbi, "watchPool"),
      read(vault, vaultAbi, "stipendPerDeed"),
      dep ? read(dep.judgeEvm, judgeEvmAbi, "erc20Docket") : undefined,
      dep ? read(dep.judgeXrpl, judgeXrplAbi, "docket") : undefined,
      dep ? read(dep.judgeXrpl, judgeXrplAbi, "paymentDocket") : undefined,
    ]);
    let summa: (UmbrellaState & { version: string; meter: Address }) | undefined;
    if (stack && String(m.sourceId).toLowerCase() === SUMMA_SOURCE.toLowerCase()) {
      summa = { version: stack.version, meter: stack.meter, ...(await new Summa(pc, stack).state(id)) };
    }
    return {
      id,
      principal: m.principal as Address,
      agent: m.agent as Address,
      budget: m.budget as bigint,
      validFrom: m.validFrom as bigint,
      validUntil: m.validUntil as bigint,
      assetKey: m.assetKey as Hex,
      vault,
      /** The consequence layer that Vault belongs to: "current", "v0.15", …, "summa" or "summa v0.15". */
      version: dep?.version ?? (stack ? `summa${stack.version === "current" ? "" : ` ${stack.version}`}` : "unknown"),
      live: live as boolean,
      /** The EVM key's promise (§6.4, §6.11) and the XRPL key's (§6.10). */
      exclusive: { evm: exclusive as boolean, xrpl: exclusiveXrpl as boolean },
      acknowledged: acknowledged as boolean,
      bond: bond as bigint,
      slashed: slashed as boolean,
      severity: severity as bigint,
      taken: taken as bigint,
      dockets: { erc20: erc20Docket as bigint | undefined, xrpOutflow: xrpDocket as bigint | undefined, xrpPayments: paymentDocket as bigint | undefined },
      watch: { pool: watchPool as bigint, perDeed: perDeed as bigint },
      /** A SUMMA umbrella: its stack's meter, the tally in µUSD there, and the tripwire (v1.2 meters only).
       *  An umbrella whose effectors write to another meter shows that meter's tally nowhere here. */
      summa,
    };
  }
}
