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

for (const prior of [
  undefined,
  { name: "Clock", sourcePath: "/weaver/widgets/clock", enabled: false },
]) {
  test(`dev shutdown keeps the ended registration removed when host reload fails${prior ? " and restores the installed registration" : ""}`, () => {
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
      ...(prior ? [prior] : []),
    ]);
  });
}
