# Security policy

DELICTI is a consequence layer: a bug in it moves somebody's bond. Reports are welcome and taken seriously.

## Scope

Everything in `src/`, and the assumptions the contracts make about Flare's FDC, `Relay`, `FdcRequestFeeConfigurations` and `ProtocolsV2` (SPEC §2, §6.7). Known limits listed in [SPEC §10](SPEC.md#10-what-delicti-does-not-claim) are not vulnerabilities — but a way to make one of them worse than §10 says is.

## Status

Testnet only (Flare Coston2). **Not audited.** Slither (medium and above) and a 300,000-call invariant campaign have been run; their findings and the false positives are recorded in [CHANGELOG.md](CHANGELOG.md).

## Reporting

Please do **not** open a public issue for an exploitable bug. Use GitHub's private reporting instead: **Security → Report a vulnerability** on this repository. Include a Foundry test or a Coston2 fork reproduction if you can — every hole fixed in this repo so far has shipped with a regression test, and yours will too, with credit in the CHANGELOG unless you prefer otherwise.

## Rules of engagement

Whitehat only: find, confirm on a fork, report. Never against mainnet funds that are not yours.
