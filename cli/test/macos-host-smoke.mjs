import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { cpSync, existsSync, mkdtempSync, readFileSync, readdirSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

if (process.platform !== "darwin") {
  process.stdout.write("macOS host smoke skipped outside macOS\n");
  process.exit(0);
}

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const cli = join(repoRoot, "cli", "bin", "weaver.js");
const tempRoot = realpathSync(tmpdir());
const scratch = mkdtempSync(join(tempRoot, "weaver-macos-host-smoke-"));
const audioControl = join(scratch, "audio-control");
const providerSendFailure = join(scratch, "provider-send-failure");
const environment = {
  ...process.env,
  HOME: join(scratch, "home"),
  WEAVER_AUTOMATION: "1",
  WEAVER_AUDIO_TEST_CONTROL: audioControl,
  WEAVER_PROVIDER_TEST_FAIL_SEND: providerSendFailure,
};
const dataRoot = join(environment.HOME, "Library", "Application Support", "Weaver");
const registryFile = join(dataRoot, "registry.json");
const statusFile = join(dataRoot, "status.json");
const hostExecutable = join(repoRoot, "host", "zig-out", "Weaverd.app", "Contents", "MacOS", "weaverd");
const clockSource = join(scratch, "clock", "widget.tsx");
const runtimeRootPrefix = `weaver-${process.getuid()}-`;
const runtimeSearchRoots = [...new Set([tempRoot, realpathSync("/tmp")])];
const runtimeEntriesBefore = new Set(runtimeSearchRoots.flatMap((root) => readdirSync(root)
  .filter((name) => name.startsWith(runtimeRootPrefix))
  .map((name) => join(root, name))));
const trackedPids = new Set();
let devProcess;
let devStdout = "";
let devStderr = "";

function run(arguments_, expectedStatus = 0) {
  const result = spawnSync(process.execPath, [cli, ...arguments_], {
    cwd: scratch,
    env: environment,
    encoding: "utf8",
  });
  assert.equal(result.status, expectedStatus, `weaver ${arguments_.join(" ")} exited ${result.status}\nstdout:\n${result.stdout}\nstderr:\n${result.stderr}`);
  return result;
}

function runAsync(arguments_) {
  const child = spawn(process.execPath, [cli, ...arguments_], { cwd: scratch, env: environment, stdio: ["ignore", "pipe", "pipe"] });
  let stdout = "";
  let stderr = "";
  child.stdout.on("data", (bytes) => { stdout += bytes; });
  child.stderr.on("data", (bytes) => { stderr += bytes; });
  return new Promise((resolvePromise, rejectPromise) => {
    child.once("error", rejectPromise);
    child.once("exit", (code, signal) => resolvePromise({ code, signal, stdout, stderr }));
  });
}

function status() {
  if (!existsSync(statusFile)) return null;
  try { return JSON.parse(readFileSync(statusFile, "utf8")); }
  catch { return null; }
}

function alive(pid) {
  if (!Number.isInteger(pid) || pid <= 0) return false;
  try { process.kill(pid, 0); return true; }
  catch { return false; }
}

function widgetLogs() {
  const directory = join(environment.HOME, "Library", "Logs", "Weaver");
  if (!existsSync(directory)) return "(no widget log directory)";
  return readdirSync(directory)
    .filter((name) => name.endsWith(".log"))
    .map((name) => {
      try { return `--- ${name} ---\n${readFileSync(join(directory, name), "utf8")}`; }
      catch { return `--- ${name} unreadable ---`; }
    })
    .join("\n");
}

async function waitFor(description, predicate, timeoutMs = 10_000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const value = predicate();
    if (value) return value;
    await new Promise((resolvePromise) => setTimeout(resolvePromise, 50));
  }
  throw new Error(`Timed out waiting for ${description}\nstatus:\n${JSON.stringify(status(), null, 2)}\ndev stdout:\n${devStdout}\ndev stderr:\n${devStderr}\nwidget logs:\n${widgetLogs()}`);
}

function editClock(from, to) {
  const source = readFileSync(clockSource, "utf8");
  assert.match(source, new RegExp(from.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")));
  writeFileSync(clockSource, source.replace(from, to), "utf8");
}

async function waitForExit(child, timeoutMs = 10_000) {
  if (child.exitCode !== null || child.signalCode !== null) return { code: child.exitCode, signal: child.signalCode };
  return Promise.race([
    new Promise((resolvePromise) => child.once("exit", (code, signal) => resolvePromise({ code, signal }))),
    new Promise((_, rejectPromise) => setTimeout(() => rejectPromise(new Error("Timed out waiting for child exit")), timeoutMs)),
  ]);
}

try {
  run(["init", "clock"]);
  devProcess = spawn(process.execPath, [cli, "dev", "clock"], { cwd: scratch, env: environment, stdio: ["ignore", "pipe", "pipe"] });
  devProcess.stdout.on("data", (bytes) => { devStdout += bytes; });
  devProcess.stderr.on("data", (bytes) => { devStderr += bytes; });
  await waitFor("dev Widget with honest renderer and cost status", () => {
    const document = status();
    const widget = document?.widgets?.[0];
    return widget?.state === "running" && widget.backend === "gpu" && widget.privateMb > 0 && widget.threads > 0 && widget;
  });
  const first = status();
  const firstHostPid = first.hostPid;
  const firstWidgetPid = first.widgets[0].pid;
  trackedPids.add(firstHostPid);
  trackedPids.add(firstWidgetPid);

  editClock("opacity-60", "opacity-61");
  await waitFor("state-preserving in-process hot swap", () => devStdout.includes("dev hot swap applied (preserved root hook state)"));
  assert.equal(status().widgets[0].pid, firstWidgetPid, "bundle-only edit restarted the Widget process");

  editClock("size: [240, 110]", "size: [241, 110]");
  await waitFor("window-contract restart", () => {
    const widget = status()?.widgets?.[0];
    return devStdout.includes("weaver dev restarted widget: window config changed") && widget?.state === "running" && widget.pid !== firstWidgetPid && widget;
  });
  trackedPids.add(status().widgets[0].pid);
  devProcess.kill("SIGINT");
  const devExit = await waitForExit(devProcess);
  assert.equal(devExit.code, 0, `weaver dev did not exit cleanly: ${JSON.stringify(devExit)}\n${devStderr}`);
  devProcess = undefined;
  await waitFor("dev registration removal acknowledgement", () => status()?.widgets?.length === 0);

  run(["install", join(repoRoot, "examples", "now-playing")]);
  const macMedia = await waitFor("settled macOS media adapter status", () => {
    const document = status();
    const widget = document?.widgets?.[0];
    const providers = document?.providers;
    return widget?.name === "Now Playing" && widget.state === "running" &&
      ["available", "unavailable"].includes(providers?.mediaAvailability) &&
      providers.mediaSubscribers === 1 && providers.mediaPipeFrames >= 1 &&
      { document, widget, providers };
  }, 20_000);
  trackedPids.add(macMedia.widget.pid);
  const mediaRuntimeRoot = runtimeSearchRoots.flatMap((root) => readdirSync(root)
    .filter((name) => name.startsWith(runtimeRootPrefix))
    .map((name) => join(root, name)))
    .filter((path) => !runtimeEntriesBefore.has(path))
    .find((path) => existsSync(join(path, "control.sock")));
  assert.ok(mediaRuntimeRoot, "macOS media test could not find the host runtime root");
  const mediaProviderSockets = readdirSync(mediaRuntimeRoot, { withFileTypes: true })
    .filter((entry) => entry.isSocket() && entry.name.startsWith("widget-"));
  assert.equal(
    mediaProviderSockets.length,
    1,
    "transport-capable unavailable media did not allocate its duplex command endpoint",
  );
  assert.ok(
    ["available", "unavailable"].includes(status().providers.mediaAvailability),
    "macOS media adapter did not expose an honest live-or-loss diagnostic",
  );
  run(["uninstall", "Now Playing"]);
  await waitFor("macOS media adapter teardown", () => {
    const document = status();
    return document?.widgets?.length === 0 && document.providers?.mediaSubscribers === 0 &&
      document.providers.mediaAvailability === "idle" && document;
  });

  run(["init", "media-recovery"]);
  writeFileSync(join(scratch, "media-recovery", "widget.tsx"), `
import { useInterval, useMediaTransport, useProvider, useState, useStorage, widget } from "@weaver/sdk";

export default widget({
  name: "Media Recovery",
  size: [260, 72],
  anchor: { corner: "bottom-left", offset: [24, 24] },
  subscribe: ["media"],
  capabilities: ["media-transport"],
}, () => {
  const media = useProvider("media");
  const transport = useMediaTransport();
  const [attempted, setAttempted] = useState(false);
  const [outcome, setOutcome] = useStorage("transport", "pending");
  useInterval(() => {
    if (attempted) return;
    setAttempted(true);
    void transport.pause().then((ok) => {
      setOutcome(\`resolved:\${ok}\`);
      console.log(\`media recovery command resolved:\${ok}\`);
    }).catch((error) => setOutcome(\`rejected:\${String(error)}\`));
  }, 2000);
  return <column class="w-[260px] h-[72px] p-3 bg-[#11141c]">
    <text class="text-sm text-white">{outcome}</text>
    <text class="text-xs text-white">{media.status}</text>
  </column>;
});
`, "utf8");
  const recoveryFramesBeforeInstall = status().providers.mediaPipeFrames;
  writeFileSync(providerSendFailure, "fail-next-send", "utf8");
  run(["install", "media-recovery"]);
  const firstRecovery = await waitFor("initial media recovery Widget", () => {
    const document = status();
    const widget = document?.widgets?.[0];
    return widget?.name === "Media Recovery" && widget.state === "running" &&
      document.providers?.mediaPipeFrames > recoveryFramesBeforeInstall &&
      { document, widget };
  }, 15_000);
  trackedPids.add(firstRecovery.widget.pid);
  const firstRecoverySockets = readdirSync(mediaRuntimeRoot, { withFileTypes: true })
    .filter((entry) => entry.isSocket() && entry.name.startsWith("widget-"))
    .map((entry) => entry.name);
  assert.equal(firstRecoverySockets.length, 1, "initial recovery Widget did not own exactly one provider endpoint");

  const replacementRecovery = await waitFor("runtime-fatal provider send recovery", () => {
    const document = status();
    const widget = document?.widgets?.[0];
    return widget?.name === "Media Recovery" && widget.state === "running" &&
      widget.pid !== firstRecovery.widget.pid && !alive(firstRecovery.widget.pid) &&
      document.providers?.mediaPipeFrames > firstRecovery.document.providers.mediaPipeFrames &&
      { document, widget };
  }, 20_000);
  trackedPids.add(replacementRecovery.widget.pid);
  assert.equal(existsSync(providerSendFailure), false, "injected send failure was not consumed by the crashed runtime");
  const replacementRecoverySockets = readdirSync(mediaRuntimeRoot, { withFileTypes: true })
    .filter((entry) => entry.isSocket() && entry.name.startsWith("widget-"))
    .map((entry) => entry.name);
  assert.equal(replacementRecoverySockets.length, 1, "replacement recovery Widget did not own exactly one provider endpoint");
  assert.notEqual(replacementRecoverySockets[0], firstRecoverySockets[0], "supervision reused the failed provider endpoint");
  // The attended 2026-07-26 run in pr05-mac-verify.md proves the recovered
  // channel remains usable on real hardware. This hosted seam's product
  // contract is the replacement PID/endpoint, resumed provider frame, and a
  // subsequent command callback. Observe that callback at its runtime log
  // boundary instead of waiting for useStorage's unrelated debounced file
  // write; keeping the deliberately crash-injected fixture alive after the
  // callback races the synthetic supervisor backoff and tests persistence,
  // not media-channel recovery.
  await waitFor(
    "successful media command after runtime-fatal recovery",
    () => widgetLogs().includes("media recovery command resolved:false"),
    15_000,
  );
  run(["uninstall", "Media Recovery"]);
  await waitFor("media recovery teardown", () => status()?.widgets?.length === 0);

  const validEmptyRegistry = readFileSync(registryFile, "utf8");
  writeFileSync(registryFile, "{ malformed\n", "utf8");
  const rejectedReload = spawnSync(hostExecutable, ["--signal-reload"], { cwd: repoRoot, env: environment, encoding: "utf8" });
  assert.equal(rejectedReload.status, 1, `malformed registry reload unexpectedly passed\n${rejectedReload.stderr}`);
  assert.match(rejectedReload.stderr, /RegistryReloadFailed/);
  assert.equal(alive(status().hostPid), true, "malformed registry killed the host");
  assert.deepEqual(status().widgets, [], "malformed registry changed the live supervisor slots");
  writeFileSync(registryFile, validEmptyRegistry, "utf8");
  const recoveredReload = spawnSync(hostExecutable, ["--signal-reload"], { cwd: repoRoot, env: environment, encoding: "utf8" });
  assert.equal(recoveredReload.status, 0, `valid registry did not recover acknowledged reload\n${recoveredReload.stderr}`);

  run(["init", "alpha"]);
  run(["init", "beta"]);
  const installs = await Promise.all([runAsync(["install", "alpha"]), runAsync(["install", "beta"])]);
  for (const result of installs) assert.equal(result.code, 0, `concurrent install failed\nstdout:\n${result.stdout}\nstderr:\n${result.stderr}`);
  await waitFor("both concurrent installs in status", () => status()?.widgets?.length === 2);
  assert.deepEqual(status().widgets.map((widget) => widget.name).sort(), ["Alpha", "Beta"]);
  const uninstalls = await Promise.all([runAsync(["uninstall", "Alpha"]), runAsync(["uninstall", "Beta"])]);
  for (const result of uninstalls) assert.equal(result.code, 0, `concurrent uninstall failed\nstdout:\n${result.stdout}\nstderr:\n${result.stderr}`);
  await waitFor("both concurrent uninstalls in status", () => status()?.widgets?.length === 0);
  assert.equal(status().providers.systemSampleCount, 0, "host sampled system providers without a subscriber");

  run(["init", "system-two"]);
  const systemSource = readFileSync(join(repoRoot, "examples", "system", "widget.tsx"), "utf8");
  writeFileSync(join(scratch, "system-two", "widget.tsx"), systemSource.replaceAll("System Monitor", "System Monitor 2"), "utf8");
  run(["install", join(repoRoot, "examples", "system")]);
  run(["install", "system-two"]);
  await waitFor("system-provider fan-out", () => {
    const document = status();
    const providers = document?.providers;
    // `systemFrames` counts successful per-endpoint writes, while subscriber
    // and running-widget counts prove both per-widget endpoints are active.
    // Do not infer packet boundaries from SOCK_STREAM or log flush timing.
    return document?.widgets?.length === 2 &&
      document.widgets.every((widget) => widget.state === "running") &&
      providers?.systemSubscribers === 2 && providers.systemSampleCount >= 2 &&
      providers.systemFrames >= providers.systemSubscribers * 4;
  });
  const activeRuntimeRoot = runtimeSearchRoots.flatMap((root) => readdirSync(root)
    .filter((name) => name.startsWith(runtimeRootPrefix))
    .map((name) => join(root, name)))
    .filter((path) => !runtimeEntriesBefore.has(path))
    .find((path) => existsSync(join(path, "control.sock")));
  assert.ok(activeRuntimeRoot, "macOS host did not create its short per-user runtime root");
  const providerSockets = readdirSync(activeRuntimeRoot, { withFileTypes: true }).filter((entry) => entry.isSocket() && entry.name.startsWith("widget-"));
  assert.equal(providerSockets.length, 2, "provider fan-out did not create one Unix socket per Widget");
  assert.ok(providerSockets.every((entry) => join(activeRuntimeRoot, entry.name).length <= 104), "provider Unix socket exceeded macOS sun_path capacity");
  const systemUninstalls = await Promise.all([runAsync(["uninstall", "System Monitor"]), runAsync(["uninstall", "System Monitor 2"])]);
  for (const result of systemUninstalls) assert.equal(result.code, 0, `concurrent System uninstall failed\n${result.stderr}`);
  await waitFor("system provider shutdown", () => status()?.providers?.systemSubscribers === 0 && status()?.widgets?.length === 0);
  assert.ok(providerSockets.every((entry) => !existsSync(join(activeRuntimeRoot, entry.name))), "uninstall left a per-Widget provider endpoint behind");
  const providerSamplesAfterStop = status().providers.systemSampleCount;
  await new Promise((resolvePromise) => setTimeout(resolvePromise, 2200));
  assert.equal(status().providers.systemSampleCount, providerSamplesAfterStop, "host continued sampling after the final system subscriber stopped");

  run(["init", "visualizer-two"]);
  const visualizerSource = readFileSync(join(repoRoot, "examples", "visualizer", "widget.tsx"), "utf8");
  writeFileSync(join(scratch, "visualizer-two", "widget.tsx"), visualizerSource
    .replace('name: "Visualizer"', 'name: "Visualizer 2"')
    .replace("offset: [24, 24]", "offset: [336, 24]"), "utf8");
  cpSync(join(repoRoot, "examples", "visualizer", "assets"), join(scratch, "visualizer-two", "assets"), { recursive: true });
  cpSync(join(repoRoot, "examples", "visualizer", "Cozette-Subset.ttf"), join(scratch, "visualizer-two", "Cozette-Subset.ttf"));
  writeFileSync(audioControl, "s", "utf8");
  const visualizerInstalls = await Promise.all([
    runAsync(["install", join(repoRoot, "examples", "visualizer")]),
    runAsync(["install", "visualizer-two"]),
  ]);
  for (const result of visualizerInstalls) assert.equal(result.code, 0, `concurrent Visualizer install failed\n${result.stderr}`);
  await waitFor("explicit audio authorization boundary", () => {
    const providers = status()?.providers;
    return providers?.audioSubscribers === 2 && providers.audioAvailability === "authorization-required" &&
      providers.audioCaptureStarts === 0 && providers;
  });

  writeFileSync(audioControl, "p", "utf8");
  const denied = run(["audio", "authorize"], 1);
  assert.match(denied.stderr, /could not authorize macOS system audio/i);
  writeFileSync(audioControl, "a", "utf8");
  run(["audio", "authorize"]);
  const liveAudio = await waitFor("one audio capture fanning out to two Visualizers", () => {
    const providers = status()?.providers;
    const logs = ["Visualizer.log", "Visualizer 2.log"]
      .map((name) => join(environment.HOME, "Library", "Logs", "Weaver", name));
    return providers?.audioSubscribers === 2 && providers.audioAvailability === "live" &&
      providers.audioCaptureStarts === 1 && providers.audioProviderFrames >= 2 && providers.audioPipeFrames >= 2 &&
      logs.every((path) => existsSync(path) && readFileSync(path, "utf8").includes("widget provider frames applied")) && providers;
  });

  writeFileSync(audioControl, "s", "utf8");
  await waitFor("audio decay and final zero", () => {
    const providers = status()?.providers;
    return providers?.audioAvailability === "live" && providers.audioSilent === true &&
      providers.audioProviderFrames > liveAudio.audioProviderFrames && providers;
  }, 15_000);
  const parkedFrames = status().providers.audioProviderFrames;
  await new Promise((resolvePromise) => setTimeout(resolvePromise, 2500));
  assert.equal(status().providers.audioProviderFrames, parkedFrames, "silent audio provider did not park after its final zero");

  writeFileSync(audioControl, "a", "utf8");
  await waitFor("audio resume after parked silence", () => {
    const providers = status()?.providers;
    return providers?.audioSilent === false && providers.audioProviderFrames > parkedFrames && providers;
  });
  const startsBeforeRevocation = status().providers.audioCaptureStarts;
  const framesBeforeRevocation = status().providers.audioProviderFrames;
  writeFileSync(audioControl, "r", "utf8");
  const revokedAudio = await waitFor("audio permission revocation", () => {
    const providers = status()?.providers;
    return providers?.audioAvailability === "permission-revoked" && providers.audioLastError !== 0 &&
      providers.audioSilent === true && providers.audioProviderFrames > framesBeforeRevocation && providers;
  });
  await new Promise((resolvePromise) => setTimeout(resolvePromise, 2200));
  assert.equal(status().providers.audioProviderFrames, revokedAudio.audioProviderFrames,
    "revoked audio emitted more than its final zero after reaching the revoked state");
  writeFileSync(audioControl, "a", "utf8");
  run(["audio", "authorize"]);
  await waitFor("audio reauthorization", () => {
    const providers = status()?.providers;
    return providers?.audioAvailability === "live" && providers.audioCaptureStarts === startsBeforeRevocation + 1 && providers;
  });

  const startsBeforeDeviceLoss = status().providers.audioCaptureStarts;
  writeFileSync(audioControl, "f", "utf8");
  await waitFor("audio device loss", () => status()?.providers?.audioAvailability === "device-unavailable");
  writeFileSync(audioControl, "a", "utf8");
  await waitFor("audio device recovery", () => {
    const providers = status()?.providers;
    return providers?.audioAvailability === "live" && providers.audioCaptureStarts > startsBeforeDeviceLoss && providers;
  });

  const visualizerUninstalls = await Promise.all([
    runAsync(["uninstall", "Visualizer"]),
    runAsync(["uninstall", "Visualizer 2"]),
  ]);
  for (const result of visualizerUninstalls) assert.equal(result.code, 0, `concurrent Visualizer uninstall failed\n${result.stderr}`);
  await waitFor("audio provider teardown", () => {
    const providers = status()?.providers;
    return status()?.widgets?.length === 0 && providers?.audioSubscribers === 0 &&
      providers.audioAvailability === "idle" && providers.audioCaptureActive === false && providers;
  });
  const audioFramesAfterStop = status().providers.audioProviderFrames;
  await new Promise((resolvePromise) => setTimeout(resolvePromise, 1000));
  assert.equal(status().providers.audioProviderFrames, audioFramesAfterStop, "host continued producing audio after the final subscriber stopped");

  run(["install", "clock"]);
  await waitFor("installed Clock", () => status()?.widgets?.[0]?.state === "running" && status().widgets[0]);
  const beforeHostCrash = status();
  const crashedHostPid = beforeHostCrash.hostPid;
  const orphanCandidatePid = beforeHostCrash.widgets[0].pid;
  trackedPids.add(crashedHostPid);
  trackedPids.add(orphanCandidatePid);
  process.kill(crashedHostPid, "SIGKILL");
  await waitFor("host crash", () => !alive(crashedHostPid));
  assert.equal(alive(orphanCandidatePid), true, "fixture did not establish the adverse orphan order");
  run(["up"]);
  await waitFor("replacement host and Widget recovery", () => {
    const document = status();
    const widget = document?.widgets?.[0];
    return document?.hostPid !== crashedHostPid && widget?.state === "running" && widget.pid !== orphanCandidatePid && widget;
  });
  assert.equal(alive(orphanCandidatePid), false, "replacement host left the old Widget orphaned");

  const afterHostRecovery = status().widgets[0].pid;
  trackedPids.add(status().hostPid);
  trackedPids.add(afterHostRecovery);
  process.kill(afterHostRecovery, "SIGKILL");
  const firstRecoveryPid = await waitFor("first Widget crash recovery", () => {
    const widget = status()?.widgets?.[0];
    return widget?.state === "running" && widget.pid !== afterHostRecovery && widget.pid;
  });
  trackedPids.add(firstRecoveryPid);
  process.kill(firstRecoveryPid, "SIGKILL");
  await waitFor("observable Widget backoff", () => status()?.widgets?.[0]?.state === "backoff");
  const secondRecoveryPid = await waitFor("Widget recovery after backoff", () => {
    const widget = status()?.widgets?.[0];
    return widget?.state === "running" && widget.pid !== firstRecoveryPid && widget.pid;
  }, 15_000);
  trackedPids.add(secondRecoveryPid);

  run(["uninstall", "Clock"]);
  assert.deepEqual(status().widgets, [], "uninstall acknowledgement left a Widget slot");
  run(["down"]);
  await waitFor("daemon shutdown", () => !alive(status()?.hostPid));
  for (const pid of trackedPids) assert.equal(alive(pid), false, `Weaver process ${pid} remained after shutdown`);
  const runtimeEntriesAfter = runtimeSearchRoots.flatMap((root) => readdirSync(root)
    .filter((name) => name.startsWith(runtimeRootPrefix))
    .map((name) => join(root, name)))
    .filter((path) => !runtimeEntriesBefore.has(path));
  assert.deepEqual(runtimeEntriesAfter, [], `runtime endpoint or lock remained: ${runtimeEntriesAfter.join(", ")}`);
} finally {
  if (devProcess && devProcess.exitCode === null && devProcess.signalCode === null) {
    devProcess.kill("SIGINT");
    await waitForExit(devProcess).catch(() => devProcess.kill("SIGKILL"));
  }
  spawnSync(process.execPath, [cli, "down"], { cwd: scratch, env: environment, stdio: "ignore" });
  for (const pid of trackedPids) {
    try { process.kill(pid, "SIGKILL"); }
    catch { /* Already stopped. */ }
  }
  rmSync(scratch, { recursive: true, force: true });
}

process.stdout.write("macOS daemon, dev hot-swap, mutation, crash, and cleanup smoke passed\n");
