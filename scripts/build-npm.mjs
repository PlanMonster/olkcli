#!/usr/bin/env node
// Stamp versions across the npm wrapper packages and (optionally) publish them.
//
//   node scripts/build-npm.mjs <version> [options]
//
//   --publish                 npm publish (default: stamp only)
//   --scope @my-org           rename every package under an npm scope
//   --registry <url>          publish/lookup against a non-default registry
//   --repository owner/name   rewrite repository/homepage/bugs URLs
//   --access public|restricted
//   --tag <dist-tag>          publish under a dist-tag other than "latest"
//   --skip-binary-check       publish binary packages with no binary
//                             (one-time bootstrap only — see
//                             docs/npm-publishing.md)
//
// <version> may be "v0.9.2" or "0.9.2" (a leading "v" is stripped). Without
// --publish it only stamps versions (safe for local inspection / dry-run).
// With --publish it `npm publish`es each per-platform package first (so the
// main package's optionalDependencies already resolve), then the main `olk`
// package. The per-platform binaries must already be present in
// npm/olk-<os>-<arch>/bin/ (the release workflow extracts them there).
//
// Scoped mode exists for forks and internal registries: npmjs.org names
// (`olkcli`, `olk-linux-x64`, …) belong to the upstream project, and GitHub
// Packages requires the scope to equal the owning org. `--scope @planmonster
// --registry https://npm.pkg.github.com --repository PlanMonster/olkcli`
// produces `@planmonster/olkcli` + `@planmonster/olk-<os>-<arch>`.
// The launcher (npm/olk/bin/olk.js) resolves the platform package from its own
// optionalDependencies, so it needs no stamping and works in either mode.

import { readFileSync, writeFileSync, existsSync, readdirSync } from "node:fs";
import { execFileSync } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const npmDir = path.join(root, "npm");

const argv = process.argv.slice(2);
function flag(name) {
  const i = argv.indexOf(name);
  return i === -1 ? undefined : argv[i + 1];
}
// Like flag(), but when the flag is present it must be followed by a real
// value (not the end of argv, not another option). Returns undefined when the
// flag is absent.
function requireValue(name) {
  const i = argv.indexOf(name);
  if (i === -1) return undefined;
  const val = argv[i + 1];
  if (val === undefined || val.startsWith("-")) {
    console.error(`${name} requires a value`);
    process.exit(2);
  }
  return val;
}

const rawVersion = argv.find((a) => !a.startsWith("-")) || process.env.VERSION || process.env.GITHUB_REF_NAME;
if (!rawVersion) {
  console.error("usage: build-npm.mjs <version> [--publish] [--scope @org] [--registry url] [--repository owner/name]");
  process.exit(2);
}
const version = rawVersion.replace(/^v/, "");
const publish = argv.includes("--publish");
const registry = flag("--registry") || process.env.NPM_REGISTRY;
const repository = flag("--repository") || process.env.NPM_REPOSITORY;
const access = flag("--access") || process.env.NPM_ACCESS || "public";
// A placeholder or pre-release publish must not claim the "latest" tag, or a
// consumer running `npm i <pkg>` receives it. An explicit `--tag` must carry a
// real value: reject a missing or option-like one rather than silently falling
// back to NPM_TAG or forwarding the next flag (e.g. `--tag --publish`) as a
// dist-tag.
const distTag = requireValue("--tag") || process.env.NPM_TAG || "";
// npm Trusted Publishing can only be configured on a package that already
// exists, so the very first publish of each name has to happen by hand and may
// carry no binary. Never set this in the release workflow.
const skipBinaryCheck = argv.includes("--skip-binary-check");

let scope = flag("--scope") || process.env.NPM_SCOPE || "";
if (scope && !scope.startsWith("@")) scope = `@${scope}`;
if (scope.endsWith("/")) scope = scope.slice(0, -1);

const platformPkgs = readdirSync(npmDir).filter((d) => d.startsWith("olk-"));

// Re-scoping must be idempotent: drop any existing scope before applying ours.
function rename(name) {
  const bare = name.includes("/") ? name.slice(name.indexOf("/") + 1) : name;
  return scope ? `${scope}/${bare}` : bare;
}

function stamp(pkgDir, mutate) {
  const p = path.join(npmDir, pkgDir, "package.json");
  const json = JSON.parse(readFileSync(p, "utf8"));
  json.version = version;
  json.name = rename(json.name);
  if (repository) {
    // GitHub Packages links a package to a repo via this field and rejects
    // a publish whose repository does not match the pushing repo.
    json.repository = { type: "git", url: `git+https://github.com/${repository}.git` };
    json.homepage = `https://github.com/${repository}`;
    if (json.bugs) json.bugs = `https://github.com/${repository}/issues`;
  }
  if (registry) {
    json.publishConfig = { ...(json.publishConfig || {}), registry, access };
  }
  if (mutate) mutate(json);
  writeFileSync(p, JSON.stringify(json, null, 2) + "\n");
  return json.name;
}

for (const pkg of platformPkgs) stamp(pkg);
const mainName = stamp("olk", (json) => {
  const deps = {};
  for (const dep of Object.keys(json.optionalDependencies || {})) {
    deps[rename(dep)] = version;
  }
  json.optionalDependencies = deps;
  // `mcpName` claims an MCP Registry namespace derived from the upstream repo;
  // it is meaningless (and misleading) for a re-scoped/internal build.
  if (scope) delete json.mcpName;
});
console.log(
  `stamped ${mainName}@${version} + ${platformPkgs.length} platform packages` +
    (registry ? ` for ${registry}` : "")
);

if (!publish) {
  console.log("(stamp-only — pass --publish to npm publish)");
  process.exit(0);
}

function pkgName(pkgDir) {
  return JSON.parse(readFileSync(path.join(npmDir, pkgDir, "package.json"), "utf8")).name;
}

// Idempotent: skip a package@version that already exists, so re-running a
// partially-failed release (e.g. the registry step failed) does not error on
// "cannot publish over previously published version".
function alreadyPublished(name) {
  const args = ["view", `${name}@${version}`, "version"];
  if (registry) args.push("--registry", registry);
  try {
    return (
      execFileSync("npm", args, {
        encoding: "utf8",
        stdio: ["ignore", "pipe", "ignore"],
      }).trim() === version
    );
  } catch {
    return false;
  }
}

function npmPublish(pkgDir) {
  const name = pkgName(pkgDir);
  if (alreadyPublished(name)) {
    console.log(`skip ${name}@${version} (already published)`);
    return;
  }
  console.log(`publishing ${name}@${version} ...`);
  const args = ["publish", "--access", access];
  if (distTag) args.push("--tag", distTag);
  if (registry) args.push("--registry", registry);
  execFileSync("npm", args, {
    cwd: path.join(npmDir, pkgDir),
    stdio: "inherit",
  });
}

for (const pkg of platformPkgs) {
  const exe = pkg.includes("win32") ? "olk.exe" : "olk";
  if (!existsSync(path.join(npmDir, pkg, "bin", exe))) {
    if (!skipBinaryCheck) {
      console.error(`refusing to publish ${pkg}: missing bin/${exe}`);
      process.exit(1);
    }
    console.warn(`WARNING: ${pkg} has no bin/${exe} — publishing a placeholder`);
  }
  npmPublish(pkg);
}
npmPublish("olk");
console.log("done");
