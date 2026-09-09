#!/usr/bin/env bash
# DELICTI — end-to-end "contradicted deed" on Coston2 (testnet only, whitehat).
#
#   witness 1: the agent anchors a receipt claiming "I paid 1 XRP to <dest> with reference R".
#   witness 2: FDC ReferencedPaymentNonexistence on testXRP proves no such payment exists.
#   consequence: Bond.challengeFalsePayment slashes the bond (10% challenger, 90% principal — both pull with claim())
#                and revokes the mandate.
#
# Requires: foundry (cast), curl, python3, and a .env with PRIVATE_KEY, COSTON2_RPC,
#           VERIFIER_URL, VERIFIER_API_KEY, DA_URL. Deployed addresses via env or defaults below.
set -euo pipefail
cd "$(dirname "$0")/.."; set -a; . ./.env; set +a
RPC=$COSTON2_RPC
REG=${REG:-0x52A61f0B9312042c514B0aC5C053747B0EdF0C17}
LOG=${LOG:-0x10F4e4bc90d483B9E1D6c90EE6d6275FF825D2ae}
BOND=${BOND:-0x84Da6082Ba9f453d6aE59A0A3f868F6A1C35046E}
ME=$(cast wallet address --private-key "$PRIVATE_KEY")
FLARE_REG=0xaD67FE66660Fb8dFE9d6b1b4240d8650e30F6019

pad() { python3 -c "import sys;print('0x'+sys.argv[1].encode().hex().ljust(64,'0'))" "$1"; }

echo "== 1. XRPL testnet: latest validated ledger + a real account to 'pay'"
XRPL=$(curl -s -m 20 -X POST https://testnet.xrpl-labs.com/ -H 'Content-Type: application/json' \
  -d '{"method":"ledger","params":[{"ledger_index":"validated","transactions":true,"expand":true}]}')
LATEST=$(echo "$XRPL" | python3 -c "import sys,json;print(json.load(sys.stdin)['result']['ledger']['ledger_index'])")
CLOSE=$(echo "$XRPL"  | python3 -c "import sys,json;print(int(json.load(sys.stdin)['result']['ledger']['close_time'])+946684800)")
DESTADDR=$(echo "$XRPL" | python3 -c "import sys,json;print([t['Account'] for t in json.load(sys.stdin)['result']['ledger']['transactions'] if 'Account' in t][0])")
MINB=$((LATEST-400)); DEADB=$((LATEST-80)); DEADT=$((CLOSE-280)); CLAIMED=$((DEADT-100))
DEST=$(cast keccak "$DESTADDR"); REF=$(cast keccak "DELICTI-invoice-$RANDOM"); AMT=1000000
SRC=$(pad testXRP); ATYPE=$(pad ReferencedPaymentNonexistence)
echo "   ledger=$LATEST dest=$DESTADDR"

echo "== 2. FDC verifier: prepare nonexistence request"
BODY=$(printf '{"attestationType":"%s","sourceId":"%s","requestBody":{"minimalBlockNumber":"%s","deadlineBlockNumber":"%s","deadlineTimestamp":"%s","destinationAddressHash":"%s","amount":"%s","standardPaymentReference":"%s","checkSourceAddresses":false,"sourceAddressesRoot":"0x%064d"}}' \
  "$ATYPE" "$SRC" "$MINB" "$DEADB" "$DEADT" "$DEST" "$AMT" "$REF" 0)
PREP=$(curl -s -m 60 -X POST "$VERIFIER_URL/verifier/xrp/ReferencedPaymentNonexistence/prepareRequest" -H "X-API-KEY: $VERIFIER_API_KEY" -H "Content-Type: application/json" -d "$BODY")
echo "   status: $(echo "$PREP" | python3 -c "import sys,json;print(json.load(sys.stdin)['status'])")"
REQ=$(echo "$PREP" | python3 -c "import sys,json;print(json.load(sys.stdin)['abiEncodedRequest'])")

echo "== 3. FdcHub: pay fee, submit"
FEECFG=$(cast call $FLARE_REG "getContractAddressByName(string)(address)" FdcRequestFeeConfigurations --rpc-url $RPC)
HUB=$(cast call $FLARE_REG "getContractAddressByName(string)(address)" FdcHub --rpc-url $RPC)
FSM=$(cast call $FLARE_REG "getContractAddressByName(string)(address)" FlareSystemsManager --rpc-url $RPC)
FEE=$(cast call $FEECFG "getRequestFee(bytes)(uint256)" $REQ --rpc-url $RPC | awk '{print $1}')
T0=$(cast call $FSM "firstVotingRoundStartTs()(uint64)" --rpc-url $RPC | awk '{print $1}'); DUR=$(cast call $FSM "votingEpochDurationSeconds()(uint64)" --rpc-url $RPC | awk '{print $1}')
TX=$(cast send $HUB "requestAttestation(bytes)" $REQ --value $FEE --private-key $PRIVATE_KEY --rpc-url $RPC --json)
BN=$(echo "$TX" | python3 -c "import sys,json;print(int(json.load(sys.stdin)['blockNumber'],16))")
TS=$(cast block $BN --rpc-url $RPC --json | python3 -c "import sys,json;print(int(json.load(sys.stdin)['timestamp'],16))")
ROUND=$(( (TS - T0) / DUR )); echo "   round=$ROUND fee=$FEE wei"

echo "== 4. Meanwhile: mandate → anchored false receipt → bond"
NOW=$(date +%s); MH=$(cast keccak "DELICTI mandate: may pay up to 5 XRP to $DESTADDR")
cast send $REG "commit(address,bytes32,bytes32,uint256,uint256,uint64,uint64)" $ME $MH 0x$(printf '%064d' 0) 0 5000000 $((NOW-120)) $((NOW+604800)) --private-key $PRIVATE_KEY --rpc-url $RPC --json >/dev/null
MID=$(( $(cast call $REG "nextId()(uint256)" --rpc-url $RPC | awk '{print $1}') - 1 ))
RH=$(cast keccak "x402_receipt: paid 1 XRP to $DESTADDR ref $REF")
LEAF="($RH,3,$SRC,$DEST,$AMT,$REF,$CLAIMED,$MID)"
LH=$(cast keccak "$(cast abi-encode 'f((bytes32,uint8,bytes32,bytes32,uint256,bytes32,uint64,uint256))' "$LEAF")")
SIB=$(cast keccak "sibling receipt: tool_call get_ftso_price")
if [[ "$LH" < "$SIB" ]]; then ROOT=$(cast keccak "$(cast concat-hex $LH $SIB)"); else ROOT=$(cast keccak "$(cast concat-hex $SIB $LH)"); fi
cast send $LOG "anchor(uint256,bytes32,uint64)" $MID $ROOT 2 --private-key $PRIVATE_KEY --rpc-url $RPC --json >/dev/null
cast send $BOND "post(uint256)" $MID --value 1ether --private-key $PRIVATE_KEY --rpc-url $RPC --json >/dev/null
echo "   mandateId=$MID leaf=$LH root=$ROOT bond=1 C2FLR"

echo "== 5. DA layer: wait for proof (round finalizes in ~3-5 min)"
for i in $(seq 1 20); do
  R=$(curl -s -m 30 -X POST "$DA_URL/api/v1/fdc/proof-by-request-round-raw" -H "X-API-KEY: $VERIFIER_API_KEY" -H "Content-Type: application/json" -d "{\"votingRoundId\":$ROUND,\"requestBytes\":\"$REQ\"}")
  if echo "$R" | grep -q '"response_hex"'; then break; fi; sleep 30
done
RESP=$(echo "$R" | python3 -c "import sys,json;print(json.load(sys.stdin)['response_hex'])")
MP=$(echo "$R" | python3 -c "import sys,json;print('['+','.join(json.load(sys.stdin)['proof'])+']')")
DATA=$(cast abi-decode "f()(bytes32,bytes32,uint64,uint64,(uint64,uint64,uint64,bytes32,uint256,bytes32,bool,bytes32),(uint64,uint64,uint64))" $RESP | sed -E 's/ \[[0-9.e]+\]//g' | python3 -c "import sys;l=[x.strip() for x in sys.stdin if x.strip()];print('('+','.join(l)+')')")

echo "== 6. Bond.challengeFalsePayment — two witnesses disagree → slash"
SIG="challengeFalsePayment(uint256,uint256,(bytes32,uint8,bytes32,bytes32,uint256,bytes32,uint64,uint256),bytes32[],(bytes32[],(bytes32,bytes32,uint64,uint64,(uint64,uint64,uint64,bytes32,uint256,bytes32,bool,bytes32),(uint64,uint64,uint64))))"
cast send $BOND "$SIG" $MID 0 "$LEAF" "[$SIB]" "($MP,$DATA)" --private-key $PRIVATE_KEY --rpc-url $RPC --json | python3 -c "import sys,json;d=json.load(sys.stdin);print('   tx',d['transactionHash'],'status',d['status'])"
echo "   bondOf=$(cast call $BOND 'bondOf(uint256)(uint256)' $MID --rpc-url $RPC) slashed=$(cast call $BOND 'slashed(uint256)(bool)' $MID --rpc-url $RPC) mandateLive=$(cast call $REG 'isLive(uint256)(bool)' $MID --rpc-url $RPC)"
