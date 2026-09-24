/**
 * A stablecoin agent under a DELICTI mandate, end to end with the SDK (Coston2).
 *
 *   tsx examples/x402-agent.ts new <n>          principal commits a 4-mUSDT0 mandate, the agent
 *                                               declares it exclusive, the principal bonds 1 C2FLR,
 *                                               then the agent makes <n> x402 payments
 *   tsx examples/x402-agent.ts pay <id> <n>     <n> more payments under mandate <id>
 *
 * Each payment is EIP-3009: the AGENT signs `transferWithAuthorization`, a FACILITATOR (its own
 * key, made here) sends it. No receipts are written. The watcher (`delicti-watch erc20 <id>`) is
 * what brings the agent to account.
 *
 * Env: PRIVATE_KEY (principal = agent in this demo), optional FAC_KEY.
 */
import { createPublicClient, createWalletClient, defineChain, http, parseAbi, parseEther, toHex, type Hex } from "viem";
import { generatePrivateKey, privateKeyToAccount } from "viem/accounts";
import { randomBytes } from "node:crypto";
import { coston2, Delicti } from "../src/index.js";

const TOKEN = "0x9Eea43feA502609d0D88DAfd1d64B4e929BF18C2" as const; // MockUSDT0, EIP-3009, 6 decimals
const PAYEE = "0x2222222222222222222222222222222222222222" as const;
const EACH = 1_000_000n;
const tokenAbi = parseAbi([
  "function mint(address,uint256)",
  "function balanceOf(address) view returns (uint256)",
  "function transferWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce,uint8 v,bytes32 r,bytes32 s)",
]);

const net = { ...coston2, rpcUrl: process.env.COSTON2_RPC ?? coston2.rpcUrl };
const chain = defineChain({ id: 114, name: "coston2", nativeCurrency: { name: "C2FLR", symbol: "C2FLR", decimals: 18 }, rpcUrls: { default: { http: [net.rpcUrl] } } });
const pc = createPublicClient({ chain, transport: http(net.rpcUrl) });
const agentKey = process.env.PRIVATE_KEY as Hex;
const agent = createWalletClient({ account: privateKeyToAccount(agentKey), chain, transport: http(net.rpcUrl) });
const facKey = (process.env.FAC_KEY as Hex) ?? generatePrivateKey();
const facilitator = createWalletClient({ account: privateKeyToAccount(facKey), chain, transport: http(net.rpcUrl) });
const delicti = new Delicti(net, pc as any);

async function pay(n: number) {
  const bal = await pc.readContract({ address: TOKEN, abi: tokenAbi, functionName: "balanceOf", args: [agent.account.address] });
  if (bal < BigInt(n) * EACH) await pc.waitForTransactionReceipt({ hash: await agent.writeContract({ address: TOKEN, abi: tokenAbi, functionName: "mint", args: [agent.account.address, BigInt(n) * EACH] }) });
  if ((await pc.getBalance({ address: facilitator.account.address })) < parseEther("0.5")) {
    await pc.waitForTransactionReceipt({ hash: await agent.sendTransaction({ to: facilitator.account.address, value: parseEther("1") }) });
  }
  const validBefore = BigInt(Math.floor(Date.now() / 1000) + 3600);
  for (let i = 0; i < n; i++) {
    const nonce = toHex(randomBytes(32));
    const sig = await agent.signTypedData({
      domain: { name: "Mock USDT0", version: "1", chainId: 114, verifyingContract: TOKEN },
      types: { TransferWithAuthorization: [
        { name: "from", type: "address" }, { name: "to", type: "address" }, { name: "value", type: "uint256" },
        { name: "validAfter", type: "uint256" }, { name: "validBefore", type: "uint256" }, { name: "nonce", type: "bytes32" },
      ] },
      primaryType: "TransferWithAuthorization",
      message: { from: agent.account.address, to: PAYEE, value: EACH, validAfter: 0n, validBefore, nonce },
    });
    const r = `0x${sig.slice(2, 66)}` as Hex, s = `0x${sig.slice(66, 130)}` as Hex, v = parseInt(sig.slice(130, 132), 16);
    const hash = await facilitator.writeContract({ address: TOKEN, abi: tokenAbi, functionName: "transferWithAuthorization", args: [agent.account.address, PAYEE, EACH, 0n, validBefore, nonce, v, r, s] });
    await pc.waitForTransactionReceipt({ hash });
    console.log(`payment ${i}: ${net.explorerUrl}/tx/${hash}  (sent by facilitator ${facilitator.account.address})`);
  }
}

const [cmd, a1, a2] = process.argv.slice(2);
if (cmd === "new") {
  const now = BigInt(Math.floor(Date.now() / 1000));
  const { id } = await delicti.commitMandate(agent, {
    agent: agent.account.address, terms: "may move up to 4 mUSDT0 out of its address via x402", budget: 4n * EACH,
    validFrom: now - 120n, validUntil: now + 86_400n, token: TOKEN,
  });
  await delicti.declareExclusive(agent, id);
  await delicti.post(agent, id, parseEther("1"));
  console.log(`mandate #${id}: budget 4 mUSDT0, exclusive, bonded 1 C2FLR`);
  await pay(Number(a1 ?? 3));
} else if (cmd === "pay") {
  await pay(Number(a2 ?? 1));
} else {
  console.error("usage: x402-agent.ts new <n> | pay <id> <n>");
  process.exit(2);
}
