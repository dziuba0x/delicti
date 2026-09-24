import {
  decodeAbiParameters,
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
import { judgeEvmAbi } from "./abi.js";
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

// The ABI of one `IEVMTransaction.Proof`, taken from the judge's own ABI so it cannot drift.
const fileErc20 = judgeEvmAbi.find((x) => x.type === "function" && x.name === "fileErc20Outflow")!;
const proofParam = (fileErc20 as any).inputs[1].components as readonly [any, any];
const responseParam = proofParam[1];

/** `IEVMTransaction.Proof` as viem takes it: the Merkle path plus the attested response. */
export interface EvmTransactionProof {
  merkleProof: readonly Hex[];
  data: any;
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
   * Ask the verifier to encode an `EVMTransaction` request. `logIndices` empty = every log of the
   * transaction up to 50; the §6.11 watcher lists exactly the logs it means to file.
   */
  async prepareEvmTransaction(txHash: Hex, logIndices: readonly number[], requiredConfirmations = 1): Promise<Hex> {
    const body = {
      attestationType: pad32("EVMTransaction"),
      sourceId: pad32(this.network.fdcSource),
      requestBody: {
        transactionHash: txHash,
        requiredConfirmations: String(requiredConfirmations),
        provideInput: false,
        listEvents: true,
        logIndices: logIndices.map(String),
      },
    };
    const r = await fetch(`${this.services.verifierUrl}/verifier/${this.network.verifierChain}/EVMTransaction/prepareRequest`, {
      method: "POST",
      headers: { "X-API-KEY": this.services.apiKey, "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
    const j = (await r.json()) as { status: string; abiEncodedRequest?: Hex };
    if (j.status !== "VALID" || !j.abiEncodedRequest) throw new Error(`verifier refused ${txHash}: ${JSON.stringify(j)}`);
    return j.abiEncodedRequest;
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

  /** Poll the DA layer until the round is finalised and the proof is served. */
  async proof(round: bigint, abiEncodedRequest: Hex, timeoutMs = 10 * 60_000): Promise<EvmTransactionProof> {
    const until = Date.now() + timeoutMs;
    for (;;) {
      const r = await fetch(`${this.services.daUrl}/api/v1/fdc/proof-by-request-round-raw`, {
        method: "POST",
        headers: { "X-API-KEY": this.services.apiKey, "Content-Type": "application/json" },
        body: JSON.stringify({ votingRoundId: Number(round), requestBytes: abiEncodedRequest }),
      }).catch(() => undefined);
      if (r?.ok) {
        const j = (await r.json().catch(() => ({}))) as { response_hex?: Hex; proof?: Hex[] };
        if (j.response_hex && j.proof) return { merkleProof: j.proof, data: decodeEvmTransactionResponse(j.response_hex) };
      }
      if (Date.now() > until) throw new Error(`no proof for round ${round} after ${timeoutMs} ms`);
      await new Promise((ok) => setTimeout(ok, 15_000));
    }
  }
}

/** `abi.encode(IEVMTransaction.Response)` → the struct viem passes back to the judge. */
export function decodeEvmTransactionResponse(responseHex: Hex): any {
  return decodeAbiParameters([responseParam], responseHex)[0];
}
