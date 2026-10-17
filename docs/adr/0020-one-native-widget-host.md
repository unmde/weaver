---
status: proposed
---

# All Widgets run in one Native host process on one thread

Weaver has to match Rainmeter on memory and CPU (CLAUDE.md: the profile is
the product). Rainmeter 4.5 runs ten clock skins in 5.4 MiB of private
working set, about 4.2 MiB of base plus 0.12 MiB per skin, at near-zero
CPU. Weaver ran ten clock Widgets in 47.4 MiB: one `weaver-widget` process
each, and a bare Windows GUI process alone costs 1–1.5 MiB. No per-process
trimming reaches the target.

ADR 0019 (proposed) measured one process on the Native fork at only 10%
below process-per-Widget. That spike gave every Widget its own thread with
its own Native `Runtime` and app, so every Widget still paid the runtime,
its fixed tables and a stack. The same Widgets as one thread and one
`Runtime` with a window each cost 3.1× less:

| ten `examples/clock`, Windows, private working set | MiB |
|---|---:|
| ten processes (today) | 45.4 |
| one host process (this ADR) | 14.6 |
| one host process, plus `weaverd` | 16.5 |
| Rainmeter 4.5, ten clock skins | 5.4 |

Ten 60 fps `m4b-synthetic` Widgets: 34 MiB in total (host 15.2, shared GPU
renderer 17.1, `weaverd` 1.8) at 28–32% CPU, against about 68 MiB before
and Rainmeter's 10 MiB at 85–107% CPU.

Decision: on Windows, `weaverd` runs every Widget that isn't in `--dev` in
one `weaver-widget --host` process. One Native `UiApp` drives one window per
Widget on one thread; a Widget's window rebuilds only when its own retained
tree moves (Native's `window_view_revision`). Each Widget keeps its own
QuickJS engine, retained tree, log, storage, placement and provider
channel. A lone Widget is a host of one, so there is one runtime code path.
`--dev` Widgets and macOS keep a process each for now.

## What this gives up

- **Crash isolation.** JS faults stay per Widget: exceptions, the interrupt
  budget and each engine's own memory limit. A native fault now stops every
  Widget; `weaverd` restarts the host and every Widget loses in-memory
  state. Dara's ruling (2026-10-14) applies: a platform fault may take the
  host down, a user's Widget may not. The host writes the running Widget's
  position into a crash breadcrumb (shared memory) on every entry, so
  `weaverd` charges a crash to that Widget alone and restarts the others at
  once; an unattributed crash charges every Widget. The breadcrumb names the
  last Widget whose code ran, which is not always the cause: a platform
  fault (or an outside kill) right after a Widget's turn blames that
  Widget. Attribution therefore uses the ordinary backoff (three restarts,
  stopped on the fourth crash within five minutes, cleared by reinstalling)
  rather than ADR 0019's quarantine on first occurrence; repeated platform
  faults can still stop a healthy Widget, which is the residual risk.
- **One thread.** A Widget's long JS turn delays every other Widget's frame
  until its interrupt budget stops it.
- **Honest billing (ADR 0005).** OS counters now describe the host, not a
  Widget. `weaver status` shows one `host` row with the process's costs and
  marks each Widget "in host" until per-Widget accounting exists.
- **Failure stays per Widget.** A Widget whose manifest, fonts or bundle
  fail to load is skipped and reported (`weaver status` shows it stopped
  with the error); a Widget whose view fails to build keeps its last frame
  while the others refresh. Native's runtime-wide registries (images,
  fonts, effect timers) hold each Widget's own budget for every window,
  with ids namespaced per Widget.

## Consequences

Supersedes the process-per-Widget half of ADR 0007 when accepted (one
runtime image and source-only Widgets stay) and answers ADR 0019's
"one process on the Native fork" option with a different measurement:
the win needs one `Runtime`, not just one process. Per-Widget cost is now
about 1.1 MiB, the next target: the QuickJS engine (~350 KiB, ~240 KiB with
a shared runtime, ~50 KiB with shared bytecode), Native's per-window state
(~245 KiB), and up to three software pixel copies per window.
Receipts and scripts: `E:\w\rm-bench` on the measuring machine, to be moved
into `spikes/` with the implementation PR.
