# delicti

```sh
npx delicti sentinel                    # observe every DELICTI mandate on Coston2 and print the public score
npx delicti status 12                   # where one mandate stands: live, bond, dockets, verdicts
npx delicti erc20 12 --once             # keep a stablecoin mandate's §6.11 docket, convict on the crossing
npx delicti xrpl 13 --once              # the same for gross XRP outflow on the XRP Ledger (§6.10)
```

This is the command line of [DELICTI](https://github.com/dziuba0x/delicti), an accountability protocol for AI agents with wallets. It is a thin launcher for [`@delicti/sdk`](https://www.npmjs.com/package/@delicti/sdk), which is the package to import in code.

The principal commits a mandate before the agent acts. The Flare Data Connector witnesses what the agent really did, on Flare, Ethereum or the XRP Ledger. When the sum of the deeds breaks the mandate, the bond pays, with no court and no admin key.

Testnet (Coston2, XRPL testnet), unaudited, MIT.
