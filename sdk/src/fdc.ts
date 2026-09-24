import {
  decodeAbiParameters,
  encodeAbiParameters,
  parseAbi,
  toHex,
  type Account,
  type Address,
  type Chain,
  type Hex,
  type PublicClient,
  type Transport,
  type WalletClient,
} from "viem";
import { agentRefsAbi, judgeEvmAbi, judgeXrplAbi } from "./abi.js";
import type { DelictiNetwork } from "./networks.js";

/** Where the FDC's off-chain halves live. Both are Flare's services; both need an API key. */
export interface FdcServices {
  verifierUrl: string;
  daUrl: string;
  apiKey: string;
}

const flareRegistryAbi = parseAbi(["function getContractAddressByName(string) view returns (address)"]);
const fdcHubAbi = parseAbi(["function requestAttestation(bytes) payable"]);
const feeConfigAbi = parseAbi(["function getRequestFee(bytes) view returns (uint256)"]);
const systemsManagerAbi = parseAbi([
  "function firstVotingRoundStartTs() view returns (uint64)",
  "function votingEpochDurationSeconds() view returns (uint64)",
]);

/** A bytes32 of an ASCII name, right-padded — how `attestationType` and `sourceId` are spelled. */
export function pad32(s: string): Hex {
  return toHex(new TextEncoder().encode(s), { size: 32 });
}

// Each attestation type's `Response` ABI, taken from the contract that consumes it, so the SDK's
// decoding cannot drift from what the judges accept.
function responseParamOf(abi: readonly any[], fn: string, arg: number): any {
  const f = abi.find((x) => x.type === "function" && x.name === fn)!;
  const input = f.inputs[arg];
  const proof = input.type.endsWith("[]") ? input.components : input.components;
  return proof[1];
}
const RESPONSE = {
  EVMTransaction: responseParamOf(judgeEvmAbi as any, "fileErc20Outflow", 1),
  BalanceDecreasingTransaction: responseParamOf(judgeXrplAbi as any, "fileXrpOutflow", 1),
  Payment: responseParamOf(agentRefsAbi as any, "proveExclusive", 1),
} as const;
export type AttestationType = keyof typeof RESPONSE;

/** An FDC proof as a judge takes it: the Merkle path plus the attested response. */
export interface FdcProof {
  merkleProof: readonly Hex[];
  data: any;
}
/** @deprecated kept for 0.13 callers */
export type EvmTransactionProof = FdcProof;

export function decodeResponse(type: AttestationType, responseHex: Hex): any {
  return decodeAbiParameters([RESPONSE[type]], responseHex)[0];
}

/** `abi.encode(IEVMTransaction.Response)` → the struct viem passes back to the judge. */
export function decodeEvmTransactionResponse(responseHex: Hex): any {
  return decodeResponse("EVMTransaction", responseHex);
}

export class Fdc {
  constructor(
    readonly network: DelictiNetwork,
    readonly services: FdcServices,
    readonly publicClient: PublicClient,
  ) {}

  private async named(name: string): Promise<Address> {
    return this.publicClient.readContract({
      address: this.network.flareContractRegistry,
      abi: flareRegistryAbi,
      functionName: "getContractAddressByName",
      args: [name],
    });
  }

  /** The voting-round clock: round R starts at `t0 + R × duration`. */
  async clock(): Promise<{ t0: bigint; duration: bigint }> {
    const fsm = await this.named("FlareSystemsManager");
    const [t0, duration] = await Promise.all([
      this.publicClient.readContract({ address: fsm, abi: systemsManagerAbi, functionName: "firstVotingRoundStartTs" }),
      this.publicClient.readContract({ address: fsm, abi: systemsManagerAbi, functionName: "votingEpochDurationSeconds" }),
    ]);
    return { t0, duration };
  }

  /**
   * Ask a verifier to encode a request. The XRP verifier's index trails the ledger by seconds to a
   * minute, so an `INVALID` for a transaction that exists is retried `tries` times, 10 s apart.
   */
  async prepare(type: AttestationType, chain: string, source: string, requestBody: object, tries = 1): Promise<Hex> {
    const body = { attestationType: pad32(type), sourceId: pad32(source), requestBody };
    let last: unknown;
    for (let i = 0; i < tries; i++) {
      const r = await fetch(`${this.services.verifierUrl}/verifier/${chain}/${type}/prepareRequest`, {
        method: "POST",
        headers: { "X-API-KEY": this.services.apiKey, "Content-Type": "application/json" },
        body: JSON.stringify(body),
      }).catch((e) => ({ ok: false, json: async () => ({ status: String(e) }) }) as any);
      const j = (await r.json().catch(() => ({}))) as { status?: string; abiEncodedRequest?: Hex };
      if (j.status === "VALID" && j.abiEncodedRequest) return j.abiEncodedRequest;
      last = j;
      if (i + 1 < tries) await new Promise((ok) => setTimeout(ok, 10_000));
    }
    throw new Error(`verifier refused ${type} ${JSON.stringify(requestBody)}: ${JSON.stringify(last)}`);
  }

  /**
   * An `EVMTransaction` request. `logIndices` empty = every log of the transaction up to 50; the
   * §6.11 watcher lists exactly the logs it means to file.
   */
  async prepareEvmTransaction(txHash: Hex, logIndices: readonly number[], requiredConfirmations = 1): Promise<Hex> {
    return this.prepare("EVMTransaction", this.network.verifierChain, this.network.fdcSource, {
      transactionHash: txHash,
      requiredConfirmations: String(requiredConfirmations),
      provideInput: false,
      listEvents: true,
      logIndices: logIndices.map(String),
    });
  }

  /** How much `account`'s XRP balance fell in transaction `txId` (§6.10). `agentRef` = keccak256(address). */
  async prepareBalanceDecrease(txId: Hex, agentRef: Hex, tries = 12): Promise<Hex> {
    return this.prepare("BalanceDecreasingTransaction", this.network.xrpl.verifierChain, this.network.xrpl.fdcSource, {
      transactionId: txId,
      sourceAddressIndicator: agentRef,
    }, tries);
  }

  /** An XRP `Payment` (§6.8, and the memo statements of `AgentRefs.prove` / `proveExclusive`). */
  async preparePayment(txId: Hex, tries = 12): Promise<Hex> {
    return this.prepare("Payment", this.network.xrpl.verifierChain, this.network.xrpl.fdcSource, {
      transactionId: txId,
      inUtxo: "0",
      utxo: "0",
    }, tries);
  }

  /** Pay the fee and submit the request to FdcHub. Returns the voting round it landed in. */
  async request(wallet: WalletClient<Transport, Chain, Account>, abiEncodedRequest: Hex): Promise<bigint> {
    const [hub, feeCfg, clock] = await Promise.all([this.named("FdcHub"), this.named("FdcRequestFeeConfigurations"), this.clock()]);
    const fee = await this.publicClient.readContract({ address: feeCfg, abi: feeConfigAbi, functionName: "getRequestFee", args: [abiEncodedRequest] });
    const hash = await wallet.writeContract({ address: hub, abi: fdcHubAbi, functionName: "requestAttestation", args: [abiEncodedRequest], value: fee });
    const rc = await this.publicClient.waitForTransactionReceipt({ hash });
    if (rc.status !== "success") throw new Error(`requestAttestation reverted: ${hash}`);
    const block = await this.publicClient.getBlock({ blockNumber: rc.blockNumber });
    return (block.timestamp - clock.t0) / clock.duration;
  }

  /** What one request of this type and source costs today, in wei — read the way the Vault reads it
   *  when it reimburses a crossing filer (`Vault.fdcCost`). */
  async feeFor(type: AttestationType, source: string): Promise<bigint> {
    const feeCfg = await this.named("FdcRequestFeeConfigurations");
    const probe = encodeAbiParameters([{ type: "bytes32" }, { type: "bytes32" }, { type: "bytes32" }], [pad32(type), pad32(source), `0x${"0".repeat(64)}`]);
    return this.publicClient.readContract({ address: feeCfg, abi: feeConfigAbi, functionName: "getRequestFee", args: [probe] });
  }

  /** What one request costs today, in wei. */
  async fee(abiEncodedRequest: Hex): Promise<bigint> {
    const feeCfg = await this.named("FdcRequestFeeConfigurations");
    return this.publicClient.readContract({ address: feeCfg, abi: feeConfigAbi, functionName: "getRequestFee", args: [abiEncodedRequest] });
  }

  /** Poll the DA layer until the round is finalised and the proof is served; decode it as `type`. */
  async proof(round: bigint, abiEncodedRequest: Hex, type: AttestationType = "EVMTransaction", timeoutMs = 10 * 60_000): Promise<FdcProof> {
    const until = Date.now() + timeoutMs;
    for (;;) {
      const r = await fetch(`${this.services.daUrl}/api/v1/fdc/proof-by-request-round-raw`, {
        method: "POST",
        headers: { "X-API-KEY": this.services.apiKey, "Content-Type": "application/json" },
        body: JSON.stringify({ votingRoundId: Number(round), requestBytes: abiEncodedRequest }),
      }).catch(() => undefined);
      if (r?.ok) {
        const j = (await r.json().catch(() => ({}))) as { response_hex?: Hex; proof?: Hex[] };
        if (j.response_hex && j.proof) return { merkleProof: j.proof, data: decodeResponse(type, j.response_hex) };
      }
      if (Date.now() > until) throw new Error(`no proof for round ${round} after ${timeoutMs} ms`);
      await new Promise((ok) => setTimeout(ok, 15_000));
    }
  }
}
