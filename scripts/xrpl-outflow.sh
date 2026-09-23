#!/usr/bin/env bash
# DELICTI — live §6.10 on Coston2 + XRPL testnet: an agent convicted for XRP that left its account,
# including a deed it never signed.
#
#   The mandate's budget is GROSS XRP OUTFLOW (assetKey = "XRP/outflow"), fees included, and the
#   agent's XRPL account itself declares that everything leaving it inside the window is this
#   mandate's business (AgentRefs.proveExclusive — a payment whose 32-byte memo is
#   `exclusiveFor(mandateId)`). No receipts are written at all. Then, under a 12 XRP budget:
#
#     3 XRP payment · 3 XRP payment  → filed on the docket at once, below the budget (v0.12)
#     an offer selling 5 XRP, left resting and CONSUMED BY ANOTHER ACCOUNT'S OfferCreate · 3 XRP
#                                     → the crossing filing, committed: 14 XRP + fees in total
#
#   Bonded 1 C2FLR by the principal and 1 by an outside insurer; under the surety rule (v0.12) the
#   insurer's share of the verdict's remainder comes back to the insurer, not to the principal.
#
#   FDC `BalanceDecreasingTransaction` proofs — one of them for the taker's transaction, in
#   which the agent's balance fell by 5 XRP without the agent signing anything — and the sum
#   convicts. On XRPL nothing but the account's own keys can make its XRP balance fall; the offer
#   was the agent's own standing order, executed later by someone else.
#
# Requires: foundry (cast), curl, python3 with xrpl-py, and a .env with PRIVATE_KEY, COSTON2_RPC,
#           VERIFIER_URL, VERIFIER_API_KEY, DA_URL; REG / BOND (= the Vault) / JUDGE_XRPL / REFS from
#           a v0.11 deployment. RESUME=1 picks a stalled run up at the attestations.
set -euo pipefail
cd "$(dirname "$0")/.."; set -a; . ./.env; set +a
. scripts/lib/commit.sh
RPC=$COSTON2_RPC
REG=${REG:?set REG to the MandateRegistry}
BOND=${BOND:?set BOND to the v0.11 Vault (the address mandates name in Terms.bond)}
JUDGE_XRPL=${JUDGE_XRPL:?set JUDGE_XRPL to the v0.11 JudgeXrpl}
REFS=${REFS:?set REFS to the v0.11 AgentRefs}
PAY=${PAY:-3000000}; OFFER=${OFFER:-5000000}; BUDGET=${BUDGET:-12000000}   # drops
ME=$(cast wallet address --private-key "$PRIVATE_KEY")
FLARE_REG=0xaD67FE66660Fb8dFE9d6b1b4240d8650e30F6019
pad() { python3 -c "import sys;print('0x'+sys.argv[1].encode().hex().ljust(64,'0'))" "$1"; }
SRC=$(pad testXRP); OUTFLOW=$(pad XRP/outflow)
Z32=0x$(printf '%064d' 0)
X="python3 tools/xrpl_testnet.py"
txid_of() { python3 -c "import sys,json;print(json.load(sys.stdin)['txid'])"; }
lc() { echo "0x$(echo "${1#0x}" | tr 'A-Z' 'a-z')"; }   # XRPL prints ids uppercase and unprefixed — prefix ONCE

HUB=$(cast call $FLARE_REG "getContractAddressByName(string)(address)" FdcHub --rpc-url $RPC)
FEECFG=$(cast call $FLARE_REG "getContractAddressByName(string)(address)" FdcRequestFeeConfigurations --rpc-url $RPC)
FSM=$(cast call $FLARE_REG "getContractAddressByName(string)(address)" FlareSystemsManager --rpc-url $RPC)
T0=$(cast call $FSM "firstVotingRoundStartTs()(uint64)" --rpc-url $RPC | awk '{print $1}')
DUR=$(cast call $FSM "votingEpochDurationSeconds()(uint64)" --rpc-url $RPC | awk '{print $1}')

# request_proof <type> <requestBody-json> -> echoes "<abiEncodedRequest> <round>"
request_proof() {
  local typ=$1 rb=$2 body req fee out blk sts
  body="{\"attestationType\":\"$(pad "$typ")\",\"sourceId\":\"$SRC\",\"requestBody\":$rb}"
  for _ in $(seq 1 "${INDEX_TRIES:-45}"); do   # the verifier's index trails the ledger by seconds
    req=$(curl -s -m 60 -X POST "$VERIFIER_URL/verifier/xrp/$typ/prepareRequest" \
      -H "X-API-KEY: $VERIFIER_API_KEY" -H "Content-Type: application/json" -d "$body" \
      | python3 -c "import sys,json;d=json.load(sys.stdin);print(d['abiEncodedRequest'] if d.get('status')=='VALID' else '')")
    [ -n "$req" ] && break
    sleep 10
  done
  [ -n "$req" ] || { echo "   !! verifier never answered VALID for $rb" >&2; return 1; }
  fee=$(cast call "$FEECFG" "getRequestFee(bytes)(uint256)" "$req" --rpc-url $RPC | awk '{print $1}')
  out=$(cast send "$HUB" "requestAttestation(bytes)" "$req" --value "$fee" --private-key $PRIVATE_KEY --rpc-url $RPC --json)
  blk=$(echo "$out" | python3 -c "import sys,json;print(int(json.load(sys.stdin)['blockNumber'],16))")
  sts=$(cast block "$blk" --rpc-url $RPC -f timestamp)
  echo "$req $(( (sts - T0) / DUR ))"
}

fetch_proof() {  # <request> <round> -> "<response_hex> [merkle,proof]"
  local req=$1 round=$2 r
  for _ in $(seq 1 "${POLL_TRIES:-40}"); do
    r=$(curl -s -m 30 -X POST "$DA_URL/api/v1/fdc/proof-by-request-round-raw" \
      -H "X-API-KEY: $VERIFIER_API_KEY" -H "Content-Type: application/json" \
      -d "{\"votingRoundId\":$round,\"requestBytes\":\"$req\"}")
    if echo "$r" | grep -q response_hex; then
      python3 -c "import json,sys;d=json.loads(sys.argv[1]);print(d['response_hex'],'['+','.join(d['proof'])+']')" "$r"
      return 0
    fi
    sleep 20
  done
  echo "   !! no proof for round $round" >&2; return 1
}

PAYMENT_T="(bytes32,bytes32,uint64,uint64,(bytes32,uint256,uint256),(uint64,uint64,bytes32,bytes32,bytes32,bytes32,int256,int256,int256,int256,bytes32,bool,uint8))"
BDT_T="(bytes32,bytes32,uint64,uint64,(bytes32,bytes32),(uint64,uint64,bytes32,int256,bytes32))"
decode() { cast abi-decode "f()($1)" "$2" | sed -E 's/ \[[0-9.e+]+\]//g' | tr -d '\n'; }

# bdt_proofs "<id> <id> …" -> sets PROOFS to the cast-ready array of BDT proofs, in that order
bdt_proofs() {
  local reqs=() rounds=() t Q R H M D
  for t in $1; do
    read -r Q R <<<"$(request_proof BalanceDecreasingTransaction "{\"transactionId\":\"$t\",\"sourceAddressIndicator\":\"$AGENT_REF\"}")"
    reqs+=("$Q"); rounds+=("$R"); echo "   requested $t in round $R$([ "$t" = "${TAKEN:-}" ] && echo '   (the counterparty’s transaction)')"
  done
  PROOFS="["
  for k in "${!reqs[@]}"; do
    read -r H M <<<"$(fetch_proof "${reqs[$k]}" "${rounds[$k]}")"
    D=$(decode "$BDT_T" "$H"); echo "   proof $k: $(echo "$D" | python3 -c "import sys;s=sys.stdin.read();print('spentAmount', s.split(',')[-2].strip())")"
    PROOFS="$PROOFS($M,$D),"
  done
  PROOFS="${PROOFS%,}]"
}
sorted_ids() { python3 -c "import sys;print(' '.join(sorted(('0x'+t.lower().removeprefix('0x') for t in sys.argv[1:]), key=lambda h:int(h,16))))" "$@"; }
FILE_SIG="fileXrpOutflow(uint256,(bytes32[],$BDT_T)[],bytes32)"

STATE=${STATE:-.run/xrpl-outflow-last.env}
mkdir -p "$(dirname "$STATE")"
if [ "${RESUME:-0}" = "1" ]; then
  echo "== resuming from $STATE"; . "$STATE"
  echo "   mandate $MID, deeds: $SORTED_IDS"
  TTL=$(cast call "$BOND" "COMMIT_TTL()(uint64)" --rpc-url "$RPC" | awk '{print $1}')
  if [ $(( $(date +%s) - DELICTI_COMMIT_TS )) -gt $(( TTL - 300 )) ]; then
    echo "   commitment aged out — committing again over the same deeds"
    delicti_commit "$BOND" 7 "$MID" "$SORTED_IDS"
    sed -i "s|^DELICTI_SALT=.*|DELICTI_SALT=$DELICTI_SALT|;s|^DELICTI_COMMIT_TS=.*|DELICTI_COMMIT_TS=$DELICTI_COMMIT_TS|" "$STATE"
    delicti_wait_lead "$BOND" "$T0" "$DUR"
  fi
else
echo "== 1. XRPL testnet: the agent's account, and a counterparty that pays, issues and trades"
AGENT_JSON=${AGENT_JSON:-$($X fund)}; CP_JSON=${CP_JSON:-$($X fund)}
AGENT_ADDR=$(echo "$AGENT_JSON" | python3 -c "import sys,json;print(json.load(sys.stdin)['address'])")
AGENT_SEED=$(echo "$AGENT_JSON" | python3 -c "import sys,json;print(json.load(sys.stdin)['seed'])")
CP_ADDR=$(echo "$CP_JSON" | python3 -c "import sys,json;print(json.load(sys.stdin)['address'])")
CP_SEED=$(echo "$CP_JSON" | python3 -c "import sys,json;print(json.load(sys.stdin)['seed'])")
AGENT_REF=$(cast keccak "$AGENT_ADDR")
echo "   agent        $AGENT_ADDR → agentRef $AGENT_REF"
echo "   counterparty $CP_ADDR"

echo "== 2. mandate: at most 12 XRP may LEAVE the agent's account, fees included"
NOW=$(date +%s); MH=$(cast keccak "DELICTI mandate: gross XRP outflow of $AGENT_ADDR at most 12 XRP")
cast send $REG "commit(address,bytes32,bytes32,uint256,uint256,uint64,uint64,(bytes32,bytes32,bytes32,address))" \
  $ME $MH $Z32 0 $BUDGET $((NOW-120)) $((NOW+604800)) "($SRC,$OUTFLOW,$AGENT_REF,$BOND)" \
  --private-key $PRIVATE_KEY --rpc-url $RPC --json >/dev/null
MID=$(( $(cast call $REG "nextId()(uint256)" --rpc-url $RPC | awk '{print $1}') - 1 ))
cast send $REG "acknowledge(uint256)" $MID --private-key $PRIVATE_KEY --rpc-url $RPC --json >/dev/null
echo "   mandateId=$MID  fullyEnforceable=$(cast call $JUDGE_XRPL 'fullyEnforceable(uint256)(bool)' $MID --rpc-url $RPC)"

echo "== 3. the XRPL key declares exclusivity (AgentRefs.proveExclusive)"
EXCL=$(cast call $REFS "exclusiveFor(uint256)(bytes32)" $MID --rpc-url $RPC)
STMT=$($X pay "$AGENT_SEED" "$CP_ADDR" 1000 "$EXCL" | txid_of)
echo "   statement payment $STMT  memo=$EXCL"
read -r SQ SR <<<"$(request_proof Payment "{\"transactionId\":\"$(lc $STMT)\",\"inUtxo\":\"0\",\"utxo\":\"0\"}")"
read -r SH SM <<<"$(fetch_proof "$SQ" "$SR")"
cast send $REFS "proveExclusive(uint256,(bytes32[],$PAYMENT_T))" $MID "($SM,$(decode "$PAYMENT_T" "$SH"))" \
  --private-key $PRIVATE_KEY --rpc-url $RPC --json >/dev/null
cast call $REFS "exclusive(uint256)(bool)" $MID --rpc-url $RPC | grep -q true || { echo "   !! exclusivity not recorded"; exit 1; }
echo "   exclusive=true, proven=$(cast call $REFS 'proven(uint256)(bool)' $MID --rpc-url $RPC)"

echo "== 4. bond: 1 C2FLR from the principal, 1 C2FLR from an outside insurer (v0.12 surety rule)"
cast send $BOND "post(uint256)" $MID --value 1ether --private-key $PRIVATE_KEY --rpc-url $RPC --json >/dev/null
INS_KEY=$(cast wallet new --json | python3 -c "import sys,json;print(json.load(sys.stdin)[0]['private_key'])")
INSURER=$(cast wallet address --private-key $INS_KEY)
cast send $INSURER --value 1.5ether --private-key $PRIVATE_KEY --rpc-url $RPC --json >/dev/null
cast send $BOND "post(uint256)" $MID --value 1ether --private-key $INS_KEY --rpc-url $RPC --json >/dev/null
[ "$(cast call $BOND 'depositOf(uint256,address)(uint256)' $MID $INSURER --rpc-url $RPC | awk '{print $1}')" != "0" ] || { echo "   !! the insurer's deposit did not land"; exit 1; }
echo "   insurer $INSURER — plain post, so its deposit compensates itself: beneficiaryOf = $(cast call $BOND 'beneficiaryOf(uint256,address)(address)' $MID $INSURER --rpc-url $RPC)"

echo "== 5. the deeds — no receipts, nothing anchored"
P1=$($X pay "$AGENT_SEED" "$CP_ADDR" $PAY "$(cast keccak "outflow $MID/1/$RANDOM")" | txid_of); echo "   payment 3 XRP  $P1"
P2=$($X pay "$AGENT_SEED" "$CP_ADDR" $PAY "$(cast keccak "outflow $MID/2/$RANDOM")" | txid_of); echo "   payment 3 XRP  $P2"
echo "== 5b. the docket: the first 6 XRP filed now, below the budget — no commitment, no verdict (v0.12)"
EARLY=$(sorted_ids $P1 $P2)
bdt_proofs "$EARLY"
cast send $JUDGE_XRPL "$FILE_SIG" $MID "$PROOFS" $Z32 --private-key $PRIVATE_KEY --rpc-url $RPC --json \
  | python3 -c "import sys,json;d=json.load(sys.stdin);print('   docket filing',d['transactionHash'],'status',int(d['status'],16))"
echo "   docket = $(cast call $JUDGE_XRPL 'docket(uint256)(uint256)' $MID --rpc-url $RPC) drops, slashed = $(cast call $BOND 'slashed(uint256)(bool)' $MID --rpc-url $RPC)"
$X trust "$AGENT_SEED" "$CP_ADDR" USD 1000 >/dev/null
OF=$($X offer "$AGENT_SEED" $OFFER 5 USD "$CP_ADDR" | txid_of);                       echo "   offer 5 XRP → 5 USD.cp, resting   $OF"
TK=$($X take "$CP_SEED" 5 USD $OFFER | txid_of);                                       echo "   TAKEN by the counterparty's tx    $TK   ← the agent signed nothing here"
P3=$($X pay "$AGENT_SEED" "$CP_ADDR" $PAY "$(cast keccak "outflow $MID/3/$RANDOM")" | txid_of); echo "   payment 3 XRP  $P3"

echo "== 6. commit (kind 7) over the NEW deeds only — the docket carries the first two"
TAKEN=$(lc $TK)
SORTED_IDS=$(sorted_ids $TK $P3)
delicti_commit $BOND 7 $MID "$SORTED_IDS" "${SALT:-}"
{ echo "MID=$MID"; echo "AGENT_REF=$AGENT_REF"; echo "INSURER=$INSURER"; echo "SORTED_IDS='$SORTED_IDS'"; echo "TAKEN=$(lc $TK)"
  echo "DELICTI_SALT=$DELICTI_SALT"; echo "DELICTI_COMMIT_TS=$DELICTI_COMMIT_TS"; } > "$STATE"
delicti_wait_lead $BOND $T0 $DUR
fi

echo "== 7. two FDC BalanceDecreasingTransaction attestations for the new deeds"
bdt_proofs "$SORTED_IDS"

echo "== 8. the crossing filing: docket + new deeds past the budget"
OUT=$(cast send $JUDGE_XRPL "$FILE_SIG" $MID "$PROOFS" "$DELICTI_SALT" \
  --private-key $PRIVATE_KEY --rpc-url $RPC --json)
echo "$OUT" | python3 -c "import sys,json;d=json.load(sys.stdin);print('   reveal',d['transactionHash'],'status',int(d['status'],16),'gas',int(d['gasUsed'],16))"

echo "== 9. the verdict, read back from the chain"
echo -n "   bondOf   "; cast call $BOND "bondOf(uint256)(uint256)" $MID --rpc-url $RPC
echo -n "   slashed  "; cast call $BOND "slashed(uint256)(bool)" $MID --rpc-url $RPC
echo -n "   live     "; cast call $REG  "isLive(uint256)(bool)" $MID --rpc-url $RPC
echo -n "   severity "; cast call $BOND "severityOf(uint256)(uint256)" $MID --rpc-url $RPC
echo -n "   docket   "; cast call $JUDGE_XRPL "docket(uint256)(uint256)" $MID --rpc-url $RPC
cast send $BOND "settle(uint256,address)" $MID $INSURER --private-key $PRIVATE_KEY --rpc-url $RPC --json >/dev/null
echo -n "   owed(principal) "; cast call $BOND "owed(address)(uint256)" $ME --rpc-url $RPC
echo -n "   owed(insurer)   "; cast call $BOND "owed(address)(uint256)" $INSURER --rpc-url $RPC
