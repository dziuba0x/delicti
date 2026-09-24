import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import type { Hex } from "viem";
import { accountRootChange, xrplAddressHash, type XrplMove } from "../src/xrpl/history.js";
import { planXrpl, XRPL_PROOF_HORIZON, type XrplMandateView } from "../src/xrpl/planner.js";

const AGENT = "ra2ALvaMmxbFW177FvHUFkhg2ukfWvJKiz"; // mandate #9's account (v0.12, docs/DEPLOYMENTS.md)
const taken = JSON.parse(readFileSync(new URL("./fixtures/xrpl-offer-taken.json", import.meta.url), "utf8"));

describe("reading an XRPL account's balance history", () => {
  it("the agentRef of mandate #9 is keccak256 of its classic address", () => {
    expect(xrplAddressHash(AGENT)).toBe("0x58457754f5e1bc66988c25ac965f321021c410f780d2165fdd32a0cc22cc80d1");
  });

  it("finds the agent's outflow in a transaction the agent did not sign — the offer taken by the counterparty", () => {
    expect(taken.tx.Account).not.toBe(AGENT); // signed by the taker
    const ch = accountRootChange(taken.tx.meta, AGENT)!;
    expect(ch.delta).toBe(-5_000_000n); // 5 XRP left the agent, no fee: the taker paid it
    expect(ch.previousTxnId).toMatch(/^[0-9A-F]{64}$/); // the backward link the walk follows
  });

  it("returns nothing for an account the transaction did not touch", () => {
    expect(accountRootChange(taken.tx.meta, "rNotInvolvedXXXXXXXXXXXXXXXXXXXXXX")).toBeUndefined();
  });
});

const T = 1_800_000_000;
const view = (o: Partial<XrplMandateView> = {}): XrplMandateView => ({ budget: 12_000_000n, validFrom: T, validUntil: T + 86_400, docket: 0n, bond: 1n, exclusive: true, ...o });
const mv = (n: number, spent: bigint, ts = T + 60, own = true): XrplMove => ({
  txId: `0x${n.toString(16).padStart(64, "0")}` as Hex, ledger: n, timestamp: ts, spent, type: "Payment", ownTransaction: own,
});

describe("planXrpl", () => {
  it("records outflow within the budget, fees and all", () => {
    const p = planXrpl([mv(1, 3_000_010n), mv(2, 3_000_010n)], () => false, view(), T + 100);
    expect(p.action).toBe("record");
    if (p.action === "record") expect(p.adds).toBe(6_000_020n);
  });

  it("an inflow is never filed: it would buy an attestation that adds nothing", () => {
    const p = planXrpl([mv(1, -100_000_000n), mv(2, 10n)], () => false, view(), T + 100);
    expect(p.action === "record" && p.txIds).toEqual([mv(2, 10n).txId]);
  });

  it("convicts past the budget, counting what someone else's transaction took", () => {
    const p = planXrpl([mv(1, 3_000_010n), mv(2, 5_000_000n, T + 60, false), mv(3, 3_000_010n), mv(4, 3_000_010n)], () => false, view(), T + 100);
    expect(p.action).toBe("convict");
    if (p.action === "convict") expect(p.docketAfter).toBe(14_000_030n);
  });

  it("skips what is filed and what is outside the window", () => {
    const p = planXrpl([mv(1, 5n), mv(2, 5n, T - 1), mv(3, 5n, T + 86_401), mv(4, 5n)], (id) => id === mv(1, 5n).txId, view(), T + 100);
    expect(p.action === "record" && p.txIds).toEqual([mv(4, 5n).txId]);
  });

  it("reports deeds past the verifier's memory as lost, and never requests them", () => {
    const now = T + 60 + XRPL_PROOF_HORIZON + 1;
    const p = planXrpl([mv(1, 5n), mv(2, 5n, T + 86_000)], () => false, view(), now);
    expect(p.lost.map((x) => x.txId)).toEqual([mv(1, 5n).txId]);
    expect(p.action === "record" && p.txIds).toEqual([mv(2, 5n).txId]);
  });

  it("is idle without exclusivity or bond", () => {
    expect(planXrpl([mv(1, 5n)], () => false, view({ exclusive: false }), T).action).toBe("idle");
    expect(planXrpl([mv(1, 5n)], () => false, view({ bond: 0n }), T).action).toBe("idle");
  });
});
