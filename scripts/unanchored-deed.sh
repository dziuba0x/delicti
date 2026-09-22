#!/usr/bin/env bash
# DELICTI — the deed nobody wrote down (SPEC §6.4), live on Coston2.
#
# Every other challenge starts from an anchored leaf, so it reaches only agents that had
# already confessed. This one reaches silence. You cannot prove a negative cheaply on-chain,
# so the burden is inverted: the challenger states the deed and stakes, the agent has a window
# to produce the receipt it claims to have written, and silence resolves against it.
#
#   MODE=silence (default): agent acts, never anchors → accuse → window closes → slash.
#   MODE=answer:            agent acts and anchors in time → accuse → answer → dismissed,
#                           and the accuser's stake goes to the principal.
#
# v0.8: the accusation is a challenge too — it publishes the case and its accuser earns the 10% —
# so it is committed before the attestation is requested (SPEC §6.7). Budget commitLead for it.
#
# The wait is real: anchorGrace then responseWindow, both read off the contract. Deploy the
# testnet Bond with short values (RESPONSE_WINDOW=600 ANCHOR_GRACE=300) or this takes 25 h.
#
# Requires: cast, curl, python3, .env with PRIVATE_KEY, COSTON2_RPC, VERIFIER_URL,
# VERIFIER_API_KEY, DA_URL.
set -euo pipefail
cd "$(dirname "$0")/.."; set -a; . ./.env; set +a
. scripts/lib/commit.sh
RPC=$COSTON2_RPC
REG=${REG:?set REG to the v0.6 MandateRegistry}
LOG=${LOG:?set LOG to the v0.6 AnchorLog}
BOND=${BOND:?set BOND to the v0.11 Vault (the address mandates name in Terms.bond)}
JUDGE_EVM=${JUDGE_EVM:?set JUDGE_EVM to the v0.11 JudgeEvm}
MERCHANT=${MERCHANT:-0x2222222222222222222222222222222222222222}
MODE=${MODE:-silence}
DEED=${DEED:-10000000000000000}   # 0.01 C2FLR — the deed itself is small; the point is that it is unrecorded
ME=$(cast wallet address --private-key "$PRIVATE_KEY")
FLARE_REG=0xaD67FE66660Fb8dFE9d6b1b4240d8650e30F6019
pad() { python3 -c "import sys;print('0x'+sys.argv[1].encode().hex().ljust(64,'0'))" "$1"; }
SRC=$(pad testFLR); ATYPE=$(pad EVMTransaction)
HUB=$(cast call $FLARE_REG "getContractAddressByName(string)(address)" FdcHub --rpc-url $RPC)
FEECFG=$(cast call $FLARE_REG "getContractAddressByName(string)(address)" FdcRequestFeeConfigurations --rpc-url $RPC)
FSM=$(cast call $FLARE_REG "getContractAddressByName(string)(address)" FlareSystemsManager --rpc-url $RPC)
T0=$(cast call $FSM "firstVotingRoundStartTs()(uint64)" --rpc-url $RPC | awk '{print $1}')
DUR=$(cast call $FSM "votingEpochDurationSeconds()(uint64)" --rpc-url $RPC | awk '{print $1}')
GRACE=$(cast call $JUDGE_EVM "anchorGrace()(uint64)" --rpc-url $RPC | awk '{print $1}')
WINDOW=$(cast call $JUDGE_EVM "responseWindow()(uint64)" --rpc-url $RPC | awk '{print $1}')
STAKE=$(cast call $BOND "ACCUSATION_STAKE()(uint256)" --rpc-url $RPC | awk '{print $1}')
LEAD=$(cast call $BOND "commitLead()(uint64)" --rpc-url $RPC | awk '{print $1}')
echo "mode=$MODE anchorGrace=${GRACE}s responseWindow=${WINDOW}s commitLead=${LEAD}s stake=$STAKE wei"

echo "== 1. mandate + exclusivity + bond"
NOW=$(date +%s)
Z32=0x$(printf '%064d' 0)  # v0.9 terms: (sourceId, assetKey, agentRef, bond) — asset and source live in the mandate
cast send $REG "commit(address,bytes32,bytes32,uint256,uint256,uint64,uint64,(bytes32,bytes32,bytes32,address))" $ME "$(cast keccak "exclusive: every deed from this address is anchored")" 0x$(printf '%064d' 0) 0 1000000000000000000 $((NOW-120)) $((NOW+604800)) "($SRC,$Z32,$Z32,$BOND)" --private-key $PRIVATE_KEY --rpc-url $RPC --json >/dev/null
MID=$(( $(cast call $REG "nextId()(uint256)" --rpc-url $RPC | awk '{print $1}') - 1 ))
cast send $REG "declareExclusive(uint256)" $MID --private-key $PRIVATE_KEY --rpc-url $RPC --json >/dev/null
cast send $REG "acknowledge(uint256)" $MID --private-key $PRIVATE_KEY --rpc-url $RPC --json >/dev/null   # the agent accepts the mandate; Bond refuses collateral without it
cast send $BOND "post(uint256)" $MID --value 1ether --private-key $PRIVATE_KEY --rpc-url $RPC --json >/dev/null
echo "   mandateId=$MID exclusive=$(cast call $REG 'exclusive(uint256)(bool)' $MID --rpc-url $RPC) bond=1 C2FLR"

echo "== 2. the deed"
TX=$(cast send $MERCHANT --value $DEED --private-key $PRIVATE_KEY --rpc-url $RPC --json)
TXH=$(echo "$TX" | python3 -c "import sys,json;print(json.load(sys.stdin)['transactionHash'])")
BN=$(echo "$TX" | python3 -c "import sys,json;print(int(json.load(sys.stdin)['blockNumber'],16))")
TS=$(cast block $BN --rpc-url $RPC --json | python3 -c "import sys,json;print(int(json.load(sys.stdin)['timestamp'],16))")
echo "   tx=$TXH at $TS"

if [ "$MODE" = answer ]; then
  RH=$(cast keccak "receipt for $TXH"); DESTH=0x$(printf '%024d' 0)${MERCHANT#0x}
  LEAF="($RH,2,$SRC,$DESTH,$DEED,$TXH,$TS,$MID)"
  LH=$(cast keccak "$(cast abi-encode 'f((bytes32,uint8,bytes32,bytes32,uint256,bytes32,uint64,uint256))' "$LEAF")")
  cast send $LOG "anchor(uint256,bytes32,uint64)" $MID $LH 1 --private-key $PRIVATE_KEY --rpc-url $RPC --json >/dev/null
  echo "   anchored in time: leaf=$LH (episode 0)"
else
  echo "   NOT anchored — this is the silence"
fi

echo "== 3. commit the accusation, wait out commitLead, then prove the deed via FDC"
delicti_commit $BOND 4 $MID "$TXH"
HONEST_SALT=$DELICTI_SALT
delicti_wait_lead $BOND $T0 $DUR
BODY=$(printf '{"attestationType":"%s","sourceId":"%s","requestBody":{"transactionHash":"%s","requiredConfirmations":"1","provideInput":false,"listEvents":false,"logIndices":[]}}' "$ATYPE" "$SRC" "$TXH")
REQ=$(curl -s -m 60 -X POST "$VERIFIER_URL/verifier/flr/EVMTransaction/prepareRequest" -H "X-API-KEY: $VERIFIER_API_KEY" -H "Content-Type: application/json" -d "$BODY" | python3 -c "import sys,json;d=json.load(sys.stdin);assert d['status']=='VALID',d;print(d['abiEncodedRequest'])")
FEE=$(cast call $FEECFG "getRequestFee(bytes)(uint256)" $REQ --rpc-url $RPC | awk '{print $1}')
STX=$(cast send $HUB "requestAttestation(bytes)" $REQ --value $FEE --private-key $PRIVATE_KEY --rpc-url $RPC --json)
SBN=$(echo "$STX" | python3 -c "import sys,json;print(int(json.load(sys.stdin)['blockNumber'],16))")
STS=$(cast block $SBN --rpc-url $RPC --json | python3 -c "import sys,json;print(int(json.load(sys.stdin)['timestamp'],16))")
ROUND=$(( (STS - T0) / DUR ))
T="((bytes32,bytes32,uint64,uint64,(bytes32,uint16,bool,bool,uint32[]),(uint64,uint64,address,bool,address,uint256,bytes,uint8,(uint32,address,bytes32[],bytes,bool)[])))"
# The DA layer answers `attestation request not found` until the round finalises. How long
# that takes is not ours to control, so be patient and, if it never lands, say what it said —
# a bare KeyError tells you nothing about whether the round, the request or the network failed.
TRIES=${POLL_TRIES:-40}
echo "   polling DA for round $ROUND (up to $((TRIES*20))s)"
for t in $(seq 1 $TRIES); do
  R=$(curl -s -m 30 -X POST "$DA_URL/api/v1/fdc/proof-by-request-round-raw" -H "X-API-KEY: $VERIFIER_API_KEY" -H "Content-Type: application/json" -d "{\"votingRoundId\":$ROUND,\"requestBytes\":\"$REQ\"}")
  echo "$R" | grep -q '"response_hex"' && { echo "   proof arrived after $((t*20))s"; break; }
  [ $((t % 5)) -eq 0 ] && echo "   ...${t}/${TRIES}: $(echo "$R" | head -c 160)"
  sleep 20
done
if ! echo "$R" | grep -q '"response_hex"'; then
  echo "   DA never returned a proof for round $ROUND. Last answer:"; echo "$R" | head -c 500; echo
  echo "   The attestation request is already paid for, so re-poll it later with:"
  echo "   curl -s -X POST \"$DA_URL/api/v1/fdc/proof-by-request-round-raw\" -H \"X-API-KEY: $VERIFIER_API_KEY\" -H 'Content-Type: application/json' -d '{\"votingRoundId\":$ROUND,\"requestBytes\":\"$REQ\"}'"
  exit 1
fi
RESP=$(echo "$R" | python3 -c "import sys,json;print(json.load(sys.stdin)['response_hex'])")
MP=$(echo "$R" | python3 -c "import sys,json;print('['+','.join(json.load(sys.stdin)['proof'])+']')")
DATA=$(cast abi-decode "f()$T" $RESP | sed -E 's/([0-9]) \[[0-9.e]+\]/\1/g')
echo "   proof ok (round $ROUND)"

echo "== 4. wait out the anchor grace, then accuse"
WAIT=$(( TS + GRACE + 5 - $(date +%s) )); [ $WAIT -gt 0 ] && { echo "   sleeping ${WAIT}s"; sleep $WAIT; }
TI="${T:1:-1}"
ACC=$(cast send $JUDGE_EVM "accuseUnanchoredDeed(uint256,(bytes32[],$TI),bytes32)" $MID "($MP,$DATA)" "$HONEST_SALT" --value $STAKE --private-key $PRIVATE_KEY --rpc-url $RPC --json)
echo "$ACC" | python3 -c "import sys,json;d=json.load(sys.stdin);print('   accusation tx',d['transactionHash'],'status',d['status'],'gas',int(d['gasUsed'],16))"
AID=$(( $(cast call $JUDGE_EVM "nextAccusationId()(uint256)" --rpc-url $RPC | awk '{print $1}') - 1 ))
echo "   accusationId=$AID deadline=$(cast call $JUDGE_EVM 'accusations(uint256)(uint256,bytes32,uint64,uint64,address,bool,uint256)' $AID --rpc-url $RPC | sed -n '4p')"

if [ "$MODE" = answer ]; then
  echo "== 5. the agent answers with the receipt"
  cast send $JUDGE_EVM "answerAccusation(uint256,uint256,(bytes32,uint8,bytes32,bytes32,uint256,bytes32,uint64,uint256),bytes32[])" $AID 0 "$LEAF" "[]" --private-key $PRIVATE_KEY --rpc-url $RPC --json | python3 -c "import sys,json;d=json.load(sys.stdin);print('   answer tx',d['transactionHash'],'status',d['status'],'gas',int(d['gasUsed'],16))"
  echo "   slashed=$(cast call $BOND 'slashed(uint256)(bool)' $MID --rpc-url $RPC) (expected false) — accuser's stake forfeited to the principal"
else
  echo "== 5. wait out the response window — nobody answers"
  sleep $((WINDOW + 10))
  cast send $JUDGE_EVM "resolveAccusation(uint256)" $AID --private-key $PRIVATE_KEY --rpc-url $RPC --json | python3 -c "import sys,json;d=json.load(sys.stdin);print('   resolve tx',d['transactionHash'],'status',d['status'],'gas',int(d['gasUsed'],16))"
  echo "   bondOf=$(cast call $BOND 'bondOf(uint256)(uint256)' $MID --rpc-url $RPC) slashed=$(cast call $BOND 'slashed(uint256)(bool)' $MID --rpc-url $RPC) mandateLive=$(cast call $REG 'isLive(uint256)(bool)' $MID --rpc-url $RPC)"
  echo "   owed(ME)=$(cast call $BOND 'owed(address)(uint256)' $ME --rpc-url $RPC)"
fi
