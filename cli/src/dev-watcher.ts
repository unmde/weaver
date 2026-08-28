import { watch, type FSWatcher } from "chokidar";
import { relative } from "node:path";

function ignoredDevPath(directory: string, watchedPath: string): boolean {
  const changed = relative(directory, watchedPath).replace(/\\/g, "/");
  return changed === "dist" || changed.startsWith("dist/") ||
    changed === ".git" || changed.startsWith(".git/") ||
    changed === ".weaver-dev-port";
}

export function watchDevDirectory(
  directory: string,
  onChange: (event: string, path: string) => void,
  onError: (error: unknown) => void,
): FSWatcher {
  const watcher = watch(directory, {
    atomic: true,
    awaitWriteFinish: false,
    ignoreInitial: true,
    ignored: (watchedPath) => ignoredDevPath(directory, watchedPath),
  });
  watcher.on("all", onChange);
  watcher.on("error", onError);
  return watcher;
}
