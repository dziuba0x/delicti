# Who watches, and why they would: lessons from seven watcher layers

*Research note, 2026-09-24. It informed the v0.14 watch pool and the sentinel (SPEC §8.4, `sdk/`). Facts carry their sources. Items marked "unverified" are background knowledge that was not re-checked.*

DELICTI's security needs one honest party to bring a case. Every system below needed the same thing, and each one found out in its own way that "anyone can" does not mean "anyone will". This note records what they learned the hard way and what DELICTI takes from it.

## 1. Lightning watchtowers: the deterrence paradox

- lnd has shipped private *altruist* towers since v0.7 (2019). Its docs still say *reward* towers "will be enabled in a subsequent release". Seven years on, they have not been. ([lnd watchtower.md](https://github.com/lightningnetwork/lnd/blob/master/docs/watchtower.md))
- A tower stores encrypted blobs keyed by half a commitment txid, and can decrypt one only once a breach appears on chain. ([BOLT 13 draft](https://github.com/sr-gi/bolt13/blob/master/13-watchtowers.md), never merged)
- The core objection: "watchtowers will not receive any fee if (thanks to them) no fraud occurs… this approach may incentivize watchtowers to encourage frauds." ([arXiv 2012.10825](https://arxiv.org/html/2012.10825))

**For DELICTI.** An agent that behaves never crosses its budget, so a crossing bounty alone pays nothing in exactly the case the protocol exists to produce. Before v0.14, docket keeping was unpaid (SPEC §10). That is the watchtower mistake, and v0.14 fixes it.

## 2. Forta: paying for uptime instead of work

- The design had detection bots staked at 100 FORT on scan nodes staked at 2,500 FORT. Nodes were paid on SLA, uptime and stake, and a node below SLA 0.75 earned nothing. ([Forta docs](https://docs.forta.network/en/latest/FAQs/))
- In August 2024 Forta pivoted to Forta Firewall, which screens transactions at the sequencer: "in most cases protocols cannot prevent the exploit TXs despite being able to detect them." ([Forta blog](https://www.forta.org/blog/introducing-forta-firewall)) The community node network no longer appears in what Forta sells. Evidence on the wind-down is thin.

**For DELICTI.** Detection had no economic sink, so nodes were paid for being there rather than for being right. DELICTI pays only for work a contract can verify: an FDC-proven deed on a docket. It never pays for a claim to be watching.

## 3. Keeper networks: races waste, rotation needs a whitelist

- Keep3r v1 paid by gas used, so competing keepers burned gas on reverted calls, and one keeper did most of a job. ([Keep3r experiment](https://macarse.medium.com/the-keep3r-network-experiment-bb1c5182bda3))
- Chainlink Keepers rotated upkeeps between nodes turn by turn ("keepers do not compete"). Automation 2.x reaches OCR3 consensus over a permissioned node set.

**For DELICTI.** Recording is upkeep, not a hunt. The cost of a lost race here is an FDC attestation fee, which is tens of FLR on mainnet, not gas. Since v0.15 the claim *is* the payment: `Vault.requestAttestation` records the first payer of each request, and a second watcher reads `requesterOf` before buying.

## 4. UMA and Kleros: open participation concentrates

- Polymarket's UMA adapter restricted proposing to 37 whitelisted addresses in August 2025. ([The Block](https://www.theblock.co/post/366507/polymarket-uma-oracle-update))
- One holder with about 5M UMA cast about 25 % of the votes on a $7M market in March 2025.

**For DELICTI.** DELICTI never votes: every verdict rests on an FDC proof. The protocol should also assume a small professional watcher set plus our own reference sentinel, and be safe with that. It is, because one honest filer is enough.

## 5. Rollup challengers: the team watches, the treasury pays

- Arbitrum BoLD (live 12 Feb 2025): honest parties get a 1 % bounty and a 100 % gas refund from the Foundation. ([BoLD economics](https://docs.arbitrum.io/how-arbitrum-works/bold/bold-economics-of-disputes))
- OP permissionless fault proofs went live on 10 June 2024 and were disabled on 17 August 2024 after audit findings. ([The Block](https://www.theblock.co/post/311702/optimism-foundation-disables-permissionless-fraud-proofs-plans-hard-fork-following-security-audits))
- The verifier's dilemma: rational parties skip costly verification that goes unpaid. (Luu et al., CCS 2015, [ePrint 2015/702](https://eprint.iacr.org/2015/702))

**For DELICTI.** Run the reference watcher ourselves and say so, and reimburse what a filer really pays. The crossing filer's attestations have been reimbursed since v0.9, and v0.14 pays recorders too.

## 6. Liquidations: winner-take-all becomes a latency war

- Black Thursday, 12–13 March 2020: 1,462 Maker auctions settled at zero bids, about $8.32M, while mempool flooding kept rival keepers out. ([CoinDesk](https://www.coindesk.com/tech/2020/07/22/mempool-manipulation-enabled-theft-of-8m-in-makerdao-collateral-on-black-thursday-report))
- Over two years, 2,011 addresses took $63.6M of liquidation profit, and 74 % of liquidations overpaid gas. ([Qin et al., IMC 2021](https://arxiv.org/pdf/2106.06389))

**For DELICTI.** The commit–reveal gate (§6.7) keeps the crossing reward from being copied. The adversary with the earliest knowledge is the agent itself (§10). Nothing here fixes that, and the note does not pretend otherwise.

## 7. Paying many contributors

- Chainlink OCR pays each oracle whose observation made it into a report, plus the transmitter separately, with gas refunded.
- Truebit's jackpot halved per extra challenger to deter sybils, which made rewards unpredictable. ([arXiv 1806.11476](https://arxiv.org/pdf/1806.11476.pdf))

**For DELICTI.** Pay per unique unit of verified work, not per filer. A deed can be filed once, so sybils cannot multiply what the agent actually did.

## What DELICTI took from this

1. **A watch pool (v0.14, reworked in v0.15, SPEC §8.4).** The principal funds a pool and sets a stipend per deed. Each new, value-moving deed pays that stipend to **whoever paid for its attestation** through the Vault, and the payer need not be the one who files it. The pool pays for verified work, not uptime, and its size is capped by what the principal chose. Honest agents now produce income for watchers, which removes the deterrence paradox for any mandate a principal cares enough to fund.
2. **Paying the attester, not the filer.** v0.14 paid the filer, and an adversarial review showed a copier lifting a watcher's proofs and taking the stipends. This is Truebit's verifier's dilemma in miniature: whoever does the work must be the one paid. Since v0.15 the first payer of an attestation holds the deed, and anyone can see who that is before buying it. That removes the duplicate-fee race.
3. **Self-recording is harmless.** An agent that pays for its own deeds' attestations collects stipends from a pool that pays for exactly that work, and its record gets updated. Draining the pool with dust costs a real transfer and an attestation per deed. With a stipend near the attestation fee, that is roughly break-even. The principal sets the rate and the cap.
4. **A reference sentinel, open-sourced and run by us.** It discovers every mandate from state, prices each case before buying anything, and acts according to a stated policy (`observe`, `profit` or `altruist`). Our own instance is one honest watcher among any number.
5. **Watch the watchers.** The public score flags provable outflow that is not yet on a docket, and deeds that aged past the verifier's memory without being filed. Proof of watching is a docket entry, never a heartbeat.
6. **No subjective adjudication, ever.** Every paid action rests on an FDC proof.

Where the evidence was thin: Forta's scan-node wind-down, Kleros juror concentration, and independent challenger counts on BoLD and OP. No primary data was found for any of them.
