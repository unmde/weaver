#!/usr/bin/env node

import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { readFileSync, readdirSync } from "node:fs";
import { dirname, extname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const expectedNativeCommit = "7368f7f59e09c372311e884190d88006a73ce97f";

function filesBelow(root) {
  const output = [];
  for (const entry of readdirSync(root, { withFileTypes: true })) {
    const path = join(root, entry.name);
    if (entry.isDirectory()) output.push(...filesBelow(path));
    else if (entry.isFile()) output.push(path);
  }
  return output;
}

function textFiles(root) {
  return filesBelow(root).filter((path) => [".ts", ".tsx", ".zig", ".c", ".h", ".m", ".md"].includes(extname(path)) || path.endsWith(".d.ts"));
}

function assertAbsent(paths, expression, description) {
  const matches = [];
  for (const path of paths) {
    const lines = readFileSync(path, "utf8").split(/\r?\n/u);
    for (const [index, line] of lines.entries()) {
      if (expression.test(line)) matches.push(`${relative(repoRoot, path)}:${index + 1}: ${line.trim()}`);
      expression.lastIndex = 0;
    }
  }
  assert.deepEqual(matches, [], `${description}:\n${matches.join("\n")}`);
}

function numericConstant(source, name) {
  const match = source.match(new RegExp(`\\b(?:pub\\s+)?const\\s+${name}(?::[^=]+)?\\s*=\\s*([\\d_]+)\\s*;`, "u"));
  assert.ok(match, `numeric constant ${name} was not found`);
  return Number(match[1].replaceAll("_", ""));
}

const sdkFiles = [...textFiles(join(repoRoot, "sdk", "src")), join(repoRoot, "sdk", "index.d.ts"), join(repoRoot, "sdk", "CONTRACT.md")];
assertAbsent(
  sdkFiles,
  /\b(?:macOS|AppKit|Metal|NSWindow|MediaRemote|Core Audio|Win32|Windows)\b/u,
  "public SDK contains a platform implementation term",
);

const productFiles = ["cli/src", "host/src", "runtime/src"].flatMap((path) => textFiles(join(repoRoot, path)));
assertAbsent(productFiles, /\bMediaRemote\b/u, "production code references private MediaRemote");
assertAbsent(productFiles, /until the native host lands in PR\s+10/u, "production code retains a completed-port allowance");

const tracked = execFileSync("git", ["ls-files", "-z"], { cwd: repoRoot })
  .toString("utf8")
  .split("\0")
  .filter(Boolean);
const trackedBuildProducts = tracked.filter((path) =>
  path.includes("/.zig-cache/") || path.includes("/zig-out/") || path.includes("/node_modules/") || path.startsWith(".zig-cache/"));
assert.deepEqual(trackedBuildProducts, [], `tracked build products found:\n${trackedBuildProducts.join("\n")}`);

const nativeCommit = execFileSync("git", ["rev-parse", "HEAD"], { cwd: join(repoRoot, "runtime", "native-sdk") }).toString("utf8").trim();
assert.equal(nativeCommit, expectedNativeCommit, "Native SDK submodule is not pinned to the reviewed fork-stack head");

const treeSource = readFileSync(join(repoRoot, "runtime", "src", "tree.zig"), "utf8");
const runtimeMainSource = readFileSync(join(repoRoot, "runtime", "src", "main.zig"), "utf8");
const nativeWidgetLimitsSource = readFileSync(join(repoRoot, "runtime", "native-sdk", "src", "primitives", "canvas", "widget_limits.zig"), "utf8");
const cliSource = readFileSync(join(repoRoot, "cli", "src", "index.ts"), "utf8");
for (const [runtimeSource, runtimeName, cliName] of [
  [treeSource, "max_nodes", "nativeWidgetNodeLimit"],
  [nativeWidgetLimitsSource, "max_widget_depth", "nativeWidgetDepthLimit"],
  [treeSource, "max_children", "nativeWidgetChildLimit"],
  [treeSource, "max_text_bytes", "nativeWidgetTextByteLimit"],
  [treeSource, "max_source_bytes", "nativeWidgetSourceByteLimit"],
  [treeSource, "max_canvases", "nativeWidgetCanvasLimit"],
  [runtimeMainSource, "max_images", "nativeWidgetImageLimit"],
]) {
  assert.equal(
    numericConstant(cliSource, cliName),
    numericConstant(runtimeSource, runtimeName),
    `CLI ${cliName} drifted from runtime ${runtimeName}`,
  );
}

const plist = readFileSync(join(repoRoot, "host", "macos", "Info.plist"), "utf8");
assert.match(plist, /<key>CFBundleIdentifier<\/key>\s*<string>com\.sunkenintime\.weaver\.host<\/string>/u);
assert.match(plist, /<key>LSMinimumSystemVersion<\/key>\s*<string>14\.2<\/string>/u);
assert.match(plist, /<key>LSUIElement<\/key>\s*<true\/>/u);
assert.match(plist, /<key>NSAudioCaptureUsageDescription<\/key>\s*<string>[^<]+<\/string>/u);

const workflow = readFileSync(join(repoRoot, ".github", "workflows", "ci.yml"), "utf8");
for (const required of [
  "windows-latest",
  "macos-15",
  "macos-15-intel",
  "spikes/macos-media-observation/build.sh",
  "cli/test/macos-host-control-smoke.mjs",
  "cli/test/macos-host-smoke.mjs",
]) assert.ok(workflow.includes(required), `CI workflow is missing ${required}`);

process.stdout.write(`Release audit passed; Native SDK pinned at ${nativeCommit.slice(0, 8)} and no platform/private API leaked into the SDK.\n`);
