#!/usr/bin/env bash
# DELICTI — commit–reveal helper (SPEC §6.7). Sourced by every challenge script.
#
# A challenge has to be committed before the FDC voting round that produces its evidence even
# begins, by at least `Bond.commitLead()`. So every script now runs in this order:
#
#     deeds → anchors → delicti_commit → delicti_wait_lead → requestAttestation → DA → reveal
#
# The encoding is done by the contract's own pure helpers (`deedsDigest`, `commitmentFor`) rather
# than by hand. That is deliberate: challenge signatures live in shell strings the compiler never
# checks (claude/11), and a digest computed two ways is a digest that silently drifts apart.
#
# Requires from the caller: RPC, PRIVATE_KEY, ME.
# Sets: DELICTI_SALT, DELICTI_DIGEST, DELICTI_COMMITMENT, DELICTI_COMMIT_TS.

# delicti_commit <BOND> <KIND> <MANDATE_ID> "<deedId> [deedId ...]" [SALT]
#   deedIds: the receipt leaf hash for KIND=1, otherwise the deeds' transaction hashes in exactly
#            the order the challenge will supply them (ascending, for the multi-deed paths).
delicti_commit() {
  local bond=$1 kind=$2 mid=$3 ids=$4 salt=${5:-}
  local arr count
  arr="[$(echo $ids | tr -s ' ' ',' | sed 's/^,//;s/,$//')]"
  count=$(echo $ids | wc -w)
  # 256 real bits. `$RANDOM` is 15 bits and `$mid`/`$kind`/`committedAt` are all public, so a
  # derived salt would leave the commitment brute-forceable in ~2^51 — which does not let anyone
  # steal the challenge (the challenger's address is in the preimage) but tells them WHICH case is
  # about to be filed, commitLead minutes before `requestAttestation` would have. That is the
  # mechanism running backwards.
  [ -n "$salt" ] || salt=$(cast keccak 0x"$(openssl rand -hex 32)")
  DELICTI_SALT=$salt
  DELICTI_DIGEST=$(cast call "$bond" "deedsDigest(bytes32[])(bytes32)" "$arr" --rpc-url "$RPC")
  DELICTI_COMMITMENT=$(cast call "$bond" "commitmentFor(address,uint256,uint8,bytes32,bytes32)(bytes32)" \
    "$ME" "$mid" "$kind" "$DELICTI_DIGEST" "$DELICTI_SALT" --rpc-url "$RPC")
  cast send "$bond" "commitChallenge(bytes32)" "$DELICTI_COMMITMENT" \
    --private-key "$PRIVATE_KEY" --rpc-url "$RPC" --json >/dev/null
  DELICTI_COMMIT_TS=$(cast call "$bond" "committedAt(bytes32)(uint64)" "$DELICTI_COMMITMENT" \
    --rpc-url "$RPC" | awk '{print $1}')
  echo "   committed kind=$kind over $count deed(s): $DELICTI_COMMITMENT at t=$DELICTI_COMMIT_TS"
}

# delicti_wait_lead <BOND> <T0> <DUR>
#   Sleep until the next voting round that begins at or after commitTs + commitLead. Requesting
#   the attestation before that moment would make our own proof unusable: the reveal compares the
#   commitment against the START of the round the request landed in, not against the request time.
delicti_wait_lead() {
  local bond=$1 t0=$2 dur=$3
  local lead r target now wait ttl
  lead=$(cast call "$bond" "commitLead()(uint64)" --rpc-url "$RPC" | awk '{print $1}')
  r=$(( ( (DELICTI_COMMIT_TS + lead) - t0 + dur - 1 ) / dur ))
  target=$(cast call "$bond" "roundStartTs(uint64)(uint64)" "$r" --rpc-url "$RPC" | awk '{print $1}')
  now=$(date +%s)
  # The window is [commitLead, COMMIT_TTL]. Blowing the far end is the failure mode nobody expects,
  # because it only bites when something else already went slowly, so say it out loud here.
  ttl=$(cast call "$bond" "COMMIT_TTL()(uint64)" --rpc-url "$RPC" | awk '{print $1}')
  if [ $(( target - DELICTI_COMMIT_TS )) -gt "$ttl" ]; then
    echo "   !! commitment would be stale by the target round (TTL ${ttl}s) — re-commit and retry"; return 1
  fi
  # +10 s of slack: the request has to be MINED in round r or later, and the local clock is not
  # the chain's clock. Landing a round late costs nothing; landing a second early costs the run.
  wait=$(( target - now + 10 ))
  echo "   commitLead=${lead}s → attestations may not be requested before t=$target (round $r)"
  if [ "$wait" -gt 0 ]; then echo "   sleeping ${wait}s"; sleep "$wait"; fi
}
