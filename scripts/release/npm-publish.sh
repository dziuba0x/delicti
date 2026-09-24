#!/usr/bin/env bash
# Publish @delicti/sdk and the `delicti` launcher to npm, from Alan's machine.
#
#   bash scripts/release/npm-publish.sh           # dry run: build, test, show what would ship
#   bash scripts/release/npm-publish.sh --go      # publish for real
#
# Once, before the first run:
#   1. npm login                                        (your npm account)
#   2. create the free organization "delicti":   https://www.npmjs.com/org/create
#      (public packages under @delicti/* cost nothing; the org is what owns the scope)
set -euo pipefail
cd "$(dirname "$0")/../.."
GO="${1:-}"

command -v npm >/dev/null || { echo "npm is not installed"; exit 1; }
who=$(npm whoami 2>/dev/null) || { echo "not logged in: run  npm login  first"; exit 1; }
echo "npm user: $who"
if ! npm org ls delicti >/dev/null 2>&1; then
  echo "the npm organization 'delicti' does not exist or you are not in it."
  echo "create it (free): https://www.npmjs.com/org/create  — name: delicti"
  exit 1
fi

for name in @delicti/sdk delicti; do
  if npm view "$name" version >/dev/null 2>&1; then echo "$name exists on npm: $(npm view "$name" version)"; else echo "$name: not yet on npm"; fi
done

echo "== @delicti/sdk: install, typecheck, test, pack"
( cd sdk && npm ci --silent && npm run typecheck && npm test --silent && npm pack --dry-run 2>&1 | grep -E "name:|version:|package size|total files" )

if [ "$GO" != "--go" ]; then
  echo; echo "dry run only. To publish:  bash scripts/release/npm-publish.sh --go"; exit 0
fi

echo "== publishing @delicti/sdk"
( cd sdk && npm publish --access public )
echo "== publishing delicti (launcher)"
( cd packages/delicti && npm publish --access public )

echo; echo "done:"; npm view @delicti/sdk version; npm view delicti version
echo "try:  npx delicti status 12"
