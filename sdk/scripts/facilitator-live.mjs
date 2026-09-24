// MandateFacilitator live on Coston2: x402 payments that cannot settle past a dollar umbrella.
//   A $3 umbrella over one MockUSDT0 rail. The agent signs five EIP-3009 `receiveWithAuthorization`
//   payments of 1 mUSDT0 to the facilitator, each bound to the seller through its nonce. Three settle
//   (brake + settlement + meter note + receipt in one transaction). The fourth and fifth are refused by the
//   facilitator before any token moves: SummaMeter says it would cross $3.
// Run from sdk/:  PRIVATE_KEY=0x… node scripts/facilitator-live.mjs
import { createPublicClient, createWalletClient, defineChain, http, parseEther, keccak256, toHex, stringToHex, pad } from "viem";
import { privateKeyToAccount, generatePrivateKey } from "viem/accounts";
import { readFileSync } from "node:fs";
import { randomBytes } from "node:crypto";

const ROOT = new URL("../../", import.meta.url).pathname;
const abi = (f, c) => JSON.parse(readFileSync(`${ROOT}out/${f}/${c}.json`, "utf8")).abi;
const RPC = process.env.COSTON2_RPC ?? "https://coston2-api.flare.network/ext/C/rpc";
const A = {
  reg: "0x2c58fb0504377fef325DceB66219bC6302263AA3",
  summa: "0x211EB7d798F528B4E66201496bE4Cf7f6A62f644",
  summaVault: "0x8Dd62BE6Ee0689e3Eb5960F08a5356a57bD2F354",
  railVault: "0xB15f5041F4aA2bc212832dfb0e59CD6c0e9a24aF",
  meter: "0x6Bc63F3aBc6Fc3055DB9949bb4e14515321a4E0f",
  fac: process.env.FACILITATOR ?? "0xBC545E2610EAf68956684c56Dd308c1988f9307B",
  usdt0: "0x9Eea43feA502609d0D88DAfd1d64B4e929BF18C2",
};
const b32 = (s) => pad(stringToHex(s), { dir: "right", size: 32 });
const chain = defineChain({ id: 114, name: "coston2", nativeCurrency: { name: "C2FLR", symbol: "C2FLR", decimals: 18 }, rpcUrls: { default: { http: [RPC] } } });
const pc = createPublicClient({ chain, transport: http(RPC) });
const principal = createWalletClient({ account: privateKeyToAccount(process.env.PRIVATE_KEY), chain, transport: http(RPC) });
const agent = createWalletClient({ account: privateKeyToAccount(generatePrivateKey()), chain, transport: http(RPC) });
const regAbi = abi("MandateRegistry.sol", "MandateRegistry");
const vaultAbi = abi("Vault.sol", "Vault");
const summaAbi = abi("JudgeSumma.sol", "JudgeSumma");
const meterAbi = abi("SummaMeter.sol", "SummaMeter");
const facAbi = abi("MandateFacilitator.sol", "MandateFacilitator");
const tokenAbi = abi("MockUSDT0.sol", "MockUSDT0");
const log = (...a) => console.log(new Date().toISOString().slice(11, 19), ...a);

async function send(w, address, abi_, functionName, args = [], value) {
  const hash = await w.writeContract({ address, abi: abi_, functionName, args, value });
  const rc = await pc.waitForTransactionReceipt({ hash });
  if (rc.status !== "success") throw new Error(`${functionName} reverted ${hash}`);
  return rc;
}
const idOf = (rc) => BigInt(rc.logs.find((l) => l.address.toLowerCase() === A.reg.toLowerCase()).topics[1]);
const now = BigInt(Math.floor(Date.now() / 1000));

log(`agent ${agent.account.address}, facilitator ${A.fac}`);
await pc.waitForTransactionReceipt({ hash: await principal.sendTransaction({ to: agent.account.address, value: parseEther("0.5") }) });
const member = idOf(await send(principal, A.reg, regAbi, "commit", [agent.account.address, keccak256(toHex("x402 rail: MockUSDT0 at most 10")),
  `0x${"0".repeat(64)}`, 0n, 10_000_000n, now - 60n, now + 86400n,
  { sourceId: b32("testFLR"), assetKey: pad(A.usdt0, { size: 32 }), agentRef: `0x${"0".repeat(64)}`, bond: A.railVault }]));
const umbrella = idOf(await send(principal, A.reg, regAbi, "commit", [agent.account.address, keccak256(toHex("umbrella: at most $3")),
  `0x${"0".repeat(64)}`, 0n, 3_000_000n, now - 60n, now + 86400n,
  { sourceId: b32("SUMMA"), assetKey: b32("USD/1e6"), agentRef: `0x${"0".repeat(64)}`, bond: A.summaVault }]));
await send(agent, A.reg, regAbi, "declareExclusive", [member]);
await send(agent, A.reg, regAbi, "acknowledge", [umbrella]);
await send(principal, A.summaVault, vaultAbi, "post", [umbrella], parseEther("0.5"));
await send(agent, A.summa, summaAbi, "link", [umbrella, member]);
await send(principal, A.meter, meterAbi, "declareEffector", [umbrella, A.fac]);
await send(principal, A.usdt0, tokenAbi, "mint", [agent.account.address, 4_000_000n]);
log(`member #${member} (MockUSDT0), umbrella #${umbrella} ($3, bond 0.5 C2FLR), facilitator declared on SummaMeter`);

const seller = "0x2222222222222222222222222222222222222222";
for (let i = 1; i <= 5; i++) {
  await new Promise((r) => setTimeout(r, 3000)); // let the RPC catch up on nonces
  const salt = toHex(randomBytes(32));
  const nonce = await pc.readContract({ address: A.fac, abi: facAbi, functionName: "payNonce", args: [seller, umbrella, member, salt] });
  const validBefore = now + 3600n;
  const sig = await agent.signTypedData({
    domain: { name: "Mock USDT0", version: "1", chainId: 114, verifyingContract: A.usdt0 },
    types: { ReceiveWithAuthorization: [
      { name: "from", type: "address" }, { name: "to", type: "address" }, { name: "value", type: "uint256" },
      { name: "validAfter", type: "uint256" }, { name: "validBefore", type: "uint256" }, { name: "nonce", type: "bytes32" }] },
    primaryType: "ReceiveWithAuthorization",
    message: { from: agent.account.address, to: A.fac, value: 1_000_000n, validAfter: 0n, validBefore, nonce },
  });
  const auth = { value: 1_000_000n, validAfter: 0n, validBefore, salt, v: parseInt(sig.slice(130, 132), 16), r: `0x${sig.slice(2, 66)}`, s: `0x${sig.slice(66, 130)}` };
  try {
    await pc.simulateContract({ account: principal.account, address: A.fac, abi: facAbi, functionName: "settle", args: [umbrella, member, seller, auth, 0] });
    const rc = await send(principal, A.fac, facAbi, "settle", [umbrella, member, seller, auth, 0]);
    const tally = await pc.readContract({ address: A.meter, abi: meterAbi, functionName: "spentUsd6", args: [umbrella] });
    log(`payment ${i}: SETTLED ${rc.transactionHash}  gas ${rc.gasUsed}  tally $${Number(tally) / 1e6}`);
  } catch (e) {
    const d = e?.cause?.data;
    const why = d?.errorName ? `${d.errorName}(${(d.args ?? []).map(String).join(",")})` : e.shortMessage;
    log(`payment ${i}: REFUSED by the facilitator before any token moved: ${why}`);
  }
}
log(`seller holds ${Number(await pc.readContract({ address: A.usdt0, abi: tokenAbi, functionName: "balanceOf", args: [seller] }))} base units total (all runs)`);
