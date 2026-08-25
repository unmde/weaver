import { randomUUID } from "node:crypto";
import { existsSync, mkdirSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";

export interface CaptureArtifact {
  path: string;
  bytes: Uint8Array;
}

export interface CapturePublishIo {
  exists(path: string): boolean;
  mkdir(path: string): void;
  write(path: string, bytes: Uint8Array): void;
  rename(source: string, destination: string): void;
  remove(path: string): void;
}

const systemIo: CapturePublishIo = {
  exists: existsSync,
  mkdir: (path) => { mkdirSync(path, { recursive: true }); },
  write: (path, bytes) => { writeFileSync(path, bytes); },
  rename: renameSync,
  remove: (path) => { rmSync(path, { force: true }); },
};

interface StagedArtifact extends CaptureArtifact {
  temporary: string;
  backup: string;
  hadPrevious: boolean;
  backupCreated: boolean;
  published: boolean;
}

export class CaptureArtifactRollbackError extends Error {
  readonly name = "CaptureArtifactRollbackError";

  constructor(readonly errors: unknown[]) {
    super("capture artifact publication failed and rollback was incomplete");
  }
}

export function publishCaptureArtifacts(
  artifacts: CaptureArtifact[],
  io: CapturePublishIo = systemIo,
  unique: () => string = randomUUID,
): void {
  const staged: StagedArtifact[] = [];
  let committed = false;
  try {
    for (const artifact of artifacts) {
      io.mkdir(dirname(artifact.path));
      const temporary = `${artifact.path}.${process.pid}.${unique()}.tmp`;
      const backup = `${artifact.path}.${process.pid}.${unique()}.backup`;
      const stagedArtifact: StagedArtifact = {
        ...artifact,
        temporary,
        backup,
        hadPrevious: io.exists(artifact.path),
        backupCreated: false,
        published: false,
      };
      staged.push(stagedArtifact);
      io.write(temporary, artifact.bytes);
    }

    for (const artifact of staged) {
      if (artifact.hadPrevious) {
        io.rename(artifact.path, artifact.backup);
        artifact.backupCreated = true;
      }
      io.rename(artifact.temporary, artifact.path);
      artifact.published = true;
    }
    committed = true;
  } catch (publicationError) {
    const rollbackErrors: unknown[] = [];
    for (const artifact of [...staged].reverse()) {
      if (artifact.backupCreated) {
        try {
          // File rename replaces the just-published file atomically. Do not
          // unlink first: a failed unlink must never prevent restoration.
          io.rename(artifact.backup, artifact.path);
          artifact.backupCreated = false;
          artifact.published = false;
        } catch (error) {
          rollbackErrors.push(error);
        }
      } else if (artifact.published) {
        try {
          io.remove(artifact.path);
          artifact.published = false;
        } catch (error) {
          rollbackErrors.push(error);
        }
      }
    }
    if (rollbackErrors.length > 0) {
      throw new CaptureArtifactRollbackError([publicationError, ...rollbackErrors]);
    }
    throw publicationError;
  } finally {
    for (const artifact of staged) {
      try { io.remove(artifact.temporary); } catch {}
      // Once every new artifact is in place, stale backups are only cleanup.
      // A cleanup failure must not roll a consistent committed set backward.
      if (committed && artifact.backupCreated) {
        try { io.remove(artifact.backup); } catch {}
      }
    }
  }
}
