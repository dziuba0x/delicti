# FTSO price history, verified on-chain (2026-09-24)

Question from amendment v1.1 (SUMMA), S.1: can a Flare contract prove what an asset was worth in USD at the moment of a past deed?

**Answer: yes, back at least a year, on Coston2 and on Flare mainnet, with no key and no fee.**

Method (`sdk/scripts/ftso-history.mjs`):

1. For each age, ask the DA layer for `anchor-feeds-with-proof` at the round that many days before the latest finalized FTSO round (90 s per round).
2. Call `FtsoV2.verifyFeedData(proof, body)` with `eth_call`. The addresses come from `FlareContractRegistry`.
3. Read `Relay.merkleRoots(100, round)`. The FTSO's protocol id is 100.
4. Tamper test: submit the same proof with `value + 1`.

The raw run:

```

== coston2: FtsoV2 0xC4e9c78EA53db782E28f28Fdf80BaF59336B304d  Relay 0x5017728F117501A24EF9C3756C07f0d564598596  latest FTSO round 1465067
  0.05d round 1465019: FLR/USD=0.0072 true | USDT/USD=0.99967 true | XRP/USD=1.5262 true  relayRoot(100)=0x19a35692b5
  1d round 1464107: FLR/USD=0.007065 true | USDT/USD=0.99983 true | XRP/USD=1.50224 true  relayRoot(100)=0x431057ecd0
  14d round 1451627: FLR/USD=0.006348 true | USDT/USD=0.9996 true | XRP/USD=1.35246 true  relayRoot(100)=0x8535a5635e
  30d round 1436267: FLR/USD=0.006594 true | USDT/USD=0.99985 true | XRP/USD=1.4386 true  relayRoot(100)=0xee0274ae2d
  104d round 1365227: FLR/USD=0.008141 true | USDT/USD=0.99952 true | XRP/USD=1.1334 true  relayRoot(100)=0x665d632bc3
  200d round 1273067: FLR/USD=0.00901 true | USDT/USD=0.99992 true | XRP/USD=1.34809 true  relayRoot(100)=0x49c2b13d5f
  365d round 1114667: FLR/USD=0.026915 true | USDT/USD=1.0002 true | XRP/USD=2.95619 true  relayRoot(100)=0x78442085d8
  tamper (value+1): revert

== flare: FtsoV2 0x7BDE3Df0624114eDB3A67dFe6753e62f4e7c1d20  Relay 0xCcF30790A93F15e24EB909548a2C58a9b0a7FBd4  latest FTSO round 1465067
  0.05d round 1465019: FLR/USD=0.007193 true | USDT/USD=0.99967 true | XRP/USD=1.52626 true  relayRoot(100)=0x619e3ffe52
  1d round 1464107: FLR/USD=0.007061 true | USDT/USD=0.99984 true | XRP/USD=1.50215 true  relayRoot(100)=0xbd69c2c538
  14d round 1451627: FLR/USD=0.006349 true | USDT/USD=0.99962 true | XRP/USD=1.35242 true  relayRoot(100)=0x6abcff3a2f
  30d round 1436267: FLR/USD=0.006593 true | USDT/USD=0.99985 true | XRP/USD=1.43858 true  relayRoot(100)=0x35e37c6af6
  104d round 1365227: FLR/USD=0.008146 true | USDT/USD=0.99952 true | XRP/USD=1.13337 true  relayRoot(100)=0x0327977d3b
  200d round 1273067: FLR/USD=0.009021 true | USDT/USD=0.99995 true | XRP/USD=1.34784 true  relayRoot(100)=0xb98957686a
  365d round 1114667: FLR/USD=0.026919 true | USDT/USD=1.00045 true | XRP/USD=2.95671 true  relayRoot(100)=0xba64a06456
  tamper (value+1): revert
```

What this settles:

- **The price leg has no practical horizon.** The developer hub says the DA layer keeps "2 weeks of historical data". It served 365-day-old proofs, and `Relay` still held every root. Nobody promises that, though, so SUMMA files each price with its deed (the docket) and caches it on-chain on first proof.
- **A forged value does not return `false`. It reverts.** A judge must not wrap `verifyFeedData` in a `try` that treats a revert as "not verified yet".
- **Block-latency reads are free.** `FeeCalculator.calculateFeeByIds([FLR, XRP, USDT])` is 0 wei on both networks, and `getFeedById(FLR/USD)` returned `0.00721` (8 decimals). This makes `SummaMeter` a free read in the payment path.
- **FLR/USD moved from 0.0269 to 0.0072 in a year (−73 %).** This is why the SUMMA bond is posted in FLR but *read* in dollars with a haircut (amendment S.7).
- **Available feeds** (anchor, same on both networks): FLR, XRP, ETH, BTC, SGB, USDT, USDC and USDS against USD. FTSO risk tiers: USDT and USDC are 0; FLR, XRP, ETH and BTC are 1; SGB is 2. There is no RLUSD feed. There are custom feeds `sFLR/USD` (Sceptre) and `stXRP/USD` (Firelight), but those have current values only, not historical proofs.
