import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { once } from "node:events";
import test from "node:test";
import { build } from "esbuild";
import { fileURLToPath } from "node:url";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, utimesSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createServer } from "node:net";

const originBundle = await build({
  entryPoints: [fileURLToPath(new URL("../src/origin.ts", import.meta.url))],
  bundle: true,
  format: "esm",
  platform: "node",
  write: false,
});
const origin = await import(`data:text/javascript;base64,${Buffer.from(originBundle.outputFiles[0].contents).toString("base64")}`);
const hostToolsBundle = await build({
  entryPoints: [fileURLToPath(new URL("../src/host-tools.ts", import.meta.url))],
  bundle: true,
  format: "esm",
  platform: "node",
  write: false,
});
const hostTools = await import(`data:text/javascript;base64,${Buffer.from(hostToolsBundle.outputFiles[0].contents).toString("base64")}`);
const devReloadBundle = await build({
  entryPoints: [fileURLToPath(new URL("../src/dev-reload.ts", import.meta.url))],
  bundle: true,
  format: "esm",
  platform: "node",
  write: false,
});
const devReload = await import(`data:text/javascript;base64,${Buffer.from(devReloadBundle.outputFiles[0].contents).toString("base64")}`);
test("icon lowering leaves icon-free widget sources byte-exact", () => {
  const transformSource = readFileSync(fileURLToPath(new URL("../src/icon-transform.ts", import.meta.url)), "utf8");
  assert.match(transformSource, /if \(!sourceContainsIcon\(sourceFile\)\) return source;/);
});

test("dev hot reload signals one loopback event instead of polling", { timeout: 5000 }, async () => {
  const root = mkdtempSync(join(tmpdir(), "weaver-dev-reload-"));
  const dist = join(root, "dist");
  mkdirSync(dist);
  let notifications = 0;
  const server = createServer((socket) => {
    notifications += 1;
    socket.end();
  });
  await new Promise((resolvePromise, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", resolvePromise);
  });
  try {
    const address = server.address();
    assert.notEqual(typeof address, "string");
    assert.ok(address);
    writeFileSync(join(dist, ".weaver-dev-port"), `${address.port}\n`);
    const notification = once(server, "connection");
    await devReload.signalDevReload(root, 1);
    await notification;
    assert.equal(notifications, 1);
  } finally {
    await new Promise((resolvePromise) => server.close(resolvePromise));
    rmSync(root, { recursive: true, force: true });
  }
});

test("CLI failures are emitted as one actionable block", () => {
  const result = spawnSync(process.execPath, ["cli/dist/index.js", "unknown", "widget"], { encoding: "utf8" });
  assert.equal(result.status, 1);
  assert.match(result.stderr, /^weaver failed \(1 error\)\n- Usage:/);
});

test("origin matching is HTTPS-only and exact-host", () => {
  assert.equal(origin.originHost("https://api.example.com/v1"), "api.example.com");
  assert.equal(origin.originHost("http://api.example.com/v1"), null);
  assert.equal(origin.originDeclared(["api.example.com"], "API.EXAMPLE.COM"), true);
  assert.equal(origin.originDeclared(["example.com"], "api.example.com"), false);
  assert.equal(origin.originNotDeclaredMessage("api.example.com"), 'OriginNotDeclared: add "api.example.com" to origins in your widget config');
});

test("status table is aligned and includes crash reasons", () => {
  const table = hostTools.formatStatus({ hostPid: 1, widgets: [
    { name: "Clock", pid: 42, backend: "software", privateMb: 9.55, cpuPercent: 0.2, uptimeSeconds: 65, state: "running", reason: "" },
    { name: "Broken", pid: 0, backend: "-", privateMb: 0, cpuPercent: 0, uptimeSeconds: 0, state: "stopped", reason: "crashed 3 times" },
  ] });
  assert.match(table, /^NAME\s+PID\s+BACKEND\s+PRIVATE\s+CPU\s+THREADS\s+UPTIME\s+STATE/m);
  assert.match(table, /Broken\s+-\s+-\s+0\.0 MB\s+0\.0%\s+0\s+0s\s+stopped: crashed 3 times/);
});

test("path helpers follow Windows case rules without weakening POSIX containment", () => {
  const root = "C:\\Users\\Dara\\AppData\\Local\\weaver\\widgets";
  assert.equal(hostTools.pathsEqual(`${root}\\Clock`, "c:/users/dara/appdata/local/weaver/widgets/clock", "win32"), true);
  assert.equal(hostTools.pathInside(root, "c:/users/dara/appdata/local/weaver/widgets/Clock", "win32"), true);
  assert.equal(hostTools.pathInside(root, "C:\\Users\\Dara\\AppData\\Local\\weaver\\widgets-old\\Clock", "win32"), false);
  assert.equal(hostTools.pathsEqual("/var/lib/Weaver", "/var/lib/weaver", "linux"), false);
  assert.equal(hostTools.pathInside("/var/lib/weaver", "/var/lib/weaver/../outside", "linux"), false);
});

test("CLI paths match the runtime contract on Windows and macOS", () => {
  const windows = { platform: "win32", localAppData: "C:\\Users\\Dara\\AppData\\Local" };
  assert.equal(hostTools.weaverDataPath(windows), "C:\\Users\\Dara\\AppData\\Local\\weaver");
  assert.equal(hostTools.weaverLogsPath(windows), "C:\\Users\\Dara\\AppData\\Local\\weaver\\logs");
  assert.equal(hostTools.registryPath(windows), "C:\\Users\\Dara\\AppData\\Local\\weaver\\registry.json");
  const macos = { platform: "darwin", home: "/Users/dara" };
  assert.equal(hostTools.weaverDataPath(macos), "/Users/dara/Library/Application Support/Weaver");
  assert.equal(hostTools.weaverLogsPath(macos), "/Users/dara/Library/Logs/Weaver");
  assert.equal(hostTools.registryPath(macos), "/Users/dara/Library/Application Support/Weaver/registry.json");
});

test("registry mutations are serialized across processes and leave no shared temp file", async () => {
  const root = mkdtempSync(join(tmpdir(), "weaver-registry-lock-"));
  const registry = join(root, "registry.json");
  const modulePath = join(root, "host-tools.mjs");
  const workerPath = join(root, "worker.mjs");
  try {
    writeFileSync(modulePath, hostToolsBundle.outputFiles[0].contents);
    writeFileSync(workerPath, `import { readRegistry, withRegistryLock, writeRegistry } from "./host-tools.mjs";
const [registry, name, hold] = process.argv.slice(2);
await withRegistryLock(async () => {
  const document = readRegistry(registry);
  await new Promise((resolve) => setTimeout(resolve, Number(hold)));
  writeRegistry({ widgets: [...document.widgets, { name, sourcePath: "/" + name, enabled: true }] }, registry);
}, registry, { timeoutMs: 5000, retryMs: 5, staleMs: 30000 });
`);
    const first = spawn(process.execPath, [workerPath, registry, "first", "150"], { stdio: ["ignore", "pipe", "pipe"] });
    await waitForPath(`${registry}.lock`);
    const second = spawn(process.execPath, [workerPath, registry, "second", "0"], { stdio: ["ignore", "pipe", "pipe"] });
    const [firstResult, secondResult] = await Promise.all([childResult(first), childResult(second)]);
    assert.equal(firstResult.code, 0, firstResult.stderr);
    assert.equal(secondResult.code, 0, secondResult.stderr);
    assert.deepEqual(hostTools.readRegistry(registry).widgets.map((widget) => widget.name), ["first", "second"]);
    assert.deepEqual(readdirSync(root).filter((name) => name.endsWith(".tmp") || name.endsWith(".lock")), []);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("an abandoned registry lock is reclaimed and completely removed", async () => {
  const root = mkdtempSync(join(tmpdir(), "weaver-abandoned-lock-"));
  const registry = join(root, "registry.json");
  const lock = `${registry}.lock`;
  try {
    mkdirSync(lock, { recursive: true });
    writeFileSync(join(lock, "owner.json"), '{"pid":0,"token":"abandoned"}\n', "utf8");
    const old = new Date(Date.now() - 60_000);
    utimesSync(lock, old, old);
    let ran = false;
    await hostTools.withRegistryLock(() => { ran = true; }, registry, { timeoutMs: 1000, retryMs: 5, staleMs: 10 });
    assert.equal(ran, true);
    assert.equal(existsSync(lock), false);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("bundle manifest is the subscription origin of truth", () => {
  const root = mkdtempSync(join(tmpdir(), "weaver-subscriptions-"));
  const widget = join(root, "system-card");
  const cli = fileURLToPath(new URL("../dist/index.js", import.meta.url));
  try {
    assert.equal(spawnSync(process.execPath, [cli, "init", "system-card"], { cwd: root, encoding: "utf8" }).status, 0);
    const sourcePath = join(widget, "widget.tsx");
    const source = `import { useProvider, useProviderSignal, widget } from "@weaver/sdk";
export default widget({ name: "System Card", size: [200, 100], subscribe: ["cpu", "memory", "audio", "media"] }, () => {
  const cpu = useProvider("cpu");
  const audio = useProvider("audio");
  const memorySnapshot = useProvider("memory");
  const memory = useProviderSignal("memory");
  return <row><text>{cpu.percent + audio.rms + memorySnapshot.percent}</text><text>{memory.map((value) => value.percent)}</text></row>;
});
`;
    writeFileSync(sourcePath, source, "utf8");
    mkdirSync(join(widget, "data"));
    writeFileSync(join(widget, "data", "widget.json"), "nested manifest asset", "utf8");
    mkdirSync(join(widget, "assets", "dist"), { recursive: true });
    writeFileSync(join(widget, "assets", "dist", "pixel.bin"), "nested dist asset", "utf8");
    const result = spawnSync(process.execPath, ["cli/dist/index.js", "bundle", widget], { encoding: "utf8" });
    assert.equal(result.status, 0, result.stderr);
    const manifest = JSON.parse(readFileSync(join(widget, "dist", "widget.json"), "utf8"));
    assert.deepEqual(manifest.subscribe, ["cpu", "memory", "audio", "media"]);
    assert.equal(manifest.renderBackend, "software");
    assert.equal(readFileSync(join(widget, "dist", "data", "widget.json"), "utf8"), "nested manifest asset");
    assert.equal(readFileSync(join(widget, "dist", "assets", "dist", "pixel.bin"), "utf8"), "nested dist asset");
    assert.equal(existsSync(join(widget, "dist", "widget.tsx")), false);

    writeFileSync(sourcePath, source.replace('subscribe: ["cpu", "memory", "audio", "media"]', 'subscribe: ["cpu", "audio", "media"]'), "utf8");
    const missingSignalSubscription = spawnSync(process.execPath, [cli, "check", widget], { encoding: "utf8" });
    assert.equal(missingSignalSubscription.status, 1);
    assert.match(missingSignalSubscription.stderr, /useProvider\("memory"\) requires subscribe: \["memory"\]/);
    assert.match(missingSignalSubscription.stderr, /useProviderSignal\("memory"\) requires subscribe: \["memory"\]/);

    writeFileSync(sourcePath, source.replace('useProviderSignal("memory")', 'useProviderSignal("memmory")'), "utf8");
    const unknownProvider = spawnSync(process.execPath, [cli, "check", widget], { encoding: "utf8" });
    assert.equal(unknownProvider.status, 1);
    assert.match(unknownProvider.stderr, /useProviderSignal\("memmory"\) names no known provider; available providers: time, cpu, memory, audio, media/);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("media transport capability gate follows SDK signatures through every binding form", () => {
  const root = mkdtempSync(join(tmpdir(), "weaver-media-capability-"));
  const widget = join(root, "transport");
  const cli = fileURLToPath(new URL("../dist/index.js", import.meta.url));
  try {
    mkdirSync(widget, { recursive: true });
    writeFileSync(join(widget, "tsconfig.json"), JSON.stringify({
      compilerOptions: {
        target: "ES2020", module: "ESNext", moduleResolution: "Bundler", strict: true, noEmit: true,
        jsx: "react-jsx", jsxImportSource: "@weaver/sdk", baseUrl: ".",
        paths: { "@weaver/sdk": [join(process.cwd(), "sdk/index.d.ts")], "@weaver/sdk/jsx-runtime": [join(process.cwd(), "sdk/jsx-runtime.d.ts")] },
      },
      include: ["**/*.ts", "**/*.tsx"],
    }));
    const rejected = [
      `import { useMediaTransport as t, widget } from "@weaver/sdk";
export default widget({ name: "Alias", size: [160, 80] }, () => { const media = t(); return <button onPress={() => void media.play()}><text>Play</text></button>; });
`,
      `import { widget } from "@weaver/sdk";
import * as Weaver from "@weaver/sdk";
export default widget({ name: "Namespace", size: [160, 80] }, () => { const media = Weaver.useMediaTransport(); return <button onPress={() => void media.pause()}><text>Pause</text></button>; });
`,
      `import { widget } from "@weaver/sdk";
import * as Weaver from "@weaver/sdk";
const { useMediaTransport: hook } = Weaver;
export default widget({ name: "Destructure", size: [160, 80] }, () => { const media = hook(); return <button onPress={() => void media.play()}><text>Play</text></button>; });
`,
      `import { widget } from "@weaver/sdk";
import * as Weaver from "@weaver/sdk";
let hook: typeof Weaver.useMediaTransport;
hook = Weaver.useMediaTransport;
export default widget({ name: "Assigned", size: [160, 80] }, () => { const media = hook(); return <button onPress={() => void media.pause()}><text>Pause</text></button>; });
`,
      `import { widget } from "@weaver/sdk";
import * as Weaver from "@weaver/sdk";
const controls = { transport: Weaver.useMediaTransport };
export default widget({ name: "Property", size: [160, 80] }, () => { const media = controls.transport(); return <button onPress={() => void media.next()}><text>Next</text></button>; });
`,
    ];
    for (const source of rejected) {
      writeFileSync(join(widget, "widget.tsx"), source);
      rmSync(join(widget, "controls.ts"), { force: true });
      const result = spawnSync(process.execPath, [cli, "check", widget], { encoding: "utf8" });
      assert.equal(result.status, 1, `${result.stderr}\n${source}`);
      assert.match(result.stderr, /useMediaTransport\(\) requires capabilities: \["media-transport"\]/);
    }

    writeFileSync(join(widget, "widget.tsx"), `import { useMediaTransport, widget } from "@weaver/sdk";
const hook = useMediaTransport;
export default widget({ name: "Const alias", size: [160, 80] }, () => { const media = hook(); return <button onPress={() => void media.play()}><text>Play</text></button>; });
`);
    const constAlias = spawnSync(process.execPath, [cli, "check", widget], { encoding: "utf8" });
    assert.equal(constAlias.status, 1);
    assert.match(constAlias.stderr, /useMediaTransport\(\) requires capabilities: \["media-transport"\]/);

    writeFileSync(join(widget, "fake-sdk.d.ts"), `export declare function useMediaTransport(): { play(): Promise<boolean> };
export declare function widget(config: unknown, render: () => unknown): unknown;
`);
    writeFileSync(join(widget, "tsconfig.json"), JSON.stringify({
      compilerOptions: {
        target: "ES2020", module: "ESNext", moduleResolution: "Bundler", strict: true, noEmit: true,
        jsx: "react-jsx", jsxImportSource: "@weaver/sdk", baseUrl: ".",
        paths: { "@weaver/sdk": ["fake-sdk.d.ts"], "@weaver/sdk/jsx-runtime": [join(process.cwd(), "sdk/jsx-runtime.d.ts")] },
      },
      include: ["**/*.ts", "**/*.tsx"],
    }));
    writeFileSync(join(widget, "widget.tsx"), `import { useMediaTransport, widget } from "@weaver/sdk";
export default widget({ name: "Mapped fake", size: [160, 80] }, () => { const media = useMediaTransport(); return <button onPress={() => void media.play()}><text>Play</text></button>; });
`);
    const customMapping = spawnSync(process.execPath, [cli, "check", widget], { encoding: "utf8" });
    assert.equal(customMapping.status, 1);
    assert.match(customMapping.stderr, /useMediaTransport\(\) requires capabilities: \["media-transport"\]/);

    writeFileSync(join(widget, "tsconfig.json"), JSON.stringify({
      compilerOptions: {
        target: "ES2020", module: "ESNext", moduleResolution: "Bundler", strict: true, noEmit: true,
        jsx: "react-jsx", jsxImportSource: "@weaver/sdk", baseUrl: ".",
        paths: { "@weaver/sdk": [join(process.cwd(), "sdk/index.d.ts")], "@weaver/sdk/jsx-runtime": [join(process.cwd(), "sdk/jsx-runtime.d.ts")] },
      },
      include: ["**/*.ts", "**/*.tsx"],
    }));
    writeFileSync(join(widget, "controls.ts"), `import { useMediaTransport } from "@weaver/sdk";
export function controls() { return useMediaTransport(); }
`);
    writeFileSync(join(widget, "widget.tsx"), `import { widget } from "@weaver/sdk";
import { controls } from "./controls";
export default widget({ name: "Helper", size: [160, 80] }, () => { const media = controls(); return <button onPress={() => void media.next()}><text>Next</text></button>; });
`);
    const helper = spawnSync(process.execPath, [cli, "check", widget], { encoding: "utf8" });
    assert.equal(helper.status, 1);
    assert.match(helper.stderr, /controls\.ts:\d+:\d+: useMediaTransport\(\) requires capabilities/);

    writeFileSync(join(widget, "transport-origin.ts"), `export { useMediaTransport as transportHook } from "@weaver/sdk";
`);
    writeFileSync(join(widget, "transport-export.ts"), `export { transportHook as hook } from "./transport-origin";
`);
    writeFileSync(join(widget, "widget.tsx"), `import { widget } from "@weaver/sdk";
import { hook } from "./transport-export";
export default widget({ name: "Re-export", size: [160, 80] }, () => { const media = hook(); return <button onPress={() => void media.previous()}><text>Previous</text></button>; });
`);
    const reexport = spawnSync(process.execPath, [cli, "check", widget], { encoding: "utf8" });
    assert.equal(reexport.status, 1);
    assert.match(reexport.stderr, /useMediaTransport\(\) requires capabilities: \["media-transport"\]/);

    writeFileSync(join(widget, "widget.tsx"), `import { widget } from "@weaver/sdk";
import { controls } from "./controls";
export default widget({ name: "Declared", size: [160, 80], capabilities: ["media-transport"] }, () => { const media = controls(); return <button onPress={() => void media.previous()}><text>Previous</text></button>; });
`);
    const bundle = spawnSync(process.execPath, [cli, "bundle", widget], { encoding: "utf8" });
    assert.equal(bundle.status, 0, bundle.stderr);
    const manifest = JSON.parse(readFileSync(join(widget, "dist", "widget.json"), "utf8"));
    assert.deepEqual(manifest.capabilities, ["media-transport"]);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("styling 07 discovers, validates, bundles, and names TrueType faces", () => {
  const root = mkdtempSync(join(tmpdir(), "weaver-font-bundle-"));
  try {
    const widget = join(root, "widget");
    mkdirSync(widget, { recursive: true });
    writeFileSync(join(widget, "tsconfig.json"), JSON.stringify({
      compilerOptions: {
        target: "ES2020", module: "ESNext", moduleResolution: "Bundler", strict: true, noEmit: true,
        jsx: "react-jsx", jsxImportSource: "@weaver/sdk", baseUrl: ".",
        paths: { "@weaver/sdk": [join(process.cwd(), "sdk/index.d.ts")], "@weaver/sdk/jsx-runtime": [join(process.cwd(), "sdk/jsx-runtime.d.ts")] },
      },
      include: ["widget.tsx"],
    }));
    writeFileSync(join(widget, "widget.tsx"), `import { widget } from "@weaver/sdk";
export default widget({ name: "Font Test", size: [160, 80] }, () => <text class="font-[Geist] font-bold">Bundled</text>);
`);
    writeFileSync(join(widget, "Geist-Regular.ttf"), readFileSync(join(process.cwd(), "runtime/native-sdk/src/primitives/canvas/fonts/Geist-Regular.ttf")));
    const check = spawnSync(process.execPath, ["cli/dist/index.js", "check", widget], { encoding: "utf8" });
    assert.equal(check.status, 0, check.stderr);
    const bundle = spawnSync(process.execPath, ["cli/dist/index.js", "bundle", widget], { encoding: "utf8" });
    assert.equal(bundle.status, 0, bundle.stderr);
    const manifest = JSON.parse(readFileSync(join(widget, "dist", "widget.json"), "utf8"));
    assert.deepEqual(manifest.fonts, [{
      id: 64, name: "Geist-Regular.ttf", stem: "Geist-Regular", family: "Geist", weight: "regular", file: "Geist-Regular.ttf",
    }]);
    assert.deepEqual(readFileSync(join(widget, "dist", "Geist-Regular.ttf")), readFileSync(join(widget, "Geist-Regular.ttf")));

    const longStem = "A".repeat(64);
    writeFileSync(join(widget, `${longStem}.ttf`), readFileSync(join(widget, "Geist-Regular.ttf")));
    const longFamily = spawnSync(process.execPath, ["cli/dist/index.js", "check", widget], { encoding: "utf8" });
    assert.equal(longFamily.status, 1);
    assert.match(longFamily.stderr, /max_font_family_bytes=63, asked for 64/);
    rmSync(join(widget, `${longStem}.ttf`));

    writeFileSync(join(widget, "widget.tsx"), `import { widget } from "@weaver/sdk";
export default widget({ name: "Font Test", size: [160, 80] }, () => <text class="font-[Missing]">Missing</text>);
`);
    const missing = spawnSync(process.execPath, ["cli/dist/index.js", "check", widget], { encoding: "utf8" });
    assert.equal(missing.status, 1);
    assert.match(missing.stderr, /Unknown bundled font "Missing".*Geist-Regular.*Geist/s);

    writeFileSync(join(widget, "Broken.ttf"), "not a font");
    const broken = spawnSync(process.execPath, ["cli/dist/index.js", "check", widget], { encoding: "utf8" });
    assert.equal(broken.status, 1);
    assert.match(broken.stderr, /Broken\.ttf: not a parseable TrueType face/);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("styling 08 resolves full Lucide and custom SVG paths without reserving fonts", () => {
  const root = mkdtempSync(join(tmpdir(), "weaver-icon-bundle-"));
  try {
    const widget = join(root, "widget");
    mkdirSync(widget, { recursive: true });
    writeFileSync(join(widget, "tsconfig.json"), JSON.stringify({
      compilerOptions: {
        target: "ES2020", module: "ESNext", moduleResolution: "Bundler", strict: true, noEmit: true,
        jsx: "react-jsx", jsxImportSource: "@weaver/sdk", baseUrl: ".",
        paths: { "@weaver/sdk": [join(process.cwd(), "sdk/index.d.ts")], "@weaver/sdk/jsx-runtime": [join(process.cwd(), "sdk/jsx-runtime.d.ts")] },
      },
      include: ["widget.tsx"],
    }));
    const validSource = `import { widget } from "@weaver/sdk";
export default widget({ name: "Icon Test", size: [160, 80] }, () => <row><icon name="badge-question-mark" class="text-red-500 w-6" /><icon d="m1 1 h10 v10 q2 2 4 0 a3 3 0 0 1 3 3 z" viewBox="0 0 20 20" stroke={1.5} /><text class="font-[Geist]">Label</text></row>);
`;
    writeFileSync(join(widget, "widget.tsx"), validSource);
    writeFileSync(join(widget, "Geist-Regular.ttf"), readFileSync(join(process.cwd(), "runtime/native-sdk/src/primitives/canvas/fonts/Geist-Regular.ttf")));
    const check = spawnSync(process.execPath, ["cli/dist/index.js", "check", widget], { encoding: "utf8" });
    assert.equal(check.status, 0, check.stderr);
    const bundle = spawnSync(process.execPath, ["cli/dist/index.js", "bundle", widget], { encoding: "utf8" });
    assert.equal(bundle.status, 0, bundle.stderr);
    const manifest = JSON.parse(readFileSync(join(widget, "dist", "widget.json"), "utf8"));
    assert.deepEqual(manifest.fonts, [
      { id: 64, name: "Geist-Regular.ttf", stem: "Geist-Regular", family: "Geist", weight: "regular", file: "Geist-Regular.ttf" },
    ]);
    assert.deepEqual(readFileSync(join(widget, "dist", "Lucide-LICENSE.txt")), readFileSync(join(process.cwd(), "sdk/assets/LUCIDE-LICENSE.txt")));
    assert.equal(existsSync(join(widget, "dist", "WeaverLucide.ttf")), false);
    const bundleSource = readFileSync(join(widget, "dist", "bundle.js"), "utf8");
    assert.match(bundleSource, /iconPath/);
    assert.match(bundleSource, /M 3\.85 8\.62/);
    assert.doesNotMatch(bundleSource, /[mhaqv]1 1/);
    assert.doesNotMatch(bundleSource, /zodiac-aquarius/);

    rmSync(join(widget, "dist"), { recursive: true, force: true });
    writeFileSync(join(widget, "controls.tsx"), 'export const Controls = () => <icon name="play" />;\n');
    writeFileSync(join(widget, "widget.tsx"), `import { widget } from "@weaver/sdk";
import { Controls } from "./controls";
export default widget({ name: "Imported Icon Test", size: [160, 80] }, () => <Controls />);
`);
    const importedBundle = spawnSync(process.execPath, ["cli/dist/index.js", "bundle", widget], { encoding: "utf8" });
    assert.equal(importedBundle.status, 0, importedBundle.stderr);
    assert.deepEqual(readFileSync(join(widget, "dist", "Lucide-LICENSE.txt")), readFileSync(join(process.cwd(), "sdk/assets/LUCIDE-LICENSE.txt")));

    writeFileSync(join(widget, "widget.tsx"), validSource.replace('name="badge-question-mark"', 'name="badge-question-mrak"'));
    const unknown = spawnSync(process.execPath, ["cli/dist/index.js", "check", widget], { encoding: "utf8" });
    assert.equal(unknown.status, 1);
    assert.match(unknown.stderr, /Unknown Lucide icon "badge-question-mrak"\. Did you mean "badge-question-mark"\?/);

    writeFileSync(join(widget, "widget.tsx"), validSource);
    writeFileSync(join(widget, "Geist-Bold.ttf"), readFileSync(join(process.cwd(), "runtime/native-sdk/src/primitives/canvas/fonts/Geist-Regular.ttf")));
    const twoFonts = spawnSync(process.execPath, ["cli/dist/index.js", "check", widget], { encoding: "utf8" });
    assert.equal(twoFonts.status, 0, twoFonts.stderr);
    writeFileSync(join(widget, "Third.ttf"), readFileSync(join(process.cwd(), "runtime/native-sdk/src/primitives/canvas/fonts/Geist-Regular.ttf")));
    const overBudget = spawnSync(process.execPath, ["cli/dist/index.js", "check", widget], { encoding: "utf8" });
    assert.equal(overBudget.status, 1);
    assert.match(overBudget.stderr, /Registered fonts exceed the widget-profile limit of 2 faces/);

    rmSync(join(widget, "Third.ttf"));
    writeFileSync(join(widget, "widget.tsx"), validSource.replace('<icon name="badge-question-mark"', '<icon name="badge-question-mark" d="M0 0"'));
    const mutuallyExclusive = spawnSync(process.execPath, ["cli/dist/index.js", "check", widget], { encoding: "utf8" });
    assert.equal(mutuallyExclusive.status, 1);
    assert.match(mutuallyExclusive.stderr, /requires exactly one of name or d/);

    writeFileSync(join(widget, "widget.tsx"), validSource.replace('<icon name="badge-question-mark" class="text-red-500 w-6" />', "<icon />"));
    const neither = spawnSync(process.execPath, ["cli/dist/index.js", "check", widget], { encoding: "utf8" });
    assert.equal(neither.status, 1);
    assert.match(neither.stderr, /requires exactly one of name or d/);

    const oversizedPath = `M0 0 ${"l1 0 ".repeat(2000)}`;
    writeFileSync(join(widget, "widget.tsx"), `import { widget } from "@weaver/sdk";
export default widget({ name: "Icon Test", size: [160, 80] }, () => <icon d="${oversizedPath}" />);
`);
    const oversized = spawnSync(process.execPath, ["cli/dist/index.js", "check", widget], { encoding: "utf8" });
    assert.equal(oversized.status, 1);
    assert.match(oversized.stderr, /Normalized icon path exceeds the 8192-byte per-node limit/);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("styling 11 requires descendant state variants to have a pressable ancestor", () => {
  const root = mkdtempSync(join(tmpdir(), "weaver-descendant-state-"));
  try {
    const widget = join(root, "widget");
    mkdirSync(widget, { recursive: true });
    writeFileSync(join(widget, "tsconfig.json"), JSON.stringify({
      compilerOptions: {
        target: "ES2020", module: "ESNext", moduleResolution: "Bundler", strict: true, noEmit: true,
        jsx: "react-jsx", jsxImportSource: "@weaver/sdk", baseUrl: ".",
        paths: { "@weaver/sdk": [join(process.cwd(), "sdk/index.d.ts")], "@weaver/sdk/jsx-runtime": [join(process.cwd(), "sdk/jsx-runtime.d.ts")] },
      },
      include: ["widget.tsx"],
    }));
    const valid = `import { widget } from "@weaver/sdk";
export default widget({ name: "State Test", size: [160, 80] }, () =>
  <button onPress={() => {}} class="pressed:shadow-[0_2px_4px_0_#0000004d] pressed:shadow-inner">
    <icon name="play" class="pressed:text-[#b6b6b6]" />
  </button>);
`;
    writeFileSync(join(widget, "widget.tsx"), valid);
    const accepted = spawnSync(process.execPath, ["cli/dist/index.js", "check", widget], { encoding: "utf8" });
    assert.equal(accepted.status, 0, accepted.stderr);

    writeFileSync(join(widget, "widget.tsx"), `import { widget } from "@weaver/sdk";
const StateIcon = () => <icon name="play" class="pressed:text-[#b6b6b6]" />;
const Pressable = ({ children }: { children: any }) => <button onPress={() => {}}>{children}</button>;
export default widget({ name: "State Test", size: [160, 80] }, () =>
  <Pressable><StateIcon /></Pressable>);
`);
    const componentBoundary = spawnSync(process.execPath, ["cli/dist/index.js", "check", widget], { encoding: "utf8" });
    assert.equal(componentBoundary.status, 0, componentBoundary.stderr);

    writeFileSync(join(widget, "widget.tsx"), `import { widget } from "@weaver/sdk";
export default widget({ name: "State Test", size: [160, 80] }, () =>
  <icon name="play" class="pressed:text-[#b6b6b6]" />);
`);
    const rejected = spawnSync(process.execPath, ["cli/dist/index.js", "check", widget], { encoding: "utf8" });
    assert.equal(rejected.status, 1);
    assert.match(rejected.stderr, /NearestPressableAncestor: state variants on non-pressable <icon> require a nearest <button> or <slider> ancestor/);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

async function waitForPath(path) {
  const deadline = Date.now() + 5000;
  while (!existsSync(path)) {
    if (Date.now() >= deadline) throw new Error(`Timed out waiting for ${path}`);
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
}

function childResult(child) {
  return new Promise((resolve) => {
    let stderr = "";
    child.stderr.setEncoding("utf8");
    child.stderr.on("data", (chunk) => { stderr += chunk; });
    child.once("exit", (code) => resolve({ code, stderr }));
  });
}
