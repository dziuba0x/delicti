import type { Address, Hex } from "viem";

export interface RawLog {
  address: Address;
  topics: Hex[];
  data: Hex;
  blockNumber: bigint;
  timestamp: number;
  txHash: Hex;
  logIndex: number;
}

/**
 * Logs through a Blockscout-compatible explorer API (`module=logs&action=getLogs`), which filters
 * by topic server-side over any block range. Flare's public RPCs serve eth_getLogs 30 blocks at a
 * time. The explorer is a finder, never a witness: nothing it returns reaches a judge except
 * inside an FDC proof, and every state it suggests is re-read from the chain.
 */
export async function explorerLogs(
  apiUrl: string,
  address: Address,
  topics: { topic0: Hex; topic1?: Hex; topic2?: Hex },
  fromBlock: bigint = 0n,
  toBlock: bigint | "latest" = "latest",
): Promise<RawLog[]> {
  const out: RawLog[] = [];
  let from = fromBlock;
  for (;;) {
    const q: Record<string, string> = { module: "logs", action: "getLogs", fromBlock: from.toString(), toBlock: toBlock.toString(), address, topic0: topics.topic0 };
    if (topics.topic1) Object.assign(q, { topic1: topics.topic1, topic0_1_opr: "and" });
    if (topics.topic2) Object.assign(q, { topic2: topics.topic2, topic0_2_opr: "and" });
    const r = await fetch(`${apiUrl}?${new URLSearchParams(q)}`);
    const j = (await r.json()) as { status: string; message: string; result: any[] | null };
    if (j.status !== "1" && !/no (records|logs) found/i.test(j.message)) throw new Error(`explorer getLogs: ${j.message}`);
    const rows = j.result ?? [];
    for (const l of rows) {
      out.push({
        address: l.address,
        topics: (l.topics as (Hex | null)[]).filter((t): t is Hex => !!t),
        data: l.data,
        blockNumber: BigInt(l.blockNumber),
        timestamp: Number(BigInt(l.timeStamp)),
        txHash: l.transactionHash,
        logIndex: Number(BigInt(l.logIndex === "0x" ? 0 : l.logIndex)),
      });
    }
    if (rows.length < 1000) break;
    from = BigInt(rows[rows.length - 1].blockNumber);
  }
  const seen = new Set<string>();
  return out.filter((l) => {
    const k = `${l.txHash.toLowerCase()}:${l.logIndex}`;
    if (seen.has(k)) return false;
    seen.add(k);
    return true;
  });
}
