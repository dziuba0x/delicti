import type { Hex } from "viem";
import { sortIds } from "../commit.js";
import type { XrplMove } from "./history.js";

export type XrplPlan =
  | { action: "idle"; reason: string; lost: XrplMove[] }
  | { action: "record"; txIds: Hex[]; adds: bigint; lost: XrplMove[] }
  | { action: "convict"; txIds: Hex[]; adds: bigint; docketAfter: bigint; lost: XrplMove[] };

export interface XrplMandateView {
  budget: bigint;
  validFrom: number;
  validUntil: number;
  docket: bigint;
  bond: bigint;
  exclusive: boolean;
}

/** The FDC's XRP verifier attests ~14 days back (SPEC §10); a deed older than this is lost to the case. */
export const XRPL_PROOF_HORIZON = 14 * 24 * 3600;

/**
 * What to do with an XRPL account's balance history (§6.10). Pure. The same rules as §6.11:
 *
 * - only moves inside the mandate's window, not yet on the docket, that took XRP OUT (an inflow
 *   adds nothing, so proving it would be an attestation fee for nothing);
 * - moves the verifier can no longer attest are reported as `lost`, never requested;
 * - one filing per cycle over every new move, ascending by id: a recording within the budget, the
 *   committed conviction past it.
 */
export function planXrpl(moves: readonly XrplMove[], isFiled: (txId: Hex) => boolean, m: XrplMandateView, now: number): XrplPlan {
  const lost: XrplMove[] = [];
  if (!m.exclusive) return { action: "idle", reason: "not exclusive on XRPL: §6.10 does not apply", lost };
  if (m.bond === 0n) return { action: "idle", reason: "nothing bonded: nothing to judge", lost };
  const fresh = new Map<string, XrplMove>();
  for (const mv of moves) {
    if (mv.spent <= 0n) continue;
    if (mv.timestamp < m.validFrom || mv.timestamp > m.validUntil) continue;
    if (isFiled(mv.txId)) continue;
    if (now - mv.timestamp > XRPL_PROOF_HORIZON) {
      lost.push(mv);
      continue;
    }
    fresh.set(mv.txId.toLowerCase(), mv);
  }
  if (fresh.size === 0) return { action: "idle", reason: "no new outflow", lost };
  const txIds = sortIds([...fresh.keys()] as Hex[]);
  const adds = txIds.reduce((s, id) => s + fresh.get(id)!.spent, 0n);
  const after = m.docket + adds;
  if (after <= m.budget) return { action: "record", txIds, adds, lost };
  return { action: "convict", txIds, adds, docketAfter: after, lost };
}
