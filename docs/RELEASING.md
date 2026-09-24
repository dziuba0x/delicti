# Releasing

## npm

There are two packages:

| package | what | who imports it |
|---|---|---|
| [`@delicti/sdk`](../sdk) | the TypeScript client, the watchers, the sentinel and the `delicti-watch` CLI | integrators, watchers |
| [`delicti`](../packages/delicti) | `npx delicti …`, a thin launcher for the SDK's CLI | anyone with a terminal |

**Why the `@delicti` scope.** It is the protocol's name, not a person's, so the packages outlive whoever maintains them. An npm organization owns it, which means more maintainers can be added without moving the packages. Public packages under an organization are free. The unscoped `delicti` is published as well: it keeps the bare name from being squatted and gives the shortest possible `npx`.

**First release, by hand:**

1. `npm login`
2. Create the organization `delicti` at <https://www.npmjs.com/org/create> (free).
3. `bash scripts/release/npm-publish.sh` does a dry run: install, typecheck, 28 tests, and the tarball contents.
4. `bash scripts/release/npm-publish.sh --go` publishes.

**Later releases:** trusted publishing from GitHub Actions. There is no token in the repo, and every release carries npm provenance. See `scripts/release/publish.yml` for the three steps that enable it.

Versions follow the contracts: SDK `0.15.x` speaks to the v0.15 deployment on Coston2.
