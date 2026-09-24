import type { RoundReport } from "./sentinel.js";

const esc = (s: string) => s.replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]!);
const flr = (wei: string) => (Number(BigInt(wei) / 10n ** 12n) / 1e6).toLocaleString("en", { maximumFractionDigits: 4 });
const short = (a: string) => `${a.slice(0, 6)}…${a.slice(-4)}`;

/** A self-contained HTML page of one sentinel round: no scripts, no external assets. */
export function renderHtml(r: RoundReport, explorer: string): string {
  const tone: Record<string, string> = { "breach-unjudged": "#ff5d5d", convicted: "#ffb020", unbonded: "#8a93a3", clean: "#39d98a", unobserved: "#8a93a3" };
  const agents = r.agents
    .map(
      (a) => `<tr><td><a href="${explorer}/address/${a.agent}">${short(a.agent)}</a>${a.xrplAccounts.map((x) => `<div class="sub">${esc(x)}</div>`).join("")}</td>
<td><span class="pill" style="--c:${tone[a.standing]}">${a.standing}</span></td><td>${a.acknowledged}/${a.mandates}</td><td>${a.exclusive}</td>
<td>${flr(a.bonded)}</td><td>${a.verdicts}</td><td>${flr(a.taken)}</td><td>${(a.worstUseBps / 100).toFixed(1)}%</td><td>${a.watched}${a.selfWatched ? ` <span class="sub">(${a.selfWatched} self)</span>` : ""}</td>
<td class="flags">${a.flags.map(esc).join("<br>")}</td></tr>`,
    )
    .join("");
  const obs = r.observations
    .map((o) => {
      const d = r.decisions.find((x) => x.mandateId === o.mandateId);
      return `<tr><td>#${o.mandateId}</td><td>${o.cls}</td><td>${esc(o.account ?? "")}</td><td>${o.seen}</td><td>${o.docket}</td><td>${o.budget}</td><td>${o.unfiled}</td><td>${o.lost}</td>
<td>${o.plan}${d?.acted ? " ✓" : ""}</td><td class="flags">${esc(d?.error ?? d?.why ?? "")}${(d?.txs ?? []).map((t) => `<br><a href="${explorer}/tx/${t}">${short(t)}</a>`).join("")}</td></tr>`;
    })
    .join("");
  const mandates = r.mandates
    .map((m) => `<tr><td>#${m.id}</td><td>${m.cls}</td><td>${m.version ?? "?"}</td><td>${m.live ? "live" : "dead"}</td><td>${flr(m.bond)}</td><td>${m.slashed ? "yes" : ""}</td><td class="flags">${esc(m.why)}</td></tr>`)
    .join("");
  return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>DELICTI sentinel</title><style>
:root{--bg:#0e1013;--panel:#161a20;--line:#262c35;--ink:#e8ebf0;--mute:#8a93a3;--accent:#dc143c}
body{margin:0;background:var(--bg);color:var(--ink);font:14px/1.5 ui-sans-serif,system-ui,-apple-system,sans-serif}
main{max-width:1200px;margin:0 auto;padding:24px 16px}h1{font-size:22px;margin:0 0 4px;letter-spacing:.02em}h1 b{color:var(--accent)}
h2{font-size:15px;margin:28px 0 8px;color:var(--mute);text-transform:uppercase;letter-spacing:.08em}
.meta{color:var(--mute)}.wrap{overflow-x:auto;background:var(--panel);border:1px solid var(--line);border-radius:10px}
table{border-collapse:collapse;width:100%;min-width:760px}th,td{text-align:left;padding:8px 10px;border-bottom:1px solid var(--line);vertical-align:top;font-variant-numeric:tabular-nums}
th{color:var(--mute);font-weight:500}a{color:#7cc4ff;text-decoration:none}.sub,.flags{color:var(--mute);font-size:12px}
.pill{display:inline-block;padding:1px 8px;border-radius:99px;border:1px solid var(--c);color:var(--c);font-size:12px}
</style></head><body><main>
<h1>DELICTI <b>sentinel</b></h1><div class="meta">${esc(r.network)} · ${esc(r.at)} · policy ${r.policy} · every number recomputable from the chains</div>
<h2>Agents</h2><div class="wrap"><table><tr><th>agent</th><th>standing</th><th>ack/all</th><th>exclusive</th><th>bonded</th><th>verdicts</th><th>taken</th><th>worst use</th><th>watched</th><th>flags</th></tr>${agents}</table></div>
<h2>Watched mandates</h2><div class="wrap"><table><tr><th>mandate</th><th>class</th><th>xrpl account</th><th>outflow seen</th><th>docket</th><th>budget</th><th>unfiled</th><th>lost</th><th>plan</th><th>note</th></tr>${obs}</table></div>
<h2>All mandates</h2><div class="wrap"><table><tr><th>mandate</th><th>class</th><th>vault</th><th>status</th><th>bond</th><th>slashed</th><th>why</th></tr>${mandates}</table></div>
</main></body></html>`;
}
