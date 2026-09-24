import type { Hex } from "viem";
import { sortIds } from "../commit.js";
import type { OutflowLog } from "./logs.js";

/** One transaction to prove: which of its logs to list in the `EVMTransaction` request. */
export interface TxFiling {
  txHash: Hex;
  /** Sorted, at most 50 — the FDC's cap per request. Logs past 50 wait for the next cycle. */
  logIndices: number[];
  value: bigint;
}

export type Plan =
  | { action: "idle"; reason: string }
  /** Below the budget: file to keep the docket current. No commitment, nothing paid. */
  | { action: "record"; filings: TxFiling[]; adds: bigint }
  /** Crosses the budget: commit (kind 8) over `filings`' hashes, wait the lead, then file. */
  | { action: "convict"; filings: TxFiling[]; adds: bigint; docketAfter: bigint };

export interface MandateView {
  budget: bigint;
  validFrom: number;
  validUntil: number;
  docket: bigint;
  bond: bigint;
  exclusive: boolean;
}

export const FDC_MAX_LOGS = 50;

/**
 * What to do with the outflow logs seen so far. Pure: the watcher feeds it chain state, and the
 * tests feed it everything else.
 *
 * - Logs outside the mandate's window are not the mandate's business, and filing one reverts.
 * - Logs already on the docket are skipped; the judge would skip them too, and a proof that adds
 *   nothing new is money spent on an attestation for no effect.
 * - One filing per cycle, over every new transaction in ascending hash order. If the docket plus
 *   everything new stays within the budget, it is a recording; if it goes past, the SAME set is
 *   the conviction and gets committed. Splitting "record what fits, convict the rest" would save
 *   nothing: the crossing filing reimburses the attestations it supplies either way, and one
 *   filing is one round of attestations instead of two.
 */
export function planErc20(logs: readonly OutflowLog[], isFiled: (l: OutflowLog) => boolean, m: MandateView): Plan {
  if (!m.exclusive) return { action: "idle", reason: "mandate not exclusive: §6.11 does not apply" };
  if (m.bond === 0n) return { action: "idle", reason: "nothing bonded: nothing to judge" };

  const byTx = new Map<string, OutflowLog[]>();
  for (const l of logs) {
    if (l.timestamp < m.validFrom || l.timestamp > m.validUntil) continue;
    if (isFiled(l)) continue;
    const k = l.txHash.toLowerCase();
    (byTx.get(k) ?? byTx.set(k, []).get(k)!).push(l);
  }
  if (byTx.size === 0) return { action: "idle", reason: "no new outflow" };

  const filings: TxFiling[] = [];
  let adds = 0n;
  for (const txHash of sortIds([...byTx.keys()] as Hex[])) {
    const ls = byTx.get(txHash)!.sort((a, b) => a.logIndex - b.logIndex).slice(0, FDC_MAX_LOGS);
    const value = ls.reduce((s, l) => s + l.value, 0n);
    filings.push({ txHash, logIndices: ls.map((l) => l.logIndex), value });
    adds += value;
  }
  const after = m.docket + adds;
  if (after <= m.budget || adds === 0n) return { action: "record", filings, adds };
  return { action: "convict", filings, adds, docketAfter: after };
}
