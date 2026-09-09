#!/usr/bin/env bash
# DELICTI — live STRUCTURING ("salami") challenge on Coston2.
#   mandate budget: 4 C2FLR. The agent makes five 1-C2FLR transfers, anchors a receipt for each.
#   Each deed is corroborated by FDC EVMTransaction (witness 2, sourceAddress == agent).
#   Sum (5) > budget (4) → Bond.challengeBudgetOverrun slashes.
set -euo pipefail
cd "$(dirname "$0")/.."; set -a; . ./.env; set +a
RPC=$COSTON2_RPC
REG=${REG:-0x52A61f0B9312042c514B0aC5C053747B0EdF0C17}
LOG=${LOG:-0x10F4e4bc90d483B9E1D6c90EE6d6275FF825D2ae}
BOND=${BOND:-0x84Da6082Ba9f453d6aE59A0A3f868F6A1C35046E}
MERCHANT=${MERCHANT:-0x2222222222222222222222222222222222222222}
N=${N:-5}; EACH=1000000000000000000; BUDGET=4000000000000000000
ME=$(cast wallet address --private-key "$PRIVATE_KEY")
FLARE_REG=0xaD67FE66660Fb8dFE9d6b1b4240d8650e30F6019
pad() { python3 -c "import sys;print('0x'+sys.argv[1].encode().hex().ljust(64,'0'))" "$1"; }
SRC=$(pad testFLR); ATYPE=$(pad EVMTransaction)
HUB=$(cast call $FLARE_REG "getContractAddressByName(string)(address)" FdcHub --rpc-url $RPC)
FEECFG=$(cast call $FLARE_REG "getContractAddressByName(string)(address)" FdcRequestFeeConfigurations --rpc-url $RPC)
FSM=$(cast call $FLARE_REG "getContractAddressByName(string)(address)" FlareSystemsManager --rpc-url $RPC)
T0=$(cast call $FSM "firstVotingRoundStartTs()(uint64)" --rpc-url $RPC | awk '{print $1}'); DUR=$(cast call $FSM "votingEpochDurationSeconds()(uint64)" --rpc-url $RPC | awk '{print $1}')

echo "== 1. mandate: budget 4 C2FLR"
NOW=$(date +%s)
cast send $REG "commit(address,bytes32,bytes32,uint256,uint256,uint64,uint64)" $ME "$(cast keccak "may spend up to 4 C2FLR at $MERCHANT")" 0x$(printf '%064d' 0) 0 $BUDGET $((NOW-120)) $((NOW+604800)) --private-key $PRIVATE_KEY --rpc-url $RPC --json >/dev/null
MID=$(( $(cast call $REG "nextId()(uint256)" --rpc-url $RPC | awk '{print $1}') - 1 )); echo "   mandateId=$MID"
cast send $BOND "post(uint256)" $MID --value 1ether --private-key $PRIVATE_KEY --rpc-url $RPC --json >/dev/null

echo "== 2. $N deeds: 1 C2FLR each → receipt anchored → FDC EVMTransaction requested"
declare -a TXS LEAVES REQS ROUNDS
for i in $(seq 0 $((N-1))); do
  TX=$(cast send $MERCHANT --value $EACH --private-key $PRIVATE_KEY --rpc-url $RPC --json); TXH=$(echo "$TX" | python3 -c "import sys,json;print(json.load(sys.stdin)['transactionHash'])")
  BN=$(echo "$TX" | python3 -c "import sys,json;print(int(json.load(sys.stdin)['blockNumber'],16))"); TS=$(cast block $BN --rpc-url $RPC --json | python3 -c "import sys,json;print(int(json.load(sys.stdin)['timestamp'],16))")
  RH=$(cast keccak "x402_receipt #$i tx $TXH"); DESTH=0x$(printf '%024d' 0)${MERCHANT#0x}
  LEAF="($RH,2,$SRC,$DESTH,$EACH,$TXH,$TS,$MID)"
  LH=$(cast keccak "$(cast abi-encode 'f((bytes32,uint8,bytes32,bytes32,uint256,bytes32,uint64,uint256))' "$LEAF")")
  cast send $LOG "anchor(uint256,bytes32,uint64)" $MID $LH 1 --private-key $PRIVATE_KEY --rpc-url $RPC --json >/dev/null
  BODY=$(printf '{"attestationType":"%s","sourceId":"%s","requestBody":{"transactionHash":"%s","requiredConfirmations":"1","provideInput":false,"listEvents":false,"logIndices":[]}}' "$ATYPE" "$SRC" "$TXH")
  PREP=$(curl -s -m 60 -X POST "$VERIFIER_URL/verifier/flr/EVMTransaction/prepareRequest" -H "X-API-KEY: $VERIFIER_API_KEY" -H "Content-Type: application/json" -d "$BODY")
  REQ=$(echo "$PREP" | python3 -c "import sys,json;d=json.load(sys.stdin);assert d['status']=='VALID',d;print(d['abiEncodedRequest'])")
  FEE=$(cast call $FEECFG "getRequestFee(bytes)(uint256)" $REQ --rpc-url $RPC | awk '{print $1}')
  STX=$(cast send $HUB "requestAttestation(bytes)" $REQ --value $FEE --private-key $PRIVATE_KEY --rpc-url $RPC --json)
  SBN=$(echo "$STX" | python3 -c "import sys,json;print(int(json.load(sys.stdin)['blockNumber'],16))"); STS=$(cast block $SBN --rpc-url $RPC --json | python3 -c "import sys,json;print(int(json.load(sys.stdin)['timestamp'],16))")
  TXS[$i]=$TXH; LEAVES[$i]=$LEAF; REQS[$i]=$REQ; ROUNDS[$i]=$(( (STS - T0) / DUR ))
  echo "   deed $i: tx=$TXH leaf=$LH round=${ROUNDS[$i]}"
done

echo "== 3. DA layer: collect $N proofs"
declare -a DATAS MPS
for i in $(seq 0 $((N-1))); do
  for t in $(seq 1 20); do
    R=$(curl -s -m 30 -X POST "$DA_URL/api/v1/fdc/proof-by-request-round-raw" -H "X-API-KEY: $VERIFIER_API_KEY" -H "Content-Type: application/json" -d "{\"votingRoundId\":${ROUNDS[$i]},\"requestBytes\":\"${REQS[$i]}\"}")
    echo "$R" | grep -q '"response_hex"' && break; sleep 20
  done
  RESP=$(echo "$R" | python3 -c "import sys,json;print(json.load(sys.stdin)['response_hex'])")
  MPS[$i]=$(echo "$R" | python3 -c "import sys,json;print('['+','.join(json.load(sys.stdin)['proof'])+']')")
  DATAS[$i]=$(cast abi-decode "f()((bytes32,bytes32,uint64,uint64,(bytes32,uint16,bool,bool,uint32[]),(uint64,uint64,address,bool,address,uint256,bytes,uint8,(uint32,address,bytes32[],bytes,bool)[])))" $RESP | sed -E 's/ \[[0-9.e]+\]//g')
  echo "   proof $i ok"
done

echo "== 4. challengeBudgetOverrun — sum 5 > budget 4"
# order deeds by tx hash ascending (contract requires strictly increasing)
ORDER=$(python3 -c "import sys;t=sys.argv[1:];print(' '.join(str(i) for i in sorted(range(len(t)),key=lambda i:int(t[i],16))))" "${TXS[@]}")
IDX="["; LS="["; PS="["; PRS="["
for i in $ORDER; do IDX+="$i,"; LS+="${LEAVES[$i]},"; PS+="[],"; PRS+="(${MPS[$i]},${DATAS[$i]}),"; done
IDX="${IDX%,}]"; LS="${LS%,}]"; PS="${PS%,}]"; PRS="${PRS%,}]"
SIG="challengeBudgetOverrun(uint256,uint256[],(bytes32,uint8,bytes32,bytes32,uint256,bytes32,uint64,uint256)[],bytes32[][],(bytes32[],(bytes32,bytes32,uint64,uint64,(bytes32,uint16,bool,bool,uint32[]),(uint64,uint64,address,bool,address,uint256,bytes,uint8,(uint32,address,bytes32[],bytes,bool)[])))[])"
cast send $BOND "$SIG" $MID "$IDX" "$LS" "$PS" "$PRS" --private-key $PRIVATE_KEY --rpc-url $RPC --json | python3 -c "import sys,json;d=json.load(sys.stdin);print('   tx',d['transactionHash'],'status',d['status'],'gas',int(d['gasUsed'],16))"
echo "   bondOf=$(cast call $BOND 'bondOf(uint256)(uint256)' $MID --rpc-url $RPC) slashed=$(cast call $BOND 'slashed(uint256)(bool)' $MID --rpc-url $RPC) mandateLive=$(cast call $REG 'isLive(uint256)(bool)' $MID --rpc-url $RPC)"
