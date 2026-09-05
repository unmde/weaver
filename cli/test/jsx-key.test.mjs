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
  const root = mkdtempSync(join(tmpdir(), "weaver-jsx-key-"));
  const initialized = runCli(root, "init", "widget");
  assert.equal(initialized.status, 0, initialized.stderr);
  const widget = join(root, "widget");
  writeFileSync(join(widget, "widget.tsx"), source, "utf8");
  return { root, widget };
}

test("check accepts key on mapped intrinsic elements", () => {
  const { root, widget } = fixture(`import { widget } from "@weaver/sdk";
const days = ["Mon", "Tue", "Wed"];
export default widget({ name: "Keyed Cells", size: [320, 200] }, () => (
  <row class="gap-2">
    {days.map((day) => (
      <column key={day} class="w-[40px]">
        <text key={\`label-\${day}\`} class="text-[11px]">{day}</text>
        <icon key={\`icon-\${day}\`} name="check" class="size-3" />
      </column>
    ))}
  </row>
));
`);
  try {
    const checked = runCli(root, "check", widget);
    assert.equal(checked.status, 0, checked.stderr);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
