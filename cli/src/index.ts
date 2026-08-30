import { spawn, spawnSync } from "node:child_process";
import { createHash, randomUUID } from "node:crypto";
import { closeSync, copyFileSync, existsSync, mkdirSync, mkdtempSync, openSync, readFileSync, readSync, readdirSync, realpathSync, renameSync, rmSync, statSync, writeFileSync } from "node:fs";
import type { Dirent } from "node:fs";
import { basename, dirname, extname, isAbsolute, join, resolve } from "node:path";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";
import { build } from "esbuild";
import ts from "typescript";
import { compileClass, UtilityError } from "../../sdk/src/class-compiler.js";
import { signalDevReload } from "./dev-reload.js";
import { createDevRebuildLoop } from "./dev-rebuild-loop.js";
import { endDevRegistration } from "./dev-registration.js";
import { watchDevDirectory } from "./dev-watcher.js";
import { lowerIconSource, resolveIconSpec } from "./icon-transform.js";
import { originDeclared, originHost, originNotDeclaredMessage, validOriginHost } from "./origin.js";
import { publishCaptureArtifacts } from "./capture-publish.js";
import { formatStatus, pathInside, pathsEqual, readRegistry, readStatus, statusPath, weaverLogsPath, widgetsPath, withRegistryLock, writeRegistry, type RegistryDocument } from "./host-tools.js";
import { extractWeave, isWeaveSourceEntryIncluded, MAX_WEAVE_ARCHIVE_BYTES, openWeave, packWeave, type DeclaredSurface, type OpenedWeave, type WeaveManifest } from "./weave.js";

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const sdkRoot = join(repoRoot, "sdk", "src");
const sdkAssetsRoot = join(sdkRoot, "..", "assets");
const iconLicenseSource = join(sdkAssetsRoot, "LUCIDE-LICENSE.txt");
const iconLicenseFile = "Lucide-LICENSE.txt";
const executableSuffix = process.platform === "win32" ? ".exe" : "";
const runtimeExecutable = join(repoRoot, "runtime", "zig-out", "bin", `weaver-widget${executableSuffix}`);
const hostExecutable = process.platform === "darwin"
  ? join(repoRoot, "host", "zig-out", "Weaverd.app", "Contents", "MacOS", "weaverd")
  : join(repoRoot, "host", "zig-out", "bin", `weaverd${executableSuffix}`);

class WeaverFailure extends Error {
  constructor(readonly details: string[]) {
    super(details.join("\n"));
    this.name = "WeaverFailure";
  }
}

interface SourceProject {
  directory: string;
  sourcePath: string;
  source: string;
  sourceFile: ts.SourceFile;
  sourceFiles: ts.SourceFile[];
  config: WidgetConfigData;
  fonts: RuntimeFont[];
  usesIcons: boolean;
}

type FontWeightName = "light" | "regular" | "medium" | "semibold" | "bold";

interface RuntimeFont {
  id: number;
  name: string;
  stem: string;
  family: string;
  weight: FontWeightName;
  file: string;
}

interface WidgetConfigData {
  name: string;
  size: [number, number];
  anchor?: {
    monitor?: "primary";
    corner: "top-left" | "top-right" | "bottom-left" | "bottom-right";
    offset?: [number, number];
  };
  layer?: "desktop" | "normal" | "topmost";
  clickThrough?: boolean;
  subscribe?: ("time" | "cpu" | "memory" | "audio" | "media")[];
  origins?: string[];
  capabilities?: ("media-transport")[];
}

interface RuntimeManifest {
  name: string;
  size: [number, number];
  anchor: NonNullable<WidgetConfigData["anchor"]>;
  layer: "desktop" | "normal" | "topmost";
  clickThrough: boolean;
  transparent: true;
  origins: string[];
  subscribe: ("time" | "cpu" | "memory" | "audio" | "media")[];
  capabilities: ("media-transport")[];
  renderBackend: "gpu" | "software";
  fonts: RuntimeFont[];
}

// Font receipt (2026-07-29): shipped widgets use one bundled face; the
// largest is 94,800 bytes (the Native SDK fixtures are 71/116 KiB). Two
// slots leave 2x face-count headroom and 512 KiB leaves 5.5x byte headroom.
// The runtime reserves 1 MiB for two slots with pages touched on registration.
// Pinned to native-sdk runtime/canvas_limits.zig's widget profile.
const MAX_WIDGET_FONTS = 2;
const MAX_WIDGET_FONT_BYTES = 512 * 1024;
// Shipped family names measure 17 bytes. The 63-byte ASCII stem grammar is
// the runtime wire bound, leaving 3.7x headroom; its inline storage is touched
// only for occupied nodes. Pinned to runtime/src/tree.zig.
const MAX_WIDGET_FONT_FAMILY_BYTES = 63;
const FIRST_REGISTERED_FONT_ID = 64;

interface BundleResult { project: SourceProject; manifest: RuntimeManifest }

interface CaptureOptions {
  out: string;
  clock?: string;
  actionFile?: string;
  providerFixture?: string;
  sessionJournal?: string;
}

interface NativeCaptureResult {
  schema: "native-sdk.capture.v1";
  status: "ok" | "error";
  output?: { widthPx: number; heightPx: number; pngBytes: number };
  renderer?: {
    pixels: "reference";
    textMeasurement: "estimator" | "coretext";
    eventsDriven: string[];
    framesDriven: number;
    retainedRevision: number;
    commands: number;
    nodes: number;
    images: number;
    fonts: number;
    pixelsDifferentFromClear: number;
  };
  pending?: { timers: number; fetches: number; images: number; providers: string[]; frameRequests: number };
  timingUs?: { startup: number; render: number; encode: number; write: number; total: number };
  warnings?: string[];
  error?: { name: string; ask: string; remedy: string; candidates?: CaptureCandidate[] };
}

interface CaptureCandidate {
  role: string;
  name: string;
  enabled: boolean;
  selected: boolean;
  value: number | null;
}

interface CaptureMediaCommandFixture {
  verb: "play" | "pause" | "next" | "previous" | "seek";
  seekMs?: number;
  ok: boolean;
}

interface ValidatedCaptureProviderFixture {
  commands: CaptureMediaCommandFixture[];
}

interface CaptureReceipt {
  schema: "weaver.capture.v1";
  status: "ok" | "error";
  provenance: { weaverCommit: string; nativeSdkCommit: string; bundleSha256: string; platform: string };
  output: { image: string; snapshot: string; widthPx: number; heightPx: number; scale: number; pngBytes: number };
  renderer: {
    pixels: "reference";
    textMeasurement: "estimator" | "coretext";
    eventsDriven: string[];
    framesDriven: number;
    retainedRevision: number;
    commands: number;
    nodes: number;
    images: number;
    fonts: number;
    pixelsDifferentFromClear: number;
  };
  pending: { timers: number; fetches: number; images: number; providers: string[]; frameRequests: number };
  timingUs: { bundle: number; spawn: number; startup: number; render: number; encode: number; write: number; total: number };
  inputs: { clock: string; storage: string; actionFileSha256?: string; providerFixtureSha256?: string; sessionJournalSha256?: string };
  interactions?: { actions: string[]; mediaCommands: CaptureMediaCommandFixture[] };
  warnings: string[];
  error?: { name: string; ask: string; remedy: string; candidates?: CaptureCandidate[] };
}

async function main(argv: string[]): Promise<void> {
  const [command, argument, ...rest] = argv;
  const directoryCommands = ["init", "check", "bundle", "dev", "pack"];
  const noArgumentCommands = ["up", "down"];
  if (command === "logs") {
    if (!argument || rest.length > 1 || (rest.length === 1 && rest[0] !== "--follow")) throw new WeaverFailure(["Usage: weaver logs <name> [--follow]"]);
    return showLogs(argument, rest[0] === "--follow");
  }
  if (command === "inspect") {
    if (!argument || rest.length > 0) throw new WeaverFailure(["Usage: weaver inspect <file.weave>"]);
    return inspectWidget(resolve(argument));
  }
  if (command === "audio") {
    if (argument !== "authorize" || rest.length > 0) throw new WeaverFailure(["Usage: weaver audio authorize"]);
    return authorizeAudio();
  }
  if (command === "capture") {
    if (!argument) throw new WeaverFailure([captureUsage()]);
    return captureWidget(resolve(argument), parseCaptureOptions(rest));
  }
  if (!command || rest.length > 0 || (directoryCommands.includes(command) && !argument) || (noArgumentCommands.includes(command) && argument) || (command === "install" && !argument) || (command === "uninstall" && !argument) || (command === "status" && argument !== undefined && argument !== "--json") || ![...directoryCommands, ...noArgumentCommands, "install", "uninstall", "status"].includes(command)) {
    throw new WeaverFailure(["Usage: weaver <init|check|bundle|dev|pack> <name-or-directory> | capture <directory> --out <file.png> [--clock <ISO-8601>] [--action-file <file>] [--provider-fixture <file>] [--session-journal <file>] | inspect <file.weave> | install <directory-or-file.weave> | uninstall <name> | up | down | status [--json] | logs <name> [--follow] | audio authorize"]);
  }
  if (command === "up") return upHost(true);
  if (command === "down") return downHost();
  if (command === "status") return showStatus(argument === "--json");
  if (command === "uninstall") return uninstallWidget(argument!);
  if (command === "init") return initWidget(argument!);
  const target = resolve(argument!);
  if (command === "install") return installWidget(target);
  const directory = target;
  if (command === "check") {
    checkWidget(directory);
    process.stdout.write(`weaver check passed: ${directory}\n`);
    return;
  }
  if (command === "bundle") {
    await bundleWidget(directory);
    process.stdout.write(`weaver bundle wrote ${join(directory, "dist")}\n`);
    return;
  }
  if (command === "pack") return packWidget(directory);
  await devWidget(directory);
}

function initWidget(target: string): void {
  const directory = resolve(target);
  const name = basename(directory);
  if (!/^[a-zA-Z][a-zA-Z0-9_-]*$/.test(name)) {
    throw new WeaverFailure([`Invalid widget directory name "${name}" from target "${target}". The final path segment must start with a letter and contain only letters, numbers, hyphens, or underscores.`]);
  }
  if (existsSync(directory)) throw new WeaverFailure([`Cannot initialize ${directory}: the path already exists.`]);
  mkdirSync(directory, { recursive: true });
  const displayName = name.replace(/[-_]+/g, " ").replace(/\b\w/g, (letter) => letter.toUpperCase());
  writeFileSync(join(directory, "widget.tsx"), starterSource(displayName), "utf8");
  writeAuthoringTsconfig(directory);
  process.stdout.write(`Initialized ${directory}\nNext: weaver check ${shellCommandArgument(directory)}\n`);
}

function shellCommandArgument(value: string): string {
  if (process.platform === "win32") return `"${value.replace(/"/g, '""')}"`;
  return `'${value.replace(/'/g, "'\\''")}'`;
}

function writeAuthoringTsconfig(directory: string): void {
  writeFileSync(join(directory, "tsconfig.json"), `${JSON.stringify({
    compilerOptions: {
      target: "ES2020",
      module: "ESNext",
      moduleResolution: "Bundler",
      strict: true,
      noEmit: true,
      skipLibCheck: true,
      jsx: "react-jsx",
      jsxImportSource: "@weaver/sdk",
      types: [],
      // Widgets scaffold anywhere on disk, not just inside the Weaver
      // monorepo, so the SDK types must be reachable by absolute path.
      baseUrl: ".",
      paths: {
        "@weaver/sdk": [join(repoRoot, "sdk", "index.d.ts").replace(/\\/g, "/")],
        "@weaver/sdk/jsx-runtime": [join(repoRoot, "sdk", "jsx-runtime.d.ts").replace(/\\/g, "/")],
      },
    },
    include: ["widget.tsx"],
  }, null, 2)}\n`, "utf8");
}

function starterSource(name: string): string {
  return `import { useProvider, widget } from "@weaver/sdk";

export default widget({
  name: ${JSON.stringify(name)},
  size: [240, 110],
  anchor: { corner: "top-right", offset: [24, 24] },
  subscribe: ["time"],
}, () => {
  const time = useProvider("time");
  return (
    <column class="p-4 gap-1 bg-[#11141c]/86 rounded-2xl">
      <row class="items-baseline gap-2">
        <text class="text-3xl font-light">{time.hh}:{time.mm}</text>
        <text class="text-sm opacity-70">{time.ss}</text>
      </row>
      <text class="text-xs opacity-60">{time.weekday}, {time.month} {time.day}</text>
    </column>
  );
});
`;
}

function checkWidget(directory: string): SourceProject {
  const project = loadProject(directory);
  const errors = validateSource(project);
  const tsc = runTypeScript(directory);
  if (tsc) errors.push(...tsc.split(/\r?\n/).filter(Boolean).map((line) => `TypeScript: ${line}`));
  if (errors.length > 0) throw new WeaverFailure(errors);
  return project;
}

async function bundleWidget(directory: string): Promise<BundleResult> {
  const project = checkWidget(directory);
  const outputDirectory = join(directory, "dist");
  mkdirSync(outputDirectory, { recursive: true });
  copyWidgetAssets(directory, outputDirectory);
  const bundle = await compileWidgetBundle(project, join(outputDirectory, "bundle.js"));
  if (project.usesIcons) {
    copyFileSync(iconLicenseSource, join(outputDirectory, iconLicenseFile));
  }
  writeAtomic(join(outputDirectory, "bundle.js"), bundle);
  const manifest: RuntimeManifest = {
    name: project.config.name,
    size: project.config.size,
    anchor: project.config.anchor ?? { monitor: "primary", corner: "top-right", offset: [24, 24] },
    layer: project.config.layer ?? "desktop",
    clickThrough: project.config.clickThrough ?? false,
    transparent: true,
    origins: project.config.origins ?? [],
    subscribe: project.config.subscribe ?? [],
    capabilities: project.config.capabilities ?? [],
    renderBackend: project.sourceFiles.some(sourceNeedsGpuSurface) ? "gpu" : "software",
    fonts: project.fonts,
  };
  writeAtomic(join(outputDirectory, "widget.json"), `${JSON.stringify(manifest, null, 2)}\n`);
  return { project, manifest };
}

function captureUsage(): string {
  return "Usage: weaver capture <directory> --out <file.png> [--clock <ISO-8601>] [--action-file <file>] [--provider-fixture <file>] [--session-journal <file>]";
}

function parseCaptureOptions(args: string[]): CaptureOptions {
  const values = new Map<string, string>();
  const allowed = new Set(["--out", "--clock", "--action-file", "--provider-fixture", "--session-journal"]);
  for (let index = 0; index < args.length; index += 2) {
    const flag = args[index];
    const value = args[index + 1];
    if (!flag || !allowed.has(flag) || !value || value.startsWith("--")) throw new WeaverFailure([captureUsage()]);
    if (values.has(flag)) throw new WeaverFailure([`weaver capture received ${flag} more than once.`, captureUsage()]);
    values.set(flag, value);
  }
  const out = values.get("--out");
  if (!out || extname(out).toLowerCase() !== ".png") throw new WeaverFailure(["weaver capture --out must name a .png file.", captureUsage()]);
  if (values.has("--action-file") && values.has("--session-journal")) {
    throw new WeaverFailure(["weaver capture accepts an action file or a session journal, not both in one run.", captureUsage()]);
  }
  return {
    out: resolve(out),
    clock: optionalCaptureClock(values.get("--clock")),
    actionFile: optionalResolvedPath(values.get("--action-file")),
    providerFixture: optionalResolvedPath(values.get("--provider-fixture")),
    sessionJournal: optionalResolvedPath(values.get("--session-journal")),
  };
}

function optionalCaptureClock(value: string | undefined): string | undefined {
  if (value === undefined) return undefined;
  const parsed = new Date(value);
  if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$/.test(value) || !Number.isFinite(parsed.valueOf())) {
    throw new WeaverFailure([`CaptureClockInvalid: ${JSON.stringify(value)} is not an ISO-8601 instant. Use a value such as 2026-08-24T17:30:00.000Z.`]);
  }
  return parsed.toISOString();
}

function optionalResolvedPath(path: string | undefined): string | undefined {
  return path === undefined ? undefined : resolve(path);
}

async function captureWidget(directory: string, options: CaptureOptions): Promise<void> {
  const commandStart = nowMicroseconds();
  const snapshot = options.out.slice(0, -extname(options.out).length) + ".snapshot.txt";
  const receiptPath = options.out.slice(0, -extname(options.out).length) + ".receipt.json";
  const captureRoot = mkdtempSync(join(tmpdir(), "weaver-capture-"));
  const temporaryImage = join(captureRoot, "capture.png");
  const temporarySnapshot = join(captureRoot, "capture.snapshot.txt");
  const nativeResultPath = join(captureRoot, "native-result.json");
  const chosenClock = options.clock ?? new Date().toISOString();
  let bundleSha256 = "";
  let bundleUs = 0;
  let spawnUs = 0;
  let nativeResult: NativeCaptureResult | undefined;
  let providerFixture: ValidatedCaptureProviderFixture | undefined;
  let unavailableProviders: string[] = [];
  const warnings: string[] = [];
  try {
    if (!existsSync(runtimeExecutable)) {
      throw new CaptureInputFailure(
        "CaptureRuntimeNotBuilt",
        `build the runtime expected at ${runtimeExecutable}`,
        "run the platform build command in the README Quickstart, then rerun capture",
      );
    }
    for (const [kind, path] of [
      ["action file", options.actionFile],
      ["provider fixture", options.providerFixture],
      ["session journal", options.sessionJournal],
    ] as const) {
      if (path !== undefined && (!existsSync(path) || !statSync(path).isFile())) {
        throw new CaptureInputFailure(
          "CaptureInputNotFile",
          `${kind} is not a regular file: ${path}`,
          `supply an existing ${kind} path and rerun capture`,
        );
      }
    }

    const bundleStart = nowMicroseconds();
    const bundled = await bundleWidget(directory);
    bundleUs = nowMicroseconds() - bundleStart;
    const bundlePath = join(directory, "dist", "bundle.js");
    bundleSha256 = sha256File(bundlePath);
    if (gitDirty(repoRoot)) warnings.push("Weaver working tree contains uncommitted changes; provenance names the checkout commit.");
    if (gitDirty(join(repoRoot, "runtime", "native-sdk"))) warnings.push("Native SDK working tree contains uncommitted changes; provenance names the checkout commit.");
    unavailableProviders = bundled.manifest.subscribe.filter((provider) => provider !== "time");
    if (unavailableProviders.length > 0 && options.providerFixture === undefined) {
      throw new CaptureInputFailure(
        "CaptureProviderUnavailable",
        `provide recorded input for: ${unavailableProviders.join(", ")}`,
        `rerun with --provider-fixture <file> containing those provider frames`,
      );
    }
    if (options.providerFixture) {
      providerFixture = validateCaptureProviderFixture(
        options.providerFixture,
        bundled.manifest.subscribe,
        bundled.manifest.capabilities,
      );
    }

    const environment: NodeJS.ProcessEnv = {
      ...process.env,
      WEAVER_CAPTURE_STATE_ROOT: captureRoot,
      NATIVE_SDK_CAPTURE_IMAGE: temporaryImage,
      NATIVE_SDK_CAPTURE_SNAPSHOT: temporarySnapshot,
      NATIVE_SDK_CAPTURE_RESULT: nativeResultPath,
      WEAVER_CAPTURE_CLOCK: chosenClock,
      WEAVER_CAPTURE_CLOCK_EPOCH_MS: String(Date.parse(chosenClock)),
    };
    delete environment.WEAVER_HOST_PIPE;
    delete environment.WEAVER_HOST_ENDPOINT;
    delete environment.WEAVER_ART_CACHE;
    delete environment.WEAVER_BACKEND_FILE;
    delete environment.WEAVER_CAPTURE_PROVIDER_FIXTURE;
    delete environment.NATIVE_SDK_CAPTURE_ACTION_FILE;
    delete environment.NATIVE_SDK_CAPTURE_SESSION_JOURNAL;
    delete environment.NATIVE_SDK_SESSION_RECORD;
    delete environment.NATIVE_SDK_SESSION_REPLAY;
    if (options.actionFile) environment.NATIVE_SDK_CAPTURE_ACTION_FILE = options.actionFile;
    if (options.providerFixture) environment.WEAVER_CAPTURE_PROVIDER_FIXTURE = options.providerFixture;
    if (options.sessionJournal) environment.NATIVE_SDK_CAPTURE_SESSION_JOURNAL = options.sessionJournal;

    const spawnStart = nowMicroseconds();
    const child = spawnSync(runtimeExecutable, [join(directory, "dist")], {
      cwd: repoRoot,
      env: environment,
      stdio: ["ignore", "ignore", "inherit"],
      windowsHide: true,
    });
    spawnUs = nowMicroseconds() - spawnStart;
    if (existsSync(nativeResultPath)) {
      nativeResult = JSON.parse(readFileSync(nativeResultPath, "utf8")) as NativeCaptureResult;
    }
    if (child.error) throw child.error;
    if (child.status !== 0 || nativeResult?.status !== "ok") {
      if (nativeResult?.error) throw new CaptureInputFailure(
        nativeResult.error.name,
        nativeResult.error.ask,
        nativeResult.error.remedy,
        nativeResult.error.candidates,
      );
      throw new CaptureInputFailure(
        "CaptureRuntimeFailed",
        `inspect the runtime diagnostic above (exit ${child.status ?? "signal"})`,
        "fix the named widget or runtime failure, then rerun the same capture command",
      );
    }
    if (!nativeResult.output || !nativeResult.renderer || !nativeResult.pending || !nativeResult.timingUs) {
      throw new Error("capture runtime returned an incomplete native-sdk.capture.v1 result");
    }
    if (!existsSync(temporaryImage) || !existsSync(temporarySnapshot)) {
      throw new Error("capture runtime reported success without both PNG and semantic snapshot artifacts");
    }

    warnings.push(...(nativeResult.warnings ?? []));
    const nativeRenderer = nativeResult.renderer;
    const nativeOutput = nativeResult.output;
    const nativePending = nativeResult.pending;
    const nativeTiming = nativeResult.timingUs;
    const receipt: CaptureReceipt = {
      schema: "weaver.capture.v1",
      status: "ok",
      provenance: {
        weaverCommit: gitCommit(repoRoot),
        nativeSdkCommit: gitCommit(join(repoRoot, "runtime", "native-sdk")),
        bundleSha256,
        platform: `${process.platform}-headless-${nativeRenderer.textMeasurement}`,
      },
      output: {
        image: options.out,
        snapshot,
        widthPx: nativeOutput.widthPx,
        heightPx: nativeOutput.heightPx,
        scale: 1,
        pngBytes: nativeOutput.pngBytes,
      },
      renderer: nativeRenderer,
      pending: nativePending,
      timingUs: {
        bundle: bundleUs,
        spawn: spawnUs,
        startup: nativeTiming.startup,
        render: nativeTiming.render,
        encode: nativeTiming.encode,
        write: nativeTiming.write,
        total: 0,
      },
      inputs: {
        clock: chosenClock,
        storage: "isolated-empty",
        ...(options.actionFile ? { actionFileSha256: sha256File(options.actionFile) } : {}),
        ...(options.providerFixture ? { providerFixtureSha256: sha256File(options.providerFixture) } : {}),
        ...(options.sessionJournal ? { sessionJournalSha256: sha256File(options.sessionJournal) } : {}),
      },
      ...captureInteractions(options.actionFile, providerFixture),
      warnings,
    };
    const publishStart = nowMicroseconds();
    const imageBytes = readFileSync(temporaryImage);
    const snapshotBytes = readFileSync(temporarySnapshot);
    receipt.timingUs.write += nowMicroseconds() - publishStart;
    receipt.timingUs.total = nowMicroseconds() - commandStart;
    const receiptBytes = Buffer.from(`${JSON.stringify(receipt, null, 2)}\n`, "utf8");
    publishCaptureArtifacts([
      { path: options.out, bytes: imageBytes },
      { path: snapshot, bytes: snapshotBytes },
      { path: receiptPath, bytes: receiptBytes },
    ]);
    process.stdout.write(`${JSON.stringify(receipt)}\n`);
  } catch (error) {
    const named = error instanceof CaptureInputFailure
      ? error
      : new CaptureInputFailure("CaptureFailed", firstFailureLine(error), "fix the named failure, then rerun the same capture command");
    const receipt = failedCaptureReceipt({
      options,
      snapshot,
      chosenClock,
      bundleSha256,
      bundleUs,
      spawnUs,
      commandStart,
      nativeResult,
      unavailableProviders,
      warnings,
      error: named,
    });
    process.stdout.write(`${JSON.stringify(receipt)}\n`);
    process.stderr.write(`weaver capture failed: ${named.name}: ${named.ask}\nremedy: ${named.remedy}\n`);
    process.exitCode = 1;
  } finally {
    rmSync(captureRoot, { recursive: true, force: true });
  }
}

class CaptureInputFailure extends Error {
  constructor(readonly name: string, readonly ask: string, readonly remedy: string, readonly candidates?: CaptureCandidate[]) {
    super(ask);
  }
}

function failedCaptureReceipt(input: {
  options: CaptureOptions;
  snapshot: string;
  chosenClock: string;
  bundleSha256: string;
  bundleUs: number;
  spawnUs: number;
  commandStart: number;
  nativeResult?: NativeCaptureResult;
  unavailableProviders: string[];
  warnings: string[];
  error: CaptureInputFailure;
}): CaptureReceipt {
  const renderer = input.nativeResult?.renderer;
  const output = input.nativeResult?.output;
  const pending = input.nativeResult?.pending;
  const timing = input.nativeResult?.timingUs;
  return {
    schema: "weaver.capture.v1",
    status: "error",
    provenance: {
      weaverCommit: gitCommit(repoRoot),
      nativeSdkCommit: gitCommit(join(repoRoot, "runtime", "native-sdk")),
      bundleSha256: input.bundleSha256,
      platform: `${process.platform}-headless-${renderer?.textMeasurement ?? captureTextMeasurement()}`,
    },
    output: {
      image: input.options.out,
      snapshot: input.snapshot,
      widthPx: output?.widthPx ?? 0,
      heightPx: output?.heightPx ?? 0,
      scale: 1,
      pngBytes: output?.pngBytes ?? 0,
    },
    renderer: renderer ?? {
      pixels: "reference",
      textMeasurement: captureTextMeasurement(),
      eventsDriven: [], framesDriven: 0, retainedRevision: 0, commands: 0, nodes: 0, images: 0, fonts: 0, pixelsDifferentFromClear: 0,
    },
    pending: pending ?? { timers: 0, fetches: 0, images: 0, providers: input.unavailableProviders, frameRequests: 0 },
    timingUs: {
      bundle: input.bundleUs,
      spawn: input.spawnUs,
      startup: timing?.startup ?? 0,
      render: timing?.render ?? 0,
      encode: timing?.encode ?? 0,
      write: timing?.write ?? 0,
      total: nowMicroseconds() - input.commandStart,
    },
    inputs: {
      clock: input.chosenClock,
      storage: "isolated-empty",
      ...(input.options.actionFile && existsSync(input.options.actionFile) ? { actionFileSha256: sha256File(input.options.actionFile) } : {}),
      ...(input.options.providerFixture && existsSync(input.options.providerFixture) ? { providerFixtureSha256: sha256File(input.options.providerFixture) } : {}),
      ...(input.options.sessionJournal && existsSync(input.options.sessionJournal) ? { sessionJournalSha256: sha256File(input.options.sessionJournal) } : {}),
    },
    warnings: [...input.warnings, ...(input.nativeResult?.warnings ?? [])],
    error: {
      name: input.error.name,
      ask: input.error.ask,
      remedy: input.error.remedy,
      ...(input.error.candidates ? { candidates: input.error.candidates } : {}),
    },
  };
}

function validateCaptureProviderFixture(
  path: string,
  subscriptions: RuntimeManifest["subscribe"],
  capabilities: RuntimeManifest["capabilities"],
): ValidatedCaptureProviderFixture {
  let document: unknown;
  try {
    document = JSON.parse(readFileSync(path, "utf8"));
  } catch {
    throw new CaptureInputFailure(
      "CaptureProviderFixtureInvalid",
      `provider fixture is not valid JSON: ${path}`,
      "supply a weaver.provider-fixture.v1 JSON object and rerun capture",
    );
  }
  if (!isRecord(document) || document.schema !== "weaver.provider-fixture.v1" || !Array.isArray(document.frames) ||
      (document.commands !== undefined && !Array.isArray(document.commands)) ||
      Object.keys(document).some((key) => !["schema", "frames", "commands"].includes(key))) {
    throw new CaptureInputFailure(
      "CaptureProviderFixtureInvalid",
      `provider fixture must use schema weaver.provider-fixture.v1 with a frames array: ${path}`,
      "fix the fixture schema and rerun capture",
    );
  }
  const commands: CaptureMediaCommandFixture[] = [];
  const knownVerbs = new Set(["play", "pause", "next", "previous", "seek"]);
  for (const [index, command] of (document.commands ?? []).entries()) {
    const keysValid = isRecord(command) && Object.keys(command).every((key) => ["verb", "seekMs", "ok"].includes(key));
    const verb = isRecord(command) ? command.verb : undefined;
    const seekMs = isRecord(command) ? command.seekMs : undefined;
    const ok = isRecord(command) ? command.ok : undefined;
    const seekValueValid = verb === "seek"
      ? typeof seekMs === "number" && Number.isSafeInteger(seekMs) && seekMs >= 0
      : seekMs === undefined;
    if (!keysValid || typeof verb !== "string" || !knownVerbs.has(verb) || !seekValueValid || (ok !== undefined && typeof ok !== "boolean")) {
      throw new CaptureInputFailure(
        "CaptureProviderFixtureCommandInvalid",
        `provider fixture command ${index} must name play, pause, next, previous, or seek; only seek requires a non-negative JavaScript-safe integer seekMs, and ok must be boolean`,
        "fix the named command fixture entry and rerun capture",
      );
    }
    commands.push({
      verb: verb as CaptureMediaCommandFixture["verb"],
      ...(seekMs === undefined ? {} : { seekMs: seekMs as number }),
      ok: ok === undefined ? true : ok as boolean,
    });
  }
  if (commands.length > 0 && !capabilities.includes("media-transport")) {
    throw new CaptureInputFailure(
      "CaptureProviderFixtureCapabilityRequired",
      "provider fixture commands require the widget's media-transport capability",
      'add capabilities: ["media-transport"] to the widget config, or remove the command expectations',
    );
  }
  const declared = new Set<string>(subscriptions.filter((provider) => provider !== "time"));
  const supplied = new Set<string>();
  for (const [index, frame] of document.frames.entries()) {
    if (!isRecord(frame) || typeof frame.provider !== "string" || !("value" in frame)) {
      throw new CaptureInputFailure(
        "CaptureProviderFixtureInvalid",
        `provider fixture frame ${index} must contain a string provider and a value`,
        "fix the named frame and rerun capture",
      );
    }
    if (!declared.has(frame.provider)) {
      throw new CaptureInputFailure(
        "CaptureProviderFixtureUndeclared",
        `provider fixture frame ${index} names undeclared provider ${JSON.stringify(frame.provider)}`,
        `declare and subscribe to that provider in the widget, or remove the frame`,
      );
    }
    supplied.add(frame.provider);
  }
  const missing = [...declared].filter((provider) => !supplied.has(provider));
  if (missing.length > 0) {
    throw new CaptureInputFailure(
      "CaptureProviderFixtureMissingProvider",
      `provider fixture has no recorded frame for: ${missing.join(", ")}`,
      "add frames for every subscribed non-time provider and rerun capture",
    );
  }
  return { commands };
}

function captureInteractions(
  actionPath: string | undefined,
  fixture: ValidatedCaptureProviderFixture | undefined,
): { interactions?: CaptureReceipt["interactions"] } {
  const actions = actionPath === undefined
    ? []
    : (JSON.parse(readFileSync(actionPath, "utf8")) as { actions: { action: string }[] }).actions.map((action) => action.action);
  const mediaCommands = fixture?.commands ?? [];
  return actions.length === 0 && mediaCommands.length === 0 ? {} : {
    interactions: { actions, mediaCommands },
  };
}

function captureTextMeasurement(): "estimator" | "coretext" {
  return process.platform === "darwin" ? "coretext" : "estimator";
}

function sha256File(path: string): string {
  return createHash("sha256").update(readFileSync(path)).digest("hex");
}

function gitCommit(directory: string): string {
  const result = spawnSync("git", ["rev-parse", "HEAD"], { cwd: directory, encoding: "utf8", windowsHide: true });
  return result.status === 0 ? result.stdout.trim() : "unknown";
}

function gitDirty(directory: string): boolean {
  return spawnSync("git", ["status", "--porcelain", "--untracked-files=no"], { cwd: directory, encoding: "utf8", windowsHide: true }).stdout.trim().length > 0;
}

function nowMicroseconds(): number {
  return Number(process.hrtime.bigint() / 1000n);
}

async function compileWidgetBundle(project: SourceProject, outfile: string): Promise<Uint8Array> {
  const built = await build({
    entryPoints: [project.sourcePath],
    outfile,
    bundle: true,
    format: "iife",
    platform: "neutral",
    target: "es2020",
    jsx: "automatic",
    jsxImportSource: "@weaver/sdk",
    legalComments: "none",
    minify: true,
    plugins: [
      iconLoweringPlugin(project.directory, () => { project.usesIcons = true; }),
      weaverResolutionPlugin(project.directory),
    ],
    logLevel: "silent",
    write: false,
  });
  return built.outputFiles[0].contents;
}

async function packWidget(directory: string): Promise<void> {
  const project = checkWidget(directory);
  await compileWidgetBundle(project, join(directory, "bundle.js"));
  const packed = packWeave(directory, project.config.name, declaredSurface(project.config));
  const output = resolve(dirname(directory), `${basename(directory)}.weave`);
  writeAtomic(output, packed.bytes);
  process.stdout.write(`Packed ${project.config.name}\nArtifact: ${packed.manifest.artifactId}\nSource: ${packed.manifest.sourceId}\nWrote ${output}\n`);
}

function inspectWidget(input: string): void {
  if (!existsSync(input)) throw new WeaverFailure([`Archive does not exist: ${input}`]);
  const inputStat = statSync(input);
  if (!inputStat.isFile() || extname(input).toLowerCase() !== ".weave") {
    throw new WeaverFailure([`Inspect expects a regular .weave file: ${input}`]);
  }
  if (inputStat.size > MAX_WEAVE_ARCHIVE_BYTES) {
    throw new WeaverFailure([`Archive exceeds the ${MAX_WEAVE_ARCHIVE_BYTES / (1024 * 1024)} MiB .weave limit: ${input}`]);
  }
  let opened: OpenedWeave;
  try { opened = openWeave(readFileSync(input)); }
  catch (error) { throw new WeaverFailure([`Cannot open ${input}: ${errorMessage(error)}`]); }
  const sourceBytes = [...opened.files.values()].reduce((total, bytes) => total + bytes.length, 0);
  printArtifactAudit(opened.manifest, opened.files.size, sourceBytes);
}

function declaredSurface(config: WidgetConfigData): DeclaredSurface {
  return {
    providers: [...(config.subscribe ?? [])],
    origins: [...(config.origins ?? [])],
    capabilities: [...(config.capabilities ?? [])],
  };
}

function writeAtomic(path: string, data: string | Uint8Array): void {
  const temporary = `${path}.${process.pid}.${randomUUID()}.tmp`;
  try {
    writeFileSync(temporary, data);
    renameSync(temporary, path);
  } finally {
    if (existsSync(temporary)) rmSync(temporary, { force: true });
  }
}

function sourceNeedsGpuSurface(sourceFile: ts.SourceFile): boolean {
  const hIdentifiers = new Set(["h"]);
  const hNamespaces = new Set<string>();
  for (const statement of sourceFile.statements) {
    if (!ts.isImportDeclaration(statement) || !ts.isStringLiteral(statement.moduleSpecifier) ||
      statement.moduleSpecifier.text !== "@weaver/sdk" || !statement.importClause) continue;
    const bindings = statement.importClause.namedBindings;
    if (bindings && ts.isNamedImports(bindings)) {
      for (const binding of bindings.elements) {
        if ((binding.propertyName?.text ?? binding.name.text) === "h") hIdentifiers.add(binding.name.text);
      }
    } else if (bindings && ts.isNamespaceImport(bindings)) {
      hNamespaces.add(bindings.name.text);
    }
  }
  const isHCall = (node: ts.CallExpression): boolean => {
    if (ts.isIdentifier(node.expression)) return hIdentifiers.has(node.expression.text);
    if (ts.isPropertyAccessExpression(node.expression)) {
      return ts.isIdentifier(node.expression.expression) &&
        hNamespaces.has(node.expression.expression.text) && node.expression.name.text === "h";
    }
    if (ts.isElementAccessExpression(node.expression)) {
      return ts.isIdentifier(node.expression.expression) &&
        hNamespaces.has(node.expression.expression.text) &&
        node.expression.argumentExpression !== undefined &&
        ts.isStringLiteral(node.expression.argumentExpression) &&
        node.expression.argumentExpression.text === "h";
    }
    return false;
  };
  const propertyName = (name: ts.PropertyName): string | null => {
    if (ts.isIdentifier(name) || ts.isStringLiteral(name) || ts.isNumericLiteral(name)) return name.text;
    if (ts.isComputedPropertyName(name) && ts.isStringLiteral(name.expression)) return name.expression.text;
    return null;
  };
  const bindingScopes: Array<Map<string, ts.Expression | null>> = [new Map()];
  const bindName = (name: ts.BindingName, value: ts.Expression | null): void => {
    if (ts.isIdentifier(name)) {
      bindingScopes[bindingScopes.length - 1].set(name.text, value);
      return;
    }
    for (const element of name.elements) {
      if (!ts.isOmittedExpression(element)) bindName(element.name, null);
    }
  };
  const boundExpression = (name: string): ts.Expression | null | undefined => {
    for (let index = bindingScopes.length - 1; index >= 0; index -= 1) {
      const scope = bindingScopes[index];
      if (scope.has(name)) return scope.get(name);
    }
    return undefined;
  };
  const unwrapExpression = (expression: ts.Expression): ts.Expression => {
    let current = expression;
    while (ts.isParenthesizedExpression(current) || ts.isAsExpression(current) ||
      ts.isTypeAssertionExpression(current) || ts.isNonNullExpression(current) || ts.isSatisfiesExpression(current)) {
      current = current.expression;
    }
    return current;
  };
  const staticString = (expression: ts.Expression, seen: Set<ts.Expression>): string | null => {
    const current = unwrapExpression(expression);
    if (ts.isStringLiteral(current) || ts.isNoSubstitutionTemplateLiteral(current)) return current.text;
    if (!ts.isIdentifier(current) || seen.has(current)) return null;
    const bound = boundExpression(current.text);
    if (!bound) return null;
    seen.add(current);
    return staticString(bound, seen);
  };
  const hPropsNeedGpu = (tag: string, props: ts.Expression | undefined): boolean => {
    if (tag === "canvas") return true;
    if (!["column", "row", "stack", "panel", "button"].includes(tag) || !props) return false;
    const seen = new Set<ts.Expression>();
    const objectNeedsGpu = (expression: ts.Expression): boolean => {
      const current = unwrapExpression(expression);
      if (seen.has(current)) return false;
      seen.add(current);
      if (ts.isIdentifier(current)) {
        const bound = boundExpression(current.text);
        return bound ? objectNeedsGpu(bound) : false;
      }
      if (!ts.isObjectLiteralExpression(current)) return false;
      if (current.properties.some((property) =>
        (ts.isPropertyAssignment(property) || ts.isShorthandPropertyAssignment(property)) &&
        propertyName(property.name) === "background")) return true;
      for (const property of current.properties) {
        if (ts.isSpreadAssignment(property) && objectNeedsGpu(property.expression)) return true;
        if (!ts.isPropertyAssignment(property) || propertyName(property.name) !== "class") continue;
        const classText = staticString(property.initializer, new Set());
        if (classText === null) continue;
        try {
          if (compileClass(classText).backgroundGradient !== undefined) return true;
        } catch {
          // The ordinary class validator reports malformed utilities.
        }
      }
      return false;
    };
    return objectNeedsGpu(props);
  };
  let found = false;
  const visit = (node: ts.Node): void => {
    if (ts.isVariableDeclaration(node)) {
      if (node.initializer) visit(node.initializer);
      bindName(node.name, node.initializer ?? null);
      return;
    }
    if (ts.isFunctionDeclaration(node) && node.name) bindName(node.name, null);
    if (ts.isClassDeclaration(node) && node.name) bindName(node.name, null);
    if (ts.isFunctionLike(node)) {
      bindingScopes.push(new Map());
      for (const parameter of node.parameters) bindName(parameter.name, null);
      ts.forEachChild(node, visit);
      bindingScopes.pop();
      return;
    }
    if (ts.isBlock(node) || ts.isModuleBlock(node) || ts.isCatchClause(node)) {
      bindingScopes.push(new Map());
      if (ts.isCatchClause(node) && node.variableDeclaration) bindName(node.variableDeclaration.name, null);
      ts.forEachChild(node, visit);
      bindingScopes.pop();
      return;
    }
    if (ts.isJsxOpeningElement(node) || ts.isJsxSelfClosingElement(node)) {
      const tag = node.tagName.getText(sourceFile);
      if (tag === "canvas") {
        found = true;
      } else if (["column", "row", "stack", "panel", "button"].includes(tag)) {
        const background = node.attributes.properties.find((attribute): attribute is ts.JsxAttribute =>
          ts.isJsxAttribute(attribute) && attribute.name.getText(sourceFile) === "background");
        if (background) {
          found = true;
        } else {
          const classAttribute = node.attributes.properties.find((attribute): attribute is ts.JsxAttribute =>
            ts.isJsxAttribute(attribute) && attribute.name.getText(sourceFile) === "class");
          const classText = classAttribute ? jsxStringValue(classAttribute.initializer) : "";
          if (classText !== null) {
            try {
              found = compileClass(classText).backgroundGradient !== undefined;
            } catch {
              // The ordinary class validator reports malformed utilities.
            }
          }
        }
      }
    }
    if (!found && ts.isCallExpression(node) && isHCall(node)) {
      const tag = node.arguments[0];
      if (tag && (ts.isStringLiteral(tag) || ts.isNoSubstitutionTemplateLiteral(tag))) {
        found = hPropsNeedGpu(tag.text, node.arguments[1]);
      }
    }
    if (!found) ts.forEachChild(node, visit);
  };
  visit(sourceFile);
  return found;
}

function sourceUsesIcon(sourceFile: ts.SourceFile): boolean {
  let found = false;
  const visit = (node: ts.Node): void => {
    if (ts.isJsxOpeningElement(node) || ts.isJsxSelfClosingElement(node)) {
      if (node.tagName.getText(sourceFile) === "icon") found = true;
    }
    if (!found) ts.forEachChild(node, visit);
  };
  visit(sourceFile);
  return found;
}

/// `dist` is the runtime artifact, so local image paths must mean the same
/// thing after install as they did beside widget.tsx. Copy every ordinary
/// widget-owned file recursively while excluding authoring/build outputs;
/// dynamic local `src` expressions then remain valid without a magic asset
/// directory or source-tree dependency.
function copyWidgetAssets(sourceDirectory: string, outputDirectory: string, root = true): void {
  for (const entry of readdirSync(sourceDirectory, { withFileTypes: true })) {
    if (!isWeaveSourceEntryIncluded(entry.name, root) || (root && entry.name === "widget.tsx")) continue;
    const source = join(sourceDirectory, entry.name);
    const destination = join(outputDirectory, entry.name);
    if (entry.isDirectory()) {
      mkdirSync(destination, { recursive: true });
      copyWidgetAssets(source, destination, false);
    } else if (entry.isFile()) {
      copyFileSync(source, destination);
    } else {
      throw new WeaverFailure([`Local widget asset ${source} must be a regular file or directory; links are not bundled.`]);
    }
  }
}

function weaverResolutionPlugin(sourceRoot: string): import("esbuild").Plugin {
  // esbuild resolves importer directories through the filesystem. On macOS,
  // tmpdir() commonly returns /var/... while the resolver reports the same
  // directory through its canonical /private/var/... path. Compare against
  // the canonical root so a real child is not mistaken for an escape.
  const canonicalSourceRoot = realpathSync(sourceRoot);
  return {
    name: "weaver-import-wall",
    setup(pluginBuild) {
      pluginBuild.onResolve({ filter: /^@weaver\/sdk$/ }, () => ({ path: join(sdkRoot, "index.ts") }));
      pluginBuild.onResolve({ filter: /^@weaver\/sdk\/jsx-runtime$/ }, () => ({ path: join(sdkRoot, "jsx-runtime.ts") }));
      pluginBuild.onResolve({ filter: /.*/ }, (args) => {
        if (args.kind === "entry-point") return null;
        if (args.importer && (pathsEqual(args.importer, sdkRoot) || pathInside(sdkRoot, args.importer))) return null;
        if (isAbsolute(args.path)) {
          return { errors: [{ text: `Absolute import "${args.path}" is not portable; use a relative path inside the widget source root` }] };
        }
        if (!args.path.startsWith(".")) {
          return { errors: [{ text: `External import "${args.path}" is not allowed in a widget. Only @weaver/sdk imports are bundled.` }] };
        }
        const candidate = resolve(args.resolveDir, args.path);
        if (!pathsEqual(candidate, canonicalSourceRoot) && !pathInside(canonicalSourceRoot, candidate)) {
          return { errors: [{ text: `Import "${args.path}" escapes the widget source root ${sourceRoot}` }] };
        }
        return null;
      });
    },
  };
}

function iconLoweringPlugin(sourceRoot: string, onIconSource: () => void): import("esbuild").Plugin {
  const canonicalSourceRoot = realpathSync(sourceRoot);
  return {
    name: "weaver-icon-lowering",
    setup(pluginBuild) {
      pluginBuild.onLoad({ filter: /\.tsx$/ }, (args) => {
        if (!pathsEqual(args.path, canonicalSourceRoot) && !pathInside(canonicalSourceRoot, args.path)) return null;
        const source = readFileSync(args.path, "utf8");
        try {
          const sourceFile = ts.createSourceFile(args.path, source, ts.ScriptTarget.Latest, true, ts.ScriptKind.TSX);
          if (sourceUsesIcon(sourceFile)) onIconSource();
          return { contents: lowerIconSource(args.path, source), loader: "tsx" };
        } catch (error) {
          return { errors: [{ text: error instanceof Error ? error.message : String(error), location: { file: args.path } }] };
        }
      });
    },
  };
}

async function devWidget(directory: string): Promise<void> {
  assertHostLifecycleAvailable("dev");
  assertRuntimeBuilt();
  await upHost(false);
  const initial = await bundleWidget(directory);
  const project = initial.project;
  let activeManifest = initial.manifest;
  let existing: RegistryDocument["widgets"][number] | undefined;
  const startupWarnings: string[] = [];
  await withRegistryLock(() => {
    const before = readRegistry();
    existing = before.widgets.find((widget) => widget.name === project.config.name);
    if (existing && !pathsEqual(existing.sourcePath, directory) && !ownedInstallPath(existing.sourcePath)) {
      throw new WeaverFailure([`Widget name "${project.config.name}" is already registered from ${existing.sourcePath}`]);
    }
    if (existing && !pathsEqual(existing.sourcePath, directory)) {
      process.stdout.write(`weaver dev is taking over installed widget "${project.config.name}" for this session; the installed copy resumes when dev exits\n`);
    }
    const nextRegistry = { widgets: [...before.widgets.filter((widget) => widget.name !== project.config.name), {
      name: project.config.name, sourcePath: directory, enabled: true, dev: true,
    }] };
    writeRegistry(nextRegistry);
    try { signalHost("--signal-reload"); }
    catch (error) {
      writeRegistry(before);
      try { signalHost("--signal-reload"); }
      catch { /* Preserve the reload failure after restoring the authoritative registry. */ }
      throw error;
    }
    // The installed registration is temporarily absent while dev owns the
    // name, but it is still the authoritative fallback we restore on exit.
    // Keep its owned directory out of the ordinary orphan sweep.
    const cleanupRegistry = existing
      ? { widgets: [...nextRegistry.widgets, existing] }
      : nextRegistry;
    startupWarnings.push(...sweepUnregisteredInstallDirectories(cleanupRegistry));
  });
  const logFollower = followLogFile(project.config.name, true);
  printCleanupWarnings(startupWarnings);
  let staleBuild: { since: Date; firstError: string } | null = null;
  const staleReminder = setInterval(() => {
    if (!staleBuild) return;
    process.stderr.write(`weaver dev OUT OF DATE since ${staleBuild.since.toISOString()}: ${staleBuild.firstError}\n`);
  }, 10_000);
  staleReminder.unref();
  const rebuild = async (): Promise<void> => {
    try {
      const next = await bundleWidget(directory);
      const configChanged = JSON.stringify(next.manifest) !== JSON.stringify(activeManifest);
      if (configChanged) {
        signalHost("--signal-reload");
        activeManifest = next.manifest;
        process.stdout.write("weaver dev restarted widget: window config changed\n");
      } else {
        await signalDevReload(directory);
        activeManifest = next.manifest;
        process.stdout.write("weaver dev bundle ready for in-place hot swap\n");
      }
      if (staleBuild) {
        process.stdout.write(`weaver dev caught up; the widget now matches disk (was out of date since ${staleBuild.since.toISOString()})\n`);
        staleBuild = null;
      }
    } catch (error) {
      printFailure(error);
      if (!staleBuild) {
        staleBuild = { since: new Date(), firstError: firstFailureLine(error) };
        process.stderr.write(`weaver dev OUT OF DATE since ${staleBuild.since.toISOString()}: ${staleBuild.firstError}; the window is still running the last good bundle\n`);
      }
    }
  };
  const rebuildLoop = createDevRebuildLoop(rebuild);
  let stopping = false;
  const watcher = watchDevDirectory(directory, () => {
    if (stopping) return;
    rebuildLoop.schedule();
  }, (error) => {
    if (stopping) return;
    process.stderr.write(`weaver dev WATCH ERROR: ${errorMessage(error)}; source changes may not rebuild until weaver dev restarts\n`);
  });
  process.stdout.write(`weaver dev watching source, assets, and fonts under ${directory}\n`);
  const presentationDeadline = Date.now() + 10_000;
  let presentationFailureReported = false;
  const presentationWatch = setInterval(() => {
    if (presentationFailureReported || Date.now() < presentationDeadline) return;
    try {
      const status = readStatus().widgets.find((widget) => widget.name === project.config.name);
      if (status && status.backend !== "-") {
        clearInterval(presentationWatch);
        return;
      }
      presentationFailureReported = true;
      const state = status ? `${status.state}${status.reason ? `: ${status.reason}` : ""}` : "absent from host status";
      process.stderr.write(`weaver dev ERROR: "${project.config.name}" has not presented a frame after 10 seconds (${state}); check weaver logs ${JSON.stringify(project.config.name)}\n`);
      clearInterval(presentationWatch);
    } catch (error) {
      presentationFailureReported = true;
      process.stderr.write(`weaver dev ERROR: presentation health could not be read after 10 seconds: ${errorMessage(error)}\n`);
      clearInterval(presentationWatch);
    }
  }, 1_000);
  presentationWatch.unref();
  await new Promise<void>((resolvePromise) => {
    const stop = (): void => {
      if (stopping) return;
      stopping = true;
      watcher.close();
      clearInterval(staleReminder);
      clearInterval(presentationWatch);
      void (async () => {
        try {
          await watcher.close();
        } catch (error) {
          printFailure(error);
        }
        try {
          await rebuildLoop.drain();
        } catch (error) {
          printFailure(error);
        }
        logFollower.stop();
        try {
          const shutdownWarnings: string[] = [];
          await withRegistryLock(() => {
            const current = readRegistry();
            const endedRegistry = endDevRegistration(
              current,
              project.config.name,
              directory,
              existing,
              writeRegistry,
              () => signalHost("--signal-reload"),
            );
            if (endedRegistry) {
              shutdownWarnings.push(...sweepUnregisteredInstallDirectories(endedRegistry));
            } else {
              shutdownWarnings.push(...sweepUnregisteredInstallDirectories(current));
            }
          });
          printCleanupWarnings(shutdownWarnings);
        } catch (error) {
          printFailure(error);
        } finally {
          process.off("SIGINT", stop);
          process.off("SIGTERM", stop);
          resolvePromise();
        }
      })();
    };
    process.on("SIGINT", stop);
    process.on("SIGTERM", stop);
  });
}

function logPath(name: string): string {
  const safe = name.replace(/[<>:"/\\|?*\u0000-\u001f]/g, "_").replace(/[. ]+$/g, "_") || "widget";
  return join(weaverLogsPath(), `${safe}.log`);
}

function showLogs(name: string, follow: boolean): Promise<void> | void {
  const path = logPath(name);
  const oldPath = `${path}.old`;
  if (!existsSync(path) && !existsSync(oldPath)) {
    const known = existsSync(weaverLogsPath())
      ? readdirSync(weaverLogsPath()).filter((file) => file.endsWith(".log")).map((file) => file.slice(0, -4))
      : [];
    const knownLine = known.length > 0 ? `Widgets with logs: ${known.join(", ")}` : `No widget has written a log yet (widgets log to ${weaverLogsPath()} once they start).`;
    if (!follow) {
      throw new WeaverFailure([`No log for "${name}" at ${path}`, knownLine, `The weaverd host process does not keep a log file; "weaver status" reports its widget states.`]);
    }
    process.stdout.write(`No log for "${name}" yet at ${path}; waiting for the widget to start.\n`);
  }
  const text = [oldPath, path].filter(existsSync).map((file) => readFileSync(file, "utf8")).join("");
  // Runtime rotation already bounds current + old logs to 2 MiB. A second
  // arbitrary line-count cap only hid older diagnostics and saved no read
  // memory (the files are already loaded), so show the complete bounded log.
  const lines = text.split(/\r?\n/).filter((line) => line.length > 0);
  const follower = follow ? followLogFile(name, true) : undefined;
  if (lines.length > 0) process.stdout.write(`${lines.join("\n")}\n`);
  if (!follower) return;
  return new Promise<void>((resolvePromise) => {
    const stop = (): void => { follower.stop(); resolvePromise(); };
    process.once("SIGINT", stop);
    process.once("SIGTERM", stop);
  });
}

function followLogFile(name: string, startAtEnd: boolean): { stop(): void } {
  const path = logPath(name);
  let offset = startAtEnd && existsSync(path) ? statSync(path).size : 0;
  const poll = (): void => {
    if (!existsSync(path)) return;
    const size = statSync(path).size;
    if (size < offset) offset = 0;
    if (size === offset) return;
    const length = size - offset;
    const bytes = Buffer.alloc(length);
    const descriptor = openSync(path, "r");
    try { readSync(descriptor, bytes, 0, length, offset); }
    finally { closeSync(descriptor); }
    offset = size;
    process.stdout.write(bytes);
  };
  const timer = setInterval(poll, 100);
  return { stop(): void { clearInterval(timer); poll(); } };
}

async function installWidget(input: string): Promise<void> {
  assertRuntimeBuilt();
  if (!existsSync(input)) throw new WeaverFailure([`Install source does not exist: ${input}`]);
  let opened: OpenedWeave;
  try {
    const inputStat = statSync(input);
    if (inputStat.isDirectory()) {
      const sourceProject = checkWidget(input);
      opened = openWeave(packWeave(input, sourceProject.config.name, declaredSurface(sourceProject.config)).bytes);
    } else {
      if (!inputStat.isFile()) throw new WeaverFailure([`Install source must be a regular directory or file: ${input}`]);
      if (extname(input).toLowerCase() !== ".weave") throw new WeaverFailure([`Install expects a widget directory or .weave file: ${input}`]);
      if (inputStat.size > MAX_WEAVE_ARCHIVE_BYTES) throw new WeaverFailure([`Archive exceeds the ${MAX_WEAVE_ARCHIVE_BYTES / (1024 * 1024)} MiB .weave limit: ${input}`]);
      opened = openWeave(readFileSync(input));
    }
  } catch (error) {
    if (error instanceof WeaverFailure) throw error;
    throw new WeaverFailure([`Cannot open ${input}: ${error instanceof Error ? error.message : String(error)}`]);
  }

  const root = widgetsPath();
  mkdirSync(root, { recursive: true });
  const destination = join(root, installDirectoryName(opened.manifest));
  const stage = mkdtempSync(join(root, `.install-${process.pid}-`));
  let stageExists = true;
  let finalExists = false;
  const cleanupWarnings: string[] = [];
  try {
    extractWeave(opened, stage);
    writeAuthoringTsconfig(stage);
    const project = checkWidget(stage);
    assertManifestMatchesSource(opened.manifest, project.config);
    await bundleWidget(stage);
    await withRegistryLock(async () => {
      const originalRegistry = readRegistry();
      if (hostLifecycleAvailable() && hostRunning()) assertHostReloadReady();
      const conflicting = originalRegistry.widgets.find((widget) => widget.name === project.config.name && !ownedInstallPath(widget.sourcePath));
      if (conflicting) {
        throw new WeaverFailure([`Widget name "${project.config.name}" is already registered from ${conflicting.sourcePath}`, `Run "weaver uninstall ${project.config.name}" before replacing a source-linked installation.`]);
      }
      if (hostLifecycleAvailable()) await upHost(false);
      renameSync(stage, destination);
      stageExists = false;
      finalExists = true;
      const nextRegistry = { widgets: [...originalRegistry.widgets.filter((widget) => widget.name !== project.config.name), {
        name: project.config.name, sourcePath: destination, enabled: true,
      }] };
      printInstallAudit(opened.manifest);
      if (process.env.WEAVER_AUTOMATION === "1" && process.env.WEAVER_AUTOMATION_FAIL_INSTALL_AFTER_PUBLISH === "1") {
        throw new WeaverFailure(["Automation refused the install after publishing its owned source."]);
      }
      writeRegistry(nextRegistry);
      if (hostLifecycleAvailable()) {
        try {
          signalHost("--signal-reload");
        } catch (error) {
          writeRegistry(originalRegistry);
          if (hostRunning()) {
            try { signalHost("--signal-reload"); }
            catch { /* Preserve the original failure; the registry is authoritative on the next reload. */ }
          }
          throw error;
        }
      }
      cleanupWarnings.push(...sweepUnregisteredInstallDirectories(nextRegistry));
    });
    finalExists = false;
    process.stdout.write(`Installed ${project.config.name}\nSource: ${destination}\n`);
  } finally {
    if (stageExists && existsSync(stage)) rmSync(stage, { recursive: true, force: true });
    if (finalExists) await removeUnregisteredInstall(destination);
    printCleanupWarnings(cleanupWarnings);
  }
}

function assertManifestMatchesSource(manifest: WeaveManifest, config: WidgetConfigData): void {
  if (manifest.name !== config.name) throw new WeaverFailure([`weave.json names "${manifest.name}" but source declares "${config.name}"`]);
  const actual = declaredSurface(config);
  for (const field of ["providers", "origins", "capabilities"] as const) {
    if (JSON.stringify(manifest.declared[field]) !== JSON.stringify(actual[field])) {
      throw new WeaverFailure([`weave.json declared.${field} does not match widget.tsx`]);
    }
  }
}

function printInstallAudit(manifest: WeaveManifest): void {
  const author = manifest.provenance.author === null ? "Author: local/unsigned" : `Claimed author (unverified): ${manifest.provenance.author}`;
  const providers = manifest.declared.providers.length > 0 ? manifest.declared.providers.join(", ") : "none";
  const origins = manifest.declared.origins.length > 0 ? manifest.declared.origins.join(", ") : "none";
  const capabilities = manifest.declared.capabilities.length > 0 ? manifest.declared.capabilities.join(", ") : "none";
  process.stdout.write(`Reviewing ${manifest.name}\n${author}\nArtifact: ${manifest.artifactId}\nSource: readable · ${manifest.sourceId}\nProviders: ${providers}\nNetwork origins: ${origins}\nSystem capabilities: ${capabilities}\n`);
}

function printArtifactAudit(manifest: WeaveManifest, sourceFiles: number, sourceBytes: number): void {
  const author = manifest.provenance.author === null ? "local/unsigned" : `${manifest.provenance.author} (claimed, unverified)`;
  const list = (values: string[]): string => values.length > 0 ? values.join(", ") : "none";
  process.stdout.write(`Name: ${manifest.name}\nFormat: .weave v${manifest.formatVersion}\nArtifact: ${manifest.artifactId}\nSource: ${manifest.sourceId}\nAuthor: ${author}\nLineage root: ${manifest.lineage.root}\nLineage parent: ${manifest.lineage.parent ?? "none"}\nProviders: ${list(manifest.declared.providers)}\nNetwork origins: ${list(manifest.declared.origins)}\nSystem capabilities: ${list(manifest.declared.capabilities)}\nReadable source: ${sourceFiles} files, ${sourceBytes} bytes\n`);
}

function installDirectoryName(manifest: WeaveManifest): string {
  // Shipped names measure 19 ASCII bytes at worst. A 48-byte slug leaves
  // >2.5x headroom and produces a directory component no longer than 111
  // bytes after hashes + UUID, well below the portable 255-byte OS bound.
  // Slicing retains no additional memory.
  const installSlugBytes = 48;
  const slug = manifest.name.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "").slice(0, installSlugBytes) || "widget";
  const nameHash = createHash("sha256").update(manifest.name, "utf8").digest("hex").slice(0, 12);
  const artifactHash = manifest.artifactId.slice("sha256:".length, "sha256:".length + 12);
  return `${slug}-${nameHash}-${artifactHash}-${randomUUID()}`;
}

function ownedInstallPath(path: string): boolean {
  const root = resolve(widgetsPath());
  const candidate = resolve(path);
  return pathInside(root, candidate) && existsSync(join(candidate, "weave.json"));
}

async function uninstallWidget(name: string): Promise<void> {
  const warnings: string[] = [];
  let installed = false;
  await withRegistryLock(() => {
    const document = readRegistry();
    const registration = document.widgets.find((widget) => widget.name === name);
    if (!registration) {
      const running = hostLifecycleAvailable() && hostRunning();
      if (running) {
        assertHostReloadReady();
        signalHost("--signal-reload");
      }
      warnings.push(...sweepUnregisteredInstallDirectories(document));
      return;
    }
    installed = true;
    const nextRegistry = { widgets: document.widgets.filter((widget) => widget.name !== name) };
    const running = hostLifecycleAvailable() && hostRunning();
    if (running) assertHostReloadReady();
    writeRegistry(nextRegistry);
    if (running) {
      try { signalHost("--signal-reload"); }
      catch (error) {
        writeRegistry(document);
        try { signalHost("--signal-reload"); }
        catch { /* Preserve the reload failure after restoring the authoritative registry. */ }
        throw error;
      }
    }
    warnings.push(...sweepUnregisteredInstallDirectories(nextRegistry));
  });
  printCleanupWarnings(warnings);
  if (!installed) throw new WeaverFailure([`Widget "${name}" is not installed.`]);
  process.stdout.write(`Uninstalled ${name}\n`);
}

function sweepUnregisteredInstallDirectories(document: RegistryDocument): string[] {
  const root = widgetsPath();
  if (!existsSync(root)) return [];
  const warnings: string[] = [];
  const registered = document.widgets.map((widget) => widget.sourcePath);
  let entries: Dirent[];
  try { entries = readdirSync(root, { withFileTypes: true }); }
  catch (error) { return [`Could not inspect owned widget sources at ${root}: ${errorMessage(error)}. A later registry mutation will retry cleanup.`]; }
  for (const entry of entries) {
    if (!entry.isDirectory()) continue;
    const candidate = join(root, entry.name);
    if (entry.name.startsWith(".install-")) {
      if (!abandonedInstallStage(candidate, entry.name)) continue;
      try { rmSync(candidate, { recursive: true, force: true }); }
      catch (error) { warnings.push(`Could not remove abandoned install stage at ${candidate}: ${errorMessage(error)}. A later registry mutation will retry cleanup.`); }
      continue;
    }
    if (registered.some((path) => pathsEqual(path, candidate)) || !existsSync(join(candidate, "weave.json"))) continue;
    try { rmSync(candidate, { recursive: true, force: true }); }
    catch (error) { warnings.push(`Could not remove unregistered owned source at ${candidate}: ${errorMessage(error)}. A later registry mutation will retry cleanup.`); }
  }
  return warnings;
}

function abandonedInstallStage(path: string, name: string): boolean {
  const staleMs = 5 * 60_000;
  let ageMs: number;
  try { ageMs = Date.now() - statSync(path).mtimeMs; }
  catch { return false; /* The directory disappeared or changed owner during the cleanup sweep; a later mutation retries. */ }
  if (ageMs <= staleMs) return false;
  const pid = /^\.install-(\d+)-/.exec(name)?.[1];
  if (!pid) return true;
  const ownerPid = Number(pid);
  if (!Number.isSafeInteger(ownerPid) || ownerPid <= 0) return true;
  try {
    process.kill(ownerPid, 0);
    return false;
  } catch (error) {
    return error instanceof Error && "code" in error && error.code !== "EPERM";
  }
}

async function removeUnregisteredInstall(candidate: string): Promise<void> {
  const warnings: string[] = [];
  try {
    await withRegistryLock(() => {
      const document = readRegistry();
      if (!document.widgets.some((widget) => pathsEqual(widget.sourcePath, candidate)) && existsSync(candidate)) {
        const running = hostLifecycleAvailable() && hostRunning();
        if (running) {
          assertHostReloadReady();
          signalHost("--signal-reload");
        }
        try { rmSync(candidate, { recursive: true, force: true }); }
        catch (error) { warnings.push(`Could not remove unregistered owned source at ${candidate}: ${errorMessage(error)}. A later registry mutation will retry cleanup.`); }
      }
    });
  } catch (error) {
    warnings.push(`Could not verify cleanup for ${candidate}: ${errorMessage(error)}. A later registry mutation will retry cleanup.`);
  }
  printCleanupWarnings(warnings);
}

function printCleanupWarnings(warnings: string[]): void {
  for (const warning of warnings) process.stderr.write(`weaver warning: ${warning}\n`);
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

function firstFailureLine(error: unknown): string {
  const details = error instanceof WeaverFailure ? error.details : [errorMessage(error)];
  return (details[0] ?? "unknown rebuild failure").split(/\r?\n/, 1)[0];
}

async function upHost(announce: boolean): Promise<void> {
  assertHostLifecycleAvailable("up");
  assertHostBuilt();
  if (hostRunning()) {
    assertHostReloadReady();
    if (announce) process.stdout.write("weaverd is already running\n");
    return;
  }
  const child = spawn(hostExecutable, [], { cwd: repoRoot, detached: true, stdio: "ignore", windowsHide: true, env: hostEnvironment() });
  child.unref();
  const deadline = Date.now() + 5000;
  while ((!hostRunning() || !hostReloadReady()) && Date.now() < deadline) await delay(50);
  if (!hostRunning() || !hostReloadReady()) throw new WeaverFailure(["weaverd did not become reload-ready"]);
  if (announce) process.stdout.write("weaverd started\n");
}

async function downHost(): Promise<void> {
  assertHostLifecycleAvailable("down");
  assertHostBuilt();
  if (!hostRunning()) {
    process.stdout.write("weaverd is not running\n");
    return;
  }
  signalHost("--signal-down");
  const deadline = Date.now() + 5000;
  while (hostRunning() && Date.now() < deadline) await delay(50);
  if (hostRunning()) throw new WeaverFailure(["weaverd did not stop cleanly"]);
  process.stdout.write("weaverd stopped\n");
}

function showStatus(json: boolean): void {
  assertHostLifecycleAvailable("status");
  if (!hostRunning()) throw new WeaverFailure(['weaverd is not running; run "weaver up"']);
  try {
    const document = readStatus();
    process.stdout.write(`${json ? JSON.stringify(document, null, 2) : formatStatus(document)}\n`);
    for (const warning of statusDivergenceWarnings(document)) process.stderr.write(`weaver status warning: ${warning}\n`);
  } catch (error) {
    throw new WeaverFailure([`weaverd status is unavailable at ${statusPath()}: ${errorMessage(error)}`]);
  }
}

function hostRunning(): boolean {
  if (!hostLifecycleAvailable()) return false;
  if (!existsSync(hostExecutable)) return false;
  return spawnSync(hostExecutable, ["--probe"], { stdio: "ignore", windowsHide: true, env: hostEnvironment() }).status === 0;
}

function hostReloadReady(): boolean {
  if (!hostLifecycleAvailable()) return false;
  if (!existsSync(hostExecutable)) return false;
  return spawnSync(hostExecutable, ["--probe-reload-ready"], { stdio: "ignore", windowsHide: true, env: hostEnvironment() }).status === 0;
}

function assertHostReloadReady(): void {
  if (!hostReloadReady()) {
    throw new WeaverFailure(["The running weaverd predates acknowledged registry reloads.", 'Run "weaver down", then retry; Weaver will start the current host automatically.']);
  }
}

function signalHost(signal: "--signal-down" | "--signal-reload"): void {
  const result = spawnSync(hostExecutable, [signal], { stdio: "ignore", windowsHide: true, env: hostEnvironment() });
  if (result.status !== 0) throw new WeaverFailure([`weaverd rejected ${signal}`]);
}

function authorizeAudio(): void {
  if (process.platform !== "darwin") throw new WeaverFailure(["weaver audio authorize is available only on macOS."]);
  assertHostBuilt();
  const result = spawnSync(hostExecutable, ["--authorize-audio"], {
    cwd: repoRoot,
    env: hostEnvironment(),
    stdio: "inherit",
  });
  if (result.status !== 0) throw new WeaverFailure(["Weaver could not authorize macOS system audio.", "Check System Settings > Privacy & Security > Screen & System Audio Recording, then retry."]);
  if (hostRunning()) signalHost("--signal-reload");
}

function hostEnvironment(): NodeJS.ProcessEnv {
  return { ...process.env, WEAVER_REPO_ROOT: repoRoot };
}

function assertHostBuilt(): void {
  if (!existsSync(hostExecutable)) throw new WeaverFailure([`Host not found at ${hostExecutable}`, "Build host/ with zig build -Doptimize=ReleaseFast."]);
}

function hostLifecycleAvailable(): boolean {
  return process.platform === "win32" || process.platform === "darwin";
}

function assertHostLifecycleAvailable(command: string): void {
  if (hostLifecycleAvailable()) return;
  const platform = process.platform === "darwin" ? "macOS" : process.platform;
  throw new WeaverFailure([`weaver ${command} is not supported on ${platform}.`, "Weaver's native host supports Windows and macOS; artifact commands remain portable only across those supported development targets."]);
}

function assertRuntimeBuilt(): void {
  if (!existsSync(runtimeExecutable)) throw new WeaverFailure([`Runtime not found at ${runtimeExecutable}`, "Build runtime/ with the platform command in the README Quickstart."]);
}

function delay(milliseconds: number): Promise<void> {
  return new Promise((resolvePromise) => setTimeout(resolvePromise, milliseconds));
}

function loadProject(directory: string): SourceProject {
  const sourcePath = join(directory, "widget.tsx");
  const configPath = join(directory, "tsconfig.json");
  if (!existsSync(sourcePath) || !existsSync(configPath)) {
    throw new WeaverFailure([`Expected ${sourcePath} and ${configPath}. Run "weaver init <name>" to scaffold a widget.`]);
  }
  const source = readFileSync(sourcePath, "utf8");
  const sourceFile = ts.createSourceFile(sourcePath, source, ts.ScriptTarget.Latest, true, ts.ScriptKind.TSX);
  const extractionErrors: string[] = [];
  const config = extractConfig(sourceFile, extractionErrors);
  if (extractionErrors.length > 0 || !config) throw new WeaverFailure(extractionErrors);
  const sourceFiles = loadLocalImports(directory, sourceFile);
  const usesIcons = sourceFiles.some(sourceUsesIcon);
  return {
    directory,
    sourcePath,
    source,
    sourceFile,
    sourceFiles,
    config,
    fonts: discoverWidgetFonts(directory),
    usesIcons,
  };
}

function localImportPath(directory: string, importer: ts.SourceFile, specifier: string): string | null {
  if (!specifier.startsWith(".")) return null;
  const unresolved = resolve(dirname(importer.fileName), specifier);
  const candidates = extname(unresolved)
    ? [unresolved]
    : [`${unresolved}.tsx`, `${unresolved}.ts`, join(unresolved, "index.tsx"), join(unresolved, "index.ts")];
  for (const candidate of candidates) {
    if ((!pathsEqual(candidate, directory) && !pathInside(directory, candidate)) || !existsSync(candidate)) continue;
    try {
      if (statSync(candidate).isFile()) return candidate;
    } catch {
      // The ordinary TypeScript check reports an unstable or unreadable import.
    }
  }
  return null;
}

function loadLocalImports(directory: string, entry: ts.SourceFile): ts.SourceFile[] {
  const files = [entry];
  const loaded = new Set([resolve(entry.fileName)]);
  // Walking the growing array keeps the complete local graph deterministic
  // without recursive call-stack depth. The loaded set also makes cycles and
  // diamond imports cost one parse per source file.
  for (let index = 0; index < files.length; index += 1) {
    const importer = files[index]!;
    for (const statement of importer.statements) {
      if ((!ts.isImportDeclaration(statement) && !ts.isExportDeclaration(statement)) ||
        !statement.moduleSpecifier || !ts.isStringLiteral(statement.moduleSpecifier)) continue;
      const path = localImportPath(directory, importer, statement.moduleSpecifier.text);
      if (!path || loaded.has(resolve(path))) continue;
      loaded.add(resolve(path));
      const source = readFileSync(path, "utf8");
      files.push(ts.createSourceFile(path, source, ts.ScriptTarget.Latest, true, path.endsWith(".tsx") ? ts.ScriptKind.TSX : ts.ScriptKind.TS));
    }
  }
  return files;
}

function extractConfig(sourceFile: ts.SourceFile, errors: string[]): WidgetConfigData | null {
  const exportNode = sourceFile.statements.find(ts.isExportAssignment);
  if (!exportNode || !ts.isCallExpression(exportNode.expression) || !ts.isIdentifier(exportNode.expression.expression) || exportNode.expression.expression.text !== "widget") {
    errors.push(locationMessage(sourceFile, exportNode ?? sourceFile, "Default export must be widget({ ... }, component)"));
    return null;
  }
  const [configNode, componentNode] = exportNode.expression.arguments;
  if (!configNode || !ts.isObjectLiteralExpression(configNode) || !componentNode) {
    errors.push(locationMessage(sourceFile, exportNode, "widget config must be a statically extractable literal object; computed values are not allowed"));
    return null;
  }
  try {
    const value = literalValue(configNode) as unknown;
    return validateConfigShape(value, sourceFile, configNode, errors);
  } catch (error) {
    errors.push(locationMessage(sourceFile, configNode, error instanceof Error ? error.message : "Config is not a literal object"));
    return null;
  }
}

function literalValue(node: ts.Expression): unknown {
  if (ts.isStringLiteral(node) || ts.isNoSubstitutionTemplateLiteral(node)) return node.text;
  if (ts.isNumericLiteral(node)) return Number(node.text);
  if (node.kind === ts.SyntaxKind.TrueKeyword) return true;
  if (node.kind === ts.SyntaxKind.FalseKeyword) return false;
  if (node.kind === ts.SyntaxKind.NullKeyword) return null;
  if (ts.isPrefixUnaryExpression(node) && node.operator === ts.SyntaxKind.MinusToken && ts.isNumericLiteral(node.operand)) return -Number(node.operand.text);
  if (ts.isArrayLiteralExpression(node)) return node.elements.map((element) => literalValue(element as ts.Expression));
  if (ts.isObjectLiteralExpression(node)) {
    const output: Record<string, unknown> = {};
    for (const property of node.properties) {
      if (!ts.isPropertyAssignment(property) || property.name === undefined || ts.isComputedPropertyName(property.name)) {
        throw new Error("widget config must contain only literal property assignments; spreads, shorthand, and computed keys are not allowed");
      }
      const name = ts.isIdentifier(property.name) || ts.isStringLiteral(property.name) || ts.isNumericLiteral(property.name) ? property.name.text : null;
      if (name === null) throw new Error("widget config property names must be literal");
      output[name] = literalValue(property.initializer);
    }
    return output;
  }
  throw new Error("widget config must be a statically extractable literal object; computed values are not allowed");
}

function validateConfigShape(value: unknown, sourceFile: ts.SourceFile, node: ts.Node, errors: string[]): WidgetConfigData | null {
  if (!isRecord(value)) {
    errors.push(locationMessage(sourceFile, node, "widget config must be an object literal"));
    return null;
  }
  const allowed = new Set(["name", "size", "anchor", "layer", "clickThrough", "subscribe", "origins", "capabilities"]);
  for (const key of Object.keys(value)) if (!allowed.has(key)) errors.push(locationMessage(sourceFile, node, `Unknown widget config field "${key}"`));
  if (typeof value.name !== "string" || value.name.trim() === "") errors.push(locationMessage(sourceFile, node, "config.name must be a non-empty string"));
  else if (Buffer.byteLength(value.name, "utf8") > 256 || /[\p{C}\p{Zl}\p{Zp}]/u.test(value.name)) errors.push(locationMessage(sourceFile, node, "config.name must be at most 256 UTF-8 bytes and contain only printable single-line characters without controls"));
  if (!isNumberPair(value.size) || value.size.some((part) => part <= 0)) errors.push(locationMessage(sourceFile, node, "config.size must be [width, height] with positive numbers"));
  const corners = ["top-left", "top-right", "bottom-left", "bottom-right"];
  if (value.anchor !== undefined) {
    if (!isRecord(value.anchor) || !corners.includes(String(value.anchor.corner)) || (value.anchor.monitor !== undefined && value.anchor.monitor !== "primary") || (value.anchor.offset !== undefined && !isNumberPair(value.anchor.offset))) {
      errors.push(locationMessage(sourceFile, node, "config.anchor must use monitor \"primary\", a supported corner, and an optional numeric [x, y] offset"));
    }
  }
  if (value.layer !== undefined && !["desktop", "normal", "topmost"].includes(String(value.layer))) errors.push(locationMessage(sourceFile, node, "config.layer must be desktop, normal, or topmost"));
  if (value.clickThrough !== undefined && typeof value.clickThrough !== "boolean") errors.push(locationMessage(sourceFile, node, "config.clickThrough must be boolean"));
  if (value.subscribe !== undefined && (!Array.isArray(value.subscribe) || value.subscribe.some((item) => !["time", "cpu", "memory", "audio", "media"].includes(String(item))))) errors.push(locationMessage(sourceFile, node, 'config.subscribe supports only "time", "cpu", "memory", "audio", and "media"'));
  if (value.capabilities !== undefined && (!Array.isArray(value.capabilities) || value.capabilities.some((item) => item !== "media-transport"))) {
    errors.push(locationMessage(sourceFile, node, 'config.capabilities supports only "media-transport"'));
  }
  if (value.origins !== undefined) {
    if (!Array.isArray(value.origins) || value.origins.some((origin) => !validOriginHost(origin))) errors.push(locationMessage(sourceFile, node, 'config.origins entries must be exact hosts such as "api.example.com"'));
  }
  if (errors.length > 0) return null;
  return value as unknown as WidgetConfigData;
}

// Runtime budget mirrors. The receipt and canonical values live beside the
// storage they bound in runtime/src/tree.zig and native-sdk's
// primitives/canvas/widget_limits.zig. release-audit.mjs enforces lockstep:
// check must reject exactly what runtime would reject.
const nativeWidgetNodeLimit = 1024;
const nativeWidgetDepthLimit = 32;
const nativeWidgetChildLimit = 64;
const nativeWidgetTextByteLimit = 1024;
const nativeWidgetSourceByteLimit = 1024;
const nativeWidgetCanvasLimit = 8;
// All shipped examples measured at most six retained images (noro-shell).
// 16 leaves 2.7x headroom and pins the Native SDK registry slot count; decoded
// pixels are committed only for registered images.
const nativeWidgetImageLimit = 16;

interface LoweredTreeMetrics {
  nodes: number;
  roots: number;
  depth: number;
  maxChildren: number;
  canvases: number;
  images: number;
  maxTextBytes: number;
  opacityCanvas: boolean;
}

function statusDivergenceWarnings(document: ReturnType<typeof readStatus>): string[] {
  const warnings: string[] = [];
  try {
    const ageMs = Date.now() - statSync(statusPath()).mtimeMs;
    if (ageMs > 5_000) {
      warnings.push(`host status has not updated for ${Math.floor(ageMs / 1000)}s; status publication may be failing and the values above may be stale`);
    }
  } catch (error) {
    warnings.push(`host status freshness could not be checked: ${errorMessage(error)}`);
  }
  try {
    const registry = readRegistry();
    const registered = new Set(registry.widgets.map((widget) => widget.name));
    const reported = new Set(document.widgets.map((widget) => widget.name));
    const missing = [...registered].filter((name) => !reported.has(name));
    const extra = [...reported].filter((name) => !registered.has(name));
    if (missing.length > 0) warnings.push(`registry widgets absent from host status: ${missing.join(", ")}; reload did not converge`);
    if (extra.length > 0) warnings.push(`host status widgets absent from the registry: ${extra.join(", ")}; uninstall/restore did not converge`);
  } catch (error) {
    warnings.push(`registry/status reconciliation could not read the registry: ${errorMessage(error)}`);
  }
  try {
    const path = statusPath();
    const prefix = `${basename(path)}.backend-`;
    const sidecars = readdirSync(dirname(path), { withFileTypes: true })
      .filter((entry) => entry.isFile() && entry.name.startsWith(prefix));
    const liveBackends = document.widgets.filter((widget) => widget.backend !== "-").length;
    if (sidecars.length > liveBackends) {
      warnings.push(`${sidecars.length - liveBackends} orphan renderer status sidecar(s) remain next to ${path}; restart weaverd to reconcile them`);
    }
  } catch (error) {
    warnings.push(`renderer status sidecars could not be reconciled: ${errorMessage(error)}`);
  }
  return warnings;
}

function validateLoweredTree(project: SourceProject, errors: string[]): void {
  type JsxRoot = ts.JsxElement | ts.JsxSelfClosingElement | ts.JsxFragment;
  interface ComponentDefinition {
    key: string;
    roots: JsxRoot[];
  }
  const unwrapJsx = (expression: ts.Expression): JsxRoot | null => {
    let current = expression;
    while (ts.isParenthesizedExpression(current)) current = current.expression;
    return ts.isJsxElement(current) || ts.isJsxSelfClosingElement(current) || ts.isJsxFragment(current) ? current : null;
  };
  const expressionRoots = (expression: ts.Expression): JsxRoot[] => {
    const direct = unwrapJsx(expression);
    if (direct) return [direct];
    let current = expression;
    while (ts.isParenthesizedExpression(current)) current = current.expression;
    if (ts.isConditionalExpression(current)) return [...expressionRoots(current.whenTrue), ...expressionRoots(current.whenFalse)];
    if (ts.isBinaryExpression(current) && (current.operatorToken.kind === ts.SyntaxKind.AmpersandAmpersandToken || current.operatorToken.kind === ts.SyntaxKind.BarBarToken)) {
      return [...expressionRoots(current.left), ...expressionRoots(current.right)];
    }
    return [];
  };
  const returnedRoots = (body: ts.ConciseBody): JsxRoot[] => {
    if (!ts.isBlock(body)) return expressionRoots(body);
    const results: JsxRoot[] = [];
    const findReturn = (node: ts.Node): void => {
      if (node !== body && ts.isFunctionLike(node)) return;
      if (ts.isReturnStatement(node) && node.expression) results.push(...expressionRoots(node.expression));
      else ts.forEachChild(node, findReturn);
    };
    findReturn(body);
    return results;
  };
  const definitions = new Map<ts.SourceFile, Map<string, ComponentDefinition>>();
  const defaultDefinitions = new Map<ts.SourceFile, ComponentDefinition>();
  for (const sourceFile of project.sourceFiles) {
    const local = new Map<string, ComponentDefinition>();
    const definition = (name: string, roots: JsxRoot[]): ComponentDefinition => ({
      key: `${resolve(sourceFile.fileName)}#${name}`,
      roots,
    });
    for (const statement of sourceFile.statements) {
      if (ts.isFunctionDeclaration(statement) && statement.body) {
        const roots = returnedRoots(statement.body);
        if (roots.length === 0) continue;
        if (statement.name) local.set(statement.name.text, definition(statement.name.text, roots));
        if (statement.modifiers?.some((modifier) => modifier.kind === ts.SyntaxKind.DefaultKeyword)) {
          defaultDefinitions.set(sourceFile, definition("default", roots));
        }
      } else if (ts.isVariableStatement(statement)) {
        for (const declaration of statement.declarationList.declarations) {
          if (!ts.isIdentifier(declaration.name) || !declaration.initializer ||
            (!ts.isArrowFunction(declaration.initializer) && !ts.isFunctionExpression(declaration.initializer))) continue;
          const roots = returnedRoots(declaration.initializer.body);
          if (roots.length > 0) local.set(declaration.name.text, definition(declaration.name.text, roots));
        }
      }
    }
    definitions.set(sourceFile, local);
    const exportAssignment = sourceFile.statements.find(ts.isExportAssignment);
    if (exportAssignment) {
      if (ts.isIdentifier(exportAssignment.expression)) {
        const exported = local.get(exportAssignment.expression.text);
        if (exported) defaultDefinitions.set(sourceFile, exported);
      } else if (ts.isArrowFunction(exportAssignment.expression) || ts.isFunctionExpression(exportAssignment.expression)) {
        const roots = returnedRoots(exportAssignment.expression.body);
        if (roots.length > 0) defaultDefinitions.set(sourceFile, definition("default", roots));
      }
    }
    for (const statement of sourceFile.statements) {
      if (!ts.isExportDeclaration(statement) || statement.moduleSpecifier || !statement.exportClause ||
        !ts.isNamedExports(statement.exportClause)) continue;
      for (const specifier of statement.exportClause.elements) {
        if (specifier.name.text !== "default") continue;
        const exported = local.get(specifier.propertyName?.text ?? specifier.name.text);
        if (exported) defaultDefinitions.set(sourceFile, exported);
      }
    }
  }
  const componentScopes = new Map<ts.SourceFile, Map<string, ComponentDefinition>>();
  for (const [sourceFile, local] of definitions) componentScopes.set(sourceFile, new Map(local));
  for (const statement of project.sourceFile.statements) {
    if (!ts.isImportDeclaration(statement) || !ts.isStringLiteral(statement.moduleSpecifier) || !statement.importClause) continue;
    const path = localImportPath(project.directory, project.sourceFile, statement.moduleSpecifier.text);
    const importedFile = path ? project.sourceFiles.find((file) => pathsEqual(file.fileName, path)) : undefined;
    const imported = importedFile ? definitions.get(importedFile) : undefined;
    if (!imported) continue;
    const entryScope = componentScopes.get(project.sourceFile)!;
    const bindings = statement.importClause.namedBindings;
    if (bindings && ts.isNamedImports(bindings)) {
      for (const binding of bindings.elements) {
        const component = imported.get(binding.propertyName?.text ?? binding.name.text);
        if (component) entryScope.set(binding.name.text, component);
      }
    }
    if (statement.importClause.name) {
      const component = defaultDefinitions.get(importedFile!);
      if (component) entryScope.set(statement.importClause.name.text, component);
    }
  }

  const tagAndAttributes = (node: ts.JsxElement | ts.JsxSelfClosingElement): { tag: string; attributes: ts.JsxAttributes } =>
    ts.isJsxElement(node)
      ? { tag: node.openingElement.tagName.getText(node.getSourceFile()), attributes: node.openingElement.attributes }
      : { tag: node.tagName.getText(node.getSourceFile()), attributes: node.attributes };
  const isPaintedLayout = (node: ts.JsxElement | ts.JsxSelfClosingElement, tag: string): boolean => {
    if (tag !== "row" && tag !== "column" && tag !== "stack") return false;
    const { attributes } = tagAndAttributes(node);
    const sourceFile = node.getSourceFile();
    const classAttribute = attributes.properties.find((attribute): attribute is ts.JsxAttribute =>
      ts.isJsxAttribute(attribute) && attribute.name.getText(sourceFile) === "class");
    const classText = classAttribute ? jsxStringValue(classAttribute.initializer) : "";
    if (classText === null) return false;
    try {
      const compiled = compileClass(classText);
      return Object.keys(compiled).some((key) => key === "background" || key === "radius" || key.startsWith("radius") || key.startsWith("border") || key.toLowerCase().includes("shadow"));
    } catch {
      return false; // The normal class validator reports the actionable error.
    }
  };
  const maximum = (values: LoweredTreeMetrics[]): LoweredTreeMetrics => ({
    nodes: Math.max(0, ...values.map((value) => value.nodes)),
    roots: Math.max(0, ...values.map((value) => value.roots)),
    depth: Math.max(0, ...values.map((value) => value.depth)),
    maxChildren: Math.max(0, ...values.map((value) => value.maxChildren)),
    canvases: Math.max(0, ...values.map((value) => value.canvases)),
    images: Math.max(0, ...values.map((value) => value.images)),
    maxTextBytes: Math.max(0, ...values.map((value) => value.maxTextBytes)),
    opacityCanvas: values.some((value) => value.opacityCanvas),
  });
  const staticPrimitiveText = (expression: ts.Expression): string | null => {
    let current = expression;
    while (ts.isParenthesizedExpression(current)) current = current.expression;
    if (ts.isStringLiteral(current) || ts.isNoSubstitutionTemplateLiteral(current) || ts.isNumericLiteral(current)) return current.text;
    if (ts.isPrefixUnaryExpression(current) && ts.isNumericLiteral(current.operand)) {
      return `${current.operator === ts.SyntaxKind.MinusToken ? "-" : current.operator === ts.SyntaxKind.PlusToken ? "+" : ""}${current.operand.text}`;
    }
    return null;
  };
  const emptyMetrics = (): LoweredTreeMetrics => ({
    nodes: 0, roots: 0, depth: 0, maxChildren: 0, canvases: 0, images: 0, maxTextBytes: 0,
    opacityCanvas: false,
  });
  const combineSiblings = (values: LoweredTreeMetrics[]): LoweredTreeMetrics => ({
    nodes: values.reduce((sum, value) => sum + value.nodes, 0),
    roots: values.reduce((sum, value) => sum + value.roots, 0),
    depth: Math.max(0, ...values.map((value) => value.depth)),
    maxChildren: Math.max(0, ...values.map((value) => value.maxChildren)),
    canvases: values.reduce((sum, value) => sum + value.canvases, 0),
    images: values.reduce((sum, value) => sum + value.images, 0),
    maxTextBytes: Math.max(0, ...values.map((value) => value.maxTextBytes)),
    opacityCanvas: values.some((value) => value.opacityCanvas),
  });
  const canvasHasOpacityLayer = (node: ts.JsxElement | ts.JsxSelfClosingElement): boolean => {
    const { tag, attributes } = tagAndAttributes(node);
    if (/^[A-Z]/.test(tag)) return false;
    const sourceFile = node.getSourceFile();
    const classAttribute = attributes.properties.find((attribute): attribute is ts.JsxAttribute =>
      ts.isJsxAttribute(attribute) && attribute.name.getText(sourceFile) === "class");
    const classText = classAttribute ? jsxStringValue(classAttribute.initializer) : "";
    if (classText === null) return false;
    try {
      const compiled = compileClass(classText);
      return typeof compiled.opacity === "number" && compiled.opacity < 1;
    } catch {
      // The ordinary class validator reports the malformed utility.
      return false;
    }
  };
  const metrics = (node: JsxRoot, visiting: Set<string>): LoweredTreeMetrics => {
    const childMetrics = (children: readonly ts.JsxChild[], parentTag: string | null): LoweredTreeMetrics[] => {
      const result: LoweredTreeMetrics[] = [];
      for (const child of children) {
        if (ts.isJsxElement(child) || ts.isJsxSelfClosingElement(child) || ts.isJsxFragment(child)) {
          result.push(metrics(child, visiting));
        } else if (parentTag !== "text" && ts.isJsxText(child) && child.getText().trim() !== "") {
          result.push({ ...emptyMetrics(), nodes: 1, roots: 1, depth: 1 });
        } else if (parentTag !== "text" && ts.isJsxExpression(child) && child.expression) {
          const roots = expressionRoots(child.expression);
          if (roots.length > 0) result.push(maximum(roots.map((root) => metrics(root, visiting))));
          else if (staticPrimitiveText(child.expression) !== null) result.push({ ...emptyMetrics(), nodes: 1, roots: 1, depth: 1 });
        }
      }
      return result;
    };
    if (ts.isJsxFragment(node)) {
      return combineSiblings(childMetrics(node.children, null));
    }
    const { tag } = tagAndAttributes(node);
    const component = componentScopes.get(node.getSourceFile())?.get(tag);
    if (/^[A-Z]/.test(tag) && component && !visiting.has(component.key)) {
      const next = new Set(visiting);
      next.add(component.key);
      return maximum(component.roots.map((root) => metrics(root, next)));
    }
    const children = ts.isJsxElement(node) ? childMetrics(node.children, tag) : [];
    const combinedChildren = combineSiblings(children);
    const ownDepth = isPaintedLayout(node, tag) ? 2 : 1;
    let textBytes = 0;
    if (tag === "text" && ts.isJsxElement(node)) {
      let text = "";
      let complete = true;
      for (const child of node.children) {
        if (ts.isJsxText(child)) text += child.getText();
        else if (ts.isJsxExpression(child) && child.expression) {
          const value = staticPrimitiveText(child.expression);
          if (value === null) complete = false;
          else text += value;
        } else if (!ts.isJsxExpression(child) || child.expression) {
          complete = false;
        }
      }
      if (complete) textBytes = Buffer.byteLength(text, "utf8");
    }
    const directChildren = combinedChildren.roots;
    const hasOpacityLayer = canvasHasOpacityLayer(node);
    return {
      nodes: ownDepth + combinedChildren.nodes,
      roots: 1,
      depth: ownDepth + combinedChildren.depth,
      maxChildren: Math.max(combinedChildren.maxChildren, directChildren, ownDepth === 2 ? 1 : 0),
      canvases: combinedChildren.canvases + (tag === "canvas" ? 1 : 0),
      images: combinedChildren.images + (tag === "image" ? 1 : 0),
      maxTextBytes: Math.max(combinedChildren.maxTextBytes, textBytes),
      opacityCanvas: combinedChildren.opacityCanvas || (hasOpacityLayer && combinedChildren.canvases > 0),
    };
  };
  type PrimitiveRoot = ts.JsxElement | ts.JsxSelfClosingElement;
  const primitiveRoots = (node: JsxRoot, visiting: Set<string>): PrimitiveRoot[] => {
    if (ts.isJsxFragment(node)) {
      const result: PrimitiveRoot[] = [];
      for (const child of node.children) {
        if (ts.isJsxElement(child) || ts.isJsxSelfClosingElement(child) || ts.isJsxFragment(child)) {
          result.push(...primitiveRoots(child, visiting));
        } else if (ts.isJsxExpression(child) && child.expression) {
          for (const root of expressionRoots(child.expression)) result.push(...primitiveRoots(root, visiting));
        }
      }
      return result;
    }
    const { tag } = tagAndAttributes(node);
    if (!/^[A-Z]/.test(tag)) return [node];
    const component = componentScopes.get(node.getSourceFile())?.get(tag);
    if (!component || visiting.has(component.key)) return [];
    const next = new Set(visiting);
    next.add(component.key);
    return component.roots.flatMap((root) => primitiveRoots(root, next));
  };
  interface ShadowOutsets { left: number; top: number; right: number; bottom: number }
  interface VisualRect { x: number; y: number; width: number; height: number }
  const shadowOutsets = (value: unknown, inset: unknown): ShadowOutsets | null => {
    if (typeof value !== "string" || value === "" || value === "none" || inset === true) return null;
    const parts = value.split(" ");
    if (parts.length !== 5 || parts[4].endsWith("00")) return null;
    const [offsetX, offsetY, blur, spread] = parts.slice(0, 4).map(Number);
    if (![offsetX, offsetY, blur, spread].every(Number.isFinite)) return null;
    // Matches native-sdk drawing.shadowBounds: translate, then inflate by
    // abs(spread) + blur. These are authored logical pixels, not a new limit.
    const radius = Math.abs(spread) + blur;
    return {
      left: Math.max(0, radius - offsetX),
      top: Math.max(0, radius - offsetY),
      right: Math.max(0, radius + offsetX),
      bottom: Math.max(0, radius + offsetY),
    };
  };
  const formatPixels = (value: number): string => Number.isInteger(value) ? String(value) : String(Number(value.toFixed(3)));
  const compiledClass = (node: PrimitiveRoot): Record<string, unknown> | null => {
    const { attributes } = tagAndAttributes(node);
    const sourceFile = node.getSourceFile();
    const classAttribute = attributes.properties.find((attribute): attribute is ts.JsxAttribute =>
      ts.isJsxAttribute(attribute) && attribute.name.getText(sourceFile) === "class");
    const classText = classAttribute ? jsxStringValue(classAttribute.initializer) : "";
    if (classText === null) return null;
    try {
      return compileClass(classText) as Record<string, unknown>;
    } catch {
      return null; // The ordinary class validator reports the malformed utility.
    }
  };
  const visualChildren = (node: PrimitiveRoot): PrimitiveRoot[] => {
    if (!ts.isJsxElement(node)) return [];
    const result: PrimitiveRoot[] = [];
    for (const child of node.children) {
      if (ts.isJsxElement(child) || ts.isJsxSelfClosingElement(child) || ts.isJsxFragment(child)) {
        result.push(...primitiveRoots(child, new Set()));
      } else if (ts.isJsxExpression(child) && child.expression) {
        for (const root of expressionRoots(child.expression)) result.push(...primitiveRoots(root, new Set()));
      }
    }
    return result;
  };
  const validateVisualNodeBounds = (node: PrimitiveRoot, rect: VisualRect, seen: Set<string>): boolean => {
    const nodeKey = `${node.getSourceFile().fileName}:${node.getStart()}`;
    if (seen.has(nodeKey)) return false;
    seen.add(nodeKey);
    const { tag, attributes } = tagAndAttributes(node);
    const sourceFile = node.getSourceFile();
    const classAttribute = attributes.properties.find((attribute): attribute is ts.JsxAttribute =>
      ts.isJsxAttribute(attribute) && attribute.name.getText(sourceFile) === "class");
    const compiled = compiledClass(node);
    if (!compiled) return false;
    const [surfaceWidth, surfaceHeight] = project.config.size;
    const shadows = [
      [compiled.shadow, compiled.shadowInset],
      [compiled.hoverShadow, compiled.hoverShadowInset],
      [compiled.pressedShadow, compiled.pressedShadowInset],
    ] as const;
    const outsets = shadows.map(([shadow, inset]) => shadowOutsets(shadow, inset)).filter((value): value is ShadowOutsets => value !== null);
    if (outsets.length > 0) {
      const required = outsets.reduce<ShadowOutsets>((result, value) => ({
        left: Math.max(result.left, value.left),
        top: Math.max(result.top, value.top),
        right: Math.max(result.right, value.right),
        bottom: Math.max(result.bottom, value.bottom),
      }), { left: 0, top: 0, right: 0, bottom: 0 });
      const available: ShadowOutsets = {
        left: rect.x,
        top: rect.y,
        right: surfaceWidth - rect.x - rect.width,
        bottom: surfaceHeight - rect.y - rect.height,
      };
      const missing: ShadowOutsets = {
        left: Math.max(0, required.left - available.left),
        top: Math.max(0, required.top - available.top),
        right: Math.max(0, required.right - available.right),
        bottom: Math.max(0, required.bottom - available.bottom),
      };
      if (missing.left > 0 || missing.top > 0 || missing.right > 0 || missing.bottom > 0) {
        const paintedWidth = surfaceWidth + missing.left + missing.right;
        const paintedHeight = surfaceHeight + missing.top + missing.bottom;
        errors.push(locationMessage(
          sourceFile,
          classAttribute ?? node,
          `RootOutsetShadowClipped: root-surface <${tag}> has an outset shadow outside config.size [${formatPixels(surfaceWidth)}, ${formatPixels(surfaceHeight)}]. ` +
          `Required shadow room: left=${formatPixels(required.left)}px, top=${formatPixels(required.top)}px, right=${formatPixels(required.right)}px, bottom=${formatPixels(required.bottom)}px; ` +
          `available: left=${formatPixels(available.left)}px, top=${formatPixels(available.top)}px, right=${formatPixels(available.right)}px, bottom=${formatPixels(available.bottom)}px; ` +
          `missing: left=${formatPixels(missing.left)}px, top=${formatPixels(missing.top)}px, right=${formatPixels(missing.right)}px, bottom=${formatPixels(missing.bottom)}px; painted bounds=${formatPixels(paintedWidth)}x${formatPixels(paintedHeight)}. ` +
          `Fix: expand config.size by the missing room and inset this surface by the required left/top room, or use shadow-inner/shadow-none.`,
        ));
        return true;
      }
    }
    if (tag !== "stack" && tag !== "row" && tag !== "column") return false;
    const uniformPadding = typeof compiled.padding === "number" ? compiled.padding : 0;
    const padding = {
      left: typeof compiled.paddingLeft === "number" && compiled.paddingLeft >= 0 ? compiled.paddingLeft : uniformPadding,
      top: typeof compiled.paddingTop === "number" && compiled.paddingTop >= 0 ? compiled.paddingTop : uniformPadding,
      right: typeof compiled.paddingRight === "number" && compiled.paddingRight >= 0 ? compiled.paddingRight : uniformPadding,
      bottom: typeof compiled.paddingBottom === "number" && compiled.paddingBottom >= 0 ? compiled.paddingBottom : uniformPadding,
    };
    const content: VisualRect = {
      x: rect.x + padding.left,
      y: rect.y + padding.top,
      width: rect.width - padding.left - padding.right,
      height: rect.height - padding.top - padding.bottom,
    };
    if (content.width < 0 || content.height < 0) return false;
    const children = visualChildren(node);
    // Stack children overlay independently, so every full-size child has the
    // content rect. A row or column passes that same rect only when it has one
    // visual child; multiple flex children require layout to determine their
    // main-axis sizes and are left to runtime rendering.
    const candidates = tag === "stack" || children.length === 1 ? children : [];
    for (const child of candidates) {
      const childCompiled = compiledClass(child);
      if (!childCompiled) continue;
      const fillsContent = (childCompiled.widthPercent === 100 && childCompiled.heightPercent === 100) ||
        (childCompiled.width === content.width && childCompiled.height === content.height);
      const hasMargins = ["marginLeft", "marginTop", "marginRight", "marginBottom"].some((key) =>
        typeof childCompiled[key] === "number" && childCompiled[key] !== 0);
      if (fillsContent && !hasMargins && validateVisualNodeBounds(child, content, seen)) return true;
    }
    return false;
  };
  const exportNode = project.sourceFile.statements.find(ts.isExportAssignment);
  const component = exportNode && ts.isCallExpression(exportNode.expression) ? exportNode.expression.arguments[1] : undefined;
  if (!component) return;
  let roots: JsxRoot[] = [];
  if (ts.isArrowFunction(component) || ts.isFunctionExpression(component)) roots = returnedRoots(component.body);
  else if (ts.isIdentifier(component)) roots = componentScopes.get(project.sourceFile)?.get(component.text)?.roots ?? [];
  else roots = expressionRoots(component);
  if (roots.length === 0) return;
  const seenVisualRoots = new Set<string>();
  for (const root of roots.flatMap((value) => primitiveRoots(value, new Set()))) {
    const key = `${root.getSourceFile().fileName}:${root.getStart()}`;
    if (seenVisualRoots.has(key)) continue;
    seenVisualRoots.add(key);
    const compiled = compiledClass(root);
    if (!compiled) continue;
    const [surfaceWidth, surfaceHeight] = project.config.size;
    const fillsSurface = (compiled.widthPercent === 100 && compiled.heightPercent === 100) ||
      (compiled.width === surfaceWidth && compiled.height === surfaceHeight);
    if (fillsSurface) validateVisualNodeBounds(root, { x: 0, y: 0, width: surfaceWidth, height: surfaceHeight }, new Set());
  }
  const lowered = maximum(roots.map((root) => metrics(root, new Set())));
  const evidenceNode = roots[0];
  const limitation = " The static estimate follows the exported widget through local components and one level of relative imports; runtime limits remain authoritative for dynamic collections and unresolved component output.";
  if (lowered.nodes > nativeWidgetNodeLimit) {
    errors.push(locationMessage(evidenceNode.getSourceFile(), evidenceNode, `LoweredWidgetNodeLimit: this tree lowers to ${lowered.nodes} Native nodes (limit ${nativeWidgetNodeLimit}); node capacity exhausted: max_nodes=${nativeWidgetNodeLimit}, asked for ${lowered.nodes}, headroom=${nativeWidgetNodeLimit - lowered.nodes}. Painted <row>/<column>/<stack> elements add an inner layout node.${limitation}`));
  }
  if (lowered.depth > nativeWidgetDepthLimit) {
    errors.push(locationMessage(evidenceNode.getSourceFile(), evidenceNode, `LoweredWidgetDepthLimit: this tree lowers to depth ${lowered.depth} (Native limit ${nativeWidgetDepthLimit}); painted <row>/<column>/<stack> elements add one nesting level.${limitation}`));
  }
  if (lowered.maxChildren > nativeWidgetChildLimit) {
    errors.push(locationMessage(evidenceNode.getSourceFile(), evidenceNode, `LoweredWidgetChildLimit: one authored parent lowers to ${lowered.maxChildren} direct Native children; child capacity exhausted: max_children=${nativeWidgetChildLimit}, asked for ${lowered.maxChildren}, headroom=${nativeWidgetChildLimit - lowered.maxChildren}.${limitation}`));
  }
  if (lowered.maxTextBytes > nativeWidgetTextByteLimit) {
    errors.push(locationMessage(evidenceNode.getSourceFile(), evidenceNode, `LoweredWidgetTextLimit: one static <text> value is ${lowered.maxTextBytes} UTF-8 bytes; text capacity exhausted: max_text_bytes=${nativeWidgetTextByteLimit}, asked for ${lowered.maxTextBytes}, headroom=${nativeWidgetTextByteLimit - lowered.maxTextBytes}.${limitation}`));
  }
  if (lowered.canvases > nativeWidgetCanvasLimit) {
    errors.push(locationMessage(evidenceNode.getSourceFile(), evidenceNode, `LoweredWidgetCanvasLimit: this tree contains ${lowered.canvases} canvases; canvas capacity exhausted: max_canvases=${nativeWidgetCanvasLimit}, asked for ${lowered.canvases}, headroom=${nativeWidgetCanvasLimit - lowered.canvases}.${limitation}`));
  }
  if (lowered.images > nativeWidgetImageLimit) {
    errors.push(locationMessage(evidenceNode.getSourceFile(), evidenceNode, `LoweredWidgetImageLimit: this tree contains ${lowered.images} images; image registry capacity exhausted: max_images=${nativeWidgetImageLimit}, asked for ${lowered.images}, headroom=${nativeWidgetImageLimit - lowered.images}.${limitation}`));
  }
  if (lowered.opacityCanvas && !errors.some((error) => error.includes("CanvasNeedsOpaqueAncestors"))) {
    errors.push(locationMessage(evidenceNode.getSourceFile(), evidenceNode, `CanvasNeedsOpaqueAncestors: a reachable <canvas> is under an opacity ancestor in the statically lowered component tree. A host GPU surface cannot be placed behind an opacity layer; move the canvas outside that ancestor and apply opacity inside onFrame.${limitation}`));
  }
}

function validateMediaTransportCapability(project: SourceProject, errors: string[]): void {
  const configPath = join(project.directory, "tsconfig.json");
  const configRead = ts.readConfigFile(configPath, (path) => readFileSync(path, "utf8"));
  if (configRead.error) return; // The ordinary TypeScript invocation reports it.
  const parsed = ts.parseJsonConfigFileContent(configRead.config, ts.sys, project.directory, undefined, configPath);
  const sdkDirectory = join(repoRoot, "sdk");
  // Bundling owns these two specifiers regardless of widget-authored paths.
  // Check must compile the same graph or a local compatible declaration can
  // hide capability use that the bundle later binds to Weaver's real SDK.
  const options: ts.CompilerOptions = {
    ...parsed.options,
    paths: {
      ...parsed.options.paths,
      "@weaver/sdk": [join(sdkDirectory, "index.d.ts")],
      "@weaver/sdk/jsx-runtime": [join(sdkDirectory, "jsx-runtime.d.ts")],
    },
  };
  const program = ts.createProgram({ rootNames: parsed.fileNames, options });
  const checker = program.getTypeChecker();

  const sdkHookDeclaration = (declaration: ts.Declaration | undefined): boolean => {
    if (!declaration) return false;
    const path = resolve(declaration.getSourceFile().fileName);
    if (!pathsEqual(path, sdkDirectory) && !pathInside(sdkDirectory, path)) return false;
    const named = declaration as ts.Declaration & { name?: ts.DeclarationName };
    if (!named.name) return false;
    let symbol = checker.getSymbolAtLocation(named.name);
    if (symbol && (symbol.flags & ts.SymbolFlags.Alias) !== 0) symbol = checker.getAliasedSymbol(symbol);
    return symbol?.getName() === "useMediaTransport";
  };

  const assignments = new Map<ts.Symbol, ts.Expression[]>();
  const canonicalSymbol = (node: ts.Node): ts.Symbol | undefined => {
    let symbol = checker.getSymbolAtLocation(node);
    const seen = new Set<ts.Symbol>();
    while (symbol && (symbol.flags & ts.SymbolFlags.Alias) !== 0 && !seen.has(symbol)) {
      seen.add(symbol);
      symbol = checker.getAliasedSymbol(symbol);
    }
    return symbol;
  };
  const rememberAssignment = (target: ts.Expression, value: ts.Expression): void => {
    const symbol = canonicalSymbol(target);
    if (!symbol) return;
    const values = assignments.get(symbol) ?? [];
    values.push(value);
    assignments.set(symbol, values);
  };
  for (const sourceFile of program.getSourceFiles()) {
    const indexAssignments = (node: ts.Node): void => {
      if (ts.isBinaryExpression(node) && node.operatorToken.kind === ts.SyntaxKind.EqualsToken) {
        rememberAssignment(node.left, node.right);
      }
      ts.forEachChild(node, indexAssignments);
    };
    indexAssignments(sourceFile);
  }

  const tracesSdkHookSymbol = (symbol: ts.Symbol | undefined, seen: Set<ts.Symbol>): boolean => {
    while (symbol && (symbol.flags & ts.SymbolFlags.Alias) !== 0 && !seen.has(symbol)) {
      seen.add(symbol);
      symbol = checker.getAliasedSymbol(symbol);
    }
    if (!symbol || seen.has(symbol)) return false;
    seen.add(symbol);
    if (symbol.getName() === "useMediaTransport" && (symbol.declarations ?? []).some(sdkHookDeclaration)) return true;
    for (const value of assignments.get(symbol) ?? []) {
      if (tracesSdkHookNode(value, seen)) return true;
    }
    for (const declaration of symbol.declarations ?? []) {
      if (ts.isVariableDeclaration(declaration) && declaration.initializer && tracesSdkHookNode(declaration.initializer, seen)) return true;
      if (ts.isPropertyAssignment(declaration) && tracesSdkHookNode(declaration.initializer, seen)) return true;
      if (ts.isShorthandPropertyAssignment(declaration)) {
        const valueSymbol = checker.getShorthandAssignmentValueSymbol(declaration);
        if (tracesSdkHookSymbol(valueSymbol, seen)) return true;
      }
      if (ts.isBindingElement(declaration)) {
        let parent: ts.Node = declaration.parent;
        while (ts.isObjectBindingPattern(parent) || ts.isArrayBindingPattern(parent) || ts.isBindingElement(parent)) parent = parent.parent;
        if (ts.isVariableDeclaration(parent) && parent.initializer) {
          const propertyNode = declaration.propertyName ?? declaration.name;
          const propertyName = ts.isIdentifier(propertyNode) || ts.isStringLiteral(propertyNode) || ts.isNumericLiteral(propertyNode)
            ? propertyNode.text
            : undefined;
          if (propertyName) {
            const sourceType = checker.getTypeAtLocation(parent.initializer);
            if (tracesSdkHookSymbol(checker.getPropertyOfType(sourceType, propertyName), seen)) return true;
          }
        }
      }
    }
    return false;
  };
  function tracesSdkHookNode(node: ts.Node, seen = new Set<ts.Symbol>()): boolean {
    return tracesSdkHookSymbol(canonicalSymbol(node), seen);
  }
  const signatureIsSdkHook = (node: ts.CallExpression): boolean => {
    const declaration = checker.getResolvedSignature(node)?.getDeclaration();
    return sdkHookDeclaration(declaration);
  };
  const isSdkHook = (node: ts.CallExpression): boolean => {
    // The signature declaration is the authoritative backstop: TypeScript
    // preserves the SDK call signature through destructuring, assignments,
    // object properties, and re-export chains even when the local symbol is a
    // BindingElement or an inferred variable.
    return signatureIsSdkHook(node) || tracesSdkHookNode(node.expression);
  };

  for (const sourceFile of program.getSourceFiles()) {
    const path = resolve(sourceFile.fileName);
    if (sourceFile.isDeclarationFile || (!pathsEqual(path, project.directory) && !pathInside(project.directory, path))) continue;
    const visit = (node: ts.Node): void => {
      if (ts.isCallExpression(node) && isSdkHook(node) && !project.config.capabilities?.includes("media-transport")) {
        errors.push(locationMessage(
          sourceFile,
          node,
          'useMediaTransport() requires capabilities: ["media-transport"]. Fix: add capabilities: ["media-transport"] to the widget config.',
        ));
      }
      ts.forEachChild(node, visit);
    };
    visit(sourceFile);
  }
}

function validateSource(project: SourceProject): string[] {
  const errors: string[] = [];
  const providerNames = ["time", "cpu", "memory", "audio", "media"] as const;
  type ProviderName = (typeof providerNames)[number];
  const usedProviders = new Map<ProviderName, Set<"useProvider" | "useProviderSignal">>();
  const stateVariantAncestry = (node: ts.JsxOpeningElement | ts.JsxSelfClosingElement): "pressable" | "component-boundary" | "none" => {
    let current: ts.Node | undefined = node.parent;
    while (current) {
      if (ts.isJsxElement(current) && current.openingElement !== node) {
        const tag = current.openingElement.tagName.getText(current.getSourceFile());
        if (tag === "button" || tag === "slider") return "pressable";
        if (/^[A-Z]/.test(tag)) return "component-boundary";
      }
      if (ts.isFunctionLike(current)) {
        const parent = current.parent;
        const isInlineWidgetRoot = ts.isCallExpression(parent) &&
          ts.isIdentifier(parent.expression) &&
          parent.expression.text === "widget" &&
          parent.arguments[1] === current;
        if (!isInlineWidgetRoot) return "component-boundary";
      }
      current = current.parent;
    }
    return "none";
  };
  const canvasOpacityAncestor = (node: ts.JsxOpeningElement | ts.JsxSelfClosingElement): string | null => {
    let current: ts.Node | undefined = node.parent;
    while (current) {
      if (ts.isJsxElement(current) && current.openingElement !== node) {
        const sourceFile = current.getSourceFile();
        const tag = current.openingElement.tagName.getText(sourceFile);
        if (/^[A-Z]/.test(tag)) return null;
        const attribute = current.openingElement.attributes.properties.find((candidate): candidate is ts.JsxAttribute =>
          ts.isJsxAttribute(candidate) && candidate.name.getText(sourceFile) === "class");
        const classText = attribute ? jsxStringValue(attribute.initializer) : "";
        if (classText !== null) {
          try {
            const compiled = compileClass(classText);
            if (typeof compiled.opacity === "number" && compiled.opacity < 1) return tag;
          } catch {
            // The ordinary class validator reports the malformed utility.
          }
        }
      }
      if (ts.isFunctionLike(current)) return null;
      current = current.parent;
    }
    return null;
  };
  const expressionMayProvideAccessibleText = (expression: ts.Expression): boolean => {
    if (expression.kind === ts.SyntaxKind.FalseKeyword || expression.kind === ts.SyntaxKind.TrueKeyword ||
        expression.kind === ts.SyntaxKind.NullKeyword || ts.isVoidExpression(expression) ||
        (ts.isIdentifier(expression) && expression.text === "undefined")) return false;
    if (ts.isStringLiteral(expression) || ts.isNoSubstitutionTemplateLiteral(expression)) return expression.text.trim().length > 0;
    if (ts.isNumericLiteral(expression)) return true;
    if (ts.isParenthesizedExpression(expression) || ts.isAsExpression(expression) || ts.isTypeAssertionExpression(expression) || ts.isNonNullExpression(expression)) {
      return expressionMayProvideAccessibleText(expression.expression);
    }
    if (ts.isConditionalExpression(expression)) {
      return expressionMayProvideAccessibleText(expression.whenTrue) || expressionMayProvideAccessibleText(expression.whenFalse);
    }
    if (ts.isArrayLiteralExpression(expression)) {
      return expression.elements.some((element) => {
        if (ts.isOmittedExpression(element)) return false;
        if (ts.isSpreadElement(element)) return expressionMayProvideAccessibleText(element.expression);
        return expressionMayProvideAccessibleText(element);
      });
    }
    // A dynamic expression may produce visible text. Runtime projection is
    // authoritative when the child is not statically knowable.
    return true;
  };
  const mayProvideAccessibleText = (child: ts.JsxChild): boolean => {
    if (ts.isJsxText(child)) return child.getText().trim().length > 0;
    if (ts.isJsxExpression(child)) {
      const expression = child.expression;
      return expression ? expressionMayProvideAccessibleText(expression) : false;
    }
    if (ts.isJsxFragment(child)) return child.children.some(mayProvideAccessibleText);
    if (ts.isJsxSelfClosingElement(child)) return /^[A-Z]/.test(child.tagName.getText(child.getSourceFile()));
    if (ts.isJsxElement(child)) {
      if (/^[A-Z]/.test(child.openingElement.tagName.getText(child.getSourceFile()))) return true;
      return child.children.some(mayProvideAccessibleText);
    }
    return false;
  };
  type AccessibleLabelResolution =
    | { kind: "absent" }
    | { kind: "unknown" }
    | { kind: "known"; value: string; node: ts.Node };
  const expressionStringValue = (expression: ts.Expression): string | null =>
    ts.isStringLiteral(expression) || ts.isNoSubstitutionTemplateLiteral(expression) ? expression.text : null;
  const expressionIsDefinitelyUndefined = (expression: ts.Expression): boolean => {
    if (ts.isVoidExpression(expression) || (ts.isIdentifier(expression) && expression.text === "undefined")) return true;
    if (ts.isParenthesizedExpression(expression) || ts.isAsExpression(expression) || ts.isTypeAssertionExpression(expression) || ts.isNonNullExpression(expression)) {
      return expressionIsDefinitelyUndefined(expression.expression);
    }
    return ts.isConditionalExpression(expression) &&
      expressionIsDefinitelyUndefined(expression.whenTrue) && expressionIsDefinitelyUndefined(expression.whenFalse);
  };
  const resolveAccessibleLabelValue = (expression: ts.Expression, node: ts.Node): AccessibleLabelResolution => {
    const value = expressionStringValue(expression);
    if (value !== null) return { kind: "known", value, node };
    return expressionIsDefinitelyUndefined(expression) ? { kind: "absent" } : { kind: "unknown" };
  };
  const propertyNameText = (name: ts.PropertyName | undefined): string | null => {
    if (!name) return null;
    if (ts.isIdentifier(name) || ts.isStringLiteral(name) || ts.isNumericLiteral(name)) return name.text;
    if (ts.isComputedPropertyName(name)) return expressionStringValue(name.expression);
    return null;
  };
  const resolveSpreadAccessibleLabel = (
    expression: ts.Expression,
    initial: AccessibleLabelResolution,
  ): AccessibleLabelResolution => {
    if (!ts.isObjectLiteralExpression(expression)) return { kind: "unknown" };
    let resolution = initial;
    for (const property of expression.properties) {
      if (ts.isSpreadAssignment(property)) {
        resolution = resolveSpreadAccessibleLabel(property.expression, resolution);
        continue;
      }
      const name = propertyNameText(property.name);
      if (name === null) {
        // A computed property may overwrite accessibilityLabel at runtime.
        resolution = { kind: "unknown" };
        continue;
      }
      if (name !== "accessibilityLabel") continue;
      if (ts.isPropertyAssignment(property)) {
        resolution = resolveAccessibleLabelValue(property.initializer, property);
      } else {
        resolution = { kind: "unknown" };
      }
    }
    return resolution;
  };
  const resolveAccessibleLabel = (node: ts.JsxOpeningElement | ts.JsxSelfClosingElement): AccessibleLabelResolution => {
    const sourceFile = node.getSourceFile();
    let resolution: AccessibleLabelResolution = { kind: "absent" };
    for (const property of node.attributes.properties) {
      if (ts.isJsxSpreadAttribute(property)) {
        resolution = resolveSpreadAccessibleLabel(property.expression, resolution);
        continue;
      }
      if (property.name.getText(sourceFile) !== "accessibilityLabel") continue;
      if (property.initializer && ts.isJsxExpression(property.initializer) && property.initializer.expression) {
        resolution = resolveAccessibleLabelValue(property.initializer.expression, property);
      } else {
        const value = jsxStringValue(property.initializer);
        resolution = value === null ? { kind: "unknown" } : { kind: "known", value, node: property };
      }
    }
    return resolution;
  };
  const validateAccessibleName = (node: ts.JsxOpeningElement | ts.JsxSelfClosingElement, tag: "button" | "slider"): void => {
    const sourceFile = node.getSourceFile();
    const labelResolution = resolveAccessibleLabel(node);
    if (labelResolution.kind === "unknown") return;
    if (labelResolution.kind === "known") {
      const label = labelResolution.value;
      const bytes = Buffer.byteLength(label, "utf8");
      if (label.trim().length === 0) {
        errors.push(locationMessage(
          sourceFile,
          labelResolution.node,
          `ActionableAccessibleNameRequired: <${tag}> accessibilityLabel is blank. Fix: use a non-empty label naming the action.`,
        ));
      } else if (bytes > nativeWidgetTextByteLimit) {
        errors.push(locationMessage(
          sourceFile,
          labelResolution.node,
          `AccessibilityLabelTooLong: <${tag}> label is ${bytes} UTF-8 bytes; max_accessibility_label_bytes=${nativeWidgetTextByteLimit}, asked for ${bytes}, headroom=${nativeWidgetTextByteLimit - bytes}.`,
        ));
      }
      return;
    }
    const hasText = tag === "button" && ts.isJsxOpeningElement(node) &&
      ts.isJsxElement(node.parent) && node.parent.children.some(mayProvideAccessibleText);
    if (!hasText) {
      errors.push(locationMessage(
        sourceFile,
        node,
        `ActionableAccessibleNameRequired: <${tag}> has no accessible name. Fix: ${tag === "button" ? "add visible <text>...</text> or " : "add "}accessibilityLabel=\"...\" naming the action.`,
      ));
    }
  };
  const visit = (node: ts.Node): void => {
    if (ts.isJsxOpeningElement(node) || ts.isJsxSelfClosingElement(node)) {
      const sourceFile = node.getSourceFile();
      const tag = node.tagName.getText(sourceFile);
      if (tag === "button" || tag === "slider") validateAccessibleName(node, tag);
      const classAttribute = node.attributes.properties.find((attribute): attribute is ts.JsxAttribute => ts.isJsxAttribute(attribute) && attribute.name.getText(sourceFile) === "class");
      if (classAttribute) {
        const classText = jsxStringValue(classAttribute.initializer);
        if (classText === null) errors.push(locationMessage(sourceFile, classAttribute, "class must be a literal string so weaver check can validate every utility"));
        else {
          try {
            const compiled = compileClass(classText);
            if (compiled.backgroundGradient !== undefined && tag !== "column" && tag !== "row" && tag !== "stack" && tag !== "panel" && tag !== "button") {
              errors.push(locationMessage(
                sourceFile,
                classAttribute,
                `GradientBackgroundElementUnsupported: gradient backgrounds are supported on <column>, <row>, <stack>, <panel>, and <button>; received <${tag}>. Fix: move the gradient to a containing panel.`,
              ));
            }
            const hasStateVariant = Object.keys(compiled).some((key) => key.startsWith("hover") || key.startsWith("pressed"));
            if (hasStateVariant && tag !== "button" && tag !== "slider" && stateVariantAncestry(node) === "none") {
              errors.push(locationMessage(
                sourceFile,
                classAttribute,
                `NearestPressableAncestor: state variants on non-pressable <${tag}> require a nearest <button> or <slider> ancestor. Fix: move the utility to the pressable node or place this node inside one.`,
              ));
            }
            if (compiled.fontFamily && !["sans", "mono"].includes(compiled.fontFamily) && !project.fonts.some((font) => font.stem === compiled.fontFamily || font.family === compiled.fontFamily)) {
              const available = project.fonts.length === 0 ? "no bundled fonts were found next to widget.tsx" : `available bundled names: ${[...new Set(project.fonts.flatMap((font) => [font.stem, font.family]))].join(", ")}`;
              errors.push(locationMessage(sourceFile, classAttribute, `Unknown bundled font "${compiled.fontFamily}"; ${available}`));
            }
            if (tag === "canvas") {
              const sizes = compiled as Record<string, unknown>;
              for (const axis of ["width", "height"] as const) {
                const percent = sizes[axis === "width" ? "widthPercent" : "heightPercent"] !== undefined;
                if (percent || sizes[axis] === undefined) {
                  const shape = percent ? `a percentage ${axis}` : `no ${axis}`;
                  errors.push(locationMessage(
                    sourceFile,
                    classAttribute,
                    `CanvasNeedsExplicitSize: <canvas> has ${shape}. A canvas has no intrinsic size, so inside a content-sized container a percentage resolves against 0 and every draw silently no-ops (ctx.${axis} === 0). Fix: give the canvas an explicit pixel ${axis}, e.g. ${axis === "width" ? "w-[312px]" : "h-[71px]"}.`,
                  ));
                }
              }
            }
          }
          catch (error) { errors.push(locationMessage(sourceFile, classAttribute, error instanceof UtilityError ? error.message : String(error))); }
        }
      }
      if (tag === "canvas" && !classAttribute) {
        errors.push(locationMessage(sourceFile, node, `CanvasNeedsExplicitSize: <canvas> has no class. A canvas has no intrinsic size and draws nothing without one; give it explicit pixel dimensions, e.g. class="w-[312px] h-[71px]".`));
      }
      if (tag === "canvas") {
        const opacityAncestor = canvasOpacityAncestor(node);
        if (opacityAncestor) {
          errors.push(locationMessage(
            sourceFile,
            node,
            `CanvasNeedsOpaqueAncestors: <canvas> is under an opacity <${opacityAncestor}> ancestor. The canvas cannot participate in ancestor opacity, so the widget would be denied and could blank. Fix: move the canvas outside that ancestor or apply opacity inside onFrame.`,
          ));
        }
      }
      if (tag === "image") {
        const sourceAttribute = node.attributes.properties.find((attribute): attribute is ts.JsxAttribute => ts.isJsxAttribute(attribute) && attribute.name.getText(sourceFile) === "src");
        const source = sourceAttribute ? jsxStringValue(sourceAttribute.initializer) : null;
        if (source !== null && (/^[a-z][a-z0-9+.-]*:/i.test(source) || source.startsWith("//"))) {
          errors.push(locationMessage(sourceFile, sourceAttribute ?? node, "RemoteImageUnsupported: <image> remote sources arrive in M3; use a local widget path"));
        } else if (source !== null) {
          const problem = validateLocalImageAsset(project.directory, source);
          if (problem) errors.push(locationMessage(sourceFile, sourceAttribute ?? node, problem));
        }
      }
      if (tag === "icon") {
        try {
          resolveIconSpec(sourceFile, node.attributes);
        } catch (error) {
          errors.push(locationMessage(sourceFile, node, error instanceof Error ? error.message : String(error)));
        }
      }
    }
    if (ts.isCallExpression(node) && ts.isIdentifier(node.expression) &&
        (node.expression.text === "useProvider" || node.expression.text === "useProviderSignal")) {
      const argument = node.arguments[0];
      if (argument && ts.isStringLiteral(argument) && (providerNames as readonly string[]).includes(argument.text)) {
        const provider = argument.text as ProviderName;
        const hooks = usedProviders.get(provider) ?? new Set<"useProvider" | "useProviderSignal">();
        hooks.add(node.expression.text);
        usedProviders.set(provider, hooks);
      } else if (argument && ts.isStringLiteral(argument)) {
        errors.push(locationMessage(
          node.getSourceFile(),
          argument,
          `${node.expression.text}("${argument.text}") names no known provider; available providers: ${providerNames.join(", ")}`,
        ));
      }
    }
    if (ts.isCallExpression(node) && ts.isIdentifier(node.expression) && node.expression.text === "wfetch") {
      const argument = node.arguments[0];
      if (argument && (ts.isStringLiteral(argument) || ts.isNoSubstitutionTemplateLiteral(argument))) {
        const host = originHost(argument.text);
        if (host === null) errors.push(locationMessage(node.getSourceFile(), argument, "wfetch requires an https:// URL"));
        else if (!originDeclared(project.config.origins ?? [], host)) errors.push(locationMessage(node.getSourceFile(), argument, originNotDeclaredMessage(host)));
      }
    }
    ts.forEachChild(node, visit);
  };
  for (const sourceFile of project.sourceFiles) visit(sourceFile);
  for (const [provider, hooks] of usedProviders) {
    if (!project.config.subscribe?.includes(provider)) {
      for (const hook of hooks) errors.push(`${hook}("${provider}") requires subscribe: ["${provider}"] in the widget config`);
    }
  }
  validateMediaTransportCapability(project, errors);
  validateLoweredTree(project, errors);
  return errors;
}

// Image receipt (2026-07-29): noro-shell and retro-player-shell both decode
// to exactly 256x256 RGBA (262,144 bytes), so the old 256 KiB cap had zero
// headroom. 1 MiB admits 512x512 album art (4x the measured bytes). Runtime
// registry storage is fixed address space and pages touch only on register.
// Pinned to both native-sdk canvas_limits.zig and platform/types.zig.
const nativeImagePixelByteLimit = 1024 * 1024;
// The historical generated grille measured 1,025,239 encoded bytes after it
// was squeezed under the old 1 MiB cap. 2 MiB leaves 1,071,913 bytes headroom;
// reads allocate actual file length, so unused allowance costs no memory.
// Pinned to runtime/src/main.zig max_image_stream_bytes.
const maxImageStreamBytes = 2 * 1024 * 1024;

function imageStreamBudgetError(source: string, asked: number): string {
  return `ImageStreamTooLarge: ${JSON.stringify(source)} is ${asked} encoded bytes; max_image_stream_bytes=${maxImageStreamBytes}, asked for ${asked}, headroom=${maxImageStreamBytes - asked}`;
}

function validateLocalImageAsset(directory: string, source: string): string | null {
  const sourceBytes = Buffer.byteLength(source, "utf8");
  if (sourceBytes > nativeWidgetSourceByteLimit) {
    return `ImageSourceTooLong: ${JSON.stringify(source)} is ${sourceBytes} UTF-8 bytes; image source capacity exhausted: max_source_bytes=${nativeWidgetSourceByteLimit}, asked for ${sourceBytes}, headroom=${nativeWidgetSourceByteLimit - sourceBytes}. Use a shorter widget-relative path.`;
  }
  if (!source || isAbsolute(source) || source.split(/[\\/]/).includes("..")) {
    return `InvalidImageSource: ${JSON.stringify(source)} is not a portable widget-relative asset path`;
  }
  const relativeSource = source.startsWith("./") || source.startsWith(".\\") ? source.slice(2) : source;
  const path = resolve(directory, relativeSource);
  if (!pathsEqual(path, directory) && !pathInside(directory, path)) {
    return `WidgetAssetEscapesRoot: ${JSON.stringify(source)} resolves outside ${directory}`;
  }
  let bytes: Buffer;
  try {
    const canonical = realpathSync(path);
    const canonicalRoot = realpathSync(directory);
    if (!pathsEqual(canonical, canonicalRoot) && !pathInside(canonicalRoot, canonical)) {
      return `WidgetAssetEscapesRoot: ${JSON.stringify(source)} resolves outside ${directory}`;
    }
    const encodedSize = statSync(canonical).size;
    if (encodedSize > maxImageStreamBytes) return imageStreamBudgetError(source, encodedSize);
    bytes = readFileSync(canonical);
  } catch (error) {
    return `ImageAssetUnreadable: ${JSON.stringify(source)} could not be read: ${errorMessage(error)}`;
  }
  // Keep the post-read guard for a file that changes between stat and read.
  if (bytes.length > maxImageStreamBytes) return imageStreamBudgetError(source, bytes.length);
  const dimensions = encodedImageDimensions(bytes);
  if (!dimensions) {
    return `ImageDecodeUnsupported: ${JSON.stringify(source)} has no readable PNG/JPEG/GIF/BMP dimensions; the runtime would fail this image only after launch`;
  }
  const decodedBytes = dimensions.width * dimensions.height * 4;
  if (!Number.isSafeInteger(decodedBytes) || decodedBytes > nativeImagePixelByteLimit) {
    return `ImageTooLarge: ${JSON.stringify(source)} is ${dimensions.width}x${dimensions.height}; decoded RGBA is ${dimensions.width} * ${dimensions.height} * 4 = ${decodedBytes} bytes, exceeding max_image_rgba_bytes=${nativeImagePixelByteLimit} by ${decodedBytes - nativeImagePixelByteLimit} bytes. Resize it to at most 512x512 (or any dimensions whose pixel product is <= 262,144).`;
  }
  return null;
}

function encodedImageDimensions(bytes: Buffer): { width: number; height: number } | null {
  if (bytes.length >= 24 && bytes.subarray(0, 8).equals(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]))) {
    return validImageDimensions(bytes.readUInt32BE(16), bytes.readUInt32BE(20));
  }
  if (bytes.length >= 10 && (bytes.toString("ascii", 0, 6) === "GIF87a" || bytes.toString("ascii", 0, 6) === "GIF89a")) {
    return validImageDimensions(bytes.readUInt16LE(6), bytes.readUInt16LE(8));
  }
  if (bytes.length >= 26 && bytes.toString("ascii", 0, 2) === "BM") {
    return validImageDimensions(Math.abs(bytes.readInt32LE(18)), Math.abs(bytes.readInt32LE(22)));
  }
  if (bytes.length >= 4 && bytes[0] === 0xff && bytes[1] === 0xd8) {
    let offset = 2;
    while (offset + 3 < bytes.length) {
      while (offset < bytes.length && bytes[offset] !== 0xff) offset += 1;
      while (offset < bytes.length && bytes[offset] === 0xff) offset += 1;
      if (offset >= bytes.length) break;
      const marker = bytes[offset++];
      if (marker === 0xd8 || marker === 0xd9 || marker === 0x01 || (marker >= 0xd0 && marker <= 0xd7)) continue;
      if (offset + 2 > bytes.length) break;
      const length = bytes.readUInt16BE(offset);
      if (length < 2 || offset + length > bytes.length) break;
      if ([0xc0, 0xc1, 0xc2, 0xc3, 0xc5, 0xc6, 0xc7, 0xc9, 0xca, 0xcb, 0xcd, 0xce, 0xcf].includes(marker) && length >= 7) {
        return validImageDimensions(bytes.readUInt16BE(offset + 5), bytes.readUInt16BE(offset + 3));
      }
      offset += length;
    }
  }
  return null;
}

function validImageDimensions(width: number, height: number): { width: number; height: number } | null {
  return Number.isInteger(width) && Number.isInteger(height) && width > 0 && height > 0 ? { width, height } : null;
}

function discoverWidgetFonts(directory: string): RuntimeFont[] {
  const candidates = readdirSync(directory, { withFileTypes: true })
    .filter((entry) => entry.isFile() && [".ttf", ".otf"].includes(extname(entry.name).toLowerCase()))
    .sort((left, right) => left.name.localeCompare(right.name, "en"));
  const errors: string[] = [];
  if (candidates.length > MAX_WIDGET_FONTS) {
    errors.push(`Registered fonts exceed the widget-profile limit of ${MAX_WIDGET_FONTS} faces: ${candidates.map((entry) => entry.name).join(", ")}`);
  }
  const fonts: RuntimeFont[] = [];
  for (const entry of candidates) {
    const path = join(directory, entry.name);
    const stem = basename(entry.name, extname(entry.name));
    const stemBytes = Buffer.byteLength(stem, "utf8");
    if (stemBytes > MAX_WIDGET_FONT_FAMILY_BYTES) {
      errors.push(`${entry.name}: font family capacity exhausted: max_font_family_bytes=${MAX_WIDGET_FONT_FAMILY_BYTES}, asked for ${stemBytes}`);
      continue;
    }
    if (!/^[A-Za-z0-9][A-Za-z0-9_-]*$/.test(stem)) {
      errors.push(`${entry.name}: font file stems must be 1-63 letters, digits, underscores, or hyphens so font-[${stem || "name"}] is a valid class`);
      continue;
    }
    const bytes = readFileSync(path);
    if (bytes.length > MAX_WIDGET_FONT_BYTES) {
      errors.push(`${entry.name}: font is ${bytes.length} bytes; the widget-profile per-face limit is ${MAX_WIDGET_FONT_BYTES} bytes (512 KiB)`);
      continue;
    }
    const parseError = validateTrueTypeFace(bytes, extname(entry.name).toLowerCase());
    if (parseError) {
      errors.push(`${entry.name}: ${parseError}`);
      continue;
    }
    const variant = /^(.*?)[_-](light|regular|medium|semibold|bold)$/i.exec(stem);
    const family = variant?.[1] || stem;
    const weight = (variant?.[2]?.toLowerCase() ?? "regular") as FontWeightName;
    fonts.push({ id: FIRST_REGISTERED_FONT_ID + fonts.length, name: entry.name, stem, family, weight, file: entry.name });
  }
  const duplicateStem = fonts.find((font, index) => fonts.findIndex((candidate) => candidate.stem.toLowerCase() === font.stem.toLowerCase()) !== index);
  if (duplicateStem) errors.push(`${duplicateStem.name}: bundled font stems must be unique ignoring case`);
  for (const family of new Set(fonts.map((font) => font.family.toLowerCase()))) {
    const members = fonts.filter((font) => font.family.toLowerCase() === family);
    const duplicateWeight = members.find((font, index) => members.findIndex((candidate) => candidate.weight === font.weight) !== index);
    if (duplicateWeight) errors.push(`${duplicateWeight.name}: family "${duplicateWeight.family}" has more than one ${duplicateWeight.weight} face`);
  }
  if (errors.length > 0) throw new WeaverFailure(errors);
  return fonts;
}

function validateTrueTypeFace(bytes: Buffer, extension: string): string | null {
  if (bytes.length < 12) return "not a parseable TrueType face (truncated SFNT header)";
  const tableCount = bytes.readUInt16BE(4);
  if (tableCount === 0 || 12 + tableCount * 16 > bytes.length) return "not a parseable TrueType face (truncated table directory)";
  const tables = new Map<string, { offset: number; length: number }>();
  for (let index = 0; index < tableCount; index += 1) {
    const record = 12 + index * 16;
    const tag = bytes.toString("ascii", record, record + 4);
    const offset = bytes.readUInt32BE(record + 8);
    const length = bytes.readUInt32BE(record + 12);
    if (offset > bytes.length || length > bytes.length - offset) return `not a parseable TrueType face (table ${JSON.stringify(tag)} extends past end of file)`;
    tables.set(tag, { offset, length });
  }
  const required = ["head", "maxp", "cmap", "loca", "glyf", "hmtx", "hhea"];
  const missing = required.filter((tag) => !tables.has(tag));
  if (missing.length > 0) {
    if (extension === ".otf" && tables.has("CFF ")) return "OTF/CFF outlines are unsupported by the bounded renderer; convert this face to TrueType glyf outlines";
    return `not a parseable TrueType glyf face (missing ${missing.join(", ")})`;
  }
  const head = tables.get("head")!;
  const maxp = tables.get("maxp")!;
  const hhea = tables.get("hhea")!;
  const cmap = tables.get("cmap")!;
  if (head.length < 52 || maxp.length < 6 || hhea.length < 36 || cmap.length < 4) return "not a parseable TrueType face (required metrics table is truncated)";
  if (bytes.readUInt16BE(head.offset + 18) === 0 || bytes.readUInt16BE(hhea.offset + 34) === 0) return "not a parseable TrueType face (invalid zero metrics)";
  const subtableCount = bytes.readUInt16BE(cmap.offset + 2);
  if (cmap.length < 4 + subtableCount * 8) return "not a parseable TrueType face (truncated cmap directory)";
  let hasUnicodeFormat4 = false;
  for (let index = 0; index < subtableCount; index += 1) {
    const record = cmap.offset + 4 + index * 8;
    const platform = bytes.readUInt16BE(record);
    const encoding = bytes.readUInt16BE(record + 2);
    const relative = bytes.readUInt32BE(record + 4);
    if (relative > cmap.length - 2) continue;
    const format = bytes.readUInt16BE(cmap.offset + relative);
    if ((platform === 0 || (platform === 3 && (encoding === 1 || encoding === 10))) && format === 4) hasUnicodeFormat4 = true;
  }
  if (!hasUnicodeFormat4) return "not a parseable TrueType face (no Unicode cmap format 4 subtable)";
  return null;
}

function runTypeScript(directory: string): string | null {
  const executable = join(repoRoot, "node_modules", "typescript", "bin", "tsc");
  const result = spawnSync(process.execPath, [executable, "--noEmit", "--pretty", "false", "--rootDir", directory, "-p", join(directory, "tsconfig.json")], { cwd: directory, encoding: "utf8", windowsHide: true });
  if (result.status === 0) return null;
  return `${result.stdout ?? ""}${result.stderr ?? ""}`.trim() || "TypeScript checker failed without output";
}

function jsxStringValue(initializer: ts.JsxAttributeValue | undefined): string | null {
  if (!initializer) return null;
  if (ts.isStringLiteral(initializer)) return initializer.text;
  if (ts.isJsxExpression(initializer) && initializer.expression && (ts.isStringLiteral(initializer.expression) || ts.isNoSubstitutionTemplateLiteral(initializer.expression))) return initializer.expression.text;
  return null;
}

function locationMessage(sourceFile: ts.SourceFile, node: ts.Node, message: string): string {
  const point = sourceFile.getLineAndCharacterOfPosition(node.getStart(sourceFile));
  return `${sourceFile.fileName}:${point.line + 1}:${point.character + 1}: ${message}`;
}

function isRecord(value: unknown): value is Record<string, unknown> { return typeof value === "object" && value !== null && !Array.isArray(value); }
function isNumberPair(value: unknown): value is [number, number] { return Array.isArray(value) && value.length === 2 && value.every((part) => typeof part === "number" && Number.isFinite(part)); }

function printFailure(error: unknown): void {
  const details = error instanceof WeaverFailure ? error.details : [error instanceof Error ? error.message : String(error)];
  process.stderr.write(`weaver failed (${details.length} error${details.length === 1 ? "" : "s"})\n${details.map((detail) => `- ${detail}`).join("\n")}\n`);
}

main(process.argv.slice(2)).catch((error: unknown) => {
  printFailure(error);
  process.exitCode = 1;
});
