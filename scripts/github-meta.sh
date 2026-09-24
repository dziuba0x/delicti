#!/usr/bin/env bash
# Keeps the GitHub page in step with the repo: About (description, homepage, topics) and a
# Release for every tag that has a CHANGELOG section. Idempotent: run it after every release.
# Needs the GitHub CLI, logged in (`gh auth status`). Nothing here touches code or funds.
set -euo pipefail
REPO="${REPO:-dziuba0x/delicti}"
cd "$(dirname "$0")/.."

gh auth status >/dev/null 2>&1 || { echo "gh is not logged in: run 'gh auth login' first"; exit 1; }

DESC="Accountability for autonomous AI agents: on-chain mandates & spending limits, Flare Data Connector (FDC) as independent witness on EVM + XRPL, proportional bond slashing, paid watchers. x402 · MCP · stablecoins. SPEC v1.0, live on Coston2."
TOPICS=(ai-agents autonomous-agents agent-security ai-safety accountability agentic-payments
        flare-network flare-data-connector xrpl x402 stablecoins mcp model-context-protocol
        erc-8004 solidity foundry attestation cross-chain slashing watchtower)

echo "== About"
gh repo edit "$REPO" --description "$DESC" --homepage "https://github.com/$REPO#readme"
# replace the topic set exactly (the API takes at most 20)
printf '%s\n' "${TOPICS[@]}" | python3 -c 'import json,sys; print(json.dumps({"names":[l.strip() for l in sys.stdin if l.strip()]}))' \
  | gh api -X PUT "repos/$REPO/topics" --input - >/dev/null
gh repo view "$REPO" --json description,repositoryTopics -q '.description, ([.repositoryTopics[].name] | join(" "))'

echo "== Releases"
notes_for() { # the CHANGELOG section of $1 (e.g. v0.15.0), heading excluded
  awk -v v="## $1 " 'index($0,v)==1{on=1;next} on&&/^## /{exit} on{print}' CHANGELOG.md
}
title_for() { grep -m1 "^## $1 " CHANGELOG.md | sed "s/^## //"; }
latest=$(git tag -l 'v*.*.*' --sort=-v:refname | head -1)
for tag in $(git tag -l 'v*.*.*' --sort=v:refname); do
  if gh release view "$tag" --repo "$REPO" >/dev/null 2>&1; then echo "  $tag: exists"; continue; fi
  body=$(notes_for "$tag")
  if [ -z "$body" ]; then echo "  $tag: no CHANGELOG section, skipped"; continue; fi
  flag=--latest=false; [ "$tag" = "$latest" ] && flag=--latest
  printf '%s\n\n---\nContracts, addresses and live transactions: [README](https://github.com/%s#contracts-v015-on-coston2) · [docs/DEPLOYMENTS.md](https://github.com/%s/blob/main/docs/DEPLOYMENTS.md). Testnet only, unaudited.\n' \
    "$body" "$REPO" "$REPO" > /tmp/delicti-notes.md
  gh release create "$tag" --repo "$REPO" --title "$(title_for "$tag")" --notes-file /tmp/delicti-notes.md --verify-tag $flag
  echo "  $tag: created"
done
gh release list --repo "$REPO" --limit 20
echo "done. The social preview image can only be set by hand: Settings → General → Social preview → assets/social-preview.png"
