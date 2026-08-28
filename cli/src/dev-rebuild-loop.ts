export interface DevRebuildLoop {
  schedule(): void;
  drain(): Promise<void>;
}

export function createDevRebuildLoop(rebuild: () => Promise<void>): DevRebuildLoop {
  let dirty = false;
  let scheduled: NodeJS.Immediate | undefined;
  let active: Promise<void> | undefined;

  const run = (): Promise<void> => {
    if (active) return active;
    if (scheduled) {
      clearImmediate(scheduled);
      scheduled = undefined;
    }
    active = (async () => {
      while (dirty) {
        dirty = false;
        await rebuild();
      }
    })();
    const current = active;
    const settled = (): void => {
      if (active === current) active = undefined;
      if (dirty) queueStart();
    };
    void current.then(settled, settled);
    return current;
  };

  const queueStart = (): void => {
    if (scheduled || active) return;
    scheduled = setImmediate(() => {
      scheduled = undefined;
      void run();
    });
  };

  return {
    schedule(): void {
      dirty = true;
      queueStart();
    },
    async drain(): Promise<void> {
      while (dirty || scheduled || active) await run();
    },
  };
}
