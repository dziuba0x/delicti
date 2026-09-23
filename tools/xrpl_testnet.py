#!/usr/bin/env python3
"""DELICTI — the XRPL side of a live run, in the smallest form that is honest.

`cast` speaks to Flare; nothing in it speaks XRPL, and the parts of an XRPL payment DELICTI
depends on are exactly the parts that are easy to get subtly wrong:

  * the payment reference the FDC will report is the MemoData of the FIRST memo, and only when
    the transaction carries EXACTLY ONE memo of EXACTLY 32 bytes. Two memos, or 31 bytes, and
    `Payment.standardPaymentReference` comes back zero — verified against the testnet verifier,
    not read off a document;
  * the address the FDC reports is `keccak256(utf8(r-address))` (its "standard address hash"),
    which is what a leaf's `destinationAddressHash` and a mandate's `agentRef` must contain;
  * a payment is only attestable once the ledger holding it is indexed by the verifier, which
    lags the tip by a second or two.

Commands
    fund                               a funded testnet account:  {"address": ..., "seed": ...}
    pay <seed> <dest> <drops> <memo>   one payment with one 32-byte memo; prints its tx id
    tx <txid>                          the ledger's own view of a transaction (for diagnosis)
    trust <seed> <issuer> <cur> <limit>  a trust line to <issuer>'s <cur> (so an offer can pay it in)
    offer <seed> <drops> <value> <cur> <issuer>
                                       rest an offer SELLING <drops> of XRP for <value> <cur>.<issuer>;
                                       prints its tx id (the offer's own tx: only the fee leaves here)
    batch <seed> <dest> <drops>[,<drops>…]
                                       one XLS-56 Batch (tfAllOrNothing) of Payments; prints the outer id
                                       and every inner id. Inner transactions are ledger transactions of
                                       their own (fee 0, meta.ParentBatchID), and the XRP leaves the
                                       account in THEM, not in the outer Batch (which pays only the fee).
                                       Verified on devnet 2026-09-23; testnet/mainnet: BatchV1_1 pending.
                                       ENDPOINT=https://devnet.xrpl-labs.com/ to run it where it is live.
    take <seed> <value> <cur> <drops>  the issuer sells <value> of its OWN <cur> for <drops> of XRP —
                                       crossing a resting offer; prints its tx id. This is the
                                       transaction in which the OFFER OWNER's XRP leaves (SPEC §6.10)

Everything here is testnet by construction: the faucet is the testnet faucet and the endpoint is
the testnet endpoint. There is no mainnet path in this file on purpose.
"""

import json
import sys

from xrpl.clients import JsonRpcClient
from xrpl.models.amounts import IssuedCurrencyAmount
from xrpl.models.transactions import Memo, OfferCreate, Payment, TrustSet
from xrpl.transaction import submit_and_wait
from xrpl.wallet import Wallet, generate_faucet_wallet

# 443 only: s.altnet.rippletest.net:51234 is not reachable from every sandbox (claude/11).
import os
ENDPOINT = os.environ.get("ENDPOINT", "https://testnet.xrpl-labs.com/")


def client() -> JsonRpcClient:
    return JsonRpcClient(ENDPOINT)


def cmd_fund() -> None:
    w = generate_faucet_wallet(client())
    print(json.dumps({"address": w.classic_address, "seed": w.seed}))


def cmd_pay(seed: str, dest: str, drops: str, memo: str) -> None:
    memo = memo[2:] if memo.startswith("0x") else memo
    if len(memo) != 64:
        raise SystemExit(f"memo must be 32 bytes (64 hex chars), got {len(memo) // 2}")
    w = Wallet.from_seed(seed)
    r = submit_and_wait(
        Payment(
            account=w.classic_address,
            destination=dest,
            amount=str(int(drops)),
            memos=[Memo(memo_data=memo.upper())],
        ),
        client(),
        w,
    )
    res = r.result
    if res["meta"]["TransactionResult"] != "tesSUCCESS":
        raise SystemExit(f"payment failed: {res['meta']['TransactionResult']}")
    print(json.dumps({"txid": res["hash"], "ledger": res.get("ledger_index")}))


def _submit(tx, w) -> dict:
    res = submit_and_wait(tx, client(), w).result
    if res["meta"]["TransactionResult"] != "tesSUCCESS":
        raise SystemExit(f"{type(tx).__name__} failed: {res['meta']['TransactionResult']}")
    return res


def cmd_trust(seed: str, issuer: str, cur: str, limit: str) -> None:
    w = Wallet.from_seed(seed)
    res = _submit(TrustSet(account=w.classic_address,
                           limit_amount=IssuedCurrencyAmount(currency=cur, issuer=issuer, value=limit)), w)
    print(json.dumps({"txid": res["hash"]}))


def cmd_offer(seed: str, drops: str, value: str, cur: str, issuer: str) -> None:
    w = Wallet.from_seed(seed)
    res = _submit(OfferCreate(account=w.classic_address, taker_gets=str(int(drops)),
                              taker_pays=IssuedCurrencyAmount(currency=cur, issuer=issuer, value=value)), w)
    print(json.dumps({"txid": res["hash"]}))


def cmd_take(seed: str, value: str, cur: str, drops: str) -> None:
    w = Wallet.from_seed(seed)
    res = _submit(OfferCreate(account=w.classic_address,
                              taker_gets=IssuedCurrencyAmount(currency=cur, issuer=w.classic_address, value=value),
                              taker_pays=str(int(drops))), w)
    print(json.dumps({"txid": res["hash"]}))


def cmd_batch(seed: str, dest: str, amounts: str) -> None:
    from xrpl.account import get_next_valid_seq_number
    from xrpl.models.transactions import Batch, BatchFlag
    w = Wallet.from_seed(seed)
    seq = get_next_valid_seq_number(w.classic_address, client())
    inner = [
        Payment(account=w.classic_address, destination=dest, amount=str(int(a)), sequence=seq + 1 + i,
                fee="0", signing_pub_key="", flags=0x40000000)  # tfInnerBatchTxn
        for i, a in enumerate(amounts.split(","))
    ]
    res = _submit(Batch(account=w.classic_address, raw_transactions=inner, flags=BatchFlag.TF_ALL_OR_NOTHING, sequence=seq), w)
    from xrpl.models.requests import AccountTx
    txs = client().request(AccountTx(account=w.classic_address, limit=len(inner) + 2)).result["transactions"]
    kids = [t["hash"] for t in txs if t["meta"].get("ParentBatchID") == res["hash"]]
    print(json.dumps({"txid": res["hash"], "inner": kids}))


def cmd_tx(txid: str) -> None:
    from xrpl.models.requests import Tx

    print(json.dumps(client().request(Tx(transaction=txid)).result, indent=1))


def main() -> None:
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    cmd, args = sys.argv[1], sys.argv[2:]
    {"fund": cmd_fund, "pay": cmd_pay, "tx": cmd_tx, "trust": cmd_trust, "offer": cmd_offer, "take": cmd_take, "batch": cmd_batch}[cmd](*args)


if __name__ == "__main__":
    main()
