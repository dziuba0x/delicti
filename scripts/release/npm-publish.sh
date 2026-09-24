#!/usr/bin/env bash
# Publish @delicti-protocol/sdk to npm, from Alan's machine.
#   bash scripts/release/npm-publish.sh        # dry run: build, test, show what would ship
#   bash scripts/release/npm-publish.sh --go   # publish for real
# Once: `npm login`, and be a member of the npm organization "delicti-protocol".
set -euo pipefail
cd "$(dirname "$0")/../.."
command -v npm >/dev/null || { echo "npm is not installed"; exit 1; }
who=$(npm whoami 2>/dev/null) || { echo "not logged in: run  npm login  first"; exit 1; }
echo "npm user: $who"
npm org ls delicti-protocol >/dev/null 2>&1 || { echo "you are not in the npm org 'delicti-protocol'"; exit 1; }
if npm view @delicti-protocol/sdk version >/dev/null 2>&1; then echo "on npm: $(npm view @delicti-protocol/sdk version)"; else echo "@delicti-protocol/sdk: not yet on npm"; fi
( cd sdk && npm ci --silent && npm run typecheck && npm test --silent && npm pack --dry-run 2>&1 | grep -E "name:|version:|package size|total files" )
[ "${1:-}" = "--go" ] || { echo; echo "dry run only. To publish:  bash scripts/release/npm-publish.sh --go"; exit 0; }
( cd sdk && npm publish --access public )
echo "published: $(npm view @delicti-protocol/sdk version)"
echo "try:  npx -p @delicti-protocol/sdk delicti status 12"
