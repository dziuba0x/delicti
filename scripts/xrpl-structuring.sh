#!/usr/bin/env bash
# DELICTI — live STRUCTURING on XRPL (SPEC §6.8), end to end on Coston2 + XRPL testnet.
#
#   The agent's identity on XRPL is an r-address, written into the mandate as `agentRef`
#   (keccak256 of the address string). The XRPL account itself confirms the mandate by making
#   one payment whose memo is `AgentRefs.challengeFor(mandateId)` — `Bond.post` refuses
#   collateral until it has (§6.8). Then five payments of 1 XRP go out under a 4 XRP budget,
#   each with its own 32-byte memo as payment reference, each anchored as a kind-3 receipt.
#   Five FDC `Payment` proofs later, the sum convicts.
#
#   Every check the challenge makes is about agreement between the two witnesses:
#   sourceAddressHash == agentRef, receivingAddressHash == leaf.destinationAddressHash,
#   receivedAmount == leaf.amount, standardPaymentReference == leaf.ref, status 0, oneToOne,
#   blockTimestamp inside the mandate window. Fees are NOT summed: on XRPL `spentAmount` is
#   Amount + Fee, and a budget an agent can overrun by twelve drops of fee is a trap.
#
# Requires: foundry (cast), curl, python3 with xrpl-py, and a .env with PRIVATE_KEY, COSTON2_RPC,
#           VERIFIER_URL, VERIFIER_API_KEY, DA_URL; REG / LOG / BOND / REFS from a v0.10 deployment.
set -euo pipefail
cd "$(dirname "$0")/.."; set -a; . ./.env; set +a
. scripts/lib/commit.sh
RPC=$COSTON2_RPC
REG=${REG:?set REG to the MandateRegistry}
LOG=${LOG:?set LOG to the AnchorLog}
BOND=${BOND:?set BOND to the Bond}
REFS=${REFS:?set REFS to the AgentRefs}
N=${N:-5}; EACH=${EACH:-1000000}; BUDGET=${BUDGET:-4000000}   # drops
ME=$(cast wallet address --private-key "$PRIVATE_KEY")
FLARE_REG=0xaD67FE66660Fb8dFE9d6b1b4240d8650e30F6019
pad() { python3 -c "import sys;print('0x'+sys.argv[1].encode().hex().ljust(64,'0'))" "$1"; }
SRC=$(pad testXRP); ATYPE=$(pad Payment)
Z32=0x$(printf '%064d' 0)

HUB=$(cast call $FLARE_REG "getContractAddressByName(string)(address)" FdcHub --rpc-url $RPC)
FEECFG=$(cast call $FLARE_REG "getContractAddressByName(string)(address)" FdcRequestFeeConfigurations --rpc-url $RPC)
FSM=$(cast call $FLARE_REG "getContractAddressByName(string)(address)" FlareSystemsManager --rpc-url $RPC)
T0=$(cast call $FSM "firstVotingRoundStartTs()(uint64)" --rpc-url $RPC | awk '{print $1}')
DUR=$(cast call $FSM "votingEpochDurationSeconds()(uint64)" --rpc-url $RPC | awk '{print $1}')

request_payment_proof() {  # <txid> -> echoes "<abiEncodedRequest> <round>"
  local txid=$1 body req fee out blk sts round tries
  body=$(python3 -c "
import json,sys
print(json.dumps({'attestationType':sys.argv[1],'sourceId':sys.argv[2],
                  'requestBody':{'transactionId':sys.argv[3],'inUtxo':'0','utxo':'0'}}))" \
    "$ATYPE" "$SRC" "0x$(echo "${txid#0x}" | tr 'A-Z' 'a-z')")   # XRPL prints ids uppercase and unprefixed; the verifier wants 0x + lowercase
  # The verifier answers from its own indexer, which trails the ledger tip by a few seconds —
  # and a payment DELICTI cares about is seconds old by construction. "TRANSACTION DOES NOT
  # EXIST" in the first seconds means "not indexed yet", not "not on XRPL", so wait for it.
  # (If it persists for minutes, suspect the request before the verifier: the first live runs of
  # this script sent "0x0x…" ids and read that as indexer trouble — see CHANGELOG v0.10.)
  local tries=${INDEX_TRIES:-45}
  for _ in $(seq 1 "$tries"); do
    req=$(curl -s -m 60 -X POST "$VERIFIER_URL/verifier/xrp/Payment/prepareRequest" \
      -H "X-API-KEY: $VERIFIER_API_KEY" -H "Content-Type: application/json" -d "$body" \
      | python3 -c "import sys,json;d=json.load(sys.stdin);print(d['abiEncodedRequest'] if d.get('status')=='VALID' else '')")
    [ -n "$req" ] && break
    sleep 10
  done
  [ -n "$req" ] || { echo "   !! verifier never indexed $txid" >&2; return 1; }
  fee=$(cast call "$FEECFG" "getRequestFee(bytes)(uint256)" "$req" --rpc-url $RPC | awk '{print $1}')
  out=$(cast send "$HUB" "requestAttestation(bytes)" "$req" --value "$fee" --private-key $PRIVATE_KEY --rpc-url $RPC --json)
  blk=$(echo "$out" | python3 -c "import sys,json;print(int(json.load(sys.stdin)['blockNumber'],16))")
  sts=$(cast block "$blk" --rpc-url $RPC -f timestamp)
  round=$(( (sts - T0) / DUR ))
  echo "$req $round"
}

fetch_proof() {  # <request> <round> -> echoes the proof tuple for cast, or fails
  local req=$1 round=$2 tries=${POLL_TRIES:-40} r
  for _ in $(seq 1 "$tries"); do
    r=$(curl -s -m 30 -X POST "$DA_URL/api/v1/fdc/proof-by-request-round-raw" \
      -H "X-API-KEY: $VERIFIER_API_KEY" -H "Content-Type: application/json" \
      -d "{\"votingRoundId\":$round,\"requestBytes\":\"$req\"}")
    if echo "$r" | grep -q response_hex; then
      python3 - "$r" <<'PY'
import json,sys
d=json.loads(sys.argv[1]); print(d['response_hex'], '[' + ','.join(d['proof']) + ']')
PY
      return 0
    fi
    sleep 20
  done
  echo "   !! no proof for round $round after $((tries*20))s" >&2; return 1
}

decode_payment() {  # <response_hex> -> the Response tuple, cast-ready
  cast abi-decode "f()((bytes32,bytes32,uint64,uint64,(bytes32,uint256,uint256),(uint64,uint64,bytes32,bytes32,bytes32,bytes32,int256,int256,int256,int256,bytes32,bool,uint8)))" \
    "$1" | sed -E 's/ \[[0-9.e+]+\]//g' | tr -d '\n'
}

# A run makes real payments on XRPL and a commitment that expires in COMMIT_TTL. When the FDC
# side of a run stalls — whatever the cause — repeating the whole run means new payments, a new
# mandate and a new commitment. So every step that costs something is written down, and RESUME
# picks the run up at the attestations.
STATE=${STATE:-.run/xrpl-last.env}
mkdir -p "$(dirname "$STATE")"
if [ "${RESUME:-0}" = "1" ]; then
  echo "== resuming from $STATE"
  . "$STATE"
  IFS=' ' read -r -a TXIDS <<<"$TXIDS_STR"; IFS=' ' read -r -a REFSARR <<<"$REFS_STR"
  IFS='|' read -r -a LEAVES <<<"$LEAVES_STR"; IFS=' ' read -r -a EPISODES <<<"$EPISODES_STR"
  echo "   mandate $MID, ${#TXIDS[@]} deeds, commitment $DELICTI_COMMITMENT (t=$DELICTI_COMMIT_TS)"
  # A commitment is only good for COMMIT_TTL (1 h), and a stalled run can outlive it. The deeds,
  # the leaves and the mandate cost real payments and are still valid — the FDC attests XRPL
  # payments up to ~14 days old — while the commitment is one SSTORE. So a resumed run re-commits over
  # exactly the same deeds when the old commitment has aged out. The gate is unaffected: the new
  # commitment still has to predate, by commitLead, the round that produces the evidence.
  TTL=$(cast call "$BOND" "COMMIT_TTL()(uint64)" --rpc-url "$RPC" | awk '{print $1}')
  if [ "${RECOMMIT:-auto}" = "1" ] || { [ "${RECOMMIT:-auto}" = "auto" ] && [ $(( $(date +%s) - DELICTI_COMMIT_TS )) -gt $(( TTL - 300 )) ]; }; then
    echo "   commitment aged out (TTL ${TTL}s) — committing again over the same deeds"
    SORTED_IDS=""; for i in $ORDER; do SORTED_IDS="$SORTED_IDS ${TXIDS[$i]}"; done
    delicti_commit "$BOND" 6 "$MID" "$SORTED_IDS"
    sed -i "s|^DELICTI_SALT=.*|DELICTI_SALT=$DELICTI_SALT|;s|^DELICTI_COMMITMENT=.*|DELICTI_COMMITMENT=$DELICTI_COMMITMENT|;s|^DELICTI_COMMIT_TS=.*|DELICTI_COMMIT_TS=$DELICTI_COMMIT_TS|" "$STATE"
    delicti_wait_lead "$BOND" "$T0" "$DUR"
  fi
fi

if [ "${RESUME:-0}" != "1" ]; then
echo "== 1. two XRPL testnet accounts: the agent and the merchant it pays"
AGENT_JSON=${AGENT_JSON:-$(python3 tools/xrpl_testnet.py fund)}
MERCH_JSON=${MERCH_JSON:-$(python3 tools/xrpl_testnet.py fund)}
AGENT_ADDR=$(echo "$AGENT_JSON" | python3 -c "import sys,json;print(json.load(sys.stdin)['address'])")
AGENT_SEED=$(echo "$AGENT_JSON" | python3 -c "import sys,json;print(json.load(sys.stdin)['seed'])")
MERCH_ADDR=$(echo "$MERCH_JSON" | python3 -c "import sys,json;print(json.load(sys.stdin)['address'])")
AGENT_REF=$(cast keccak "$AGENT_ADDR"); DEST=$(cast keccak "$MERCH_ADDR")
echo "   agent   $AGENT_ADDR  → agentRef $AGENT_REF"
echo "   merchant $MERCH_ADDR → destinationAddressHash $DEST"

echo "== 2. mandate: 4 XRP on testXRP, this Bond, that XRPL account as the agent's identity"
NOW=$(date +%s); MH=$(cast keccak "DELICTI mandate: up to 4 XRP to $MERCH_ADDR")
cast send $REG "commit(address,bytes32,bytes32,uint256,uint256,uint64,uint64,(bytes32,bytes32,bytes32,address))" \
  $ME $MH $Z32 0 $BUDGET $((NOW-120)) $((NOW+604800)) "($SRC,$Z32,$AGENT_REF,$BOND)" \
  --private-key $PRIVATE_KEY --rpc-url $RPC --json >/dev/null
MID=$(( $(cast call $REG "nextId()(uint256)" --rpc-url $RPC | awk '{print $1}') - 1 ))
cast send $REG "acknowledge(uint256)" $MID --private-key $PRIVATE_KEY --rpc-url $RPC --json >/dev/null
echo "   mandateId=$MID (acknowledged by the EVM key)"

# --- proof of control: the XRPL account speaks for itself -----------------------------------
echo "== 3. the XRPL account confirms the mandate (AgentRefs, §6.8)"
CHAL=$(cast call $REFS "challengeFor(uint256)(bytes32)" $MID --rpc-url $RPC)
CTRL=$(python3 tools/xrpl_testnet.py pay "$AGENT_SEED" "$MERCH_ADDR" 1000 "$CHAL" | python3 -c "import sys,json;print(json.load(sys.stdin)['txid'])")
echo "   control payment $CTRL  memo=$CHAL"

CTRL_OUT=$(request_payment_proof "$CTRL") || exit 1
read -r CTRL_REQ CTRL_ROUND <<<"$CTRL_OUT"
echo "   attestation requested, round $CTRL_ROUND — waiting for the DA layer"
CTRL_P=$(fetch_proof "$CTRL_REQ" "$CTRL_ROUND") || exit 1
read -r CTRL_HEX CTRL_MP <<<"$CTRL_P"
cast send $REFS "prove(uint256,(bytes32[],(bytes32,bytes32,uint64,uint64,(bytes32,uint256,uint256),(uint64,uint64,bytes32,bytes32,bytes32,bytes32,int256,int256,int256,int256,bytes32,bool,uint8))))" \
  $MID "($CTRL_MP,$(decode_payment "$CTRL_HEX"))" --private-key $PRIVATE_KEY --rpc-url $RPC --json >/dev/null
cast call $REFS "proven(uint256)(bool)" $MID --rpc-url $RPC | grep -q true || { echo "   !! agentRef not proven"; exit 1; }
echo "   agentRef proven on-chain"

echo "== 4. bond 1 C2FLR (refused until both the agent and its XRPL account have spoken)"
cast send $BOND "post(uint256)" $MID --value 1ether --private-key $PRIVATE_KEY --rpc-url $RPC --json >/dev/null

echo "== 5. five payments of 1 XRP under a 4 XRP budget, each with its own reference"
TXIDS=(); REFSARR=(); TS=()
for i in $(seq 1 $N); do
  REF=$(cast keccak "DELICTI x402 invoice $MID/$i/$RANDOM")
  TX=$(python3 tools/xrpl_testnet.py pay "$AGENT_SEED" "$MERCH_ADDR" "$EACH" "$REF" | python3 -c "import sys,json;print(json.load(sys.stdin)['txid'])")
  TXIDS+=("0x$(echo "$TX" | tr 'A-Z' 'a-z')"); REFSARR+=("$REF"); TS+=("$(date +%s)")
  echo "   deed $i: $TX  ref=$REF"
done

echo "== 6. one anchored kind-3 receipt per deed (witness 1)"
LEAVES=(); EPISODES=()
for i in $(seq 0 $((N-1))); do
  RH=$(cast keccak "flario-receipt/2: paid 1 XRP to $MERCH_ADDR ref ${REFSARR[$i]}")
  LEAF="($RH,3,$SRC,$DEST,$EACH,${REFSARR[$i]},${TS[$i]},$MID)"
  LH=$(cast keccak "$(cast abi-encode 'f((bytes32,uint8,bytes32,bytes32,uint256,bytes32,uint64,uint256))' "$LEAF")")
  cast send $LOG "anchor(uint256,bytes32,uint64)" $MID "$LH" 1 --private-key $PRIVATE_KEY --rpc-url $RPC --json >/dev/null
  LEAVES+=("$LEAF"); EPISODES+=("$i")
  echo "   leaf $i: $LH (episode $i, anchored alone: the root IS the leaf)"
done

echo "== 7. commit the challenge — before a single attestation is requested (§6.7)"
# The deed ids are the payments' transaction ids, in the order the challenge supplies them, which
# the contract requires to be strictly increasing. Sort now, and carry the order everywhere.
ORDER=$(python3 - "${TXIDS[*]}" <<'PY'
import sys
ids=sys.argv[1].split()
print(' '.join(str(i) for i in sorted(range(len(ids)), key=lambda k: int(ids[k],16))))
PY
)
SORTED_IDS=""; for i in $ORDER; do SORTED_IDS="$SORTED_IDS ${TXIDS[$i]}"; done
delicti_commit $BOND 6 $MID "$SORTED_IDS" "${SALT:-}"
{
  echo "MID=$MID"
  echo "ORDER='$ORDER'"
  echo "TXIDS_STR='${TXIDS[*]}'"
  echo "REFS_STR='${REFSARR[*]}'"
  echo "LEAVES_STR='$(IFS='|'; echo "${LEAVES[*]}")'"
  echo "EPISODES_STR='${EPISODES[*]}'"
  echo "DELICTI_SALT=$DELICTI_SALT"
  echo "DELICTI_COMMITMENT=$DELICTI_COMMITMENT"
  echo "DELICTI_COMMIT_TS=$DELICTI_COMMIT_TS"
} > "$STATE"
echo "   state written to $STATE (RESUME=1 picks the run up from the attestations)"
delicti_wait_lead $BOND $T0 $DUR
fi

echo "== 8. five FDC Payment attestations (witness 2)"
REQS=(); ROUNDS=()
for i in $ORDER; do
  RP_OUT=$(request_payment_proof "${TXIDS[$i]}") || exit 1
  read -r Q R <<<"$RP_OUT"
  REQS+=("$Q"); ROUNDS+=("$R")
  echo "   requested proof for ${TXIDS[$i]} in round $R"
done
HEXES=(); MPS=()
for k in $(seq 0 $((N-1))); do
  FP_OUT=$(fetch_proof "${REQS[$k]}" "${ROUNDS[$k]}") || exit 1
  read -r H M <<<"$FP_OUT"
  HEXES+=("$H"); MPS+=("$M")
done

echo "== 9. reveal: the sum convicts"
IDX="["; LVS="["; PATHS="["; PROOFS="["; k=0
for i in $ORDER; do
  IDX="$IDX${EPISODES[$i]},"; LVS="$LVS${LEAVES[$i]},"; PATHS="$PATHS[],"
  PROOFS="$PROOFS(${MPS[$k]},$(decode_payment "${HEXES[$k]}")),"
  k=$((k+1))
done
IDX="${IDX%,}]"; LVS="${LVS%,}]"; PATHS="${PATHS%,}]"; PROOFS="${PROOFS%,}]"
SIG="challengeBudgetOverrunPayment(uint256,uint256[],(bytes32,uint8,bytes32,bytes32,uint256,bytes32,uint64,uint256)[],bytes32[][],(bytes32[],(bytes32,bytes32,uint64,uint64,(bytes32,uint256,uint256),(uint64,uint64,bytes32,bytes32,bytes32,bytes32,int256,int256,int256,int256,bytes32,bool,uint8)))[],bytes32)"
OUT=$(cast send $BOND "$SIG" $MID "$IDX" "$LVS" "$PATHS" "$PROOFS" "$DELICTI_SALT" \
  --private-key $PRIVATE_KEY --rpc-url $RPC --json)
echo "$OUT" | python3 -c "import sys,json;d=json.load(sys.stdin);print('   reveal',d['transactionHash'],'status',int(d['status'],16),'gas',int(d['gasUsed'],16))"

echo "== 10. the verdict, read back from the chain"
echo -n "   bondOf   "; cast call $BOND "bondOf(uint256)(uint256)" $MID --rpc-url $RPC
echo -n "   slashed  "; cast call $BOND "slashed(uint256)(bool)" $MID --rpc-url $RPC
echo -n "   live     "; cast call $REG  "isLive(uint256)(bool)" $MID --rpc-url $RPC
echo -n "   severity "; cast call $BOND "severityOf(uint256)(uint256)" $MID --rpc-url $RPC
