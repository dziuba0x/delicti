// SPEC amendment v1.1 (SUMMA), S.1: can a Flare contract verify an FTSO anchor-feed value for a PAST
// voting round? Fetches value + Merkle proof from the DA layer and eth_calls FtsoV2.verifyFeedData.
// Run from sdk/:  node scripts/ftso-history.mjs   (no key, no gas: view calls only)
import { createPublicClient, http, parseAbi } from "viem";

const NETS = {
  coston2: { rpc: "https://coston2-api.flare.network/ext/C/rpc", da: "https://ctn2-data-availability.flare.network" },
  flare: { rpc: "https://flare-api.flare.network/ext/C/rpc", da: "https://flr-data-availability.flare.network" },
};
const REGISTRY = "0xaD67FE66660Fb8dFE9d6b1b4240d8650e30F6019";
const regAbi = parseAbi(["function getContractAddressByName(string) view returns (address)"]);
const ftsoAbi = [
  {
    type: "function", name: "verifyFeedData", stateMutability: "view",
    inputs: [{ name: "_feedData", type: "tuple", components: [
      { name: "proof", type: "bytes32[]" },
      { name: "body", type: "tuple", components: [
        { name: "votingRoundId", type: "uint32" }, { name: "id", type: "bytes21" },
        { name: "value", type: "int32" }, { name: "turnoutBIPS", type: "uint16" }, { name: "decimals", type: "int8" } ] } ] }],
    outputs: [{ type: "bool" }],
  },
];
const relayAbi = parseAbi([
  "function merkleRoots(uint256 _protocolId, uint256 _votingRoundId) view returns (bytes32)",
]);

const FEEDS = {
  "XRP/USD": "0x015852502f55534400000000000000000000000000",
  "USDT/USD": "0x01555344542f555344000000000000000000000000",
  "FLR/USD": "0x01464c522f55534400000000000000000000000000",
};

for (const [net, cfg] of Object.entries(NETS)) {
  const c = createPublicClient({ transport: http(cfg.rpc) });
  const ftso = await c.readContract({ address: REGISTRY, abi: regAbi, functionName: "getContractAddressByName", args: ["FtsoV2"] });
  const relay = await c.readContract({ address: REGISTRY, abi: regAbi, functionName: "getContractAddressByName", args: ["Relay"] });
  const status = await (await fetch(`${cfg.da}/api/v0/fsp/status`)).json();
  const latest = status.latest_ftso.voting_round_id;
  console.log(`\n== ${net}: FtsoV2 ${ftso}  Relay ${relay}  latest FTSO round ${latest}`);
  for (const days of [0.05, 1, 14, 30, 104, 200, 365]) {
    const round = latest - Math.round((days * 86400) / 90);
    const r = await fetch(`${cfg.da}/api/v0/ftso/anchor-feeds-with-proof?voting_round_id=${round}`, {
      method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ feed_ids: Object.values(FEEDS) }),
    });
    if (!r.ok) { console.log(`  ${days}d round ${round}: DA ${r.status}`); continue; }
    const arr = await r.json();
    const out = [];
    for (const f of arr) {
      let ok;
      try {
        ok = await c.readContract({ address: ftso, abi: ftsoAbi, functionName: "verifyFeedData",
          args: [{ proof: f.proof, body: { ...f.body, value: f.body.value, decimals: f.body.decimals } }] });
      } catch (e) { ok = "revert:" + (e.shortMessage || e.message).slice(0, 60); }
      const name = Object.keys(FEEDS).find((k) => FEEDS[k] === f.body.id);
      out.push(`${name}=${f.body.value / 10 ** f.body.decimals} ${ok}`);
    }
    let root;
    try { root = await c.readContract({ address: relay, abi: relayAbi, functionName: "merkleRoots", args: [100n, BigInt(round)] }); } catch (e) { root = "err"; }
    console.log(`  ${days}d round ${round}: ${out.join(" | ")}  relayRoot(100)=${String(root).slice(0, 12)}`);
  }
  // tamper test: flip value, must be false
  const r = await fetch(`${cfg.da}/api/v0/ftso/anchor-feeds-with-proof?voting_round_id=${latest - 960}`, {
    method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ feed_ids: [FEEDS["XRP/USD"]] }) });
  const [f] = await r.json();
  const bad = await c.readContract({ address: ftso, abi: ftsoAbi, functionName: "verifyFeedData",
    args: [{ proof: f.proof, body: { ...f.body, value: f.body.value + 1 } }] }).catch((e) => "revert");
  console.log(`  tamper (value+1): ${bad}`);
}
