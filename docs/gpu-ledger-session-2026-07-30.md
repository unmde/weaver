# Session teachings — naming the GPU ledger wall (2026-07-30)

Scoped record of one working session on Dara's `Mac15,6` (M3 Pro, 18 GB,
macOS 26.5.2). The durable state lives in `docs/macos-memory-handoff.md`
and `docs/gpu-ledger-wall-brief.md`; this file is the distilled lessons of
how the 85 MB got its name, for anyone (human or agent) doing memory
forensics on this platform again. Branch state: weaver `78f8cdf` →
`0db488a`, native `6a8e6178`.

## The finding, in one paragraph

The ~85–96 MB of dirty "owned physical footprint (unmapped) (graphics)"
that every measured continuously presenting Weaver widget carried on this
machine is the Apple GPU driver's
**per-process command-submission working set**: a ~95 MB arena the driver
commits to any process that submits Metal command buffers in a sustained
cadence (≥ ~1 Hz), plus ~2.4 MB per additional presenting layer, reclaimed
after submission silence. The samples bound that release only indirectly: the
arena was held by 1-second submissions, did not establish across 5-second gaps,
and was gone by the 10-second idle checkpoint. It is not window setup, not
device creation, not presentation (offscreen renders trigger it), not
drawable size (240×110 and 960×440 pay the same), and not anything Weaver
allocates. Weaver pinned it forever because `renderFrame` presents
unconditionally from a 60 Hz timer — on the software backend too, since
both paths drive the same CAMetalLayer.

## The mental model that survived

**The driver charges every continuously active GPU client a flat
subscription fee, billed to the submitting process.** Everything follows:

- Who submits, pays. A process that submits no Metal and shows frames via
  IOSurface contents on a plain CALayer pays ~0 — the compositing charge
  lands in WindowServer, which is composing every window on the system
  anyway. Measured: 0–16 KB graphics ledger at 60 Hz content updates.
- One bill per process, not per renderer/layer/window. 8 presenting
  layers in one process: 95.6 → 112.7 MB, not 8 × 95 MB.
- The fee's size is driver policy per hardware class. Same binary, same
  commit: ~95 MB on the M3 Pro (18 GB), near zero on the M2 Air (8 GB).
  We measured THAT it differs, not why — separating GPU generation from
  RAM size needs a third machine. Don't write a "why" without one.
- Lazy commit, idle release: it is not eagerly reserved at device
  creation (one present ≈ 1 MB), and it releases within seconds of
  silence. Held at 1 s submission intervals; never establishes at 5 s
  intervals. The measured 1 Hz workload stays pinned; the measured 0.2 Hz
  workload does not establish the arena. Cadences between them were not
  measured.

## Method teachings (how the name was found)

1. **Turn it on and off, or it has no name.** The receipt is a ~100-line
   probe with zero Weaver code that reproduces the exact vmmap signature
   and releases it on idle. Every hypothesis got a probe variant: rate
   (60/1/0.2 Hz), size, layer count, offscreen-vs-present,
   IOSurface-vs-Metal. Probe sources + raw logs:
   `.zig-cache/macos-memory/gpu-ledger-wall/` (throwaway; never in a PR).
2. **One-shot probes lie about steady-state costs.** Two prior threads
   measured floors with a single present and concluded "no wall" — the
   trigger was sustained cadence. When chasing a steady-state number,
   the probe must run the steady-state loop.
3. **Match the suspect's exact configuration.** The probe copied weaver's
   layer setup verbatim (framebufferOnly, allowsNextDrawableTimeout=NO,
   BGRA8, contentsScale, drawable size) so a null result would have been
   meaningful. It wasn't needed — but a config-mismatched probe proves
   nothing either way.
4. **Ledger self-report + external attach, cross-checked.**
   `task_info(TASK_VM_INFO).ledger_tag_graphics_footprint` from inside
   the probe, `footprint`/`vmmap --summary` from outside (attach works on
   this harness, unlike the Air's T3 harness). The graphics *category*,
   not the total, is what identifies the wall — totals were ±10 MB noisy
   across the whole investigation.
5. **PID-vs-build-time discipline is not optional.** This machine had
   seven stale weaver-widget processes from prior sessions at
   investigation start, two of them running the same fixture path.
   Stale-PID mixups had already burned two threads; `ps -o lstart` vs
   build finish time before every measurement.
6. **Read the incumbent platform before theorizing.** The Windows source
   answered two architecture questions for free: presents are packet-
   driven ("frames exist only on demand" — webview2_host.cpp), and "the
   widget never creates or loads a D3D device" (d3d_presenter.h). The
   macOS 60 Hz pump is the outlier, not the norm.

## What this settles (decisions recorded in the handoff doc)

- Shared renderer re-approved by Dara on this receipt: one render host
  pays the arena once; device-less widget processes (IOSurface on plain
  CALayer) pay ~0. Next work is Phase 1 of the handoff plan.
- Event-driven presenting (kill the unconditional 60 Hz pump) is correct
  and Windows-proven, good for CPU/battery, and makes the shared host
  cheap — but it is NOT the memory fix: 1 Hz still holds the arena.
- The Phase 1 "20s–30s MB" gate was calibrated on Air content costs; on
  M3-class machines verify by vmmap category ("footprint minus the
  ~95 MB arena"), not by a single total.

## Corrections to prior session records

- The 2026-07-30 correction's fear that "whatever allocates the 85 MB
  would move with the rendering" resolved favorably: it moves with the
  *submitting process*, and is paid once there.
- The Phase 0 falsification stands as honest — its "Metal baseline"
  theory was genuinely wrong. The gate asked "is the wall in device/window
  setup?" and the true answer was no; the wall was in sustained
  submission, a question the gate never posed.
