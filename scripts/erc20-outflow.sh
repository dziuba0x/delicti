#!/usr/bin/env bash
# DELICTI — §6.11 live on Coston2: a stablecoin agent convicted from the token's event log alone.
#
#   mandate: the agent may move up to 4 mUSDT0 out of its address; it declares the mandate
#            EXCLUSIVE and writes NO receipts.
#   deeds:   5 × 1 mUSDT0 x402 settlements (EIP-3009 transferWithAuthorization): the agent signs,
#            a separate FACILITATOR key sends. The agent is never a transaction's sender.
#   docket:  the first 3 settlements filed by anyone, uncommitted (3 ≤ 4: recorded, nothing judged),
#            with every log of each transaction listed (`logIndices: []`).
#   verdict: the last 2 committed (kind 8) BEFORE their attestations are requested, then filed:
#            the docket crosses 4 → the Vault slashes.
#
# Requires: cast, curl, python3, openssl, .env (PRIVATE_KEY, VERIFIER_*, DA_URL, REG, BOND=Vault,
# JUDGE_EVM). FAC_KEY is the facilitator's key; a fresh one is made and funded if unset.
set -euo pipefail
cd "$(dirname "$0")/.."; set -a; . ./.env; set +a
. scripts/lib/commit.sh
RPC=$COSTON2_RPC
BOND=${BOND:?set BOND to the v0.13 Vault}
JUDGE_EVM=${JUDGE_EVM:?set JUDGE_EVM to the v0.13 JudgeEvm}
TOKEN=${TOKEN:-0x9Eea43feA502609d0D88DAfd1d64B4e929BF18C2}   # MockUSDT0 (EIP-3009), 6 dec
PAYEE=${PAYEE:-0x2222222222222222222222222222222222222222}
N=5; EACH=1000000; BUDGET=4000000
ME=$(cast wallet address --private-key "$PRIVATE_KEY")   # the agent (and, here, the principal)
if [ -z "${FAC_KEY:-}" ]; then FAC_KEY=$(cast wallet new --json | python3 -c "import sys,json;print(json.load(sys.stdin)[0]['private_key'])"); fi
FAC=$(cast wallet address --private-key "$FAC_KEY")
FLARE_REG=0xaD67FE66660Fb8dFE9d6b1b4240d8650e30F6019
pad() { python3 -c "import sys;print('0x'+sys.argv[1].encode().hex().ljust(64,'0'))" "$1"; }
SRC=$(pad testFLR); ATYPE=$(pad EVMTransaction)
HUB=$(cast call $FLARE_REG "getContractAddressByName(string)(address)" FdcHub --rpc-url $RPC)
FEECFG=$(cast call $FLARE_REG "getContractAddressByName(string)(address)" FdcRequestFeeConfigurations --rpc-url $RPC)
FSM=$(cast call $FLARE_REG "getContractAddressByName(string)(address)" FlareSystemsManager --rpc-url $RPC)
T0=$(cast call $FSM "firstVotingRoundStartTs()(uint64)" --rpc-url $RPC | awk '{print $1}'); DUR=$(cast call $FSM "votingEpochDurationSeconds()(uint64)" --rpc-url $RPC | awk '{print $1}')
T="((bytes32,bytes32,uint64,uint64,(bytes32,uint16,bool,bool,uint32[]),(uint64,uint64,address,bool,address,uint256,bytes,uint8,(uint32,address,bytes32[],bytes,bool)[])))"
TI="${T:1:-1}"; FILE_SIG="fileErc20Outflow(uint256,(bytes32[],$TI)[],bytes32)"
OUT=$(mktemp -d); echo "work dir: $OUT"; echo "agent=$ME facilitator=$FAC"

# attest <txhash> → prints "<round> <abiEncodedRequest>"; every log of the transaction is listed
attest() {
  local body req fee stx sbn sts
  body=$(printf '{"attestationType":"%s","sourceId":"%s","requestBody":{"transactionHash":"%s","requiredConfirmations":"1","provideInput":false,"listEvents":true,"logIndices":[]}}' "$ATYPE" "$SRC" "$1")
  req=$(curl -s -m 60 -X POST "$VERIFIER_URL/verifier/flr/EVMTransaction/prepareRequest" -H "X-API-KEY: $VERIFIER_API_KEY" -H "Content-Type: application/json" -d "$body" | python3 -c "import sys,json;d=json.load(sys.stdin);assert d['status']=='VALID',d;print(d['abiEncodedRequest'])")
  fee=$(cast call $FEECFG "getRequestFee(bytes)(uint256)" $req --rpc-url $RPC | awk '{print $1}')
  stx=$(cast send $HUB "requestAttestation(bytes)" $req --value $fee --private-key $PRIVATE_KEY --rpc-url $RPC --json)
  sbn=$(echo "$stx" | python3 -c "import sys,json;print(int(json.load(sys.stdin)['blockNumber'],16))"); sts=$(cast block $sbn --rpc-url $RPC --json | python3 -c "import sys,json;print(int(json.load(sys.stdin)['timestamp'],16))")
  echo "$(( (sts - T0) / DUR )) $req"
}
# proof <round> <request> → prints the (merkleProof, data) tuple
proof() {
  local r resp mp data
  for t in $(seq 1 30); do
    r=$(curl -s -m 30 -X POST "$DA_URL/api/v1/fdc/proof-by-request-round-raw" -H "X-API-KEY: $VERIFIER_API_KEY" -H "Content-Type: application/json" -d "{\"votingRoundId\":$1,\"requestBytes\":\"$2\"}")
    echo "$r" | grep -q '"response_hex"' && break; sleep 20
  done
  resp=$(echo "$r" | python3 -c "import sys,json;print(json.load(sys.stdin)['response_hex'])")
  mp=$(echo "$r" | python3 -c "import sys,json;print('['+','.join(json.load(sys.stdin)['proof'])+']')")
  data=$(cast abi-decode "f()$T" $resp | sed -E 's/([0-9]) \[[0-9.e]+\]/\1/g')
  echo "($mp,$data)"
}

echo "== 1. mandate (4 mUSDT0 of outflow), declared EXCLUSIVE, bonded; facilitator funded"
NOW=$(date +%s); Z32=0x$(printf '%064d' 0)
cast send $REG "commit(address,bytes32,bytes32,uint256,uint256,uint64,uint64,(bytes32,bytes32,bytes32,address))" $ME "$(cast keccak "may move up to 4 mUSDT0 out of its address")" $Z32 0 $BUDGET $((NOW-120)) $((NOW+604800)) "($SRC,$(cast to-uint256 $TOKEN),$Z32,$BOND)" --private-key $PRIVATE_KEY --rpc-url $RPC --json >/dev/null
MID=$(( $(cast call $REG "nextId()(uint256)" --rpc-url $RPC | awk '{print $1}') - 1 )); echo "   mandateId=$MID"
cast send $REG "declareExclusive(uint256)" $MID --private-key $PRIVATE_KEY --rpc-url $RPC --json >/dev/null
cast send $BOND "post(uint256)" $MID --value 1ether --private-key $PRIVATE_KEY --rpc-url $RPC --json >/dev/null
BAL=$(cast call $TOKEN "balanceOf(address)(uint256)" $ME --rpc-url $RPC | awk '{print $1}')
[ "$BAL" -lt $((N*EACH)) ] && cast send $TOKEN "mint(address,uint256)" $ME $((N*EACH)) --private-key $PRIVATE_KEY --rpc-url $RPC --json >/dev/null
FB=$(cast balance $FAC --rpc-url $RPC)
[ "$FB" -lt 500000000000000000 ] && cast send $FAC --value 1ether --private-key $PRIVATE_KEY --rpc-url $RPC --json >/dev/null

echo "== 2. $N x402 settlements: the agent signs, the facilitator sends. No receipts."
declare -a TXS
for i in $(seq 0 $((N-1))); do
  NONCE=$(cast keccak "delicti-6.11-$MID-$i-$RANDOM"); VB=$((NOW+3600))
  cat > $OUT/td$i.json <<EOF
{"types":{"EIP712Domain":[{"name":"name","type":"string"},{"name":"version","type":"string"},{"name":"chainId","type":"uint256"},{"name":"verifyingContract","type":"address"}],"TransferWithAuthorization":[{"name":"from","type":"address"},{"name":"to","type":"address"},{"name":"value","type":"uint256"},{"name":"validAfter","type":"uint256"},{"name":"validBefore","type":"uint256"},{"name":"nonce","type":"bytes32"}]},"primaryType":"TransferWithAuthorization","domain":{"name":"Mock USDT0","version":"1","chainId":114,"verifyingContract":"$TOKEN"},"message":{"from":"$ME","to":"$PAYEE","value":"$EACH","validAfter":"0","validBefore":"$VB","nonce":"$NONCE"}}
EOF
  SIG=$(cast wallet sign --private-key $PRIVATE_KEY --data --from-file $OUT/td$i.json); R=${SIG:0:66}; S=0x${SIG:66:64}; V=$((16#${SIG:130:2}))
  TX=$(cast send $TOKEN "transferWithAuthorization(address,address,uint256,uint256,uint256,bytes32,uint8,bytes32,bytes32)" $ME $PAYEE $EACH 0 $VB $NONCE $V $R $S --private-key $FAC_KEY --rpc-url $RPC --json)
  TXS[$i]=$(echo "$TX" | python3 -c "import sys,json;print(json.load(sys.stdin)['transactionHash'])")
  echo "   settlement $i: ${TXS[$i]} (from=$(echo "$TX" | python3 -c "import sys,json;print(json.load(sys.stdin)['from'])"))"
done
SORTED=($(python3 -c "import sys;print(' '.join(sorted(sys.argv[1:],key=lambda t:int(t,16))))" "${TXS[@]}"))
HEAD=("${SORTED[@]:0:3}"); TAIL=("${SORTED[@]:3:2}")

echo "== 3. docket: the first 3, filed by the facilitator (anyone), uncommitted"
PRS="["
for h in "${HEAD[@]}"; do read RD RQ < <(attest $h); PRS+="$(proof $RD $RQ),"; echo "   attested $h (round $RD)"; done
PRS="${PRS%,}]"
cast send $JUDGE_EVM "$FILE_SIG" $MID "$PRS" $Z32 --private-key $FAC_KEY --rpc-url $RPC --json | python3 -c "import sys,json;d=json.load(sys.stdin);print('   filed tx',d['transactionHash'],'status',d['status'])"
echo "   erc20Docket=$(cast call $JUDGE_EVM 'erc20Docket(uint256)(uint256)' $MID --rpc-url $RPC) slashed=$(cast call $BOND 'slashed(uint256)(bool)' $MID --rpc-url $RPC)"

echo "== 4. commit the crossing (kind 8) over the last 2 — before their attestations exist"
delicti_commit $BOND 8 $MID "${TAIL[*]}"
delicti_wait_lead $BOND $T0 $DUR
PRS="["
for h in "${TAIL[@]}"; do read RD RQ < <(attest $h); PRS+="$(proof $RD $RQ),"; echo "   attested $h (round $RD)"; done
PRS="${PRS%,}]"

echo "== 5. the crossing filing: 5 × 1 > 4 mUSDT0"
cast send $JUDGE_EVM "$FILE_SIG" $MID "$PRS" $DELICTI_SALT --private-key $PRIVATE_KEY --rpc-url $RPC --json | python3 -c "import sys,json;d=json.load(sys.stdin);print('   tx',d['transactionHash'],'status',d['status'],'gas',int(d['gasUsed'],16))"
echo "   erc20Docket=$(cast call $JUDGE_EVM 'erc20Docket(uint256)(uint256)' $MID --rpc-url $RPC) bondOf=$(cast call $BOND 'bondOf(uint256)(uint256)' $MID --rpc-url $RPC) slashed=$(cast call $BOND 'slashed(uint256)(bool)' $MID --rpc-url $RPC) mandateLive=$(cast call $REG 'isLive(uint256)(bool)' $MID --rpc-url $RPC)"
