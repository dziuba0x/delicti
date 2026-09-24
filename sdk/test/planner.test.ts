import { describe, expect, it } from "vitest";
import type { Hex } from "viem";
import { planErc20, type MandateView } from "../src/erc20/planner.js";
import type { OutflowLog } from "../src/erc20/logs.js";

const T = 1_800_000_000;
const m = (over: Partial<MandateView> = {}): MandateView => ({
  budget: 4_000_000n, validFrom: T, validUntil: T + 86_400, docket: 0n, bond: 10n ** 18n, exclusive: true, ...over,
});
const tx = (n: number) => (`0x${n.toString(16).padStart(64, "0")}`) as Hex;
const log = (t: number, i: number, value = 1_000_000n, ts = T + 60): OutflowLog => ({
  txHash: tx(t), logIndex: i, blockNumber: 1n, timestamp: ts, value, to: "0x2222222222222222222222222222222222222222",
});
const none = () => false;

describe("planErc20", () => {
  it("records while the docket stays within the budget", () => {
    const p = planErc20([log(1, 0), log(2, 1), log(3, 2)], none, m());
    expect(p.action).toBe("record");
    if (p.action === "record") expect(p.adds).toBe(3_000_000n);
  });

  it("exactly the budget is not an overrun", () => {
    expect(planErc20([1, 2, 3, 4].map((t) => log(t, t)), none, m()).action).toBe("record");
  });

  it("convicts when the new outflow takes the docket past the budget, over every new transaction", () => {
    const p = planErc20([1, 2].map((t) => log(t, t)), none, m({ docket: 3_000_000n }));
    expect(p.action).toBe("convict");
    if (p.action === "convict") {
      expect(p.docketAfter).toBe(5_000_000n);
      expect(p.filings.map((f) => f.txHash)).toEqual([tx(1), tx(2)]);
    }
  });

  it("orders transactions by hash, ascending, whatever order the logs arrived in", () => {
    const p = planErc20([log(9, 0), log(3, 1), log(0x100, 2)], none, m());
    expect(p.action !== "idle" && p.filings.map((f) => f.txHash)).toEqual([tx(3), tx(9), tx(0x100)]);
  });

  it("groups the logs of one transaction into one filing, indices sorted", () => {
    const p = planErc20([log(1, 7), log(1, 2), log(1, 5)], none, m());
    expect(p.action !== "idle" && p.filings).toEqual([{ txHash: tx(1), logIndices: [2, 5, 7], value: 3_000_000n }]);
  });

  it("lists at most 50 logs of a transaction; the rest wait for the next cycle", () => {
    const logs = Array.from({ length: 60 }, (_, i) => log(1, 59 - i, 1n));
    const p = planErc20(logs, none, m());
    expect(p.action !== "idle" && p.filings[0].logIndices).toEqual(Array.from({ length: 50 }, (_, i) => i));
    const done = new Set(Array.from({ length: 50 }, (_, i) => i));
    const next = planErc20(logs, (l) => done.has(l.logIndex), m({ docket: 50n }));
    expect(next.action !== "idle" && next.filings[0].logIndices).toEqual([50, 51, 52, 53, 54, 55, 56, 57, 58, 59]);
  });

  it("skips what is already on the docket, per log", () => {
    const p = planErc20([log(1, 0), log(1, 1), log(2, 2)], (l) => l.logIndex === 0, m({ docket: 1_000_000n }));
    expect(p.action !== "idle" && p.filings.map((f) => [f.txHash, f.logIndices])).toEqual([[tx(1), [1]], [tx(2), [2]]]);
  });

  it("ignores logs outside the window (filing one would revert)", () => {
    const p = planErc20([log(1, 0, 9_000_000n, T - 1), log(2, 1, 9_000_000n, T + 86_401), log(3, 2)], none, m());
    expect(p.action === "record" && p.filings.map((f) => f.txHash)).toEqual([tx(3)]);
  });

  it("after a conviction, any new outflow is another (nested) crossing", () => {
    expect(planErc20([log(7, 0, 1n)], none, m({ docket: 5_000_000n })).action).toBe("convict");
  });

  it("zero-value transfers only record: the judge convicts nothing on a docket that did not move", () => {
    expect(planErc20([log(7, 0, 0n)], none, m({ docket: 5_000_000n })).action).toBe("record");
  });

  it("is idle with nothing new, nothing bonded, or no exclusivity", () => {
    expect(planErc20([], none, m()).action).toBe("idle");
    expect(planErc20([log(1, 0)], () => true, m()).action).toBe("idle");
    expect(planErc20([log(1, 0)], none, m({ bond: 0n })).action).toBe("idle");
    expect(planErc20([log(1, 0)], none, m({ exclusive: false })).action).toBe("idle");
  });
});
