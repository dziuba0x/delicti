# Releasing

## npm: `@delicti-protocol/sdk`

The TypeScript client, the watchers, the sentinel and the CLI (`delicti`, alias `delicti-watch`), all in one package.

**Why this scope.** It is named after the protocol, not a person, so the package outlives whoever maintains it. An npm organization owns it, so maintainers can be added without moving it. The bare name `delicti` is refused by npm, because it is too similar to `del-cli`, so there is no unscoped package.

**First release, by hand:**

1. `npm login`, as a member of the org `delicti-protocol`.
2. `bash scripts/release/npm-publish.sh` runs a dry run: install, typecheck, 28 tests, and the tarball contents.
3. `bash scripts/release/npm-publish.sh --go` publishes.

**Later releases:** trusted publishing from GitHub Actions, with provenance and no token. `scripts/release/publish.yml` says how to enable it.
