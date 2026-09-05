import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const cli = fileURLToPath(new URL("../dist/index.js", import.meta.url));

function runCli(cwd, ...arguments_) {
  return spawnSync(process.execPath, [cli, ...arguments_], { cwd, encoding: "utf8" });
}

function fixture(source) {
  const root = mkdtempSync(join(tmpdir(), "weaver-canvas-size-"));
  const initialized = runCli(root, "init", "widget");
  assert.equal(initialized.status, 0, initialized.stderr);
  const widget = join(root, "widget");
  writeFileSync(join(widget, "widget.tsx"), source, "utf8");
  return { root, widget };
}

function source(canvas) {
  return `import { widget } from "@weaver/sdk";
export default widget({ name: "Canvas Size", size: [320, 200] }, () => (
  <column>${canvas}</column>
));
`;
}

test("check accepts a canvas sized by layout with a percentage width", () => {
  const { root, widget } = fixture(source(`<canvas class="w-full h-[71px]" fps={0} onFrame={() => {}} />`));
  try {
    const checked = runCli(root, "check", widget);
    assert.equal(checked.status, 0, checked.stderr);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("check accepts a canvas that grows into its row", () => {
  const { root, widget } = fixture(source(`<row class="w-full"><canvas class="w-0 grow h-[8px]" fps={0} onFrame={() => {}} /></row>`));
  try {
    const checked = runCli(root, "check", widget);
    assert.equal(checked.status, 0, checked.stderr);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("check accepts a canvas with no class at all", () => {
  const { root, widget } = fixture(source(`<canvas fps={0} onFrame={() => {}} />`));
  try {
    const checked = runCli(root, "check", widget);
    assert.equal(checked.status, 0, checked.stderr);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("check accepts a canvas with explicit pixel sizes", () => {
  const { root, widget } = fixture(source(`<canvas class="w-[312px] h-[71px]" fps={0} onFrame={() => {}} />`));
  try {
    const checked = runCli(root, "check", widget);
    assert.equal(checked.status, 0, checked.stderr);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("check accepts a canvas clipped by a rounded overflow-hidden ancestor", () => {
  const canvas = `<stack class="w-[312px] h-[71px] rounded-[16px] overflow-hidden"><canvas class="w-[312px] h-[71px]" fps={0} onFrame={() => {}} /></stack>`;
  const { root, widget } = fixture(source(canvas));
  try {
    const checked = runCli(root, "check", widget);
    assert.equal(checked.status, 0, checked.stderr);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("check rejects a canvas below an opacity ancestor", () => {
  const canvas = `<column class="opacity-50"><canvas class="w-[312px] h-[71px]" fps={0} onFrame={() => {}} /></column>`;
  const { root, widget } = fixture(source(canvas));
  try {
    const checked = runCli(root, "check", widget);
    assert.equal(checked.status, 1);
    assert.match(checked.stderr, /CanvasNeedsOpaqueAncestors/);
    assert.match(checked.stderr, /opacity <column> ancestor/);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("check follows conditional opacity through a component boundary", () => {
  const widgetSource = `import { widget } from "@weaver/sdk";
const faded = true;
function Surface() {
  return <canvas class="w-[312px] h-[71px]" fps={0} onFrame={() => {}} />;
}
export default widget({ name: "Conditional Canvas Opacity", size: [320, 200] }, () => (
  <column class={faded ? "opacity-50" : "opacity-100"}><Surface /></column>
));
`;
  const { root, widget } = fixture(widgetSource);
  try {
    const checked = runCli(root, "check", widget);
    assert.equal(checked.status, 1);
    assert.match(checked.stderr, /CanvasNeedsOpaqueAncestors/);
    assert.match(checked.stderr, /statically lowered component tree/);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("check accepts a rounded canvas clip across a component boundary", () => {
  const widgetSource = `import { widget } from "@weaver/sdk";
function Surface() {
  return <canvas class="w-[312px] h-[71px]" fps={0} onFrame={() => {}} />;
}
export default widget({ name: "Canvas Component", size: [320, 200] }, () => (
  <stack class="w-[312px] h-[71px] rounded-[16px] overflow-hidden"><Surface /></stack>
));
`;
  const { root, widget } = fixture(widgetSource);
  try {
    const checked = runCli(root, "check", widget);
    assert.equal(checked.status, 0, checked.stderr);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
