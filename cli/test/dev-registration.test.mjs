import assert from "node:assert/strict";
import test from "node:test";
import { build } from "esbuild";
import { fileURLToPath } from "node:url";

const bundle = await build({
  entryPoints: [fileURLToPath(new URL("../src/dev-registration.ts", import.meta.url))],
  bundle: true,
  format: "esm",
  platform: "node",
  write: false,
});
const { endDevRegistration } = await import(`data:text/javascript;base64,${Buffer.from(bundle.outputFiles[0].contents).toString("base64")}`);

for (const { title, prior, fallback } of [
  {
    title: "dev shutdown removes its temporary registration when host reload fails",
    prior: undefined,
    fallback: [],
  },
  {
    title: "dev shutdown restores the installed registration when host reload fails",
    prior: { name: "Clock", sourcePath: "/weaver/widgets/clock", enabled: false },
    fallback: [{ name: "Clock", sourcePath: "/weaver/widgets/clock", enabled: false }],
  },
  {
    title: "dev shutdown does not restore a stale dev registration when host reload fails",
    prior: { name: "Clock", sourcePath: "/projects/clock", enabled: true, dev: true },
    fallback: [],
  },
]) {
  test(title, () => {
    const current = {
      widgets: [
        { name: "Weather", sourcePath: "/widgets/weather", enabled: true },
        { name: "Clock", sourcePath: "/projects/clock", enabled: true, dev: true },
      ],
    };
    let stored = current;
    let reloadAttempts = 0;
    const reloadFailure = new Error("host reload failed");

    assert.throws(() => endDevRegistration(
      current,
      "Clock",
      "/projects/clock",
      prior,
      (document) => { stored = document; },
      () => {
        reloadAttempts += 1;
        throw reloadFailure;
      },
    ), reloadFailure);

    assert.equal(reloadAttempts, 1);
    assert.deepEqual(stored.widgets, [
      { name: "Weather", sourcePath: "/widgets/weather", enabled: true },
      ...fallback,
    ]);
  });
}
