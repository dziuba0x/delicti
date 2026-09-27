import {
  encodeAbiParameters,
  keccak256,
  pad,
  parseSignature,
  stringToHex,
  type Account,
  type Address,
  type Chain,
  type Hex,
  type PublicClient,
  type Transport,
  type WalletClient,
} from "viem";
import { judgeSummaAbi, mandateFacilitatorAbi, summaMeterAbi } from "./abi.js";
import { randomSalt } from "./commit.js";
import type { DelictiNetwork, SummaStack } from "./networks.js";

type Wallet = WalletClient<Transport, Chain, Account>;

/** An umbrella's `Terms.sourceId` and `Terms.assetKey` (amendment v1.1): one budget in µUSD. */
export const SUMMA_SOURCE = pad(stringToHex("SUMMA"), { dir: "right", size: 32 });
export const USD6_ASSET = pad(stringToHex("USD/1e6"), { dir: "right", size: 32 });

/** The SUMMA stack an umbrella is bonded in (its `Terms.bond` is the stack's VaultSumma): current or earlier. */
export function summaStackOf(n: DelictiNetwork, vault: Address): (SummaStack & { version: string }) | undefined {
  const v = vault.toLowerCase();
  if (n.summa && n.summa.vault.toLowerCase() === v) return { ...n.summa, version: "current" };
  return n.summaHistory?.find((s) => s.vault.toLowerCase() === v);
}

/** `MandateFacilitator.payNonce`: the EIP-3009 nonce an agent signs to pay `seller` under an umbrella and a member. */
export function payNonce(seller: Address, umbrellaId: bigint, memberId: bigint, salt: Hex): Hex {
  return keccak256(
    encodeAbiParameters(
      [{ type: "string" }, { type: "address" }, { type: "uint256" }, { type: "uint256" }, { type: "bytes32" }],
      ["DELICTI/x402", seller, umbrellaId, memberId, salt],
    ),
  );
}

/** `MandateFacilitator.Auth`: an EIP-3009 `receiveWithAuthorization` to the facilitator, split for the call. */
export interface Auth {
  value: bigint;
  validAfter: bigint;
  validBefore: bigint;
  salt: Hex;
  v: number;
  r: Hex;
  s: Hex;
}

/**
 * The agent signs one x402 payment: an EIP-3009 `receiveWithAuthorization` of `value` to the
 * facilitator, its nonce bound to the seller, umbrella and member. It is the signature `settle`
 * takes and `recordAttempt` records when the brake refuses it. `domain` is the token's EIP-712
 * name and version ("Mock USDT0" / "1" for MockUSDT0 on Coston2).
 */
export async function signPayment(
  agent: Wallet,
  o: {
    token: Address;
    domain: { name: string; version: string };
    facilitator: Address;
    seller: Address;
    umbrellaId: bigint;
    memberId: bigint;
    value: bigint;
    validAfter?: bigint;
    validBefore: bigint;
    salt?: Hex;
  },
): Promise<Auth> {
  const salt = o.salt ?? randomSalt();
  const validAfter = o.validAfter ?? 0n;
  const sig = await agent.signTypedData({
    domain: { name: o.domain.name, version: o.domain.version, chainId: agent.chain.id, verifyingContract: o.token },
    types: {
      ReceiveWithAuthorization: [
        { name: "from", type: "address" },
        { name: "to", type: "address" },
        { name: "value", type: "uint256" },
        { name: "validAfter", type: "uint256" },
        { name: "validBefore", type: "uint256" },
        { name: "nonce", type: "bytes32" },
      ],
    },
    primaryType: "ReceiveWithAuthorization",
    message: {
      from: agent.account.address,
      to: o.facilitator,
      value: o.value,
      validAfter,
      validBefore: o.validBefore,
      nonce: payNonce(o.seller, o.umbrellaId, o.memberId, salt),
    },
  });
  const p = parseSignature(sig);
  return { value: o.value, validAfter, validBefore: o.validBefore, salt, v: Number(p.v ?? BigInt(p.yParity + 27)), r: p.r, s: p.s };
}

/** What an umbrella's meter says now: the tally, the principal's tripwire, the strikes, and whether it is
 *  tripped. The last three are absent on meters from before amendment v1.2 (the v0.15 stack). */
export interface UmbrellaState {
  tallyUsd6: bigint;
  /** Strikes that trip the umbrella; 0 = no tripwire set. */
  tripwire?: bigint;
  strikes?: bigint;
  tripped?: boolean;
}

/**
 * One SUMMA stack (amendment v1.1) with v1.2's tripwire and attempt register: the calls a principal,
 * an effector and a facilitator make. `Summa.of(network)` is the current stack.
 */
export class Summa {
  constructor(readonly publicClient: PublicClient, readonly stack: SummaStack) {}

  static of(n: DelictiNetwork, publicClient: PublicClient, vault?: Address): Summa {
    const stack = vault ? summaStackOf(n, vault) : n.summa;
    if (!stack) throw new Error(`no SUMMA stack${vault ? ` with VaultSumma ${vault}` : ""} on ${n.name}`);
    return new Summa(publicClient, stack);
  }

  private async mined(hash: Hex): Promise<Hex> {
    const rc = await this.publicClient.waitForTransactionReceipt({ hash });
    if (rc.status !== "success") throw new Error(`reverted: ${hash}`);
    return hash;
  }

  async state(umbrellaId: bigint): Promise<UmbrellaState> {
    const r = (functionName: "spentUsd6" | "tripwire" | "strikes" | "tripped") =>
      this.publicClient.readContract({ address: this.stack.meter, abi: summaMeterAbi, functionName, args: [umbrellaId] });
    const v12 = (functionName: "tripwire" | "strikes" | "tripped") => r(functionName).catch(() => undefined); // absent before v1.2
    const [tallyUsd6, tripwire, strikes, tripped] = await Promise.all([r("spentUsd6"), v12("tripwire"), v12("strikes"), v12("tripped")]);
    return { tallyUsd6: tallyUsd6 as bigint, tripwire: tripwire as bigint | undefined, strikes: strikes as bigint | undefined, tripped: tripped as boolean | undefined };
  }

  /** The umbrella's agent puts one of its rail mandates under it (JudgeSumma.link): same principal, acknowledged,
   *  receipt-less (§6.10 or §6.11, exclusive), priced by the stack's map. Sticky; counts deeds from now on. */
  async link(agent: Wallet, umbrellaId: bigint, memberId: bigint): Promise<Hex> {
    return this.mined(await agent.writeContract({ address: this.stack.judge, abi: judgeSummaAbi, functionName: "link", args: [umbrellaId, memberId] }));
  }

  /** Principal: let `effector` note spend and strike on this umbrella (a guard, a facilitator). */
  async declareEffector(principal: Wallet, umbrellaId: bigint, effector: Address): Promise<Hex> {
    return this.mined(await principal.writeContract({ address: this.stack.meter, abi: summaMeterAbi, functionName: "declareEffector", args: [umbrellaId, effector] }));
  }

  /** Principal: after `strikesToTrip` recorded attempts, the meter answers "stop" on every rail. */
  async setTripwire(principal: Wallet, umbrellaId: bigint, strikesToTrip: bigint): Promise<Hex> {
    return this.mined(await principal.writeContract({ address: this.stack.meter, abi: summaMeterAbi, functionName: "setTripwire", args: [umbrellaId, strikesToTrip] }));
  }

  /** Principal, having looked: clear the strikes. */
  async rearm(principal: Wallet, umbrellaId: bigint): Promise<Hex> {
    return this.mined(await principal.writeContract({ address: this.stack.meter, abi: summaMeterAbi, functionName: "rearm", args: [umbrellaId] }));
  }

  /** A declared effector reports a refused attempt; `evidence` is whatever it can point to (a hash of the signed request). */
  async strike(effector: Wallet, umbrellaId: bigint, evidence: Hex): Promise<Hex> {
    return this.mined(await effector.writeContract({ address: this.stack.meter, abi: summaMeterAbi, functionName: "strike", args: [umbrellaId, evidence] }));
  }

  /** Would `amount` of (`sourceId`, `assetKey`) take the umbrella past its budget, priced now? (a simulated call: free) */
  async wouldExceed(umbrellaId: bigint, sourceId: Hex, assetKey: Hex, amount: bigint, slackBps = 0): Promise<{ stop: boolean; usd6: bigint }> {
    const { result } = await this.publicClient.simulateContract({
      address: this.stack.meter, abi: summaMeterAbi, functionName: "wouldExceed", args: [umbrellaId, sourceId, assetKey, amount, slackBps],
    });
    const [stop, usd6] = result as readonly [boolean, bigint];
    return { stop, usd6 };
  }

  /** Settle one x402 payment through the facilitator: brake, transfer, meter note and receipt in one transaction. */
  async settle(caller: Wallet, o: { umbrellaId: bigint; memberId: bigint; seller: Address; auth: Auth; slackBps?: number }): Promise<Hex> {
    return this.mined(await caller.writeContract({
      address: this.stack.facilitator, abi: mandateFacilitatorAbi, functionName: "settle",
      args: [o.umbrellaId, o.memberId, o.seller, o.auth, o.slackBps ?? 0],
    }));
  }

  /**
   * Conatus: record an authorisation the brake refuses (anyone holding it may). The contract checks
   * that the agent signed it to the facilitator, that it is live, and that it breaks the budget
   * against the tally at `validAfter`, at 99 % of its value. Returns by how much, in µUSD.
   */
  async recordAttempt(caller: Wallet, o: { umbrellaId: bigint; memberId: bigint; seller: Address; auth: Auth }): Promise<{ tx: Hex; overUsd6: bigint }> {
    const { result, request } = await this.publicClient.simulateContract({
      account: caller.account, address: this.stack.facilitator, abi: mandateFacilitatorAbi, functionName: "recordAttempt",
      args: [o.umbrellaId, o.memberId, o.seller, o.auth],
    });
    const tx = await this.mined(await caller.writeContract(request as any));
    return { tx, overUsd6: result as bigint };
  }

  /** When the attempt with this nonce was recorded (0 = never). */
  async attemptedAt(nonce: Hex): Promise<bigint> {
    return BigInt(await this.publicClient.readContract({ address: this.stack.facilitator, abi: mandateFacilitatorAbi, functionName: "attemptedAt", args: [nonce] }));
  }

  /** How many attempts were recorded against a member's agent. */
  async attempts(memberId: bigint): Promise<bigint> {
    return (await this.publicClient.readContract({ address: this.stack.facilitator, abi: mandateFacilitatorAbi, functionName: "attempts", args: [memberId] })) as bigint;
  }
}
