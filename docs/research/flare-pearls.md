# Pearls from the Flare developer hub, and what DELICTI can do with them (2026-09-24)

This is a full pass over the source of dev.flare.network (`flare-foundation/developer-hub`, commit `9b3ac35`, 269 pages), read for things DELICTI can use. Each entry gives what Flare offers, the page it is on, and the use. Items marked **verified** were run against Coston2 and Flare mainnet in this session.

## 1. FTSO anchor feeds are provable a year back (verified)
`ftso/scaling/*`, DA layer `anchor-feeds-with-proof`, `FtsoV2.verifyFeedData`.
The docs say two weeks. The measured history is ≥ 365 days on both networks, and a tampered value reverts.
**Use:** SUMMA values every deed in USD at the round it happened (amendment v1.1). See `ftso-history-2026-09-24.md`.

## 2. Secure randomness, free, historical per round
`network/guides/secure-random-numbers.mdx`, `RandomNumberV2Interface.getRandomNumberHistorical(round)`.
It is the sum of about 100 providers' committed values. It is uniform if a single provider is honest. It carries an `isSecure` flag, and reading it costs nothing.
**Use:**
- (a) **The Rogue's schedule**: the live-fire agent draws when, where and how much to breach from the random number of a round that did not exist when it committed. So not even its operators can tip anyone off (`tools/rogue/`).
- (b) An open problem in §10 (the agent self-slashing through its own commitment and taking the reward off real watchers) has a randomised answer: split or draw the challenger's share across every valid commitment for the same case, seeded by the round after the reveal. That changes the Vault's reward rule, so it belongs to v2. It is written down here so it is not lost.

## 3. FDC proofs travel: the Relay can be relayed
`fdc/guides/foundry/09-cross-chain-fdc.mdx`. Flare relays `Relay` roots to the XRPL EVM Sidechain, and an `FdcVerification` there checks FDC proofs natively.
**Use: a DELICTI passport.**
- An `EVMTransaction` attestation with `sourceId = FLR` can prove a *Flare* transaction, including its events.
- A DELICTI `Verdict`, a SUMMA checkpoint or an `ExclusiveProven` is therefore a provable fact on any chain whose Relay is relayed.
- A contract on another chain can read an agent's standing with no bridge and no DELICTI key, at FDC latency.
- This is the natural home for the XRPL-credential idea (§13) on EVM chains.

## 4. `proofOwner`: proofs that only one address can use
`fdc/attestation-types/xrp-payment.mdx`, `xrp-payment-nonexistence.mdx`: *"proofOwner lets a contract bind a proof to a specific caller."*
**Use:** a judge built on `XRPPayment` / `XRPPaymentNonexistence` can require `requestBody.proofOwner == msg.sender`. The copier problem (§6.7, §8.4) then disappears at the source for those kinds. Commit–reveal and `deedKey` exist because v1.0's FDC types have no such field.

## 5. `XRPPaymentNonexistence`: absence matched by memo or destination tag
The same page. It matches by first-memo hash and/or destination tag, not by the 32-byte standard reference.
**Use:** "false payment" (§6.1) for XRPL invoice flows that identify the payer by destination tag. This is part of what x402-on-XRPL cannot express through `ReferencedPaymentNonexistence`.

## 6. USD₮0 on Flare speaks EIP-3009; FXRP does not yet (verified in the docs)
`network/guides/gasless-usdt0-transfers.mdx`, `fxrp/token-interactions/03-x402-payments.mdx`.
x402's `exact` scheme therefore works on Flare with real USD₮0 today. Flare's own x402 guide still uses MockUSDT0 for FXRP "until FXRP implements EIP-3009".

## 7. Flare's x402 facilitator is a contract
The same x402 guide. `X402Facilitator.settlePayment()` calls `transferWithAuthorization`.
**Use (step 3 of the plan):** a `MandateFacilitator` that, in **one transaction**:
1. checks `SummaMeter.wouldExceed`;
2. settles;
3. calls `note`;
4. emits the receipt.

The brake stops being a server's promise. It becomes atomic with the payment, and witness 1 is the settlement itself.

## 8. Custom feeds (FIP.13)
`ftso/guides/create-custom-feed.mdx`. Anyone can publish an `IICustomFeed` (id prefix `0x21`), and the example fills it from a Web2Json proof. Live examples: `sFLR/USD` (Sceptre) and `stXRP/USD` (Firelight).
**Use:**
- (a) the missing `RLUSD/USD` value, for coverage checks;
- (b) sFLR as a bond that keeps its staking yield while it guards, valued live by its custom feed;
- (c) a DELICTI index as a feed (total value bonded, breach rate), readable by any Flare contract the same way it reads a price.

Custom feeds have current values only, not historical proofs. So they are fine for "is the bond enough *now*" and never for "what was this deed worth *then*".

## 9. FTSO risk tiers and stability data, published by Flare
`ftso/3-feed-stability-and-risks.mdx`, `automations/ftso_risk.json`. Tiers: USDT and USDC are 0; FLR, XRP, ETH and BTC are 1; SGB is 2. Stability is measured against a 0.2 % band.
**Use:** SUMMA's haircut table keys on Flare's own risk tier, not on a number we invented (amendment S.7).

## 10. New attestation types can be proposed
`fdc/guides/foundry/create-attestation-type.mdx` (VerifierServerGenerator).
**Use, later:** an XRPL issued-currency payment type would put RLUSD in evidence class A. It needs Flare governance. By Alan's decision (24.09), we do not approach Flare yet, and the idea is kept.

## 11. TEE identities are secp256k1
`fcc/2-tee-keys.mdx`. Each machine generates an ECDSA/ECIES key at boot, and the key never leaves the enclave.
**Use:** the XRP Ledger accepts secp256k1 signers. An FCC machine's own identity can therefore sit directly in an agent account's `SignerList` as Lancea's co-signer. No key import, no custody.

## 12. Smart Accounts give XRPL users an EVM body
`smart-accounts/*`, including "control USD₮0". An XRPL address drives a personal account on Flare through `Payment` memos.
**Use:** an XRPL-native agent's USD₮0 spending on Flare comes from an EVM address that §6.11 already judges. That account can be a SUMMA member next to the agent's XRP outflow.
