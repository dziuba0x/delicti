import type { Address } from "viem";

/** Everything the SDK needs to know about one deployment. */
export interface DelictiNetwork {
  name: string;
  chainId: number;
  rpcUrl: string;
  /** Blockscout-compatible explorer API, used to backfill logs (Flare RPCs serve 30 blocks per eth_getLogs). */
  explorerApi: string;
  explorerUrl: string;
  /** Flare's FlareContractRegistry — the same address on every Flare network. */
  flareContractRegistry: Address;
  /** FDC source name of this chain, as the verifier and `sourceId` spell it. */
  fdcSource: string;
  /** Path segment of this chain's verifier (`/verifier/<x>/EVMTransaction/...`). */
  verifierChain: string;
  contracts: {
    registry: Address;
    anchorLog: Address;
    meter: Address;
    agentRefs: Address;
    vault: Address;
    judgeEvm: Address;
    judgeXrpl: Address;
    bondLens: Address;
  };
}

/** v0.13 on Coston2 (2026-09-24), production timers. docs/DEPLOYMENTS.md. */
export const coston2: DelictiNetwork = {
  name: "coston2",
  chainId: 114,
  rpcUrl: "https://coston2-api.flare.network/ext/C/rpc",
  explorerApi: "https://coston2-explorer.flare.network/api",
  explorerUrl: "https://coston2-explorer.flare.network",
  flareContractRegistry: "0xaD67FE66660Fb8dFE9d6b1b4240d8650e30F6019",
  fdcSource: "testFLR",
  verifierChain: "flr",
  contracts: {
    registry: "0x2c58fb0504377fef325DceB66219bC6302263AA3",
    anchorLog: "0xF2b7A2668e7430611c9b225ea7c966E489Fa40a8",
    meter: "0xa5e06ADc76b96cc8c941B98FDA365f10a0576dE2",
    agentRefs: "0x6036B279d6Fe4aB5DAcbea97162C5394B6E0fca0",
    vault: "0x3e3316D2Dd78d548DFBa2A777171F1E3e05F55EE",
    judgeEvm: "0x175a11C19Fee05DF390D915B2bD7bcF594a59720",
    judgeXrpl: "0x16Db5a2ba8b6C6B3cBaaCe95b0e9D78fa5Dd1D79",
    bondLens: "0xf5b44588b81Da8F042F368B9796De14574a0FAeA",
  },
};
