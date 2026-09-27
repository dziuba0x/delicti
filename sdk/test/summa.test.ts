import { describe, expect, it } from "vitest";
import { createWalletClient, defineChain, http, recoverTypedDataAddress, type Address, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { Delicti } from "../src/client.js";
import { coston2 } from "../src/networks.js";
import { SUMMA_SOURCE, Summa, payNonce, signPayment, summaStackOf } from "../src/summa.js";

// SUMMA helpers (amendment v1.1 + v1.2's tripwire and attempt register), offline.

describe("SUMMA helpers", () => {
  it("payNonce matches the live MandateFacilitator (v0.16, read 2026-09-27)", () => {
    const salt = `0x${"11".repeat(32)}` as Hex;
    expect(payNonce("0x2222222222222222222222222222222222222222", 7n, 5n, salt)).toBe(
      "0x7b55dc2939c741058f156cb19ef58021588ddafc294921bbae57e1f5708de1a7",
    );
  });

  it("finds an umbrella's stack by its VaultSumma: current, earlier, or none", () => {
    expect(summaStackOf(coston2, coston2.summa!.vault)?.version).toBe("current");
    expect(summaStackOf(coston2, "0x8Dd62BE6Ee0689e3Eb5960F08a5356a57bD2F354")?.version).toBe("v0.15");
    expect(summaStackOf(coston2, coston2.contracts.vault)).toBeUndefined();
  });

  it("the agent's signature recovers to the agent, over the nonce the facilitator will rebuild", async () => {
    const chain = defineChain({ id: 114, name: "coston2", nativeCurrency: { name: "C2FLR", symbol: "C2FLR", decimals: 18 }, rpcUrls: { default: { http: ["http://127.0.0.1:1"] } } });
    const agent = createWalletClient({ account: privateKeyToAccount(`0x${"42".repeat(32)}`), chain, transport: http() });
    const token = "0x9Eea43feA502609d0D88DAfd1d64B4e929BF18C2" as Address, facilitator = coston2.summa!.facilitator;
    const seller = "0x2222222222222222222222222222222222222222" as Address;
    const a = await signPayment(agent, { token, domain: { name: "Mock USDT0", version: "1" }, facilitator, seller, umbrellaId: 9n, memberId: 8n, value: 1_000_000n, validBefore: 2_000_000_000n });
    const signer = await recoverTypedDataAddress({
      domain: { name: "Mock USDT0", version: "1", chainId: 114, verifyingContract: token },
      types: { ReceiveWithAuthorization: [
        { name: "from", type: "address" }, { name: "to", type: "address" }, { name: "value", type: "uint256" },
        { name: "validAfter", type: "uint256" }, { name: "validBefore", type: "uint256" }, { name: "nonce", type: "bytes32" }] },
      primaryType: "ReceiveWithAuthorization",
      message: { from: agent.account.address, to: facilitator, value: 1_000_000n, validAfter: 0n, validBefore: 2_000_000_000n, nonce: payNonce(seller, 9n, 8n, a.salt) },
      signature: `${a.r}${a.s.slice(2)}${a.v.toString(16)}` as Hex,
    });
    expect(signer).toBe(agent.account.address);
    expect([27, 28]).toContain(a.v);
  });

  it("a meter from before v1.2 has a tally and no tripwire", async () => {
    const pc = {
      async readContract({ functionName }: { functionName: string }) {
        if (functionName === "spentUsd6") return 1_234_567n;
        throw new Error("execution reverted"); // tripwire/strikes/tripped do not exist there
      },
    };
    const st = await new Summa(pc as any, summaStackOf(coston2, "0x8Dd62BE6Ee0689e3Eb5960F08a5356a57bD2F354")!).state(26n);
    expect(st).toEqual({ tallyUsd6: 1_234_567n, tripwire: undefined, strikes: undefined, tripped: undefined });
  });
});

describe("Delicti.status reads a mandate from its own Vault", () => {
  const V015 = { vault: "0xB15f5041F4aA2bc212832dfb0e59CD6c0e9a24aF", judgeEvm: "0x463042fbFD04c723F430eC299aD4000D4d42cFf2", judgeXrpl: "0x9201272ee10B19177A04435195B3b29D9a765940" };
  const fake = (bond: Address, sourceId: Hex) => {
    const touched = new Set<string>();
    const pc = {
      async readContract({ address, functionName }: { address: Address; functionName: string }) {
        touched.add(address.toLowerCase());
        if (functionName === "get") return { principal: V015.vault, agent: V015.vault, budget: 1n, validFrom: 0n, validUntil: 1n, assetKey: sourceId, bond, sourceId };
        if (["isLive", "exclusive", "acknowledged", "slashed", "tripped"].includes(functionName)) return false;
        return 7n;
      },
    };
    return { pc, touched };
  };

  it("a v0.15 mandate: v0.15 Vault and judges, never the current ones", async () => {
    const { pc, touched } = fake(V015.vault as Address, `0x${"0".repeat(64)}`);
    const s = await new Delicti(coston2, pc as any).status(14n);
    expect(s.version).toBe("v0.15");
    for (const a of Object.values(V015)) expect(touched.has(a.toLowerCase())).toBe(true);
    for (const a of [coston2.contracts.vault, coston2.contracts.judgeEvm, coston2.contracts.judgeXrpl]) expect(touched.has(a.toLowerCase())).toBe(false);
    expect(s.summa).toBeUndefined();
  });

  it("a SUMMA umbrella in the current VaultSumma: its meter's tally and tripwire", async () => {
    const { pc, touched } = fake(coston2.summa!.vault, SUMMA_SOURCE);
    const s = await new Delicti(coston2, pc as any).status(30n);
    expect(s.version).toBe("summa");
    expect(touched.has(coston2.summa!.meter.toLowerCase())).toBe(true);
    expect(s.summa).toMatchObject({ version: "current", meter: coston2.summa!.meter, tallyUsd6: 7n, tripwire: 7n, strikes: 7n, tripped: false });
    expect(s.dockets).toEqual({ erc20: undefined, xrpOutflow: undefined, xrpPayments: undefined });
  });
});
