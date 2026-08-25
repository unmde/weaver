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
  const root = mkdtempSync(join(tmpdir(), "weaver-visual-bounds-"));
  const initialized = runCli(root, "init", "widget");
  assert.equal(initialized.status, 0, initialized.stderr);
  const widget = join(root, "widget");
  writeFileSync(join(widget, "widget.tsx"), source, "utf8");
  return { root, widget };
}

test("check reports exact outsets when a root shadow exceeds config.size", () => {
  const source = `import { widget } from "@weaver/sdk";
function Surface() {
  return <stack class="size-full rounded-[24px] shadow-[0_16px_28px_0_#00000066]" />;
}
export default widget({ name: "Clipped Shadow", size: [100, 100] }, () => <Surface />);
`;
  const { root, widget } = fixture(source);
  try {
    const checked = runCli(root, "check", widget);
    assert.equal(checked.status, 1);
    assert.match(checked.stderr, /RootOutsetShadowClipped/);
    assert.match(checked.stderr, /left=28px, top=12px, right=28px, bottom=44px/);
    assert.match(checked.stderr, /painted bounds=156x156/);
    assert.match(checked.stderr, /expand config\.size/);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("check accepts a shadowed inner surface with measured transparent room", () => {
  const source = `import { widget } from "@weaver/sdk";
export default widget({ name: "Shadow Room", size: [156, 156] }, () => (
  <stack class="size-full pl-[28px] pt-[12px] pr-[28px] pb-[44px]">
    <stack class="w-[100px] h-[100px] rounded-[24px] shadow-[0_16px_28px_0_#00000066]" />
  </stack>
));
`;
  const { root, widget } = fixture(source);
  try {
    const checked = runCli(root, "check", widget);
    assert.equal(checked.status, 0, checked.stderr);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("check follows a full-size stack child that still reaches the window edge", () => {
  const source = `import { widget } from "@weaver/sdk";
export default widget({ name: "Nested Clipped Shadow", size: [100, 100] }, () => (
  <stack class="size-full rounded-[24px] overflow-hidden">
    <column class="size-full rounded-[24px] shadow-[0_16px_28px_0_#00000066]" />
  </stack>
));
`;
  const { root, widget } = fixture(source);
  try {
    const checked = runCli(root, "check", widget);
    assert.equal(checked.status, 1);
    assert.match(checked.stderr, /RootOutsetShadowClipped: root-surface <column>/);
    assert.match(checked.stderr, /missing: left=28px, top=12px, right=28px, bottom=44px/);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

for (const container of ["row", "column"]) {
  test(`check follows a lone full-size child through a ${container} root`, () => {
    const source = `import { widget } from "@weaver/sdk";
export default widget({ name: "Nested ${container} Shadow", size: [100, 100] }, () => (
  <${container} class="size-full">
    <panel class="size-full rounded-[24px] shadow-[0_16px_28px_0_#00000066]" />
  </${container}>
));
`;
    const { root, widget } = fixture(source);
    try {
      const checked = runCli(root, "check", widget);
      assert.equal(checked.status, 1);
      assert.match(checked.stderr, /RootOutsetShadowClipped: root-surface <panel>/);
      assert.match(checked.stderr, /missing: left=28px, top=12px, right=28px, bottom=44px/);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });
}

test("check accepts an inset shadow on a full-size root", () => {
  const source = `import { widget } from "@weaver/sdk";
export default widget({ name: "Inset Shadow", size: [100, 100] }, () => (
  <stack class="size-full rounded-[24px] shadow-[0_16px_28px_0_#00000066] shadow-inner" />
));
`;
  const { root, widget } = fixture(source);
  try {
    const checked = runCli(root, "check", widget);
    assert.equal(checked.status, 0, checked.stderr);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
