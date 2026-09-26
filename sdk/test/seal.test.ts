import { describe, expect, it } from "vitest";
import { keccak256, type Address, type Hex } from "viem";
import { commitmentFor } from "../src/commit.js";
import { KIND_CLAIM, claimKeyOf, payClaims, requestAttestations, sealClaims, sealOf } from "../src/seal.js";
import type { Deployment } from "../src/networks.js";

// Watch pool v2 (v0.16): seal, wait commitLead, pay with the salt. Offline, against a fake chain
// that keeps the Vault's commitment book the way Vault.commitChallenge / committedAt do.

const ME = "0x1111111111111111111111111111111111111111" as Address;
const OTHER = "0x2222222222222222222222222222222222222222" as Address;
const VAULT = "0x91Dc735b78d22331E4D345370D625Eb25E5cc77a" as Address;
const ZERO = "0x0000000000000000000000000000000000000000";
const req = (b: string): Hex => `0x${b.repeat(160)}`; // ≥ 128 bytes, like a real request
const dep = (features: Deployment["features"]): Deployment => ({ version: "test", vault: VAULT, judgeEvm: VAULT, judgeXrpl: VAULT, features });
const V016 = dep(["erc20Docket", "xrpDocket", "paymentDocket", "watchPool", "paidRequests", "sealedClaims"]);

function chain(o: { holders?: Record<string, Address>; lead?: bigint; alreadyClaimed?: Set<Hex> } = {}) {
  let now = 1_000n;
  const committed = new Map<Hex, bigint>();
  const calls: { fn: string; args?: readonly unknown[]; via?: unknown; at: bigint }[] = [];
  const publicClient = {
    async readContract({ functionName, args }: { functionName: string; args?: readonly unknown[] }) {
      if (functionName === "claimantOf") return o.holders?.[String(args![0])] ?? ZERO;
      if (functionName === "committedAt") return committed.get(args![0] as Hex) ?? 0n;
      if (functionName === "commitLead") return o.lead ?? 600n;
      throw new Error(`unexpected read ${functionName}`);
    },
    async waitForTransactionReceipt() { return { status: "success" }; },
    async getBlock() { return { timestamp: now }; },
  };
  const wallet = {
    account: { address: ME },
    async writeContract({ functionName, args }: { functionName: string; args: readonly unknown[] }) {
      calls.push({ fn: functionName, args, at: now });
      if (functionName === "commitChallenge") committed.set(args[0] as Hex, now);
      return `0x${"ab".repeat(32)}` as Hex;
    },
  };
  const fdc = {
    async request(_w: unknown, request: Hex, via?: unknown) {
      if (typeof via === "object" && o.alreadyClaimed?.has(request)) throw new Error('reverted with the following reason: AlreadyClaimed()');
      calls.push({ fn: "fdc.request", args: [request], via, at: now });
      return 7n;
    },
  };
  const sleep = async (ms: number) => { now += BigInt(Math.ceil(ms / 1000)); };
  return { publicClient: publicClient as any, wallet: wallet as any, fdc: fdc as any, calls, sleep, committed };
}

describe("watch pool v2: the seal", () => {
  it("seals keccak256(request) under kind 0, mandate 0", () => {
    const r = req("ab"), salt = `0x${"5a".repeat(32)}` as Hex;
    expect(KIND_CLAIM).toBe(0);
    expect(claimKeyOf(r)).toBe(keccak256(r));
    expect(sealOf(ME, r, salt)).toBe(commitmentFor(ME, 0n, 0, keccak256(r), salt));
  });

  it("v0.16: seals what nobody holds, waits commitLead, pays through the Vault with that salt", async () => {
    const free = req("01"), mine = req("02"), theirs = req("03");
    const c = chain({ holders: { [keccak256(mine)]: ME, [keccak256(theirs)]: OTHER } });
    const { plan, rounds } = await requestAttestations({ ...c, dep: V016, requests: [free, mine, theirs] });

    expect(plan.entries.map((e) => e.route)).toEqual(["sealed", "held", "taken"]);
    const seals = c.calls.filter((x) => x.fn === "commitChallenge");
    expect(seals).toHaveLength(1); // only the free request is sealed
    const salt = plan.entries[0].salt!;
    expect(seals[0].args![0]).toBe(sealOf(ME, free, salt));

    const paid = c.calls.filter((x) => x.fn === "fdc.request");
    expect(paid.map((x) => x.via)).toEqual([{ vault: VAULT, salt }, { vault: VAULT, salt: `0x${"0".repeat(64)}` }, undefined]);
    // never before the seal is commitLead old: the Vault would refuse CommittedTooLate
    expect(paid[0].at).toBeGreaterThanOrEqual(seals[0].at + 600n);
    expect(rounds).toEqual([7n, 7n, 7n]);
  });

  it("one wait covers a challenge committed after the seals", async () => {
    const c = chain();
    const plan = await sealClaims({ ...c, dep: V016, requests: [req("04")] });
    await c.sleep(700_000); // commitAndWait for the challenge: longer than commitLead
    const before = c.calls.length;
    await payClaims({ ...c, plan });
    expect(c.calls.length - before).toBe(1); // paid at once, no second wait
  });

  it("someone paid for the same bytes in the meantime: the request goes to FdcHub", async () => {
    const r = req("05");
    const c = chain({ alreadyClaimed: new Set([r]) });
    const { plan } = await requestAttestations({ ...c, dep: V016, requests: [r] });
    expect(plan.entries[0].route).toBe("taken");
    expect(c.calls.filter((x) => x.fn === "fdc.request").map((x) => x.via)).toEqual([undefined]);
  });

  it("v0.15: through the Vault, unsealed; earlier Vaults: straight to FdcHub", async () => {
    const c15 = chain();
    await requestAttestations({ ...c15, dep: dep(["erc20Docket", "xrpDocket", "paymentDocket", "watchPool", "paidRequests"]), requests: [req("06")] });
    expect(c15.calls.map((x) => [x.fn, x.via])).toEqual([["fdc.request", VAULT]]);

    const c13 = chain();
    await requestAttestations({ ...c13, dep: dep(["erc20Docket", "xrpDocket", "paymentDocket"]), requests: [req("07")] });
    expect(c13.calls.map((x) => [x.fn, x.via])).toEqual([["fdc.request", undefined]]);
  });
});
