# Handoff — Weaver widget memory reduction (Noro focus)

Continuation brief for a fresh agent. The prior thread ran in T3 Code (codex
harness) on Dara's other laptop, session id
`019fafbc-4c73-7ef3-a1e6-cd3ffd497f8f`, 2026-07-29. This doc is the recovered
state of that thread plus everything needed to continue. It lives on branch
`feat/macos-memory-work`, which is the complete working set: this doc, the
audit briefs, the `examples/myclock/` bakeoff fixture, and the pinned native-sdk
memory work.

## Goal

Get a Weaver widget's Activity Monitor "Memory" number (phys_footprint) as low
as possible. Dara's target: **~20 MB per widget** (numbers in the 20s in
Activity Monitor). Current reality: Noro sits at ~155-166 MB, and even the
trivial Myclock widget is ~130 MB. Dara considers 100+ MB per desk widget
insane, and it is. Push back on the 20 MB target only with measurements, not
vibes — see "The remaining wall" below for why the honest near-term floor may
be higher, and what would have to change to actually reach the 20s.

Verify end-to-end: live process measurements (footprint, vmmap) AND visual
correctness of the rendered widget. A lower number with broken rendering is a
failure.

## Setup (2026-07-30)

You are already on the right branch if you can read this file. It is
rebased onto master with PRs #43-45 merged (error-propagation seams,
Noro art-shadow scrim, visualizer spectrum meter), so all current
widgets are available as test subjects.

- Native SDK memory work: branch `macos-memory-shared-renderer-prep`
  (head `6a8e6178`; memory implementation `600d6cf6`, on top of
  `45336f24`) in SunkenInTime/native — the autorelease pools,
  framebufferOnly, analytic rounded clips, the Metal tiled-image primitive,
  and diagnostics-only screenshot/cache/task-ledger receipts. Setup:
  `git submodule update --init`, then in `runtime/native-sdk`:
  `git fetch origin macos-memory-shared-renderer-prep && git checkout --detach
  6a8e6178`.
- `examples/myclock/` is the clean isolated-benchmark fixture
  (`examples/myclock/dist` is the bundle the bakeoff harness takes).
- The audit briefs (`docs/receipt-sweep-brief.md`,
  `docs/error-propagation-brief.md`) are separate passes; do not mix
  them into this work.

Everything that was once loose on the old machine (the Noro scrim, the
briefs, the fixture) is now merged or on this branch; nothing else needs
recovering.

## What was diagnosed (in order)

Starting point: Noro at ~161 MB phys_footprint, of which ~105 MB graphics
(~87 MB "owned unmapped graphics" + ~18 MB IOAccelerator). Widget files are
220 KB; the album art (256x256) and ArtShadow.png (174 bytes) were ruled out.
Not a leak: 30-second sampling flat, near-zero CPU. It is high steady state.

Ruled out: the old "Dock-icon snapshot for accessory processes" postmortem
(~70 MB class) — current runtime passes no_activate, guards present. That old
28.5 MB validated baseline is stale for today's renderer/OS.

Found, fixed, verified:

1. **Missing Objective-C autorelease pools** around the Zig->AppKit packet
   presentation ABI (pixel, JSON-packet, binary-packet) and the parallel
   raster fill workers. Temporary NSMutableData / NSBitmapGraphicsContext per
   raster fill were never released. Fix verified live on Noro:
   raster backing 16.4 MB -> 23 KB, stale bitmap contexts 102 -> 0,
   heap 33.1 MB -> 19.2 MB, counts flat afterward.
2. **`CAMetalLayer.framebufferOnly = NO`** (inherited from old commit
   `b4711106`, not a current requirement). Changed to YES in production, NO
   kept for automation builds (automation does a 1x1 blit from the drawable
   for first-pixel verification). Semantically correct but **measured no
   footprint win** (Myclock 131.9 -> 132.0 MB). Keep the change, claim
   nothing for it.
3. **Per-command raster cache blowup from rounded ancestor clips.** Noro's
   command cache held 99 textures / 12.93 MB: 31 rounded fills (2.53 MB) +
   31 rounded strokes (2.53 MB) + 28 shadows (2.45 MB) + 6 images (5.37 MB)
   + 3 text. Rounded fills/strokes fell off the analytic Metal path solely
   because an ancestor clip had rounded corners (the progress strip generated
   most of them). Fix: analytic path extended — rounded fills honor rounded
   ancestor clips, analytic rounded strokes added, shader multiplies shape
   coverage by clip coverage. Verified live: cache 99 -> 37 entries, payload
   12.93 -> 7.87 MB, IOAccelerator resident 20.5 -> 14.2 MB, regions 76 -> 63,
   owned-unmapped-graphics virtual 92 -> 52 MB.
4. **Tiled-image expansion** (~4 MB): tiny source tiles were expanded into
   destination-sized retained rasters. Fix implemented: direct Metal
   tiled-image primitive, one lazily created source texture per image ID,
   repeat samplers. Restricted to untransformed, uncropped, full-source tiles
   with no image-local radius; everything else stays on the raster path.
   Shader compiles, full ReleaseFast build passes. **This fix's live memory
   win and visual correctness were NEVER verified** — the thread died during
   visual inspection. This is where you pick up.

## Where the thread died

Repeated failed attempts to visually inspect the live Noro window via
Computer Use (Sky cannot address Noro by name — it's an unbundled accessory
process with no LaunchServices identity; full-screen captures kept getting
blocked by T3 Code's own window and Mission Control wouldn't hold open).
Meanwhile a stale/current PID mixup happened once already (measured the wrong
binary's cache: 99 entries "still there" was a pre-rebuild PID — always check
process start time vs. build finish time, and use weaver's status API to find
the ACTIVE Noro PID; there were two at one point).

Better inspection route than Computer Use, discovered late in the thread:
weaver has a production GPU screenshot hook that reads the composited Metal
texture directly. The env var is inherited by the CLI watcher but NOT by an
already-running host — the instrumented instance must be launched fresh (or
use the window-capture approach in the weaver memory note
"verify-widgets-by-window-capture" if working with the Claude harness).

## Remaining work, in order

1. Tiled-image validation is complete: the cache payload fell by the expected
   ~4 MB, the composited screenshot passed visual comparison, and
   `test-canvas` passed 841/841 after the patch (checkpoint below).
2. Shadows: 28 entries / 2.45 MB still rasterized. Analytic shadow parity is
   harder; measure before attempting.
3. **The remaining wall:** see "The shared-renderer experiment" below. This
   is the real fight for the 20 MB target and has its own phased plan.
4. Keep the per-widget heap wins honest: re-sample after each change,
   multiple samples (footprint numbers were noisy run to run, ±10 MB).

## The shared-renderer experiment (the ~90 MB wall)

### Background

On the measured M3 Pro-class machine, sustained Metal submission at roughly
1 Hz or faster establishes an ~89-96 MB per-process "owned unmapped graphics"
working set. Both the Metal-composite and software-pixel paths paid it because
both presented through CAMetalLayer. The same workload's graphics ledger was
near zero on the M2 Air, so ~130 MB is not a universal per-widget floor; it is
a hardware- and workload-scoped result.

**Key discovery: weaver's Windows runtime already solved this.** Widget
processes on Windows are device-less — display-list packets go over a pipe
to a shared renderer owned by weaverd, and the rendered surface is imported
into the widget's window by DirectComposition. See
`runtime/native-sdk/src/platform/windows/shared_renderer_client.h` and
`d3d_presenter.h` ("the widget never creates or loads a D3D device";
lazy connect, reconnect after renderer crash). That is why Windows widgets
sit at 20-40 MB. macOS is the outlier: every widget owns a CAMetalLayer and
pays the full Metal entry fee. The plan is to port the shared-renderer
contract to macOS: pipe -> unix socket/XPC, DirectComposition shared
surface -> IOSurface into the widget window's CALayer, d3d_presenter -> a
Metal presenter owned by the render host.

### The decision is made — gates are falsification checks, not a debate

Dara has approved the shared-renderer architecture (2026-07-29). Do not
re-litigate whether to build it; build it. The gates below exist to
FALSIFY the decision, and only these findings overturn it:

1. The probe delta shows the ~90 MB is not device-scoped (Phase 0 gate).
2. Per-widget overhead of the new design comes in an order of magnitude
   worse than expected — ~20 MB+ per widget over the current design's
   content cost, not a couple MB of IPC/surface overhead.
3. The design scales badly: per-widget marginal cost in the host grows
   super-linearly with widget count, or memory drifts upward over time
   (a leak-shaped curve) rather than holding a flat steady state.

Any of those three is a stop-and-report finding. Anything smaller is a
note in the results, not a reason to deviate.

### End state (this is what done means)

Every weaver widget on macOS shows in the 20s-30s MB in Activity Monitor
(phys_footprint), with one shared render host paying the Metal baseline
once. Rendering is visually identical to today (rounded clips, tiles,
strokes, shadows verified by screenshot), test-canvas and the runtime suite
pass, and every claimed number is recorded in this doc with multiple
samples. Work the problem however long it takes — but done is defined by
those recorded numbers, not by code existing.

Phases below are the strategy, in order. Each phase's numbers get recorded
in this doc BEFORE its conclusions are acted on — the numbers are what make
the next step trustworthy, including to you.

**Non-goals (read twice — these bound the tenacity):**
- Do NOT implement both architectures. The comparison happens in Phase 0
  with throwaway probes; after the gate, exactly one architecture is built.
- A failed gate is a FINDING, not an obstacle. If the gate number says the
  hypothesis is dead, the problem you are grinding on changes from "build
  the shared renderer" to "explain where the memory actually lives and
  report." Do not make a dead architecture work through sheer persistence.
- Do NOT weaken visual correctness or tests to hit the memory number. A
  low number with broken rendering is a failed end state.
- The deeper consolidation — host owns the windows, widget processes
  become pure JS runners with no AppKit — is OUT OF SCOPE for this pass,
  even if probe 3 makes it look attractive. Measure it (probe 3 stays),
  record the numbers as evidence for a future decision, but Phase 2 builds
  the device-less-widget-process design and stops there. Dara has
  explicitly deferred this call.

### Phase 0 — floor probes (throwaway code, no weaver changes)

Three standalone probe apps (~100 lines each), each measured with
`footprint` (multiple samples, note the spread):

1. Process + NSWindow + CAMetalLayer + Metal device, drawing one quad.
   = floor of the CURRENT architecture.
2. Process + NSWindow + plain CALayer with IOSurface contents, no Metal
   device anywhere in-process. = floor of a device-less widget process.
3. Process, no AppKit at all, allocate + fill an IOSurface.
   = floor of a pure JS-runner widget (host owns the window).

Record all three numbers here.

**GATE:** the bet rests on (probe 1 - probe 2) being large (expected
~70-90 MB). If it is small, the ~90 MB is not device-scoped, the shared
renderer will not reclaim it, and the plan must stop here and be rethought
— record the numbers and end the phase either way.

### Phase 1 — one-widget spike (ugly, hardcoded, throwaway)

Route ONE widget (`examples/myclock/dist`, the clean fixture) through a minimal Metal
presenter running in a second process, frames delivered via IOSurface into
the widget window's CALayer. Ignore crash-reconnect, multi-client, and
protocol cleanliness. Deliverable: the widget process's footprint with real
weaver content (QuickJS + packet ABI) and a screenshot proving it renders.
Record the number here.

**SUPERSEDED GATE:** the original target was for the widget process to land in
the 20s-30s, but the Phase 1 kickoff calibration below replaced that fixed
total-footprint target. The active gate is categorical: the widget process's
`ledger_tag_graphics_footprint` must stay near zero. Report the remaining
hardware-specific content cost separately before any Phase 2 work.

**Scaling check (falsification condition 3):** extend the spike to N
clients — run 1, 2, 4, 8 myclock instances through the one host and record
host footprint at each N plus one widget-process footprint. Expected: host
grows linearly with a modest per-widget slope (surfaces + retained state,
single-digit MB per widget); widget processes stay flat. Then hold the
8-widget configuration for 30+ minutes and sample: steady state must be
flat, not drifting. Super-linear host growth or upward drift is a
stop-and-report finding per the falsification list above.

#### Phase 1 kickoff calibration (2026-07-30, after the wall was named)

Approved to run on `Mac15,6` (the M3 Pro) — the machine where the
submission arena exists, so the gates have teeth; the M2 Air is the
post-pass cross-check, not the spike machine. Read
`docs/gpu-ledger-wall-brief.md` (recorded results) and
`docs/gpu-ledger-session-2026-07-30.md` before starting; the wall's name
changes how this phase is judged:

- **Recalibrated gate:** the original "widget lands in the 20s-30s" was
  written against Air content costs. The success criterion here is
  categorical, not a bare total: the widget process's graphics ledger
  (`vmmap` "owned unmapped graphics" / `ledger_tag_graphics_footprint`)
  stays at ~0 — the ~95 MB arena must not appear in any widget process —
  and the widget total is judged as myclock content cost without the
  arena. The host pays the arena once; that is by design, not a failure.
- **The widget side must submit no Metal at all.** The blueprint is the
  probe's IOSurface-contents-on-plain-CALayer row (~10 MB at 60 Hz content
  updates). Probe sources: `.zig-cache/macos-memory/gpu-ledger-wall/`.
  Any Metal submission from the widget process at >=1 Hz cadence recommits
  the arena and fails the phase, whatever the total reads.
- **Do not mix in event-driven presenting.** Killing the unconditional
  60 Hz pump is separately approved, Windows-proven work — but it is not
  the memory fix (1 Hz still holds the arena) and bundling it into the
  spike muddies the receipt. The host may keep the dumb 60 Hz loop for
  this phase.
- **Expected host shape, from the N-layer probe:** ~95 MB arena plus
  ~2.4 MB per additional presenting layer — and the host can render
  widget frames to IOSurfaces offscreen, so N widgets need not mean N
  presenting layers. The scaling check validates per-widget host cost and
  the 30-minute drift, which the probes did not cover.
- Stale-PID discipline applies (this machine had seven stale
  weaver-widget processes at the last session's start): PID start time >
  build finish time, every measurement.

### Phase 2 — build the winning implementation as reviewed slices

Only if Phase 1's gate confirms an obviously winning design (if it does
not, stop at the finding and report — no build-out for a coin flip).

This phase IS the real, ship-bound implementation, and it is built as a
sequence of PRs against master — one coherent slice per PR. The reason for
slicing: the code review bots review one focused slice of production code
far better than a monolithic port. The throwaway probe/spike code from
Phases 0-1 never appears in a PR.

Spec: mirror the Windows contract
(`runtime/native-sdk/src/platform/windows/shared_renderer_client.h` is the
interface to follow; keep the lazy connect + reconnect-after-crash
semantics). A plausible slice sequence — adjust to what the spike taught:

1. IOSurface presentation path (widget window presents from an IOSurface).
2. Render host process + socket protocol (host side of the contract).
3. Device-less widget client (widget side; no Metal device in-process).
4. Cutover + per-client frame budgets — one host serving N widgets means a
   pathological widget can starve its neighbors; that is a new tripwire
   surface and it must name the budget when it fires (see CLAUDE.md).

For each PR:
- The description carries the receipts: relevant probe/spike numbers,
  before/after footprint where the slice moves it, and visual-verification
  screenshots. Every number states its measurement.
- Babysit it until the code review bots are fully green and the review
  score is 5/5 BEFORE starting the next slice. Address findings properly —
  fix real issues, push back with evidence on false positives; never
  satisfy a bot by weakening tests, suppressing warnings, or shrinking the
  change's honesty.
- Re-run live memory measurements after any review-driven change to the
  render path, and update the PR's numbers if they move.

### Recorded results (append below as phases complete)

- Phase 0 (probes): **FALSIFIED on 2026-07-30; stop-and-report gate
  fired.** Metal-window minus device-less IOSurface-window physical
  footprint was 2.781 MiB at the same five-second checkpoint and 2.861 MiB
  across the ten-sample means, not the expected 70-90 MB.
  **Partially rescinded later the same day — see "2026-07-30 correction"
  below. The probe result stands, but it answered the wrong question: the
  wall is workload-scoped, not window-scoped, and it reproduces on other
  hardware.**
- Phase 1 (spike): **not started.** Un-blocked 2026-07-30: the wall was
  named (per-process Metal submission working set — see the "wall is
  named" section below and `docs/gpu-ledger-wall-brief.md`) and Dara
  re-approved the shared-renderer plan on that receipt. This is the next
  work.
- Phase 2 (slices — one line per merged PR): **not started; gated on
  Phase 1.**

### 2026-07-30 continuation receipts

Hardware was a MacBook Air `Mac14,2`, Apple M2, 8 GB, macOS 26.5.1
(`25F80`). The T3 Code harness could not attach Apple's `footprint` or
`vmmap` processes to another process: each command hung until explicitly
terminated. The replacement measurement path was not RSS or an estimate:
each throwaway probe called `task_info(mach_task_self(), TASK_VM_INFO, ...)`
and recorded the kernel's `phys_footprint` plus graphics ledgers itself.
Ten one-second `proc_pid_rusage(RUSAGE_INFO_V6).ri_phys_footprint` samples
then matched that self-reported checkpoint byte-for-byte on the first sample
and stayed within the spreads below. Probe source and raw JSON live only in
`.zig-cache/macos-memory/phase0/`; they are throwaway and must not enter a
PR.

#### Tiled-image checkpoint — verified

The rebuilt runtime binary completed at `00:35:21`; the measured Noro PID
`16114` started at `00:35:27`, so this was not the stale-PID failure from
the prior thread. The GPU screenshot hook produced both the composited PNG
and a cache receipt:

- raster cache: 33 entries / 3,917,992 bytes (3.737 MiB), down from the
  prior 37 / 7.87 MB;
- direct source-image textures: 4 entries / 133,840 bytes;
- scratch textures: 3 entries / 49,152 bytes;
- first present: 102 commands = 33 cache fills + 69 direct commands.

The retained cache therefore fell by approximately the expected 4 MB. The
fresh screenshot at
`.zig-cache/macos-memory/noro-self-ledger/widget-canvas-p1.png` was opened
and compared with `docs/mac-styling-2026-07-24/noro-shell.png`: the outer
51 px rounded clip, tile orientation/seams/opacity, progress-strip bottom
corners, button borders, and asymmetric corner radii remained intact.
`zig build test-canvas --summary all` passed 841/841.

The screenshot diagnostic deliberately makes the composite target
CPU-readable, so its self-ledger is not used as the production footprint:
57,901,872 bytes physical, including 13,352,960 bytes graphics. The clean
non-diagnostic metal run below is the production number.

#### Phase 0 floor probes — falsification finding

Each row is ten one-second samples after a five-second warmup. Values are
the XNU physical-footprint ledger, in MiB; the parenthesized bytes are the
self-reported five-second checkpoint.

| Probe | Min | Mean | Max | Self checkpoint | Graphics at checkpoint |
|---|---:|---:|---:|---:|---:|
| NSWindow + CAMetalLayer + Metal device + one quad | 11.204 | 11.233 | 11.313 | 11.313 (11,862,712) | 1,163,264 footprint + 2,424,832 no-footprint bytes |
| NSWindow + plain CALayer + IOSurface contents | 8.329 | 8.373 | 8.532 | 8.532 (8,946,336) | 16,384 footprint + 0 no-footprint bytes |
| no AppKit + allocated/filled IOSurface | 2.516 | 2.518 | 2.532 | 2.532 (2,654,616) | 0 bytes |

The decisive delta is only 2,916,376 bytes (2.781 MiB) at the same
checkpoint, or 2,999,935 bytes (2.861 MiB) between the sample means. The
probe does **not** reproduce a device-scoped ~90 MB wall. This is
falsification condition 1 from the approved plan, so the shared-renderer
spike and production slices stop here.

#### Where the current footprint actually lives

Full Weaver measurements used the same ten one-second
`ri_phys_footprint` samples. Each run was flat or had the spread shown in
`.zig-cache/macos-memory/phase0/runtime-results.json`.

| Workload | Mean physical footprint |
|---|---:|
| Myclock, metal | 35,929,314 bytes / 34.265 MiB |
| Myclock, software | 32,824,570 bytes / 31.304 MiB |
| Noro, metal production path | 52,429,664 bytes / 50.001 MiB |
| Noro, forced software | 44,876,640 bytes / 42.798 MiB |

The current Noro metal total decomposes without inventing categories:

- 31.304 MiB: full Weaver + Myclock software floor;
- 2.961 MiB: Myclock's metal-over-software delta;
- 11.494 MiB: Noro's software content over Myclock software;
- 4.242 MiB: Noro-specific GPU content above Myclock's metal delta.

Those measured parts total 50.001 MiB. Moving rendering out of process
cannot turn this widget into a 20s-MB process: even the forced-software Noro
is 42.798 MiB, and the isolated device delta is under 3 MiB.

The diagnostics-only `WEAVER_MEMORY_RECEIPT=1` line also rules out QuickJS
as the wall. Noro's QuickJS allocator held 398,176 bytes (Myclock: 332,224
bytes). The fixed Weaver `WidgetApp` value is 5,845,424 bytes and its
retained `Tree` is 2,512,320 bytes. A `CanvasState` is 294,960 bytes, so the
eight inline canvas slots account for 2,359,680 bytes of every `Tree` before
a widget uses a canvas; the transaction path can retain another whole
`Tree` as `snapshot_storage`. Lazy canvas capacity and the transaction
representation are therefore evidence-led next investigation targets. They
require a new plan; this handoff's shared-renderer plan is stopped by its
own gate.

### 2026-07-30 correction — the wall is real, workload-scoped, and machine-dependent

Measured the same day on Dara's other machine, `Mac15,6` (MacBook Pro,
Apple M3 Pro, 18 GB, macOS 26.5.2, build `25F84`), on a fresh ReleaseFast
build of this exact branch state (weaver `73789e3`, native `6a8e6178`;
widget PID start verified after build finish):

| Measurement (Mac15,6) | Result |
|---|---|
| Bare NSWindow + CAMetalLayer + device + one cleared/presented frame | 9.705 MiB mean (10x1s samples; ~1.1 MB graphics footprint + 2.4 MB no-footprint) |
| Bare NSWindow + plain CALayer + IOSurface contents, no Metal | 8.541 MiB mean |
| Myclock, metal production path, live | **125.3 MB footprint (peak 128.3), of which 85 MB dirty "Owned physical footprint (unmapped) (graphics)", 33 regions** |

The same branch state measures Myclock at 34.265 MiB on the `Mac14,2` Air.
Conclusions, in order of importance:

1. **The ~85-90 MB wall is real and current — on this hardware class.** It
   is not stale-measurement error, not the `footprint` tool (the bare-probe
   floors match the Air's within ~1.5 MiB using the same tool), and not
   Dara's corporate security software (which would appear as mapped library
   regions, not driver graphics ledger).
2. **It is workload-scoped, not window-scoped.** A bare Metal window on the
   same machine carries ~1 MB of graphics ledger; Weaver's trivial clock
   carries 85 MB. Something Weaver's renderer does — canvas GPU surface
   allocation, the per-second `gpu_surface_frame` redraw, texture/heap
   allocation pattern — makes this GPU driver retain ~85 MB that the M2
   driver does not.
3. **The Phase 0 gate design was flawed, not the probes.** The probes
   honestly measured window floors and found no device-scoped wall; but the
   wall was never in the device setup. The falsification verdict stops the
   original "move the Metal *baseline* into a shared host" plan — that
   baseline genuinely does not exist. It does NOT settle whether an
   out-of-process renderer is needed, because whatever allocates the 85 MB
   would move with the rendering. Architecture stays on hold until the
   allocation is named.

The investigation itself is separate work with its own brief:
`docs/gpu-ledger-wall-brief.md` (runs on the `Mac15,6` machine, where the
wall reproduces). This handoff's shared-renderer plan remains stopped.

Do not repeat these mistakes: the falsified gate was treated as closing
the architecture question when it only closed the baseline theory; and
"reproduces on machine A, absent on machine B" was nearly misread twice
(first as security software, then as measurement artifact). Both machines'
numbers are honest; the difference is the finding.

### 2026-07-30 — the wall is named; shared-renderer plan re-opened

The GPU-ledger investigation (`docs/gpu-ledger-wall-brief.md`, "Recorded
results") named the 85 MB with an on/off receipt from bare probes
containing no Weaver code. Summary of what it is:

- The Apple GPU driver's **per-process command-submission working set** on
  the M3 Pro / macOS 26.5.2 class: ~95 MB committed as soon as a process
  submits Metal command buffers in a sustained cadence (>= ~1 Hz), plus
  ~2.4 MB per additional presenting layer. Presentation is not required —
  offscreen renders trigger it; window/device setup alone does not
  (~1 MB). Reclaimed after ~2-5 s of submission silence.
- Weaver pins it forever on every widget because `renderFrame` presents
  unconditionally from a 60 Hz display timer — including the software
  backend, which presents through the same CAMetalLayer.
- A device-less process showing frames via IOSurface contents on a plain
  CALayer measures ~10 MB footprint even at 60 Hz content updates: the
  compositing charge lands in WindowServer, never on the widget's ledger.
- The M2 Air's driver sizes the same working set near zero (34.3 MiB
  total). Driver policy per hardware class, not a Weaver allocation.

Consequences for this plan, per Dara (2026-07-30): **the shared-renderer
architecture is re-approved on the new receipt** — one render host pays
the ~95 MB arena once, device-less widget processes pay ~0. The original
Phase 0 gate stays honestly failed (its "Metal baseline" theory was
wrong), but the new probes answer the question that gate was built to
answer: the wall is real, it moves with whoever submits, and it is paid
per process. Event-driven presenting (drop the unconditional 60 Hz pump;
Windows already works this way — "frames exist only on demand") is worth
doing for CPU/battery and makes the shared host cheap, but is NOT the
memory fix by itself for the measured seconds-clock workload: 1 Hz submission
still holds the full arena, while the measured 0.2 Hz workload does not
establish it. Intermediate cadences were not measured.

Phase 1 (the one-widget spike, myclock through an out-of-process Metal
presenter into an IOSurface-backed CALayer) is therefore the next step, with
the recalibrated gate: the widget process must keep
`ledger_tag_graphics_footprint` near zero. Report the hardware-specific content
cost separately from the removed arena; do not treat a fixed total-footprint
estimate as the acceptance criterion.

## Validation status at handoff

- Native platform tests: pass.
- `test-canvas`: 841/841 pass after the tile patch.
- Direct runtime suite: 57 pass, 1 skip.
- Known false negative: `zig build test` wrapper misclassifies an intentional
  provider-timeout warning on stderr as failure; the direct test executable
  passes. Don't chase it.
- ReleaseFast build + codesign: pass.

## Commands

```sh
# build (from runtime/)
mise exec zig@0.16.0 -- zig build -Doptimize=ReleaseFast

# isolated bakeoff (myclock is the clean fixture; Noro can't run isolated —
# its media provider intentionally requires Weaverd)
# Use `--candidate software` for the software-path comparison.
python3 scripts/macos-renderer-bakeoff.py \
  --runtime runtime/zig-out/bin/weaver-widget \
  --candidate software \
  --bundles examples/myclock/dist \
  --count 1 --warmup-seconds 5 --sample-seconds 5 \
  --output .zig-cache/myclock-software.json --stage-trace

# live measurement (get ACTIVE pid from weaver status --json first)
footprint --noCategories --swapped --format bytes -p <PID>
vmmap -summary <PID>
```

## Reference numbers (all measured 2026-07-29, old laptop, may drift)

| Metric | Before | After fixes 1-3 |
|---|---|---|
| Noro raster cache | 99 entries / 12.93 MB | 37 / 7.87 MB |
| Noro IOAccelerator resident | 20.5 MB | 14.2 MB |
| Noro mutable raster backing | 16.4 MB | 23 KB |
| Noro heap | 33.1 MB | 19.2 MB |
| Noro phys_footprint | ~161-166 MB | ~166 MB (noisy; category shifts confirm wins) |
| Myclock phys_footprint (isolated) | — | 131.9 MB metal / 128.6 MB software |
| Per-process graphics baseline | — | ~89-91 MB (the wall) |
