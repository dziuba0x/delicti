#!/usr/bin/env bash
# DELICTI — the REAL x402 salami on Coston2.
#
#   mandate: agent may spend 4 mUSDT0 at the payee.
#   deeds:   5 × 1 mUSDT0, each a genuine EIP-3009 transferWithAuthorization settlement
#            (agent signs typed data, facilitator submits — exactly what flario's x402 does),
#            each wrapped in a genuine flario-receipt/2 with mandate_ref (witness 1),
#            each corroborated by FDC EVMTransaction with the Transfer event (witness 2).
#   verdict: sum 5 > budget 4 → Bond.challengeBudgetOverrunERC20 → slash.
#
# Requires: cast, curl, python3, a flario checkout (FLARIO_DIR, for buildReceipt), .env.
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
N=${N:-5}; EACH=1000000; BUDGET=4000000
ME=$(cast wallet address --private-key "$PRIVATE_KEY")   # agent == payer; also facilitator (pays gas)
FLARE_REG=0xaD67FE66660Fb8dFE9d6b1b4240d8650e30F6019
pad() { python3 -c "import sys;print('0x'+sys.argv[1].encode().hex().ljust(64,'0'))" "$1"; }
SRC=$(pad testFLR); ATYPE=$(pad EVMTransaction)
HUB=$(cast call $FLARE_REG "getContractAddressByName(string)(address)" FdcHub --rpc-url $RPC)
FEECFG=$(cast call $FLARE_REG "getContractAddressByName(string)(address)" FdcRequestFeeConfigurations --rpc-url $RPC)
FSM=$(cast call $FLARE_REG "getContractAddressByName(string)(address)" FlareSystemsManager --rpc-url $RPC)
T0=$(cast call $FSM "firstVotingRoundStartTs()(uint64)" --rpc-url $RPC | awk '{print $1}'); DUR=$(cast call $FSM "votingEpochDurationSeconds()(uint64)" --rpc-url $RPC | awk '{print $1}')
OUT=$(mktemp -d); echo "work dir: $OUT"

echo "== 1. mandate (budget 4 mUSDT0) + bond"
NOW=$(date +%s)
cast send $REG "commit(address,bytes32,bytes32,uint256,uint256,uint64,uint64)" $ME "$(cast keccak "may spend up to 4 mUSDT0 at $PAYEE via x402")" 0x$(printf '%064d' 0) 0 $BUDGET $((NOW-120)) $((NOW+604800)) --private-key $PRIVATE_KEY --rpc-url $RPC --json >/dev/null
MID=$(( $(cast call $REG "nextId()(uint256)" --rpc-url $RPC | awk '{print $1}') - 1 )); echo "   mandateId=$MID"
cast send $BOND "post(uint256)" $MID --value 1ether --private-key $PRIVATE_KEY --rpc-url $RPC --json >/dev/null
BAL=$(cast call $TOKEN "balanceOf(address)(uint256)" $ME --rpc-url $RPC | awk '{print $1}')
[ "$BAL" -lt $((N*EACH)) ] && cast send $TOKEN "mint(address,uint256)" $ME $((N*EACH)) --private-key $PRIVATE_KEY --rpc-url $RPC --json >/dev/null

echo "== 2. $N x402 settlements (EIP-3009) → flario receipt v2 → anchor → FDC request (with Transfer event)"
declare -a TXS REQS ROUNDS LEAFH
for i in $(seq 0 $((N-1))); do
  NONCE=$(cast keccak "delicti-x402-$MID-$i-$RANDOM"); VB=$((NOW+3600))
  cat > $OUT/td$i.json <<EOF
{"types":{"EIP712Domain":[{"name":"name","type":"string"},{"name":"version","type":"string"},{"name":"chainId","type":"uint256"},{"name":"verifyingContract","type":"address"}],"TransferWithAuthorization":[{"name":"from","type":"address"},{"name":"to","type":"address"},{"name":"value","type":"uint256"},{"name":"validAfter","type":"uint256"},{"name":"validBefore","type":"uint256"},{"name":"nonce","type":"bytes32"}]},"primaryType":"TransferWithAuthorization","domain":{"name":"Mock USDT0","version":"1","chainId":114,"verifyingContract":"$TOKEN"},"message":{"from":"$ME","to":"$PAYEE","value":"$EACH","validAfter":"0","validBefore":"$VB","nonce":"$NONCE"}}
EOF
  SIG=$(cast wallet sign --private-key $PRIVATE_KEY --data --from-file $OUT/td$i.json); R=${SIG:0:66}; S=0x${SIG:66:64}; V=$((16#${SIG:130:2}))
  TX=$(cast send $TOKEN "transferWithAuthorization(address,address,uint256,uint256,uint256,bytes32,uint8,bytes32,bytes32)" $ME $PAYEE $EACH 0 $VB $NONCE $V $R $S --private-key $PRIVATE_KEY --rpc-url $RPC --json)
  TXH=$(echo "$TX" | python3 -c "import sys,json;print(json.load(sys.stdin)['transactionHash'])")
  LOGIDX=$(echo "$TX" | python3 -c "import sys,json;d=json.load(sys.stdin);print([int(l['logIndex'],16) for l in d['logs'] if l['topics'][0].lower()=='0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef'][0])")
  BN=$(echo "$TX" | python3 -c "import sys,json;print(int(json.load(sys.stdin)['blockNumber'],16))"); TS=$(cast block $BN --rpc-url $RPC --json | python3 -c "import sys,json;print(int(json.load(sys.stdin)['timestamp'],16))")
  # genuine flario receipt v2 (witness 1)
  (cd $FLARIO_DIR && npx tsx -e "
import { buildReceipt } from './src/x402/receipt.ts';
console.log(JSON.stringify(buildReceipt({ payer: '$ME', payee: '$PAYEE', amount: '$EACH', asset: '$TOKEN', network: 'coston2', toolId: 'fassets_liquidation_scanner', settlementTxHash: '$TXH', timestamp: $TS, mandateRef: { chain_id: 114, registry: '$REG', mandate_id: '$MID' } })));") > $OUT/receipt$i.json
  python3 tools/delicti.py normalize $OUT/receipt$i.json > $OUT/leaf$i.json
  LH=$(python3 -c "import json;print(json.load(open('$OUT/leaf$i.json'))['leafHash'])")
  cast send $LOG "anchor(uint256,bytes32,uint64)" $MID $LH 1 --private-key $PRIVATE_KEY --rpc-url $RPC --json >/dev/null
  BODY=$(printf '{"attestationType":"%s","sourceId":"%s","requestBody":{"transactionHash":"%s","requiredConfirmations":"1","provideInput":false,"listEvents":true,"logIndices":["%s"]}}' "$ATYPE" "$SRC" "$TXH" "$LOGIDX")
  REQ=$(curl -s -m 60 -X POST "$VERIFIER_URL/verifier/flr/EVMTransaction/prepareRequest" -H "X-API-KEY: $VERIFIER_API_KEY" -H "Content-Type: application/json" -d "$BODY" | python3 -c "import sys,json;d=json.load(sys.stdin);assert d['status']=='VALID',d;print(d['abiEncodedRequest'])")
  FEE=$(cast call $FEECFG "getRequestFee(bytes)(uint256)" $REQ --rpc-url $RPC | awk '{print $1}')
  STX=$(cast send $HUB "requestAttestation(bytes)" $REQ --value $FEE --private-key $PRIVATE_KEY --rpc-url $RPC --json)
  SBN=$(echo "$STX" | python3 -c "import sys,json;print(int(json.load(sys.stdin)['blockNumber'],16))"); STS=$(cast block $SBN --rpc-url $RPC --json | python3 -c "import sys,json;print(int(json.load(sys.stdin)['timestamp'],16))")
  TXS[$i]=$TXH; REQS[$i]=$REQ; ROUNDS[$i]=$(( (STS - T0) / DUR )); LEAFH[$i]=$LH
  echo "   deed $i: settle=$TXH logIndex=$LOGIDX receipt=$(python3 -c "import json;print(json.load(open('$OUT/receipt$i.json'))['receipt_hash'][:14])") leaf=${LH:0:14} round=${ROUNDS[$i]}"
done

echo "== 3. DA layer: $N proofs with events"
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

echo "== 4. challengeBudgetOverrunERC20 — 5 × 1 mUSDT0 > 4 mUSDT0"
ORDER=$(python3 -c "import sys;t=sys.argv[1:];print(' '.join(str(i) for i in sorted(range(len(t)),key=lambda i:int(t[i],16))))" "${TXS[@]}")
IDX="["; LS="["; PS="["; PRS="["
for i in $ORDER; do IDX+="$i,"; LS+="$(python3 -c "import json;print(json.load(open('$OUT/leaf$i.json'))['_tuple'])"),"; PS+="[],"; PRS+="(${MPS[$i]},${DATAS[$i]}),"; done
IDX="${IDX%,}]"; LS="${LS%,}]"; PS="${PS%,}]"; PRS="${PRS%,}]"
TI="${T:1:-1}"; SIG="challengeBudgetOverrunERC20(uint256,address,uint256[],(bytes32,uint8,bytes32,bytes32,uint256,bytes32,uint64,uint256)[],bytes32[][],(bytes32[],$TI)[],address)"
cast send $BOND "$SIG" $MID $TOKEN "$IDX" "$LS" "$PS" "$PRS" $VICTIM --private-key $PRIVATE_KEY --rpc-url $RPC --json | python3 -c "import sys,json;d=json.load(sys.stdin);print('   tx',d['transactionHash'],'status',d['status'],'gas',int(d['gasUsed'],16))"
echo "   bondOf=$(cast call $BOND 'bondOf(uint256)(uint256)' $MID --rpc-url $RPC) slashed=$(cast call $BOND 'slashed(uint256)(bool)' $MID --rpc-url $RPC) mandateLive=$(cast call $REG 'isLive(uint256)(bool)' $MID --rpc-url $RPC)"
echo "receipts + leaves kept in $OUT"
