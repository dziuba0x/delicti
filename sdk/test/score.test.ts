import { describe, expect, it } from "vitest";
import { scoreAgents, type Observation } from "../src/sentinel/score.js";
import { coston2 } from "../src/networks.js";
import type { MandateInfo } from "../src/sentinel/discover.js";

// A chain where nobody has ever been convicted.
const pc = { readContract: async () => 0n } as any;
const A = "0x00000000000000000000000000000000000000a1";
const m = (id: bigint, o: Partial<MandateInfo> = {}): MandateInfo => ({
  id, principal: A, agent: A, budget: 4_000_000n, validFrom: 0, validUntil: 1, revoked: false, sourceId: "0x", assetKey: "0x", agentRef: "0x",
  vault: coston2.contracts.vault, acknowledged: true, exclusive: true, live: true, deathTime: 0, bond: 10n ** 18n, slashed: false,
  severity: 0n, taken: 0n, cls: "erc20-outflow", why: "", ...o,
});
const ob = (id: string, seen: bigint, docket: bigint): Observation => ({
  mandateId: id, cls: "erc20-outflow", seen: seen.toString(), unfiled: (seen - docket).toString(), lost: 0, docket: docket.toString(), budget: "4000000", plan: "record", checkedAt: 0,
});

describe("the public score", () => {
  it("raises the alarm when the chain shows more outflow than the budget and no verdict exists yet", async () => {
    const [s] = await scoreAgents(pc, coston2, [m(1n)], new Map([["1", ob("1", 5_000_000n, 3_000_000n)]]));
    expect(s.standing).toBe("breach-unjudged");
    expect(s.worstUseBps).toBe(12_500);
    expect(s.flags[0]).toMatch(/2000000 of outflow not yet on the docket/);
  });

  it("clean within the budget; watched and self-watched counted from the watch pool", async () => {
    const [s] = await scoreAgents(pc, coston2, [m(1n, { watchPool: 1n, stipendPerDeed: 1n, agentFundedWatch: 1n })], new Map([["1", ob("1", 3_000_000n, 3_000_000n)]]));
    expect(s.standing).toBe("clean");
    expect([s.watched, s.selfWatched]).toEqual([1, 1]);
  });

  it("ignores what the agent never acknowledged (SPEC §11.1)", async () => {
    const [s] = await scoreAgents(pc, coston2, [m(1n, { acknowledged: false })], new Map([["1", ob("1", 9_000_000n, 0n)]]));
    expect(s.standing).toBe("unobserved");
  });
});
