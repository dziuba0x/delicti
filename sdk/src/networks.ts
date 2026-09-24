import type { Address } from "viem";

/** What a consequence layer can do; older Vaults' judges lack the later dockets. */
export type Feature = "erc20Docket" | "xrpDocket" | "paymentDocket" | "watchPool";

export interface Deployment {
  version: string;
  vault: Address;
  judgeEvm: Address;
  judgeXrpl: Address;
  features: Feature[];
}

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
  /** The XRP Ledger this deployment's FDC indexes (§6.8, §6.10). */
  xrpl: {
    rpcUrl: string;
    explorerUrl: string;
    fdcSource: string;
    verifierChain: string;
  };
  /** Earlier consequence layers over the same core. Mandates name the Vault they were bonded in,
   *  and stay judged by that Vault's judges for ever (SPEC §8.2). Newest first. */
  history: Deployment[];
  /** The current consequence layer's features. */
  features: Feature[];
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

/** v0.14 on Coston2 (2026-09-24), production timers. docs/DEPLOYMENTS.md. */
export const coston2: DelictiNetwork = {
  name: "coston2",
  chainId: 114,
  rpcUrl: "https://coston2-api.flare.network/ext/C/rpc",
  explorerApi: "https://coston2-explorer.flare.network/api",
  explorerUrl: "https://coston2-explorer.flare.network",
  flareContractRegistry: "0xaD67FE66660Fb8dFE9d6b1b4240d8650e30F6019",
  fdcSource: "testFLR",
  verifierChain: "flr",
  xrpl: {
    rpcUrl: "https://testnet.xrpl-labs.com/",
    explorerUrl: "https://testnet.xrpl.org",
    fdcSource: "testXRP",
    verifierChain: "xrp",
  },
  features: ["erc20Docket", "xrpDocket", "paymentDocket", "watchPool"],
  history: [
    { version: "v0.13", vault: "0x3e3316D2Dd78d548DFBa2A777171F1E3e05F55EE", judgeEvm: "0x175a11C19Fee05DF390D915B2bD7bcF594a59720", judgeXrpl: "0x16Db5a2ba8b6C6B3cBaaCe95b0e9D78fa5Dd1D79", features: ["erc20Docket", "xrpDocket", "paymentDocket"] },
    { version: "v0.12", vault: "0xFd09d39519F51Ccf12c57bd2D5cF8A71a593Ffae", judgeEvm: "0xb3565787D1d61BF95fA5ACAa394dEAA7deF783aB", judgeXrpl: "0xcf08E6acCbe9042394625350d1DA1888DBcAca63", features: ["xrpDocket"] },
    { version: "v0.11", vault: "0x40A149aCdA2A3D2e299e0FaE4aAA695662AbDAAB", judgeEvm: "0xB6bbb2612d74B2751e8A05C2C5EC3911dBeA9c6c", judgeXrpl: "0xFc4Ae81bfD8dA949Af04177FcCF47A91C006ABAa", features: [] },
    // v0.10 and earlier: one `Bond` that held the collateral and judged; no dockets
    { version: "v0.10", vault: "0x6800400225e03539c4B719f470cC2C8edC3cf65B", judgeEvm: "0x6800400225e03539c4B719f470cC2C8edC3cf65B", judgeXrpl: "0x6800400225e03539c4B719f470cC2C8edC3cf65B", features: [] },
  ],
  contracts: {
    registry: "0x2c58fb0504377fef325DceB66219bC6302263AA3",
    anchorLog: "0xF2b7A2668e7430611c9b225ea7c966E489Fa40a8",
    meter: "0xa5e06ADc76b96cc8c941B98FDA365f10a0576dE2",
    agentRefs: "0x6036B279d6Fe4aB5DAcbea97162C5394B6E0fca0",
    vault: "0x9bF9e4186cFb569Fe5bf528e2859aA7B672566fE",
    judgeEvm: "0x361730A0D1e5886DfF3f7Ea4fC38832Ed29a2C36",
    judgeXrpl: "0xE9E6eD9E3ca7d005a37568E18A80226B4a14E688",
    bondLens: "0xA73f740302FCFE27880EbDd3be3B77FF5500BE1b",
  },
};

/** The consequence layer a mandate's `bond` names: the current one or an earlier one. */
export function deploymentOf(n: DelictiNetwork, vault: Address): Deployment | undefined {
  const v = vault.toLowerCase();
  if (n.contracts.vault.toLowerCase() === v) {
    return { version: "current", vault: n.contracts.vault, judgeEvm: n.contracts.judgeEvm, judgeXrpl: n.contracts.judgeXrpl, features: n.features };
  }
  return n.history.find((d) => d.vault.toLowerCase() === v);
}
