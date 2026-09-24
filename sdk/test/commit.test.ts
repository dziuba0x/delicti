import { describe, expect, it } from "vitest";
import { commitmentFor, deedsDigest, Kind, randomSalt, sortIds } from "../src/commit.js";
import { pad32 } from "../src/fdc.js";

// Computed on-chain by the v0.13 Vault's own pure helpers (`cast call … commitmentFor/deedsDigest`),
// so the SDK's encoding is pinned to the contract's, not to another copy of itself.
const ONCHAIN = "0x785fba54b6bf96c5ffd939691e001be2d0a1fc69a42dd8c956e58b6243be1aa7";

describe("commitment encoding", () => {
  it("matches Vault.commitmentFor(deedsDigest(ids)) computed on Coston2", () => {
    const ids = sortIds([
      "0x242ce977a21f6e1ceb13225b43f8ee832361c45a668b1d19fc357f5e039c6b83",
      "0x0d8542ed973f8604e004f78b1087869f928b2e3a8cbb4cfeb017782fff22f659",
    ]);
    const salt = `0x${(7).toString(16).padStart(64, "0")}` as const;
    expect(commitmentFor("0x34D940fb868dbac296311857903C6dA0cbb7C9F1", 11n, Kind.ERC20_OUTFLOW, deedsDigest(ids), salt)).toBe(ONCHAIN);
  });

  it("sorts by numeric value, not by string", () => {
    expect(sortIds(["0xff", "0x0a", "0x100"] as any)).toEqual(["0x0a", "0xff", "0x100"]);
  });

  it("salts are 32 random bytes and do not repeat", () => {
    const a = randomSalt();
    expect(a).toMatch(/^0x[0-9a-f]{64}$/);
    expect(randomSalt()).not.toBe(a);
  });

  it("pads names the way sourceId and attestationType are spelled", () => {
    expect(pad32("testFLR")).toBe("0x74657374464c5200000000000000000000000000000000000000000000000000");
  });
});
