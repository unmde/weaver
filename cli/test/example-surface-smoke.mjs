import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { existsSync, rmSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const cli = join(repoRoot, "cli", "bin", "weaver.js");
// Every shipped example plus the measurement fixtures that scripts/ and docs/
// still drive. Each must check and bundle on a clean checkout.
const surfaces = [
  "examples/clock",
  "examples/system",
  "examples/pomodoro",
  "examples/now-playing",
  "examples/weather",
  "examples/noro-shell",
  "examples/noro-signal",
  "examples/visualizer",
  "test/fixtures/dpi-diagnostic",
  "test/fixtures/m4b-parity",
  "test/fixtures/m4b-synthetic",
  "test/fixtures/gradient-stack",
];

for (const surface of surfaces) {
  const source = join(repoRoot, surface);
  const dist = join(source, "dist");
  const distExisted = existsSync(dist);
  for (const command of ["check", "bundle"]) {
    const result = spawnSync(process.execPath, [cli, command, source], { cwd: repoRoot, encoding: "utf8" });
    assert.equal(result.status, 0, `${command} failed for ${surface}\nstdout:\n${result.stdout}\nstderr:\n${result.stderr}`);
  }
  assert.equal(existsSync(join(dist, "bundle.js")), true, `${surface} bundle is missing`);
  assert.equal(existsSync(join(dist, "widget.json")), true, `${surface} manifest is missing`);
  if (!distExisted) rmSync(dist, { recursive: true, force: true });
}

process.stdout.write(`Checked and bundled ${surfaces.length} portable widget surfaces.\n`);
