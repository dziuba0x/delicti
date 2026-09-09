#!/usr/bin/env bash
# DELICTI — live test of the effector-side brake (SPEC §7) through flario.
#
# FDC finality is minutes, so DELICTI's consequence is after the fact. The brake
# is the cheap half: the effector reads MandateRegistry.isLive() before the funds
# move. Four cases, all against a real running flario MCP server:
#
#   0. live mandate, correct agent  → PAID          (positive control)
#   1. no mandate_id at all         → REFUSED       (DELICTI_REQUIRE_MANDATE=1)
#   2. revoked mandate              → REFUSED
#   3. someone else's mandate       → REFUSED       (payer is not the agent)
#
# Cases 1–3 must also leave the token balance untouched: a refusal that still
# moves money is not a brake.
#
# Requires: same env as scripts/mcp-structuring.sh.
set -euo pipefail
cd "$(dirname "$0")/.."; set -a; . ./.env; set +a
RPC=$COSTON2_RPC
FLARIO_DIR=${FLARIO_DIR:-../flario}
REG=${REG:-0x1e85be1CD6D499f5E8AE12C6Fa1336949188FbB7}
TOKEN=${TOKEN:-0x9Eea43feA502609d0D88DAfd1d64B4e929BF18C2}
PAYEE=${PAYEE:-0x2222222222222222222222222222222222222222}
STRANGER=${STRANGER:-0x000000000000000000000000000000000000dEaD}
PRICE=${PRICE:-1}; EACH=1000000
ME=$(cast wallet address --private-key "$PRIVATE_KEY")
OUT=$(mktemp -d); NOW=$(date +%s); ZERO=0x$(printf '%064d' 0)
newid() { echo $(( $(cast call $REG "nextId()(uint256)" --rpc-url $RPC | awk '{print $1}') - 1 )); }
bal() { cast call $TOKEN "balanceOf(address)(uint256)" $ME --rpc-url $RPC | awk '{print $1}'; }

run() { # run <label> <mandate_id|""> <expect: PAID|REFUSED>
  local label="$1" mid="$2" expect="$3" before after rc=0
  before=$(bal)
  ( cd "$FLARIO_DIR" && \
    X402_ENABLED=true X402_NETWORK=coston2 X402_PAY_TO=$PAYEE X402_TOKEN_ADDRESS=$TOKEN \
    X402_PRICE_DEFAULT=$PRICE X402_TOKEN_DECIMALS=6 X402_TOKEN_EIP712_VERSION=1 \
    FLARE_PRIVATE_KEY=$PRIVATE_KEY X402_CLIENT_PRIVATE_KEY=$PRIVATE_KEY \
    DELICTI_REGISTRY=$REG DELICTI_REQUIRE_MANDATE=1 \
    MANDATE_ID="$mid" N=1 OUT_DIR="$OUT/$label" \
    EXPECT_REFUSAL=$([ "$expect" = REFUSED ] && echo 1 || echo 0) \
    npx tsx scripts/x402-agent.ts ) || rc=$?
  after=$(bal)
  if [ "$expect" = REFUSED ] && [ "$before" != "$after" ]; then
    echo "   !! $label: refused but balance moved ($before → $after) — BRAKE BROKEN"; exit 1
  fi
  [ $rc -eq 0 ] && echo "   ✓ $label: $expect as expected (balance $before → $after)" \
                || { echo "   !! $label: expected $expect, got the opposite"; exit 1; }
}

echo "== mint if needed"
[ "$(bal)" -lt $((3*EACH)) ] && cast send $TOKEN "mint(address,uint256)" $ME $((5*EACH)) --private-key $PRIVATE_KEY --rpc-url $RPC --json >/dev/null

echo "== case 0: live mandate, correct agent → PAID"
cast send $REG "commit(address,bytes32,bytes32,uint256,uint256,uint64,uint64)" $ME "$(cast keccak "brake test: live")" $ZERO 0 $((10*EACH)) $((NOW-120)) $((NOW+86400)) --private-key $PRIVATE_KEY --rpc-url $RPC --json >/dev/null
LIVE=$(newid); run live "$LIVE" PAID

echo "== case 1: no mandate_id (DELICTI_REQUIRE_MANDATE=1) → REFUSED"
run nomandate "" REFUSED

echo "== case 2: revoked mandate → REFUSED"
cast send $REG "commit(address,bytes32,bytes32,uint256,uint256,uint64,uint64)" $ME "$(cast keccak "brake test: revoked")" $ZERO 0 $((10*EACH)) $((NOW-120)) $((NOW+86400)) --private-key $PRIVATE_KEY --rpc-url $RPC --json >/dev/null
DEAD=$(newid)
cast send $REG "revoke(uint256)" $DEAD --private-key $PRIVATE_KEY --rpc-url $RPC --json >/dev/null
echo "   mandate $DEAD isLive=$(cast call $REG 'isLive(uint256)(bool)' $DEAD --rpc-url $RPC)"
run revoked "$DEAD" REFUSED

echo "== case 3: someone else's mandate → REFUSED"
cast send $REG "commit(address,bytes32,bytes32,uint256,uint256,uint64,uint64)" $STRANGER "$(cast keccak "brake test: stranger")" $ZERO 0 $((10*EACH)) $((NOW-120)) $((NOW+86400)) --private-key $PRIVATE_KEY --rpc-url $RPC --json >/dev/null
OTHER=$(newid); echo "   mandate $OTHER belongs to $STRANGER, payer is $ME"
run borrowed "$OTHER" REFUSED

echo "ALL FOUR CASES BEHAVED. refusals + receipt in $OUT"
