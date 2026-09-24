import { keccak256, toHex, type Hex } from "viem";

/** One transaction that changed an XRPL account's XRP balance. */
export interface XrplMove {
  /** `0x` + lowercase hex, the form the FDC and the judges use. */
  txId: Hex;
  ledger: number;
  /** Unix seconds (the verifier's `timestamp`, which is the ledger's close time). */
  timestamp: number;
  /** Drops that LEFT the account in this transaction, fee included; negative when XRP came in. */
  spent: bigint;
  type: string;
  /** Whether the account signed it. `false` is the interesting case: an offer taken by another
   *  account's transaction, a check cashed, an escrow finished by someone else. */
  ownTransaction: boolean;
}

export interface WalkResult {
  moves: XrplMove[];
  /** Why the walk stopped: it reached the window's start, the account's creation, or the edge of
   *  the verifier's memory (older transactions can no longer be proven by anyone). */
  stoppedAt: "window-start" | "account-created" | "verifier-horizon" | "index-behind" | "limit";
}

/** The FDC's standard address hash for an XRPL account: keccak256 of the classic address string. */
export function xrplAddressHash(address: string): Hex {
  return keccak256(toHex(address));
}

/** How `account`'s XRP balance changed in a transaction, and the previous transaction that changed
 *  its AccountRoot — the backward link that makes the account's history a list. */
export function accountRootChange(meta: any, account: string): { delta: bigint; previousTxnId?: string } | undefined {
  for (const n of meta?.AffectedNodes ?? []) {
    const node = n.ModifiedNode ?? n.DeletedNode ?? n.CreatedNode;
    if (!node || node.LedgerEntryType !== "AccountRoot") continue;
    const fields = node.FinalFields ?? node.NewFields;
    if (fields?.Account !== account) continue;
    const final = BigInt(fields.Balance ?? "0");
    const prev = node.PreviousFields?.Balance !== undefined ? BigInt(node.PreviousFields.Balance) : n.CreatedNode ? 0n : final;
    return { delta: final - prev, previousTxnId: node.PreviousTxnID };
  }
  return undefined;
}

/**
 * An XRPL account's history, read the way the FDC will read it.
 *
 * Public XRPL nodes keep little history (the testnet endpoint reachable here keeps ~1,300 ledgers,
 * under an hour and a half), and `account_tx` over a longer range needs a full-history server.
 * But every transaction that moves an account's XRP modifies its AccountRoot, and every AccountRoot
 * modification records the PREVIOUS transaction that touched it (`PreviousTxnID`). The account's
 * balance history is therefore a linked list, anchored at the head `account_info` returns. The
 * FDC's own XRP verifier indexes ~15 days of full transactions with metadata.
 *
 * So the watcher walks the list backwards through the verifier's index — the same index that will
 * attest the deeds. What it finds is exactly what can still be proven, and nothing that can be
 * proven is missed: a balance change that is not on the list did not happen.
 */
export class XrplHistory {
  constructor(
    readonly rpcUrl: string,
    readonly verifierUrl: string,
    readonly apiKey: string,
    readonly verifierChain = "xrp",
  ) {}

  private async rpc(method: string, params: object): Promise<any> {
    const r = await fetch(this.rpcUrl, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ method, params: [params] }) });
    const j = (await r.json()) as { result: any };
    if (j.result?.status !== "success") throw new Error(`xrpl ${method}: ${JSON.stringify(j.result)}`);
    return j.result;
  }

  /** The last validated transaction that touched the account's root, and its balance. */
  async head(account: string): Promise<{ previousTxnId: string; balance: bigint }> {
    const r = await this.rpc("account_info", { account, ledger_index: "validated" });
    return { previousTxnId: r.account_data.PreviousTxnID, balance: BigInt(r.account_data.Balance) };
  }

  /** A transaction with its metadata from the verifier's index, or null if it is not (or no longer) there. */
  async indexed(txId: string): Promise<{ tx: any; timestamp: number; ledger: number } | null> {
    const id = txId.replace(/^0x/, "").toUpperCase();
    const r = await fetch(`${this.verifierUrl}/verifier/${this.verifierChain}/api/indexer/transaction/${id}`, { headers: { "X-API-KEY": this.apiKey } });
    if (!r.ok) return null;
    const j = (await r.json().catch(() => ({}))) as { status?: string; data?: any };
    if (j.status !== "OK" || !j.data?.response?.result) return null;
    return { tx: j.data.response.result, timestamp: Number(j.data.timestamp), ledger: Number(j.data.blockNumber) };
  }

  /** The account a transaction was signed by — how the watcher learns an XRPL address from the
   *  on-chain exclusivity statement, which records only the transaction id. */
  async signerOf(txId: string): Promise<string | null> {
    const t = await this.indexed(txId);
    return t?.tx?.Account ?? null;
  }

  /** Every XRP balance change of `account` back to `since` (unix), newest first. */
  async walk(account: string, since: number, limit = 1000): Promise<WalkResult> {
    const moves: XrplMove[] = [];
    let id: string | undefined = (await this.head(account)).previousTxnId;
    let first = true;
    while (id) {
      if (moves.length >= limit) return { moves, stoppedAt: "limit" };
      const t = await this.indexed(id);
      if (!t) return { moves, stoppedAt: first ? "index-behind" : "verifier-horizon" };
      first = false;
      const ch = accountRootChange(t.tx.meta, account);
      if (!ch) throw new Error(`transaction ${id} is on ${account}'s chain but does not touch its AccountRoot`);
      if (t.timestamp < since) return { moves, stoppedAt: "window-start" };
      moves.push({
        txId: `0x${id.toLowerCase()}` as Hex,
        ledger: t.ledger,
        timestamp: t.timestamp,
        spent: -ch.delta,
        type: t.tx.TransactionType,
        ownTransaction: t.tx.Account === account,
      });
      id = ch.previousTxnId;
    }
    return { moves, stoppedAt: "account-created" };
  }
}
