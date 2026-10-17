---
status: proposed
---

# All Widgets run in one GPUI runtime process; isolation moves to the QuickJS runtime

Weaver pays about 11 MiB of private working set per Widget. On Windows, ten
60 fps copies of `examples/m4b-synthetic` on today's stack (one `weaver-widget` process per Widget plus the shared `weaver-renderer`)
hold 130 MiB private working set and 572 MiB private bytes. A port of the same
scene to ten windows of one GPUI
([Zed's](https://github.com/zed-industries/zed/tree/main/crates/gpui) Rust UI
framework) process holds 28 MiB and 120 MiB. CPU is lower for GPUI on the
median (17% vs 36% as normal windows, 31% vs 37% on the desktop layer), but
the desktop-layer ranges overlap, and the GPUI port runs the bar math in Rust
where Weaver runs it in JS. Receipts:
[`spikes/gpui-host`](../../spikes/gpui-host/README.md).

The gap is not the same thing on both sides. Within GPUI, process topology
matters: three windows cost 18 MiB in one process against 44 MiB as three
processes, and each added window costs about 1.6 MiB. Within Weaver it barely
matters: ten Widgets as threads of one Native process hold 121–124 MiB
against 133–138 MiB as ten processes, about 10% less
([`spikes/native-one-process`](../../spikes/native-one-process/README.md)).
With the renderer subtracted, a Weaver Widget costs 11.7–12.1 MiB as a
process and 10.5–10.8 MiB as a thread. Most of it is fixed-capacity state
touched at startup: a full copy of the Model's default image, 4.3 MB
including the retained tree's unused node and canvas arrays, and about
2.4 MiB of resident stack, probably from large scratch frames. Building the
Model without that copy brings ten Widgets to 93–95 MiB as processes and
77–83 MiB in one process; [#87](https://github.com/unmde/weaver/pull/87)
makes that change.

Decision: Weaver runs every Widget inside one runtime process built on GPUI.
That process owns every Widget window and the GPU device. Each Widget gets its
own QuickJS runtime on its own thread, with its own memory limit, stack limit
and interrupt handler. `weaverd` stays the supervisor and Provider host.
Widget source, the SDK, and `.weave` files do not change.

Today a Widget's reconciler mutates its retained tree synchronously inside its
own process (ADR 0009). Under this decision the tree lives on the Widget's
thread and each committed batch crosses to GPUI's UI thread. That is a new
boundary; its ownership, ordering and backpressure rules are designed in the
migration plan, not assumed.

## What this gives up

ADR 0010 rejected moving Widget logic into a shared process because it would
destroy "the crash-isolation and capability model that process-per-widget
provides". Both halves are real costs here.

- **Crash isolation.** JS faults stay per-Widget: exceptions, runaway loops
  (the interrupt handler) and heap exhaustion (the per-runtime limit) stop one
  Widget, as today. A native fault in our Rust code, GPUI, QuickJS, or the
  graphics driver now stops every Widget. `weaverd` restarts the runtime, and
  every Widget loses its in-memory state (`useState`, timers, open requests);
  only `useStorage` values survive, minus any writes its debounce had not
  yet flushed (it flushes 200 ms after the last write, so a Widget writing
  continuously can lose more). ADRs 0010 and 0018 accepted a shorter
  outage: a renderer crash blanked pixels while Widget logic and state kept
  running.

  Dara's ruling (2026-10-14): the larger trade is acceptable when the fault is
  the platform's, and not when a user's Widget causes it. So no Widget may be
  able to crash the runtime. Everything a Widget can hand to native code
  (props, canvas commands, batch sizes, Provider and capability calls) is
  validated, and misuse becomes that Widget's own error. A Widget that still
  triggers a native crash has exposed a platform bug: the runtime attributes
  the crash to it and quarantines it on the first occurrence, so the other
  Widgets come back without it.
- **Capabilities.** QuickJS has no ambient authority: Weaver compiles it
  without `quickjs-libc`, so a Widget can only call host functions registered
  into its own runtime, and the capability wall (ADR 0002) stays at that
  binding. What changes is identity. `weaverd` authenticates each Provider
  pipe by the client's process ID and authorizes media control per Widget
  slot. One process means one ID, so the runtime must carry per-Widget
  identity on every Provider and capability call instead. Separately, a
  QuickJS engine exploit already reaches the user's account today; in one
  process it also reaches other Widgets' memory, including their stored state.

Honest billing (ADR 0005) moves from OS counters to runtime accounting. A
Widget's row covers its QuickJS heap, retained tree, textures, its thread's CPU
time, and UI-thread time spent on its window; shared costs are a separate
runtime row. The cutover gate is attribution, not arithmetic: adding,
changing or removing one Widget must move that Widget's row by what it costs.

## Considered options

- **Keep the current stack.** Measured above.
- **One GPUI process per Widget.** Three single-window GPUI processes cost
  44 MiB and 198 threads, more threads than today's stack and only slightly
  less memory. The win requires one process.
- **One process on the Native fork.** Measured: consolidation alone saves
  about 10% (121–124 MiB against 133–138 MiB for ten Widgets), because most
  of the cost is per Widget, not per process.
- **Keep process-per-Widget and cut Native's per-Widget state.** Not yet a
  full option. The Model fix above is measured (93–95 MiB for ten, crash
  isolation kept); the stack frames and Native's default-initialized tables
  are identified but not fixed. If both went to zero, subtraction suggests
  a Widget process would still hold about 4 MiB. That is an estimate, not a
  measured floor, and it isn't directly comparable with GPUI's 1.6 MiB: that
  is the marginal cost of one more window in a process that already pays
  about 13 MiB, and the GPUI spike runs no QuickJS. A fair comparison needs
  both stacks running the same JS. CPU has not been attributed on either
  side.

## Consequences

This ADR is accepted or rejected at the end of phase 1 of
[`docs/gpui-runtime-migration.md`](../gpui-runtime-migration.md). If accepted,
it supersedes the process-per-Widget half of ADR 0007 (one runtime image and
source-only Widgets stay), the substrate choice in ADR 0008, and the shared
renderer processes of ADRs 0010 and 0018. Those ADRs are marked superseded at
cutover, not before.
