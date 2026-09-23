#!/usr/bin/env bash
# forge_green [forge args…] — run `forge test` and succeed only if the summary says nothing failed.
# Why not the exit code: the npm distribution of forge (@foundry-rs/forge, a Node shim) exits 0
# even when tests fail — setUp failures included. The native binary does not. Judge the output.
forge_green() {
  local log; log=$(mktemp)
  forge test "$@" > "$log" 2>&1
  local summary; summary=$(grep -E "^Ran [0-9]+ test suites?" "$log" | tail -1)
  echo "$summary"
  if [ -z "$summary" ] || ! echo "$summary" | grep -q " 0 failed" || grep -q "^\[FAIL" "$log"; then
    echo "forge test RED — see $log"; return 1
  fi
}
