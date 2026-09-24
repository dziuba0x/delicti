import type { Address, PublicClient } from "viem";
import { bondLensAbi } from "../abi.js";
import { Kind } from "../commit.js";
import type { MandateInfo } from "./discover.js";

/** Gas a sentinel spends, measured on Coston2 (docs/DEPLOYMENTS.md, mandates #11–#12). */
export const GAS = { request: 95_000n, commit: 47_000n, fileBase: 60_000n, filePerProof: 110_000n, verdict: 120_000n };

export interface Quote {
  proofs: number;
  /** Attestation fees plus gas at the current price, in wei. */
  cost: bigint;
  /** Stipends from the watch pool (v0.14) for the value-moving new deeds. */
  stipends: bigint;
  /** What the verdict would take, and the filer's share of it (reimbursed fees + 10 % of the rest). */
  take: bigint;
  reward: bigint;
  income: bigint;
  worthIt: boolean;
}

/**
 * What acting on a plan costs and pays, before a single attestation is bought. A watcher that
 * cannot price its work either overspends or stops; the research this is built on (docs/research/
 * watchers.md) is mostly the history of systems that learned that late.
 */
export async function quote(
  pc: PublicClient,
  lens: Address,
  m: MandateInfo,
  plan: { action: "record" | "convict"; proofs: number; eligible: number; severityAfter?: bigint },
  feePerRequest: bigint,
): Promise<Quote> {
  const gasPrice = await pc.getGasPrice();
  const n = BigInt(plan.proofs);
  let gas = n * (GAS.request + GAS.filePerProof) + GAS.fileBase;
  if (plan.action === "convict") gas += GAS.commit + GAS.verdict;
  const cost = n * feePerRequest + gas * gasPrice;
  let stipends = 0n;
  if (m.stipendPerDeed && m.watchPool) {
    const want = BigInt(plan.eligible) * m.stipendPerDeed;
    stipends = want > m.watchPool ? m.watchPool : want;
  }
  let take = 0n;
  let reward = 0n;
  if (plan.action === "convict" && plan.severityAfter !== undefined) {
    const kind = m.cls === "xrp-outflow" ? Kind.XRP_OUTFLOW : Kind.ERC20_OUTFLOW;
    const [inc] = (await pc.readContract({ address: lens, abi: bondLensAbi, functionName: "penaltyFor", args: [m.vault, m.id, kind, plan.severityAfter] })) as readonly [bigint, bigint];
    take = inc;
    const fees = n * feePerRequest > take ? take : n * feePerRequest;
    reward = fees + ((take - fees) * 1000n) / 10_000n;
  }
  const income = stipends + reward;
  return { proofs: plan.proofs, cost, stipends, take, reward, income, worthIt: income >= cost };
}
