# GPUI runtime migration plan

Status: proposed with [ADR 0019](adr/0019-one-gpui-runtime-process.md).
Receipts so far: [`spikes/gpui-host`](../spikes/gpui-host/README.md).

## Why

Ten animated Widgets hold 130 MiB private working set on today's stack and
28 MiB as windows of one GPUI process. On Weaver's side the process model is
a small part of the difference: a Widget costs 11.7–12.1 MiB as a process
and 10.5–10.8 MiB as a thread of a shared one, mostly state touched at
startup ([`spikes/native-one-process`](../spikes/native-one-process/README.md)). Widget source, the SDK ([`sdk/CONTRACT.md`](../sdk/CONTRACT.md))
and `.weave` files stay exactly as they are. Developers and their agents
should not be able to tell anything changed except the bill.

## What stays, what goes

| Piece | Fate |
|---|---|
| TSX, `@weaver/sdk`, reconciler, class compiler, `weaver check` | Stays. The class compiler gains a GPUI style target. |
| Retained-tree mutation ops (ADR 0009) | Stays. The tree moves to the Widget's thread; committed batches cross to the UI thread. |
| QuickJS-NG with memory, stack and interrupt limits | Stays. One runtime per Widget, each on its own thread. |
| `weaverd` supervision, registry, Providers | Stays. It supervises one runtime process instead of N. |
| `weaver-widget` (Native fork runtime) | Replaced by the GPUI runtime process. |
| `weaver-renderer` and the macOS render host | Retired. The runtime owns the GPU device. |
| Native SDK fork | Retired after cutover. Gradient, DPI and windowing work is ported, not lost. |

## Open questions that can still reject ADR 0019

Each is settled by a receipt in `spikes/gpui-host`, not by argument. Dara
has ruled on the crash trade (recorded in ADR 0019): platform faults may take
down the shared runtime, a user's Widget may not.

1. **GPUI or a consolidated Native?** Measured
   ([`spikes/native-one-process`](../spikes/native-one-process/README.md)):
   ten Widgets in one Native process hold 121–124 MiB against 133–138 MiB as
   ten processes, about 10% less, so consolidation alone does not close
   the gap. What is
   still open is how far Native's per-Widget state can shrink with
   process-per-Widget kept: building the Model without copying its default
   image already brings ten Widgets to 93–95 MiB; the large stack frames and
   Native's default-initialized tables are identified but not yet fixed.
2. **Threading.** GPUI's `App` lives on the main thread. Each Widget's
   QuickJS runtime needs its own thread with a stack sized for today's 4 MiB
   QuickJS limit (the runtime reserves 16 MiB today), its own copy of state
   that is process-global now (the canvas scratch buffer), owned batch
   messages, and generation numbers so events for a reloaded or removed Widget
   are dropped. Prototype it with the real reconciler and measure the cost of
   the crossing.
3. **One Widget cannot starve the others.** A Widget whose JS is busy must not
   delay another Widget's frames, and a Widget emitting huge batches must hit
   a named limit with a fix-it message rather than stall the UI thread.
   Report per-window frame intervals, not averages.
4. **A Widget cannot crash the runtime.** Fuzz every call a Widget can make
   across the boundary (node and prop ops, canvas command buffers, batch
   sizes, Provider and capability calls) with hostile input and show the
   process survives, with each rejection reported as that Widget's error. The
   memory limit does not cover native allocations made for a Widget, so those
   need their own named limits. Backstop: when a crash happens anyway, show it
   is attributed to the Widget whose call was in flight and that Widget is
   quarantined on the first occurrence. Also show that a Widget whose thread is
   stuck in native code (which the interrupt handler cannot stop) can be
   removed or reloaded while the others keep running.
5. **Identity for Providers and capabilities.** Today `weaverd` authenticates
   Provider pipes by process ID and authorizes media control per Widget slot.
   Design and test per-Widget identity on every call from one process.
6. **macOS.** Run the spike on the MacBook: ten Widgets in one process against
   a matching ADR 0018 workload, with its shared render host counted. GPUI
   creates a Metal renderer, command queue and sprite atlas per window, so one
   process does not automatically mean shared GPU resources there. ADR 0012
   measured about 89–98 MiB (its 93–103 MB) per whole Widget process before
   the shared host.
7. **Idle-zero (ADR 0005).** Ten static clocks in one GPUI process must sit at
   about 0% CPU between ticks, with every wakeup accounted for.
8. **Desktop behavior.** Click-through, per-region hit testing, simultaneous
   interaction across Widgets, pointer capture, no activation, mixed monitor
   DPI and refresh rates, display removal, sleep and resume, and graphics
   device loss. Parent to the desktop on current Windows builds, where the
   wallpaper WorkerW is a child of Progman.
9. **Software fallback and `weaver capture`.** GPUI's production Windows path
   enumerates adapters; a usable WARP fallback is unproven. Show one
   rendering pixel-close to hardware, and decide whether `weaver capture`
   renders headlessly through GPUI or keeps a reference rasterizer.
10. **Billing attribution.** Prototype per-Widget rows and show that adding,
    changing or removing one Widget moves its row by what it costs, with
    shared costs in a separate runtime row.

If any of these fails in a way we cannot fix, ADR 0019 is rejected and the
Native stack stays.

## Phases

Each phase lands as its own PRs with receipts. Nothing switches the default
until phase 6.

1. **Answer the open questions.** Gate: each has a receipt and ADR 0019 is
   accepted or rejected.
2. **Runtime skeleton.** A Rust GPUI runtime process supervised by `weaverd`
   loads Widget bundles, runs QuickJS per Widget, applies batches to retained
   trees, and renders them as GPUI elements. Canvas maps to GPUI `canvas`
   with the existing command buffer. Gate: `examples/clock` and
   `examples/m4b-synthetic` pass the parity check below, idle-zero holds, and
   ten synthetic Widgets stay within a memory budget set from the phase 1
   threading prototype's receipt (the Rust-only spike is a floor, not a
   budget).
3. **Element and styling parity.** Text, images, icons, shadows, gradients,
   interaction, drag and geometry (ADR 0016), per-monitor DPI. GPUI has linear
   gradients with Oklab interpolation; radial, conic, repeating and mesh
   gradients go into our GPUI fork's shaders. Gate: every `examples/styling-*`
   and `examples/m4b-parity` pass the parity check below.
4. **Providers, capabilities, billing.** Provider frames arrive in process
   with per-Widget identity. The capability wall binds per QuickJS runtime.
   `weaver status` shows per-Widget rows plus a runtime row. Gate: the
   attribution test from question 10.
5. **macOS runtime.** Same process on Metal, desktop-level windows, Spaces and
   Stage Manager behavior. Gate: the macOS receipts from question 6 hold with
   real Widgets.
6. **Cutover.** Flip the default behind a flag, run the noro-player gate and
   the [skin parity targets](skin-parity-targets.md) on both OSes, then delete
   the Native runtime and renderer paths and mark ADRs 0007, 0008, 0010 and
   0018 superseded.

## Parity check

Native and GPUI captures of the same Widget, same frame and same capture
conditions, inspected side by side by a person, plus a per-scene numeric
bound measured in phase 1. The m4b receipt (0.71/255 mean channel error,
confined to bar edges, in [`m4b-results.md`](m4b-results.md)) is a reference
point for one static scene, not a tolerance for every Widget: GPUI renders
text differently from Native, and that difference must be judged by eye.

## Fork policy

GPUI is pinned to a Zed commit and forked where Weaver needs more (gradients,
desktop windowing if calls from outside the crate stop being enough). Changes
that make sense upstream go upstream, as with the Native fork.
