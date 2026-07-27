#!/usr/bin/env node
"use strict";

// Launcher for the `olk` CLI distributed via npm. The actual binary ships in a
// per-platform optional dependency (olk-<platform>-<arch>); npm installs only
// the one matching this host (via the package's "os"/"cpu" fields). We resolve
// that binary and exec it, forwarding args, stdio, and exit code.
//
// The platform package name is read from our own optionalDependencies rather
// than hardcoded, so the same launcher works for the unscoped npmjs.org
// packages and for a re-scoped build (e.g. @planmonster/olk-linux-x64 on an
// internal registry). See scripts/build-npm.mjs --scope.

const { execFileSync } = require("child_process");
const path = require("path");

function candidates() {
  const suffix = `olk-${process.platform}-${process.arch}`;
  const names = [];
  try {
    const self = require(path.join(__dirname, "..", "package.json"));
    for (const dep of Object.keys(self.optionalDependencies || {})) {
      if (dep === suffix || dep.endsWith(`/${suffix}`)) names.push(dep);
    }
  } catch (_) {
    // fall through to the unscoped default
  }
  if (!names.includes(suffix)) names.push(suffix);
  return names;
}

function binaryPath() {
  const exe = process.platform === "win32" ? "olk.exe" : "olk";
  const tried = candidates();
  for (const pkg of tried) {
    try {
      return require.resolve(`${pkg}/bin/${exe}`);
    } catch (_) {
      // try the next candidate
    }
  }
  throw new Error(
    `olk: no prebuilt binary for ${process.platform}-${process.arch}. ` +
      `The optional dependency "${tried[0]}" is missing — reinstall without ` +
      `--no-optional, or build from source (https://github.com/rlrghb/olkcli).`
  );
}

try {
  execFileSync(binaryPath(), process.argv.slice(2), { stdio: "inherit" });
} catch (err) {
  if (typeof err.status === "number") {
    process.exit(err.status);
  }
  if (err.message) {
    process.stderr.write(err.message + "\n");
  }
  process.exit(1);
}
