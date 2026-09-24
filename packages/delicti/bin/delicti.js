#!/usr/bin/env node
// `npx delicti …` runs the @delicti/sdk command line (the same one installed as `delicti-watch`).
import { createRequire } from "node:module";
import { pathToFileURL } from "node:url";
import { dirname, join } from "node:path";

const require = createRequire(import.meta.url);
const sdkDir = dirname(require.resolve("@delicti/sdk/package.json"));
await import(pathToFileURL(join(sdkDir, "dist", "cli.js")).href);
