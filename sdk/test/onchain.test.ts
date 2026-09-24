import { describe, expect, it } from "vitest";
import { createPublicClient, http, BaseError, ContractFunctionRevertedError } from "viem";
import { readFileSync } from "node:fs";
import { decodeEvmTransactionResponse } from "../src/fdc.js";
import { coston2 } from "../src/networks.js";
import { judgeEvmAbi } from "../src/abi.js";

const fx = JSON.parse(readFileSync(new URL("./fixtures/m11-evmtx.json", import.meta.url), "utf8"));
// #11's bond was emptied by the sentinel on 2026-09-24 (docs/DEPLOYMENTS.md), and a judge refuses an
// empty bond before it verifies anything; the round trip uses #12's, which still has bond left.
const fx12 = JSON.parse(readFileSync(new URL("./fixtures/m12-evmtx.json", import.meta.url), "utf8"));
const online = process.env.DELICTI_ONLINE === "1";

describe("a real FDC proof from mandate #11", () => {
  const data = decodeEvmTransactionResponse(fx.response_hex);

  it("decodes into the judge's struct", () => {
    expect(data.requestBody.transactionHash).toBe(fx.txHash);
    expect(data.votingRound).toBe(BigInt(fx.round));
    expect(data.responseBody.status).toBe(1);
    // the facilitator sent it — not the agent
    expect(data.responseBody.sourceAddress.toLowerCase()).not.toBe("0x34d940fb868dbac296311857903c6da0cbb7c9f1");
    const transfers = data.responseBody.events.filter(
      (e: any) => e.topics[0] === "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef",
    );
    expect(transfers).toHaveLength(1);
    expect(BigInt(transfers[0].data)).toBe(1_000_000n);
  });

  // Round trip through the live judge: the proof passes FdcVerification and every check, and is
  // refused only because it is already on the docket. `DELICTI_ONLINE=1 npm test` to run.
  it.skipIf(!online)("the live JudgeEvm verifies a real proof and answers NothingNew (already filed)", async () => {
    const pc = createPublicClient({ transport: http(coston2.rpcUrl) });
    const err = await pc
      .simulateContract({
        // mandate #11 was bonded in the v0.13 Vault; its judge stays its judge (SPEC §8.2)
        address: coston2.history.find((d) => d.version === "v0.13")!.judgeEvm,
        abi: judgeEvmAbi,
        functionName: "fileErc20Outflow",
        args: [12n, [{ merkleProof: fx12.proof, data: decodeEvmTransactionResponse(fx12.response_hex) }], `0x${"0".repeat(64)}`],
      })
      .then(() => undefined, (e) => e);
    expect(err).toBeInstanceOf(BaseError);
    const revert = (err as BaseError).walk((e) => e instanceof ContractFunctionRevertedError) as ContractFunctionRevertedError;
    expect(revert.data?.errorName).toBe("NothingNew");
  }, 60_000);
});
