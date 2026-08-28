export interface DevRebuildLoop {
  schedule(): void;
  drain(): Promise<void>;
}

export function createDevRebuildLoop(rebuild: () => Promise<void>): DevRebuildLoop {
  let dirty = false;
  let startQueued = false;
  let active: Promise<void> | undefined;

  const run = (): Promise<void> => {
    if (active) return active;
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
    if (startQueued || active) return;
    startQueued = true;
    queueMicrotask(() => {
      startQueued = false;
      void run();
    });
  };

  return {
    schedule(): void {
      dirty = true;
      queueStart();
    },
    async drain(): Promise<void> {
      while (dirty || startQueued || active) await run();
    },
  };
}
