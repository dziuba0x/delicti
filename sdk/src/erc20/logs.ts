import { pad, parseAbiItem, type Address, type Hex, type PublicClient } from "viem";

/** One `Transfer(from = agent, …)` log of the mandate's token: a candidate for the §6.11 docket. */
export interface OutflowLog {
  txHash: Hex;
  /** Block-level log index — the docket's key, together with the transaction. */
  logIndex: number;
  blockNumber: bigint;
  timestamp: number;
  value: bigint;
  to: Address;
}

export interface LogSource {
  /** Every `Transfer(from = agent)` emitted by `token` in blocks [fromBlock, toBlock]. */
  outflows(token: Address, agent: Address, fromBlock: bigint, toBlock: bigint | "latest"): Promise<OutflowLog[]>;
}

const TRANSFER_TOPIC = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef";
const transferEvent = parseAbiItem("event Transfer(address indexed from, address indexed to, uint256 value)");

/**
 * Backfill through a Blockscout-compatible explorer API (`module=logs&action=getLogs`), which
 * filters by topic server-side over any block range. Flare's public RPCs serve eth_getLogs 30
 * blocks at a time, so a mandate's week of history is ~340,000 RPC calls and one explorer call.
 * The explorer is a convenience, not a witness: nothing it says is filed without an FDC proof.
 */
export class ExplorerLogSource implements LogSource {
  constructor(readonly apiUrl: string) {}

  async outflows(token: Address, agent: Address, fromBlock: bigint, toBlock: bigint | "latest"): Promise<OutflowLog[]> {
    const out: OutflowLog[] = [];
    let from = fromBlock;
    for (;;) {
      const q = new URLSearchParams({
        module: "logs",
        action: "getLogs",
        fromBlock: from.toString(),
        toBlock: toBlock.toString(),
        address: token,
        topic0: TRANSFER_TOPIC,
        topic1: pad(agent.toLowerCase() as Hex, { size: 32 }),
        topic0_1_opr: "and",
      });
      const r = await fetch(`${this.apiUrl}?${q}`);
      const j = (await r.json()) as { status: string; message: string; result: any[] | null };
      if (j.status !== "1" && !/no (records|logs) found/i.test(j.message)) throw new Error(`explorer getLogs: ${j.message}`);
      const rows = j.result ?? [];
      for (const l of rows) {
        out.push({
          txHash: l.transactionHash,
          logIndex: Number(BigInt(l.logIndex)),
          blockNumber: BigInt(l.blockNumber),
          timestamp: Number(BigInt(l.timeStamp)),
          value: BigInt(l.data),
          to: ("0x" + (l.topics[2] as string).slice(26)) as Address,
        });
      }
      // Blockscout pages at 1,000 rows; continue from the last block seen (dedup below).
      if (rows.length < 1000) break;
      from = BigInt(rows[rows.length - 1].blockNumber);
    }
    return dedup(out);
  }
}

/** Plain JSON-RPC, walked in chunks the node accepts (30 blocks on Flare's public endpoints). */
export class RpcLogSource implements LogSource {
  constructor(readonly client: PublicClient, readonly chunk = 30n) {}

  async outflows(token: Address, agent: Address, fromBlock: bigint, toBlock: bigint | "latest"): Promise<OutflowLog[]> {
    const end = toBlock === "latest" ? await this.client.getBlockNumber() : toBlock;
    const out: OutflowLog[] = [];
    const stamps = new Map<bigint, number>();
    for (let a = fromBlock; a <= end; a += this.chunk) {
      const b = a + this.chunk - 1n < end ? a + this.chunk - 1n : end;
      const logs = await this.client.getLogs({ address: token, event: transferEvent, args: { from: agent }, fromBlock: a, toBlock: b });
      for (const l of logs) {
        if (!stamps.has(l.blockNumber!)) stamps.set(l.blockNumber!, Number((await this.client.getBlock({ blockNumber: l.blockNumber! })).timestamp));
        out.push({
          txHash: l.transactionHash!,
          logIndex: l.logIndex!,
          blockNumber: l.blockNumber!,
          timestamp: stamps.get(l.blockNumber!)!,
          value: l.args.value!,
          to: l.args.to!,
        });
      }
    }
    return dedup(out);
  }
}

function dedup(logs: OutflowLog[]): OutflowLog[] {
  const seen = new Set<string>();
  return logs.filter((l) => {
    const k = `${l.txHash.toLowerCase()}:${l.logIndex}`;
    if (seen.has(k)) return false;
    seen.add(k);
    return true;
  });
}
