#!/usr/bin/env bash
# DELICTI — the x402 salami, end to end THROUGH A RUNNING flario MCP SERVER.
#
# Same verdict as scripts/x402-structuring.sh, but witness 1 is no longer built
# by hand: the agent is an MCP client, the effector is the flario server process,
# and the receipts are the ones that server emitted. That is the difference
# between a demo of the contracts and a demo of the loop.
#
#   mandate: agent may spend 4 mUSDT0 at the payee, via x402.
#   deeds:   5 paid MCP tool calls, each settled by flario as EIP-3009
#            transferWithAuthorization, each answered with a flario-receipt/2
#            carrying mandate_ref (witness 1),
#            each corroborated by FDC EVMTransaction + Transfer event (witness 2).
#   verdict: sum 5 > budget 4 → Bond.challengeBudgetOverrunERC20 → slash.
#
# Requires: cast, curl, python3, node; a flario checkout at FLARIO_DIR with
# `npm run build` done and the mandate-gate commit applied; .env with
# PRIVATE_KEY, COSTON2_RPC, VERIFIER_URL, VERIFIER_API_KEY, DA_URL.
set -euo pipefail
cd "$(dirname "$0")/.."; set -a; . ./.env; set +a
RPC=$COSTON2_RPC
FLARIO_DIR=${FLARIO_DIR:-../flario}
REG=${REG:-0x73109d769878cA2Cf0Ba180CF4f1a24b404F3f48}
LOG=${LOG:-0x8eC9C70f9615804259c16e811dC428Db7a1522Fe}
BOND=${BOND:-0xBA146240AC394E64ca50CaC40100A2cdAE241e4e}
TOKEN=${TOKEN:-0x9Eea43feA502609d0D88DAfd1d64B4e929BF18C2}   # MockUSDT0 (EIP-3009), 6 dec
PAYEE=${PAYEE:-0x2222222222222222222222222222222222222222}
VICTIM=${VICTIM:-0x1111111111111111111111111111111111111111}
N=${N:-5}; EACH=1000000; BUDGET=4000000; PRICE=${PRICE:-1}
ME=$(cast wallet address --private-key "$PRIVATE_KEY")   # agent == payer == facilitator gas payer
FLARE_REG=0xaD67FE66660Fb8dFE9d6b1b4240d8650e30F6019
pad() { python3 -c "import sys;print('0x'+sys.argv[1].encode().hex().ljust(64,'0'))" "$1"; }
SRC=$(pad testFLR); ATYPE=$(pad EVMTransaction)
HUB=$(cast call $FLARE_REG "getContractAddressByName(string)(address)" FdcHub --rpc-url $RPC)
FEECFG=$(cast call $FLARE_REG "getContractAddressByName(string)(address)" FdcRequestFeeConfigurations --rpc-url $RPC)
FSM=$(cast call $FLARE_REG "getContractAddressByName(string)(address)" FlareSystemsManager --rpc-url $RPC)
T0=$(cast call $FSM "firstVotingRoundStartTs()(uint64)" --rpc-url $RPC | awk '{print $1}')
DUR=$(cast call $FSM "votingEpochDurationSeconds()(uint64)" --rpc-url $RPC | awk '{print $1}')
OUT=$(mktemp -d); echo "work dir: $OUT"

echo "== 1. mandate (budget 4 mUSDT0) + bond"
NOW=$(date +%s)
cast send $REG "commit(address,bytes32,bytes32,uint256,uint256,uint64,uint64)" $ME "$(cast keccak "may spend up to 4 mUSDT0 at $PAYEE via flario x402")" 0x$(printf '%064d' 0) 0 $BUDGET $((NOW-120)) $((NOW+604800)) --private-key $PRIVATE_KEY --rpc-url $RPC --json >/dev/null
MID=$(( $(cast call $REG "nextId()(uint256)" --rpc-url $RPC | awk '{print $1}') - 1 )); echo "   mandateId=$MID"
cast send $BOND "post(uint256)" $MID --value 1ether --private-key $PRIVATE_KEY --rpc-url $RPC --json >/dev/null
BAL=$(cast call $TOKEN "balanceOf(address)(uint256)" $ME --rpc-url $RPC | awk '{print $1}')
[ "$BAL" -lt $((N*EACH)) ] && cast send $TOKEN "mint(address,uint256)" $ME $((N*EACH)) --private-key $PRIVATE_KEY --rpc-url $RPC --json >/dev/null

echo "== 2. $N paid MCP calls through flario (agent → server → settlement → receipt)"
( cd "$FLARIO_DIR" && \
  X402_ENABLED=true X402_NETWORK=coston2 X402_PAY_TO=$PAYEE X402_TOKEN_ADDRESS=$TOKEN \
  X402_PRICE_DEFAULT=$PRICE X402_TOKEN_DECIMALS=6 X402_TOKEN_EIP712_VERSION=1 \
  FLARE_PRIVATE_KEY=$PRIVATE_KEY X402_CLIENT_PRIVATE_KEY=$PRIVATE_KEY \
  DELICTI_REGISTRY=$REG DELICTI_REQUIRE_MANDATE=1 \
  MANDATE_ID=$MID N=$N OUT_DIR="$OUT/x402" npx tsx scripts/x402-agent.ts )

echo "== 3. normalize → anchor → FDC request (Transfer event inside the proof)"
declare -a TXS REQS ROUNDS
for i in $(seq 0 $((N-1))); do
  R="$OUT/x402/receipt$i.json"
  [ -f "$R" ] || { echo "missing $R — the server refused or errored; abort"; exit 1; }
  TXH=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['settlement_tx_hash'])" "$R")
  RCPT=$(cast receipt $TXH --rpc-url $RPC --json)
  LOGIDX=$(echo "$RCPT" | python3 -c "import sys,json;d=json.load(sys.stdin);print([int(l['logIndex'],16) for l in d['logs'] if l['topics'][0].lower()=='0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef'][0])")
  python3 tools/delicti.py normalize "$R" > $OUT/leaf$i.json
  LH=$(python3 -c "import json;print(json.load(open('$OUT/leaf$i.json'))['leafHash'])")
  cast send $LOG "anchor(uint256,bytes32,uint64)" $MID $LH 1 --private-key $PRIVATE_KEY --rpc-url $RPC --json >/dev/null
  BODY=$(printf '{"attestationType":"%s","sourceId":"%s","requestBody":{"transactionHash":"%s","requiredConfirmations":"1","provideInput":false,"listEvents":true,"logIndices":["%s"]}}' "$ATYPE" "$SRC" "$TXH" "$LOGIDX")
  REQ=$(curl -s -m 60 -X POST "$VERIFIER_URL/verifier/flr/EVMTransaction/prepareRequest" -H "X-API-KEY: $VERIFIER_API_KEY" -H "Content-Type: application/json" -d "$BODY" | python3 -c "import sys,json;d=json.load(sys.stdin);assert d['status']=='VALID',d;print(d['abiEncodedRequest'])")
  FEE=$(cast call $FEECFG "getRequestFee(bytes)(uint256)" $REQ --rpc-url $RPC | awk '{print $1}')
  STX=$(cast send $HUB "requestAttestation(bytes)" $REQ --value $FEE --private-key $PRIVATE_KEY --rpc-url $RPC --json)
  SBN=$(echo "$STX" | python3 -c "import sys,json;print(int(json.load(sys.stdin)['blockNumber'],16))")
  STS=$(cast block $SBN --rpc-url $RPC --json | python3 -c "import sys,json;print(int(json.load(sys.stdin)['timestamp'],16))")
  TXS[$i]=$TXH; REQS[$i]=$REQ; ROUNDS[$i]=$(( (STS - T0) / DUR ))
  echo "   deed $i: settle=$TXH logIndex=$LOGIDX leaf=${LH:0:14} round=${ROUNDS[$i]}"
done

echo "== 4. DA layer: $N proofs with events"
declare -a DATAS MPS
T="((bytes32,bytes32,uint64,uint64,(bytes32,uint16,bool,bool,uint32[]),(uint64,uint64,address,bool,address,uint256,bytes,uint8,(uint32,address,bytes32[],bytes,bool)[])))"
for i in $(seq 0 $((N-1))); do
  for t in $(seq 1 24); do
    R=$(curl -s -m 30 -X POST "$DA_URL/api/v1/fdc/proof-by-request-round-raw" -H "X-API-KEY: $VERIFIER_API_KEY" -H "Content-Type: application/json" -d "{\"votingRoundId\":${ROUNDS[$i]},\"requestBytes\":\"${REQS[$i]}\"}")
    echo "$R" | grep -q '"response_hex"' && break; sleep 20
  done
  RESP=$(echo "$R" | python3 -c "import sys,json;print(json.load(sys.stdin)['response_hex'])")
  MPS[$i]=$(echo "$R" | python3 -c "import sys,json;print('['+','.join(json.load(sys.stdin)['proof'])+']')")
  DATAS[$i]=$(cast abi-decode "f()$T" $RESP | sed -E 's/([0-9]) \[[0-9.e]+\]/\1/g')
  echo "   proof $i ok (events: $(echo "${DATAS[$i]}" | grep -o 'ddf252ad' | wc -l) Transfer)"
done

echo "== 5. challengeBudgetOverrunERC20 — $N × 1 mUSDT0 > 4 mUSDT0"
ORDER=$(python3 -c "import sys;t=sys.argv[1:];print(' '.join(str(i) for i in sorted(range(len(t)),key=lambda i:int(t[i],16))))" "${TXS[@]}")
IDX="["; LS="["; PS="["; PRS="["
for i in $ORDER; do IDX+="$i,"; LS+="$(python3 -c "import json;print(json.load(open('$OUT/leaf$i.json'))['_tuple'])"),"; PS+="[],"; PRS+="(${MPS[$i]},${DATAS[$i]}),"; done
IDX="${IDX%,}]"; LS="${LS%,}]"; PS="${PS%,}]"; PRS="${PRS%,}]"
TI="${T:1:-1}"; SIG="challengeBudgetOverrunERC20(uint256,address,uint256[],(bytes32,uint8,bytes32,bytes32,uint256,bytes32,uint64,uint256)[],bytes32[][],(bytes32[],$TI)[],address)"
cast send $BOND "$SIG" $MID $TOKEN "$IDX" "$LS" "$PS" "$PRS" $VICTIM --private-key $PRIVATE_KEY --rpc-url $RPC --json | python3 -c "import sys,json;d=json.load(sys.stdin);print('   tx',d['transactionHash'],'status',d['status'],'gas',int(d['gasUsed'],16))"
echo "   bondOf=$(cast call $BOND 'bondOf(uint256)(uint256)' $MID --rpc-url $RPC) slashed=$(cast call $BOND 'slashed(uint256)(bool)' $MID --rpc-url $RPC) mandateLive=$(cast call $REG 'isLive(uint256)(bool)' $MID --rpc-url $RPC)"
echo "receipts (from the flario server) + leaves kept in $OUT"
