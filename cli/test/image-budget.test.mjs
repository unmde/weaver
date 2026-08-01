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

function pngHeader(width, height) {
  const bytes = Buffer.alloc(24);
  Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]).copy(bytes);
  bytes.writeUInt32BE(width, 16);
  bytes.writeUInt32BE(height, 20);
  return bytes;
}

function fixture(width, height, source = "./cover.png") {
  const root = mkdtempSync(join(tmpdir(), "weaver-image-budget-"));
  const initialized = runCli(root, "init", "widget");
  assert.equal(initialized.status, 0, initialized.stderr);
  const widget = join(root, "widget");
  writeFileSync(join(widget, "cover.png"), pngHeader(width, height));
  writeFileSync(
    join(widget, "widget.tsx"),
    `import { widget } from "@weaver/sdk";
export default widget({ name: "Image Budget", size: [320, 200] }, () => (
  <image src=${JSON.stringify(source)} class="w-[256px] h-[256px]" />
));
`,
    "utf8",
  );
  return { root, widget };
}

test("check reports exact decoded RGBA image budget math", () => {
  const { root, widget } = fixture(513, 512);
  try {
    const checked = runCli(root, "check", widget);
    assert.equal(checked.status, 1);
    assert.match(checked.stderr, /ImageTooLarge/);
    assert.match(checked.stderr, /513 \* 512 \* 4 = 1050624 bytes/);
    assert.match(checked.stderr, /max_image_rgba_bytes=1048576 by 2048 bytes/);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("check accepts an image exactly at the decoded RGBA budget", () => {
  const { root, widget } = fixture(512, 512);
  try {
    const checked = runCli(root, "check", widget);
    assert.equal(checked.status, 0, checked.stderr);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("check rejects an oversized encoded image before decoding it", () => {
  const { root, widget } = fixture(256, 256);
  try {
    writeFileSync(join(widget, "cover.png"), Buffer.alloc(2 * 1024 * 1024 + 1));
    const checked = runCli(root, "check", widget);
    assert.equal(checked.status, 1);
    assert.match(checked.stderr, /ImageStreamTooLarge/);
    assert.match(checked.stderr, /max_image_stream_bytes=2097152, asked for 2097153/);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("source budget accepts exactly max_source_bytes using UTF-8 byte length", () => {
  const source = "é".repeat(512);
  assert.equal(Buffer.byteLength(source, "utf8"), 1024);
  const { root, widget } = fixture(256, 256, source);
  try {
    const checked = runCli(root, "check", widget);
    assert.equal(checked.status, 1);
    assert.doesNotMatch(checked.stderr, /ImageSourceTooLong/);
    assert.match(checked.stderr, /ImageAssetUnreadable/);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("check rejects a static image source one UTF-8 byte over max_source_bytes", () => {
  const source = `${"é".repeat(512)}a`;
  assert.equal(Buffer.byteLength(source, "utf8"), 1025);
  const { root, widget } = fixture(256, 256, source);
  try {
    const checked = runCli(root, "check", widget);
    assert.equal(checked.status, 1);
    assert.match(checked.stderr, /ImageSourceTooLong/);
    assert.match(checked.stderr, /max_source_bytes=1024, asked for 1025, headroom=-1/);
    assert.doesNotMatch(checked.stderr, /ImageAssetUnreadable/);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
