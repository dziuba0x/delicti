import { encodeAbiParameters, keccak256, toHex, type Address, type Hex } from "viem";
import { randomBytes } from "node:crypto";

/** Challenge kinds (SPEC §6.7, `Kinds.sol`). Unique across every judge of a Vault. */
export const Kind = {
  FALSE_PAYMENT: 1,
  BUDGET_NATIVE: 2,
  BUDGET_ERC20: 3,
  UNANCHORED_DEED: 4,
  UNDER_REPORTED: 5,
  BUDGET_PAYMENT: 6,
  XRP_OUTFLOW: 7,
  ERC20_OUTFLOW: 8,
} as const;

/** `Vault.deedsDigest(ids)`: keccak256(abi.encode(bytes32[])). */
export function deedsDigest(ids: readonly Hex[]): Hex {
  return keccak256(encodeAbiParameters([{ type: "bytes32[]" }], [ids]));
}

/** `Vault.commitmentFor(challenger, mandateId, kind, digest, salt)`. */
export function commitmentFor(challenger: Address, mandateId: bigint, kind: number, digest: Hex, salt: Hex): Hex {
  return keccak256(
    encodeAbiParameters(
      [{ type: "address" }, { type: "uint256" }, { type: "uint8" }, { type: "bytes32" }, { type: "bytes32" }],
      [challenger, mandateId, kind, digest, salt],
    ),
  );
}

/**
 * 256 bits from the OS. Never derive a salt from public values: the commitment would be
 * brute-forceable, which cannot steal the case (the challenger is in the preimage) but tells the
 * world which case is coming, `commitLead` early — the mechanism running backwards.
 */
export function randomSalt(): Hex {
  return toHex(randomBytes(32));
}

/** Strict ascending order by numeric value — the order every multi-deed challenge requires. */
export function sortIds(ids: readonly Hex[]): Hex[] {
  return [...ids].sort((a, b) => (BigInt(a) < BigInt(b) ? -1 : BigInt(a) > BigInt(b) ? 1 : 0));
}
