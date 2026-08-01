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

function fixture(source, files = {}) {
  const root = mkdtempSync(join(tmpdir(), "weaver-lowered-budget-"));
  const initialized = runCli(root, "init", "widget");
  assert.equal(initialized.status, 0, initialized.stderr);
  const widget = join(root, "widget");
  writeFileSync(join(widget, "widget.tsx"), source, "utf8");
  for (const [name, contents] of Object.entries(files)) writeFileSync(join(widget, name), contents, "utf8");
  return { root, widget };
}

function source(tree) {
  return `import { widget } from "@weaver/sdk";
export default widget({ name: "Lowered Budget", size: [320, 200] }, () => (${tree}));
`;
}

test("check rejects node counts after painted row and column lowering", () => {
  const groups = Array.from({ length: 16 }, (_, group) =>
    `<column key="g${group}">${Array.from({ length: 32 }, (_, child) => `<row key="r${group}-${child}" class="bg-[#111]" />`).join("")}</column>`,
  ).join("");
  const { root, widget } = fixture(source(`<column>${groups}</column>`));
  try {
    const checked = runCli(root, "check", widget);
    assert.equal(checked.status, 1);
    assert.match(checked.stderr, /LoweredWidgetNodeLimit: this tree lowers to 1041 Native nodes \(limit 1024\)/);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("check rejects depth after painted layout lowering", () => {
  let tree = "<text>leaf</text>";
  for (let index = 0; index < 16; index += 1) tree = `<row class="border">${tree}</row>`;
  const { root, widget } = fixture(source(tree));
  try {
    const checked = runCli(root, "check", widget);
    assert.equal(checked.status, 1);
    assert.match(checked.stderr, /LoweredWidgetDepthLimit: this tree lowers to depth 33 \(Native limit 32\)/);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("check budgets only the exported widget's reachable tree", () => {
  const dead = `<column>${Array.from({ length: 1024 }, () => "<row />").join("")}</column>`;
  const widgetSource = `import { widget } from "@weaver/sdk";
const DeadPreview = () => (${dead});
export default widget({ name: "Reachable Budget", size: [320, 200] }, () => <text>live</text>);
`;
  const { root, widget } = fixture(widgetSource);
  try {
    const checked = runCli(root, "check", widget);
    assert.equal(checked.status, 0, checked.stderr);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("check takes the maximum across every JSX return branch", () => {
  const oversized = `<column>${Array.from({ length: 1024 }, () => "<row />").join("")}</column>`;
  const widgetSource = `import { widget } from "@weaver/sdk";
function Branch({ large }: { large: boolean }) {
  if (!large) return <text>small</text>;
  return (${oversized});
}
export default widget({ name: "Branch Budget", size: [320, 200] }, () => <Branch large={true} />);
`;
  const { root, widget } = fixture(widgetSource);
  try {
    const checked = runCli(root, "check", widget);
    assert.equal(checked.status, 1);
    assert.match(checked.stderr, /LoweredWidgetNodeLimit: this tree lowers to 1025 Native nodes/);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("check does not sum mutually exclusive JSX return branches", () => {
  const group = () => `<column>${Array.from({ length: 20 }, () => "<row />").join("")}</column>`;
  const branch = () => `<column>${Array.from({ length: 4 }, group).join("")}</column>`;
  const widgetSource = `import { widget } from "@weaver/sdk";
function Branch({ first }: { first: boolean }) {
  if (first) return (${branch()});
  return (${branch()});
}
export default widget({ name: "Branch Maximum", size: [320, 200] }, () => <Branch first={true} />);
`;
  const { root, widget } = fixture(widgetSource);
  try {
    const checked = runCli(root, "check", widget);
    assert.equal(checked.status, 0, checked.stderr);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("check names the direct-child budget and authored ask", () => {
  const children = Array.from({ length: 65 }, () => "<row />").join("");
  const { root, widget } = fixture(source(`<column>${children}</column>`));
  try {
    const checked = runCli(root, "check", widget);
    assert.equal(checked.status, 1);
    assert.match(checked.stderr, /LoweredWidgetChildLimit/);
    assert.match(checked.stderr, /max_children=64, asked for 65, headroom=-1/);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("check names the static text byte budget and authored ask", () => {
  const { root, widget } = fixture(source(`<text>${"x".repeat(1025)}</text>`));
  try {
    const checked = runCli(root, "check", widget);
    assert.equal(checked.status, 1);
    assert.match(checked.stderr, /LoweredWidgetTextLimit/);
    assert.match(checked.stderr, /max_text_bytes=1024, asked for 1025, headroom=-1/);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("check names the canvas budget and authored ask", () => {
  const canvases = Array.from({ length: 9 }, () => '<canvas class="w-[10px] h-[10px]" fps={0} onFrame={() => {}} />').join("");
  const { root, widget } = fixture(source(`<column>${canvases}</column>`));
  try {
    const checked = runCli(root, "check", widget);
    assert.equal(checked.status, 1);
    assert.match(checked.stderr, /LoweredWidgetCanvasLimit/);
    assert.match(checked.stderr, /max_canvases=8, asked for 9, headroom=-1/);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("check counts statically evident implicit text children", () => {
  const primitives = Array.from({ length: 1024 }, (_, index) => `{${index}}`).join("");
  const { root, widget } = fixture(source(`<column>${primitives}</column>`));
  try {
    const checked = runCli(root, "check", widget);
    assert.equal(checked.status, 1);
    assert.match(checked.stderr, /LoweredWidgetNodeLimit: this tree lowers to 1025 Native nodes/);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("check resolves one level of local imported components", () => {
  const importedTree = `<column>${Array.from({ length: 1024 }, () => "<row />").join("")}</column>`;
  const widgetSource = `import { widget } from "@weaver/sdk";
import { ImportedTree as Tree } from "./tree";
export default widget({ name: "Imported Budget", size: [320, 200] }, () => <Tree />);
`;
  const { root, widget } = fixture(widgetSource, {
    "tree.tsx": `export function ImportedTree() { return (${importedTree}); }\n`,
  });
  try {
    const checked = runCli(root, "check", widget);
    assert.equal(checked.status, 1);
    assert.match(checked.stderr, /LoweredWidgetNodeLimit: this tree lowers to 1025 Native nodes/);
    assert.match(checked.stderr, /one level of relative imports/);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("check resolves a directly imported default function component", () => {
  const importedTree = `<column>${Array.from({ length: 1024 }, () => "<row />").join("")}</column>`;
  const widgetSource = `import { widget } from "@weaver/sdk";
import Tree from "./tree";
export default widget({ name: "Default Import Budget", size: [320, 200] }, () => <Tree />);
`;
  const { root, widget } = fixture(widgetSource, {
    "tree.tsx": `export default function Tree() { return (${importedTree}); }\n`,
  });
  try {
    const checked = runCli(root, "check", widget);
    assert.equal(checked.status, 1);
    assert.match(checked.stderr, /LoweredWidgetNodeLimit: this tree lowers to 1025 Native nodes/);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("check resolves a directly imported aliased default export", () => {
  const importedTree = `<column>${Array.from({ length: 1024 }, () => "<row />").join("")}</column>`;
  const widgetSource = `import { widget } from "@weaver/sdk";
import Tree from "./tree";
export default widget({ name: "Aliased Default Budget", size: [320, 200] }, () => <Tree />);
`;
  const { root, widget } = fixture(widgetSource, {
    "tree.tsx": `function Tree() { return (${importedTree}); }\nexport { Tree as default };\n`,
  });
  try {
    const checked = runCli(root, "check", widget);
    assert.equal(checked.status, 1);
    assert.match(checked.stderr, /LoweredWidgetNodeLimit: this tree lowers to 1025 Native nodes/);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("check resolves nested helpers in their declaring module", () => {
  const oversized = `<column>${Array.from({ length: 1024 }, () => "<row />").join("")}</column>`;
  const widgetSource = `import { widget } from "@weaver/sdk";
import { SmallTree } from "./small";
import { LargeTree } from "./large";
void SmallTree;
export default widget({ name: "Module Scope Budget", size: [320, 200] }, () => <LargeTree />);
`;
  const { root, widget } = fixture(widgetSource, {
    "small.tsx": `function Helper() { return <text>small</text>; }\nexport function SmallTree() { return <Helper />; }\n`,
    "large.tsx": `function Helper() { return (${oversized}); }\nexport function LargeTree() { return <Helper />; }\n`,
  });
  try {
    const checked = runCli(root, "check", widget);
    assert.equal(checked.status, 1);
    assert.match(checked.stderr, /LoweredWidgetNodeLimit: this tree lowers to 1025 Native nodes/);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
