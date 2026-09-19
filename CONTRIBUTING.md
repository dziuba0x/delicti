# Contributing

Issues and pull requests are welcome. What helps most right now:

- **A way to break it.** A Foundry test that makes an invariant in `test/invariant/` fail, or a sequence the handler does not reach. Exploitable bugs go through [SECURITY.md](SECURITY.md), not a public issue.
- **An effector that speaks DELICTI.** An MCP server, an x402 facilitator or an agent framework that binds `mandate_ref` into its receipts and reads `SpendMeter` before it settles. [flario](https://github.com/dziuba0x/flario) is the reference.
- **Evidence the FDC can or cannot give.** SPEC §6.9 waits on one experiment: a `BalanceDecreasingTransaction` proof for a non-`Payment` XRPL transaction on Coston2.

House rules: every behaviour change comes with a test; every limit it leaves open goes into SPEC §10 in the same pull request; nothing is described in the README as live unless there is a transaction to link to.

```bash
npm ci && forge build && forge test
```
