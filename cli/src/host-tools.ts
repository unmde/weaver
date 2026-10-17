import { randomUUID } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, renameSync, rmSync, statSync, utimesSync, writeFileSync } from "node:fs";
import { dirname, join, posix, resolve, win32 } from "node:path";

export interface Registration { name: string; sourcePath: string; enabled: boolean; dev?: boolean }
export interface RegistryDocument { widgets: Registration[] }
export interface WidgetStatus {
  name: string;
  pid: number;
  privateMb: number;
  cpuPercent: number;
  threads?: number;
  backend: "gpu" | "software" | "-";
  uptimeSeconds: number;
  state: "disabled" | "starting" | "running" | "backoff" | "stopped" | "source missing";
  reason: string;
  /** Runs inside the shared host process; its memory and CPU are the host row's. */
  hosted?: boolean;
  /** This row is the shared widget host process itself. */
  host?: boolean;
}
export interface ProviderStatus {
  systemSubscribers: number;
  systemSampleCount: number;
  systemFrames: number;
  audioCaptureActive: boolean;
  audioSilent: boolean;
  audioPipeFrames: number;
  audioAvailability: "idle" | "authorization-required" | "starting" | "live" | "permission-denied" | "permission-revoked" | "device-unavailable" | "capture-failed";
  audioSubscribers: number;
  audioCaptureStarts: number;
  audioProviderFrames: number;
  audioLastError: number;
  mediaPipeFrames: number;
  mediaAvailability: "available" | "unavailable";
  mediaSubscribers: number;
}
export interface StatusDocument { hostPid: number; providers: ProviderStatus; widgets: WidgetStatus[] }
export interface RegistryLockOptions { timeoutMs?: number; retryMs?: number; staleMs?: number }
export interface WeaverPathEnvironment {
  platform?: NodeJS.Platform;
  localAppData?: string;
  home?: string;
}

export function weaverDataPath(environment: WeaverPathEnvironment = {}): string {
  const platform = environment.platform ?? process.platform;
  if (platform === "win32") {
    const localAppData = environment.localAppData ?? process.env.LOCALAPPDATA;
    if (!localAppData) throw new Error("LOCALAPPDATA is not available");
    return win32.join(localAppData, "weaver");
  }
  if (platform === "darwin") {
    const home = environment.home ?? process.env.HOME;
    if (!home) throw new Error("HOME is not available");
    return posix.join(home, "Library", "Application Support", "Weaver");
  }
  throw new Error(`Weaver data paths are not supported on ${platform}`);
}

export function weaverLogsPath(environment: WeaverPathEnvironment = {}): string {
  const platform = environment.platform ?? process.platform;
  if (platform === "win32") return win32.join(weaverDataPath(environment), "logs");
  if (platform === "darwin") {
    const home = environment.home ?? process.env.HOME;
    if (!home) throw new Error("HOME is not available");
    return posix.join(home, "Library", "Logs", "Weaver");
  }
  throw new Error(`Weaver log paths are not supported on ${platform}`);
}

export function widgetsPath(environment: WeaverPathEnvironment = {}): string {
  const implementation = (environment.platform ?? process.platform) === "win32" ? win32 : posix;
  return implementation.join(weaverDataPath(environment), "widgets");
}

export function registryPath(environment: WeaverPathEnvironment = {}): string {
  const implementation = (environment.platform ?? process.platform) === "win32" ? win32 : posix;
  return implementation.join(weaverDataPath(environment), "registry.json");
}

export function statusPath(environment: WeaverPathEnvironment = {}): string {
  const implementation = (environment.platform ?? process.platform) === "win32" ? win32 : posix;
  return implementation.join(weaverDataPath(environment), "status.json");
}

export function readRegistry(path = registryPath()): RegistryDocument {
  if (!existsSync(path)) return { widgets: [] };
  const parsed = JSON.parse(readFileSync(path, "utf8")) as RegistryDocument;
  if (!parsed || !Array.isArray(parsed.widgets)) throw new Error(`Invalid Weaver registry at ${path}`);
  return { widgets: parsed.widgets.map((widget) => ({
    name: String(widget.name), sourcePath: resolve(String(widget.sourcePath)), enabled: Boolean(widget.enabled), dev: Boolean(widget.dev),
  })) };
}

export function writeRegistry(document: RegistryDocument, path = registryPath()): void {
  mkdirSync(dirname(path), { recursive: true });
  const temporary = `${path}.${process.pid}.${randomUUID()}.tmp`;
  try {
    writeFileSync(temporary, `${JSON.stringify(document, null, 2)}\n`, "utf8");
    renameSync(temporary, path);
  } finally {
    if (existsSync(temporary)) rmSync(temporary, { force: true });
  }
}

export async function withRegistryLock<T>(operation: () => T | Promise<T>, path = registryPath(), options: RegistryLockOptions = {}): Promise<T> {
  // A transaction may spend up to five seconds starting the host and ten
  // seconds waiting for its reload acknowledgement. Contenders must wait
  // longer than the longest valid critical section before declaring failure.
  const timeoutMs = options.timeoutMs ?? 30_000;
  const retryMs = options.retryMs ?? 25;
  const staleMs = options.staleMs ?? 5 * 60_000;
  const lockDirectory = `${path}.lock`;
  const ownerPath = join(lockDirectory, "owner.json");
  const token = randomUUID();
  const deadline = Date.now() + timeoutMs;
  mkdirSync(dirname(path), { recursive: true });
  while (true) {
    try {
      mkdirSync(lockDirectory);
      try {
        writeFileSync(ownerPath, `${JSON.stringify({ pid: process.pid, token })}\n`, "utf8");
      } catch (error) {
        rmSync(lockDirectory, { recursive: true, force: true });
        throw error;
      }
      break;
    } catch (error) {
      if (!isAlreadyExists(error)) throw error;
      if (reclaimAbandonedLock(lockDirectory, ownerPath, staleMs)) continue;
      if (Date.now() >= deadline) throw new Error(`Timed out waiting for Weaver registry lock at ${lockDirectory}`);
      await delay(retryMs);
    }
  }

  const heartbeat = setInterval(() => {
    if (!lockOwnedBy(ownerPath, token)) return;
    const now = new Date();
    try { utimesSync(lockDirectory, now, now); }
    catch { /* A later owner reclaimed the lease; release must not remove it. */ }
  }, Math.max(1_000, Math.floor(staleMs / 3)));
  heartbeat.unref();
  try {
    return await operation();
  } finally {
    clearInterval(heartbeat);
    if (lockOwnedBy(ownerPath, token)) rmSync(lockDirectory, { recursive: true, force: true });
  }
}

export function pathsEqual(left: string, right: string, platform: NodeJS.Platform = process.platform): boolean {
  return comparablePath(left, platform) === comparablePath(right, platform);
}

export function pathInside(root: string, candidate: string, platform: NodeJS.Platform = process.platform): boolean {
  const implementation = platform === "win32" ? win32 : posix;
  const relative = implementation.relative(comparablePath(root, platform), comparablePath(candidate, platform));
  return relative !== "" && relative !== ".." && !relative.startsWith(`..${implementation.sep}`) && !implementation.isAbsolute(relative);
}

export function readStatus(path = statusPath()): StatusDocument {
  return JSON.parse(readFileSync(path, "utf8")) as StatusDocument;
}

export function formatStatus(document: StatusDocument): string {
  const headings = ["NAME", "PID", "BACKEND", "PRIVATE", "CPU", "THREADS", "UPTIME", "STATE"];
  const rows = document.widgets.map((widget) => [
    widget.name,
    widget.pid === 0 ? "-" : String(widget.pid),
    widget.backend ?? "-",
    widget.hosted ? "in host" : `${widget.privateMb.toFixed(1)} MB`,
    widget.hosted ? "in host" : `${widget.cpuPercent.toFixed(1)}%`,
    String(widget.threads ?? 0),
    formatUptime(widget.uptimeSeconds),
    widget.reason ? `${widget.state}: ${widget.reason}` : widget.state,
  ]);
  const widths = headings.map((heading, column) => Math.max(heading.length, ...rows.map((row) => row[column].length)));
  return [headings, ...rows].map((row) => row.map((cell, column) => column === row.length - 1 ? cell : cell.padEnd(widths[column])).join("  ")).join("\n");
}

/** What `weaver-widget --status` prints when no host runs (host_lifecycle.zig `describeDown`). Times are Unix milliseconds. */
export interface HostDown {
  stopped: { at: number } | null;
  now: number;
  recordPath: string;
  restartCap: number;
  restartWindowMs: number;
  minRunMs: number;
  restartWaitMs: number;
  /** The slowest restart measured (host_contract.os_restart_measured_max_ms). */
  restartMeasuredMs: number;
  /** The Win32 error a starting host gets opening its record, when no live host holds it; such a host exits (host_contract.exit_record_unavailable). */
  recordHeld: null | { error: number; sharing: boolean };
  record: null | {
    generation: number;
    pid: number;
    state: "running" | "stopped" | "none";
    process: "gone" | "alive" | "unknown";
    startedAt: number;
    stopReason: string;
    crash: null | { kind: "widget" | "ui" | "other"; cause: "panic" | "wedged" | "exception"; code: number; at: number; widget: string | null };
    restart: "none" | "registered" | "capped" | "failed";
    restartError: number;
    /** The restart command line's length in UTF-16 units, and Windows' limit with its terminator. */
    restartLineLength: number;
    restartLineLimit: number;
    automaticRestarts: number[];
  };
}

/** Why no widget host runs, and what to run, from its record and the stop marker. */
export function describeHostDown(down: HostDown): string[] {
  const clock = (ms: number): string => new Date(ms).toLocaleTimeString();
  const seconds = (ms: number): string => `${Math.max(0, Math.round(ms / 1000))} s`;
  const up = 'Run "weaver up" to start it.';
  if (down.stopped) return [`The widget host is not running: "weaver down" stopped it at ${clock(down.stopped.at)}.`, up];
  if (down.recordHeld) {
    const why = down.recordHeld.sharing ? "another program holds it open" : `Windows answers Win32 error ${down.recordHeld.error}`;
    return [`The widget host is not running: it cannot open its record at ${down.recordPath} (${why}), and a host exits without it, because it could not quarantine the widget a crash blames.`, 'Close whatever holds that file, then run "weaver up".'];
  }
  const record = down.record;
  if (!record) return [`The widget host is not running, and ${down.recordPath} holds no record of an earlier run.`, up];
  // A host whose record holds a crash and whose process is alive is dying:
  // Windows is reporting the crash. It is worded as the crash below.
  if (record.process === "alive" && !record.crash) return [`The widget host (pid ${record.pid}) is running but has not published its control objects, so it is starting or stopping.`, 'Run "weaver status" again in a few seconds; if this stays, run "weaver down", then "weaver up".'];
  if (record.process === "unknown" && !record.crash) return [`The widget host's state is unknown: its record names pid ${record.pid}, which Weaver could not open.`, 'Run "weaver down", then "weaver up".'];
  if (record.state === "stopped") {
    if (record.stopReason) return [`The widget host is not running: it stopped as it started, with error.${record.stopReason}.`, 'Run "weaver up" to try again.'];
    return ["The widget host is not running: it exited cleanly on its own.", up];
  }
  const crash = record.crash;
  if (!crash) return ["The widget host is not running: it ended without recording a crash, so it was killed or failed where its crash handler could not see. No widget is blamed, and Windows does not restart it.", up];
  const code = `0x${crash.code.toString(16).toUpperCase().padStart(8, "0")}`;
  const what = crash.cause === "panic" ? `a panic (${code})` : crash.cause === "wedged" ? `its UI thread stuck past the apply deadline (${code})` : `exception ${code}`;
  const where = crash.kind === "widget" ? `in the turn of ${crash.widget ? `"${crash.widget}"` : "a widget"}` : crash.kind === "ui" ? "on its UI thread, outside any widget's turn" : "on a provider or management thread";
  const lines = [`The widget host is not running: it crashed at ${clock(crash.at)} with ${what} ${where}, ${seconds(crash.at - record.startedAt)} after it started.`];
  if (record.process === "alive") lines.push(`Its process (pid ${record.pid}) is still exiting while Windows reports the crash.`);
  if (crash.kind === "widget") lines.push(`${crash.widget ? `"${crash.widget}"` : "That widget"} is quarantined when the host next starts; reinstall or update it to run it again.`);
  else lines.push("No widget is blamed.");
  const window = `${Math.round(down.restartWindowMs / 60_000)} minutes`;
  if (record.restart === "capped") {
    lines.push(`Windows restarted it ${record.automaticRestarts.length} times within ${window}, the cap (restart_cap=${down.restartCap}), so it was not asked to again and the host stays down.`);
    lines.push('Run "weaver up" to start it with a fresh restart count.');
    return lines;
  }
  if (record.restart === "failed") {
    if (record.restartLineLength >= record.restartLineLimit) {
      lines.push(`Windows could not be asked to restart it: its restart command line carries the profile path and is ${record.restartLineLength} UTF-16 units, past RegisterApplicationRestart's limit of ${record.restartLineLimit} with its terminator. Set LOCALAPPDATA to a path at least ${record.restartLineLength - record.restartLineLimit + 1} characters shorter.`);
    } else {
      lines.push(`Windows could not be asked to restart it (RegisterApplicationRestart returned 0x${record.restartError.toString(16).toUpperCase().padStart(8, "0")}).`);
    }
  } else if (record.restart === "none") {
    lines.push("It had not asked Windows to restart it.");
  } else if (crash.at - record.startedAt < down.minRunMs) {
    lines.push(`Windows restarts only a process that ran ${seconds(down.minRunMs)}, so this one stays down.`);
  } else if (down.now - crash.at < down.restartWaitMs) {
    lines.push(`Windows restarts it shortly; restarts have come up to ${seconds(down.restartMeasuredMs)} after a crash. Run "weaver status" again then, or "weaver up" to start it now.`);
    return lines;
  } else {
    lines.push(`Windows was asked to restart it, but nothing came back ${seconds(down.now - crash.at)} after the crash.`);
  }
  lines.push(up);
  return lines;
}

function formatUptime(seconds: number): string {
  const total = Math.max(0, Math.floor(seconds));
  const hours = Math.floor(total / 3600);
  const minutes = Math.floor((total % 3600) / 60);
  const remainder = total % 60;
  return hours > 0 ? `${hours}h${String(minutes).padStart(2, "0")}m` : minutes > 0 ? `${minutes}m${String(remainder).padStart(2, "0")}s` : `${remainder}s`;
}

function comparablePath(path: string, platform: NodeJS.Platform): string {
  const implementation = platform === "win32" ? win32 : posix;
  const normalized = implementation.resolve(path);
  return platform === "win32" ? normalized.toLowerCase() : normalized;
}

function reclaimAbandonedLock(lockDirectory: string, ownerPath: string, staleMs: number): boolean {
  let ageMs: number;
  try { ageMs = Date.now() - statSync(lockDirectory).mtimeMs; }
  catch { return true; /* The lock vanished between discovery and inspection, so there is nothing left to reclaim. */ }
  let pid: number | null = null;
  try {
    const owner = JSON.parse(readFileSync(ownerPath, "utf8")) as { pid?: unknown };
    if (typeof owner.pid === "number" && Number.isInteger(owner.pid) && owner.pid > 0) pid = owner.pid;
  } catch { /* A creator may still be publishing a fresh owner file. */ }
  if (pid !== null && processIsRunning(pid) && ageMs <= staleMs) return false;
  if (pid === null && ageMs <= staleMs) return false;
  try {
    rmSync(lockDirectory, { recursive: true, force: true });
    return true;
  } catch {
    return false; // The lock owner changed or access was denied; the bounded acquire loop reports timeout to the caller.
  }
}

function processIsRunning(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return !isNoSuchProcess(error);
  }
}

function lockOwnedBy(ownerPath: string, token: string): boolean {
  try {
    const owner = JSON.parse(readFileSync(ownerPath, "utf8")) as { token?: unknown };
    return owner.token === token;
  } catch {
    return false; // A missing, partial, or replaced owner file means this lease must not delete the lock.
  }
}

function isAlreadyExists(error: unknown): boolean {
  return error instanceof Error && "code" in error && error.code === "EEXIST";
}

function isNoSuchProcess(error: unknown): boolean {
  return error instanceof Error && "code" in error && error.code === "ESRCH";
}

function delay(milliseconds: number): Promise<void> {
  return new Promise((resolvePromise) => setTimeout(resolvePromise, milliseconds));
}
