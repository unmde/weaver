import assert from "node:assert/strict";
import { once } from "node:events";
import { mkdtemp, mkdir, rename, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { build } from "esbuild";
import { fileURLToPath } from "node:url";

const bundle = await build({
  entryPoints: [fileURLToPath(new URL("../src/dev-watcher.ts", import.meta.url))],
  bundle: true,
  format: "esm",
  platform: "node",
  write: false,
});
const { watchDevDirectory } = await import(`data:text/javascript;base64,${Buffer.from(bundle.outputFiles[0].contents).toString("base64")}`);

async function waitForEvent(watcher, events, predicate) {
  while (!events.some(predicate)) await once(watcher, "all");
}

test("dev watcher normalizes atomic saves and ignores Weaver output", async () => {
  const directory = await mkdtemp(join(tmpdir(), "weaver-dev-watcher-"));
  const sourcePath = join(directory, "widget.tsx");
  const replacementPath = join(directory, ".widget.tsx.tmp");
  const outputPath = join(directory, "dist", "widget.js");
  const gitPath = join(directory, ".git", "config");
  const portPath = join(directory, ".weaver-dev-port");
  await writeFile(sourcePath, "before");
  await mkdir(join(directory, "dist"));
  await mkdir(join(directory, ".git"));

  const events = [];
  const watcher = watchDevDirectory(directory, (event, path) => {
    events.push([event, path]);
  }, (error) => {
    throw error;
  });

  try {
    await once(watcher, "ready");
    assert.deepEqual(events, []);

    await writeFile(replacementPath, "after");
    await rename(replacementPath, sourcePath);
    await waitForEvent(watcher, events, ([event, path]) => event === "change" && path === sourcePath);

    await writeFile(outputPath, "generated");
    await writeFile(gitPath, "internal");
    await writeFile(portPath, "internal");
    await writeFile(sourcePath, "after again");
    await waitForEvent(watcher, events, () => events.filter(([event, path]) => event === "change" && path === sourcePath).length >= 2);

    assert.equal(events.some(([, path]) => path === outputPath), false);
    assert.equal(events.some(([, path]) => path === gitPath), false);
    assert.equal(events.some(([, path]) => path === portPath), false);
    assert.equal(events.some(([event, path]) => (event === "add" || event === "unlink") && path === sourcePath), false);
    assert.equal(events.filter(([, path]) => path === sourcePath).length, 2);
  } finally {
    await watcher.close();
    await rm(directory, { recursive: true, force: true });
  }
});
