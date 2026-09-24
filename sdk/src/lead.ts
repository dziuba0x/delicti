import type { Account, Address, Chain, Hex, PublicClient, Transport, WalletClient } from "viem";
import { vaultAbi } from "./abi.js";
import { commitmentFor, deedsDigest, randomSalt } from "./commit.js";
import type { Fdc } from "./fdc.js";

/**
 * Commit to a case before any attestation makes it public, then wait until the first voting
 * round that starts `commitLead` after the commitment (SPEC §6.7). Requests landing earlier would
 * make the filer's own proofs unusable: the reveal compares the commitment against the START of
 * the round each request landed in. Returns the salt to reveal with.
 */
export async function commitAndWait(o: {
  publicClient: PublicClient;
  wallet: WalletClient<Transport, Chain, Account>;
  fdc: Fdc;
  vault: Address;
  mandateId: bigint;
  kind: number;
  ids: readonly Hex[];
  say?: (m: string) => void;
}): Promise<{ salt: Hex; commitTx: Hex }> {
  const { publicClient: pc, wallet, vault } = o;
  const salt = randomSalt();
  const c = commitmentFor(wallet.account.address, o.mandateId, o.kind, deedsDigest(o.ids), salt);
  const commitTx = await wallet.writeContract({ address: vault, abi: vaultAbi, functionName: "commitChallenge", args: [c] });
  const rc = await pc.waitForTransactionReceipt({ hash: commitTx });
  if (rc.status !== "success") throw new Error(`commitChallenge reverted: ${commitTx}`);
  const [at, lead, clock] = await Promise.all([
    pc.readContract({ address: vault, abi: vaultAbi, functionName: "committedAt", args: [c] }),
    pc.readContract({ address: vault, abi: vaultAbi, functionName: "commitLead" }),
    o.fdc.clock(),
  ]);
  const r = (BigInt(at) + BigInt(lead) - clock.t0 + clock.duration - 1n) / clock.duration;
  const target = clock.t0 + r * clock.duration + 10n;
  o.say?.(`committed ${c} at ${at}; attestations wait until t=${target} (round ${r})`);
  for (;;) {
    const now = (await pc.getBlock()).timestamp;
    if (now >= target) break;
    await new Promise((ok) => setTimeout(ok, Math.min(30, Number(target - now)) * 1000));
  }
  return { salt, commitTx };
}
