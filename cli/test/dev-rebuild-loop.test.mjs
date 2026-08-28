import assert from "node:assert/strict";
import test from "node:test";
import { build } from "esbuild";
import { fileURLToPath } from "node:url";

const bundle = await build({
  entryPoints: [fileURLToPath(new URL("../src/dev-rebuild-loop.ts", import.meta.url))],
  bundle: true,
  format: "esm",
  platform: "node",
  write: false,
});
const { createDevRebuildLoop } = await import(`data:text/javascript;base64,${Buffer.from(bundle.outputFiles[0].contents).toString("base64")}`);

test("dev rebuilds coalesce one event-loop turn across watcher microtasks", async () => {
  let rebuilds = 0;
  const loop = createDevRebuildLoop(async () => { rebuilds += 1; });

  loop.schedule();
  await Promise.resolve();
  loop.schedule();
  await Promise.resolve();
  loop.schedule();
  assert.equal(rebuilds, 0);

  await new Promise((resolvePromise) => setImmediate(resolvePromise));
  await loop.drain();

  assert.equal(rebuilds, 1);
});

test("dev rebuilds rerun the newest dirty generation without overlap", async () => {
  const releases = [];
  let active = 0;
  let maxActive = 0;
  let rebuilds = 0;
  const loop = createDevRebuildLoop(() => new Promise((resolvePromise) => {
    rebuilds += 1;
    active += 1;
    maxActive = Math.max(maxActive, active);
    releases.push(() => {
      active -= 1;
      resolvePromise();
    });
  }));

  loop.schedule();
  await new Promise((resolvePromise) => setImmediate(resolvePromise));
  assert.equal(rebuilds, 1);

  loop.schedule();
  loop.schedule();
  releases.shift()();
  await new Promise((resolvePromise) => setImmediate(resolvePromise));
  assert.equal(rebuilds, 2);

  const drained = loop.drain();
  releases.shift()();
  await drained;

  assert.equal(maxActive, 1);
  assert.equal(rebuilds, 2);
});

test("dev shutdown drain waits for a queued final rebuild", async () => {
  let release;
  let rebuilds = 0;
  const loop = createDevRebuildLoop(() => new Promise((resolvePromise) => {
    rebuilds += 1;
    release = resolvePromise;
  }));

  loop.schedule();
  let drained = false;
  const shutdown = loop.drain().then(() => { drained = true; });
  assert.equal(rebuilds, 1);
  assert.equal(drained, false);

  release();
  await shutdown;

  assert.equal(drained, true);
  assert.equal(rebuilds, 1);
});
