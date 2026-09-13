#!/usr/bin/env bash
# DELICTI — the fast half: structuring refused while it is happening (SPEC §7.1),
# and the effector whose tally lied convicted afterwards (SPEC §6.5).
#
#   MODE=brake       (default, ~1 min, no FDC): four slices fit, the fifth is refused by an
#                    eth_call against the meter — not slashed four minutes later.
#   MODE=underreport (~5-15 min): the effector records two of five settlements and stays quiet
#                    about the rest; FDC proves five; challengeUnderReportedSpend → slash.
#
# Requires: cast, curl, python3; .env with PRIVATE_KEY, COSTON2_RPC, VERIFIER_URL,
# VERIFIER_API_KEY, DA_URL; REG / LOG / BOND / METER pointing at a v0.7 deployment.
set -euo pipefail
cd "$(dirname "$0")/.."; set -a; . ./.env; set +a
RPC=$COSTON2_RPC
REG=${REG:?set REG to the v0.7 MandateRegistry}
BOND=${BOND:?set BOND to the v0.7 Bond}
METER=${METER:?set METER to the v0.7 SpendMeter}
MERCHANT=${MERCHANT:-0x2222222222222222222222222222222222222222}
MODE=${MODE:-brake}
EACH=${EACH:-10000000000000000}          # 0.01 C2FLR per deed
BUDGET=$((EACH * 4))
ME=$(cast wallet address --private-key "$PRIVATE_KEY")
FLARE_REG=0xaD67FE66660Fb8dFE9d6b1b4240d8650e30F6019
pad() { python3 -c "import sys;print('0x'+sys.argv[1].encode().hex().ljust(64,'0'))" "$1"; }
SRC=$(pad testFLR); ATYPE=$(pad EVMTransaction)
echo "mode=$MODE each=$EACH budget=$BUDGET"

echo "== 1. mandate (budget = 4 deeds) + exclusivity + metered effector + bond"
NOW=$(date +%s)
cast send $REG "commit(address,bytes32,bytes32,uint256,uint256,uint64,uint64)" $ME "$(cast keccak "metered: every settlement is recorded on the meter")" 0x$(printf '%064d' 0) 0 $BUDGET $((NOW-120)) $((NOW+604800)) --private-key $PRIVATE_KEY --rpc-url $RPC --json >/dev/null
MID=$(( $(cast call $REG "nextId()(uint256)" --rpc-url $RPC | awk '{print $1}') - 1 ))
cast send $REG "declareExclusive(uint256)" $MID --private-key $PRIVATE_KEY --rpc-url $RPC --json >/dev/null
cast send $METER "declareEffector(uint256,address)" $MID $ME --private-key $PRIVATE_KEY --rpc-url $RPC --json >/dev/null
cast send $BOND "post(uint256)" $MID --value 1ether --private-key $PRIVATE_KEY --rpc-url $RPC --json >/dev/null
echo "   mandateId=$MID exclusive=$(cast call $REG 'exclusive(uint256)(bool)' $MID --rpc-url $RPC) metered=$(cast call $METER 'metered(uint256)(bool)' $MID --rpc-url $RPC)"

deed() { # deed <i> -> echoes tx hash
  cast send $MERCHANT --value $EACH --private-key $PRIVATE_KEY --rpc-url $RPC --json | python3 -c "import sys,json;print(json.load(sys.stdin)['transactionHash'])"
}

if [ "$MODE" = brake ]; then
  echo "== 2. four slices, each checked against the tally before it happens"
  for i in 0 1 2 3; do
    EX=$(cast call $METER "wouldExceed(uint256,uint256)(bool)" $MID $EACH --rpc-url $RPC)
    HR=$(cast call $METER "headroom(uint256)(uint256)" $MID --rpc-url $RPC | awk '{print $1}')
    [ "$EX" = "true" ] && { echo "   !! slice $i refused early, headroom=$HR — unexpected"; exit 1; }
    TXH=$(deed $i)
    cast send $METER "note(uint256,uint256)" $MID $EACH --private-key $PRIVATE_KEY --rpc-url $RPC --json >/dev/null
    echo "   slice $i: wouldExceed=false headroom_before=$HR settled=$TXH noted"
  done
  echo "== 3. the fifth slice — this is the whole point"
  EX=$(cast call $METER "wouldExceed(uint256,uint256)(bool)" $MID $EACH --rpc-url $RPC)
  echo "   spent=$(cast call $METER 'spent(uint256)(uint256)' $MID --rpc-url $RPC | awk '{print $1}') headroom=$(cast call $METER 'headroom(uint256)(uint256)' $MID --rpc-url $RPC | awk '{print $1}') wouldExceed=$EX exceeded=$(cast call $METER 'exceeded(uint256)(bool)' $MID --rpc-url $RPC)"
  [ "$EX" = "true" ] && echo "   ✓ refused in one eth_call — no FDC round, no waiting, funds never moved" || { echo "   !! the brake did not refuse — BROKEN"; exit 1; }
  echo "   (the bond is untouched: slashed=$(cast call $BOND 'slashed(uint256)(bool)' $MID --rpc-url $RPC))"
  exit 0
fi

echo "== 2. five settlements, of which the effector records only two"
FSM=$(cast call $FLARE_REG "getContractAddressByName(string)(address)" FlareSystemsManager --rpc-url $RPC)
HUB=$(cast call $FLARE_REG "getContractAddressByName(string)(address)" FdcHub --rpc-url $RPC)
FEECFG=$(cast call $FLARE_REG "getContractAddressByName(string)(address)" FdcRequestFeeConfigurations --rpc-url $RPC)
T0=$(cast call $FSM "firstVotingRoundStartTs()(uint64)" --rpc-url $RPC | awk '{print $1}')
DUR=$(cast call $FSM "votingEpochDurationSeconds()(uint64)" --rpc-url $RPC | awk '{print $1}')
declare -a TXS REQS ROUNDS
for i in 0 1 2 3 4; do
  TXH=$(deed $i); TXS[$i]=$TXH
  if [ $i -lt 2 ]; then
    cast send $METER "note(uint256,uint256)" $MID $EACH --private-key $PRIVATE_KEY --rpc-url $RPC --json >/dev/null
    echo "   deed $i: $TXH  → recorded"
  else
    echo "   deed $i: $TXH  → NOT recorded (this is the lie)"
  fi
  BODY=$(printf '{"attestationType":"%s","sourceId":"%s","requestBody":{"transactionHash":"%s","requiredConfirmations":"1","provideInput":false,"listEvents":false,"logIndices":[]}}' "$ATYPE" "$SRC" "$TXH")
  REQ=$(curl -s -m 60 -X POST "$VERIFIER_URL/verifier/flr/EVMTransaction/prepareRequest" -H "X-API-KEY: $VERIFIER_API_KEY" -H "Content-Type: application/json" -d "$BODY" | python3 -c "import sys,json;d=json.load(sys.stdin);assert d['status']=='VALID',d;print(d['abiEncodedRequest'])")
  FEE=$(cast call $FEECFG "getRequestFee(bytes)(uint256)" $REQ --rpc-url $RPC | awk '{print $1}')
  STX=$(cast send $HUB "requestAttestation(bytes)" $REQ --value $FEE --private-key $PRIVATE_KEY --rpc-url $RPC --json)
  SBN=$(echo "$STX" | python3 -c "import sys,json;print(int(json.load(sys.stdin)['blockNumber'],16))")
  STS=$(cast block $SBN --rpc-url $RPC --json | python3 -c "import sys,json;print(int(json.load(sys.stdin)['timestamp'],16))")
  REQS[$i]=$REQ; ROUNDS[$i]=$(( (STS - T0) / DUR ))
done
echo "   meter says spent=$(cast call $METER 'spent(uint256)(uint256)' $MID --rpc-url $RPC | awk '{print $1}'), the world will say $((5*EACH))"

echo "== 3. DA layer: five proofs"
T="((bytes32,bytes32,uint64,uint64,(bytes32,uint16,bool,bool,uint32[]),(uint64,uint64,address,bool,address,uint256,bytes,uint8,(uint32,address,bytes32[],bytes,bool)[])))"
TRIES=${POLL_TRIES:-40}
declare -a DATAS MPS
for i in 0 1 2 3 4; do
  for t in $(seq 1 $TRIES); do
    R=$(curl -s -m 30 -X POST "$DA_URL/api/v1/fdc/proof-by-request-round-raw" -H "X-API-KEY: $VERIFIER_API_KEY" -H "Content-Type: application/json" -d "{\"votingRoundId\":${ROUNDS[$i]},\"requestBytes\":\"${REQS[$i]}\"}")
    echo "$R" | grep -q '"response_hex"' && break
    [ $((t % 5)) -eq 0 ] && echo "   ...proof $i, ${t}/${TRIES}: $(echo "$R" | head -c 120)"
    sleep 20
  done
  echo "$R" | grep -q '"response_hex"' || { echo "   DA never returned proof $i (round ${ROUNDS[$i]}). Last: $(echo "$R" | head -c 300)"; exit 1; }
  RESP=$(echo "$R" | python3 -c "import sys,json;print(json.load(sys.stdin)['response_hex'])")
  MPS[$i]=$(echo "$R" | python3 -c "import sys,json;print('['+','.join(json.load(sys.stdin)['proof'])+']')")
  DATAS[$i]=$(cast abi-decode "f()$T" $RESP | sed -E 's/([0-9]) \[[0-9.e]+\]/\1/g')
  echo "   proof $i ok"
done

echo "== 4. challengeUnderReportedSpend — the world shows more than the tally admits"
ORDER=$(python3 -c "import sys;t=sys.argv[1:];print(' '.join(str(i) for i in sorted(range(len(t)),key=lambda i:int(t[i],16))))" "${TXS[@]}")
PRS="["; for i in $ORDER; do PRS+="(${MPS[$i]},${DATAS[$i]}),"; done; PRS="${PRS%,}]"
TI="${T:1:-1}"
cast send $BOND "challengeUnderReportedSpend(uint256,address,(bytes32[],$TI)[])" $MID 0x0000000000000000000000000000000000000000 "$PRS" --private-key $PRIVATE_KEY --rpc-url $RPC --json | python3 -c "import sys,json;d=json.load(sys.stdin);print('   tx',d['transactionHash'],'status',d['status'],'gas',int(d['gasUsed'],16))"
echo "   bondOf=$(cast call $BOND 'bondOf(uint256)(uint256)' $MID --rpc-url $RPC) slashed=$(cast call $BOND 'slashed(uint256)(bool)' $MID --rpc-url $RPC) mandateLive=$(cast call $REG 'isLive(uint256)(bool)' $MID --rpc-url $RPC)"
