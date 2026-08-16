# The GPU ledger wall — name the 85 MB

Brief for an agent on Dara's MacBook Pro (`Mac15,6`, Apple M3 Pro, 18 GB,
macOS 26.5.2). This is the successor to the shared-renderer experiment in
`docs/macos-memory-handoff.md`, whose Phase 0 gate stopped that plan; read
its "2026-07-30 correction" section for the full evidence trail. Vocabulary
(receipt, tripwire, landmine) is CLAUDE.md.

## The finding you are chasing

This brief was opened on branch `feat/macos-memory-work` at weaver `c099db6`.
The recorded measurements below were taken at weaver `78f8cdf` with native
`6a8e6178`; `0db488a` is the subsequent documentation state, not a measurement
commit.

- Bare NSWindow + CAMetalLayer + Metal device + one presented frame:
  9.705 MiB mean physical footprint (~1.1 MB graphics ledger).
- Weaver running trivial Myclock: **125.3 MB footprint, of which 85 MB is
  dirty "Owned physical footprint (unmapped) (graphics)" across 33
  regions** (peak 128.3 MB).
- The identical branch state measures 34.265 MiB on a `Mac14,2` M2 Air.

So the wall is not the Metal entry fee (bare probe ~1 MB graphics), not
measurement error (same tools, floors match the Air within ~1.5 MiB), and
not machine-generic (absent on the Air). Something Weaver's renderer does
makes THIS GPU driver retain ~85 MB for a clock. Your job: give that 85 MB
a name — which allocation, which API pattern, which driver behavior. No
architecture decisions until it has one.

## End state

A written receipt in this doc that names what the 85 MB is, demonstrated
by turning it on and off: a change (or workload variation) that moves the
owned-unmapped-graphics ledger by tens of MB, measured live, plus the
recommendation that follows (fix in-process vs shared renderer vs report
as driver behavior). Rendering stays visually correct and tests stay
green throughout; a low number with broken rendering is a failed end
state.

## Evidence-led order

1. **Reproduce first.** From `runtime/`:
   `mise exec zig@0.16.0 -- zig build -Doptimize=ReleaseFast`, then run
   `runtime/zig-out/bin/weaver-widget examples/myclock/dist`, verify the PID started
   after the build finished, and sample `footprint -p <pid>` after a 5 s
   warmup. Expect ~120-125 MB with ~85 MB owned-unmapped-graphics. Record
   the number before touching anything.
2. **Software-candidate discriminator.** Run:

   ```sh
   python3 scripts/macos-renderer-bakeoff.py \
     --runtime runtime/zig-out/bin/weaver-widget \
     --candidate software \
     --bundles examples/myclock/dist \
     --count 1 \
     --output .zig-cache/myclock-software.json
   ```

   The harness sets `WEAVER_FORCE_SOFTWARE=1` for this candidate. The old thread
   saw software at 128.6 MB — if software is still wall-height, the trigger is
   in the CAMetalLayer present loop shared by both paths, not in canvas GPU
   rendering.
3. **Redraw-rate variation.** Myclock ticks at 1 Hz (`timer` +
   `gpu_surface_frame` every second). Compare a static widget (no timer,
   one present) against Myclock: does the ledger hit 85 MB at first present
   or accumulate to a high-water mark? Immediate points at layer/surface
   allocation; accumulating points at drawable/command-buffer pool
   retention.
4. **Machine A/B.** Same widget, same commit, `vmmap --summary` +
   `footprint` on both this machine and the Air; diff the graphics
   categories (here: 85 MB owned-unmapped dirty, IOAccelerator 3.5 MB,
   IOSurface 432 KB). The Air's continuation receipts in the handoff doc
   have its numbers.
5. **Bisect Weaver's Metal usage** until the ledger moves: canvas GPU
   surface allocation, drawable pool configuration, texture/heap allocation
   pattern, `WEAVER_MEMORY_RECEIPT=1` internals. Metal debug/environment
   instrumentation is fair game for diagnosis; nothing diagnostic ships.

## Rules

- Every claimed number: live measurement, multiple samples, recorded here.
- Always verify PID start time > build finish time (stale-PID mixups have
  burned two threads already), and use weaver's status API for the active
  PID when running under weaverd.
- The measurement method that works everywhere: the process's own
  `task_info(TASK_VM_INFO).phys_footprint`, or `footprint`/`vmmap` where
  attach is permitted. On the Air's T3 harness, attach hangs; self-report
  instead.
- Do not start shared-renderer work from this brief. If the name you find
  argues for it, record the receipt and stop; that decision gets made with
  Dara.

## Recorded results (append as you go)

### 2026-07-30 — named. The wall is the AGX driver's per-process Metal submission working set

All measurements on this machine (`Mac15,6`, macOS 26.5.2 `25F84`), branch
state weaver `78f8cdf` / native `6a8e6178`, fresh ReleaseFast build
(finished 11:09:06; measured PID 63629 started 11:09:13). Probe sources and
raw logs: `.zig-cache/macos-memory/gpu-ledger-wall/` (throwaway; never in a
PR). Ledger numbers are the process's own
`task_info(TASK_VM_INFO).ledger_tag_graphics_footprint`; footprints
cross-checked with `footprint`/`vmmap --summary` attach, which works on this
harness.

**Reproduction (step 1):** fresh Myclock (240x110, dist manifest says
`renderBackend: software`): 133.1 MB phys_footprint, flat over 5 samples.
Prior morning session's vmmap of the same workload: 121 MB with **85 MB
dirty "Owned physical footprint (unmapped) (graphics)" across 33 regions**
(saved in the cache dir). A 960x440 software-backend variant: 159 MB with
96.2 MB owned-unmapped-graphics — the wall barely scales with window size
and hits the software path too, because both paths drive the same
CAMetalLayer present loop.

**The turn-it-on-and-off receipt.** A ~100-line bare probe (weaver's exact
layer config: BGRA8, framebufferOnly=YES, opaque=YES,
allowsNextDrawableTimeout=NO, 480x220 drawable) presenting clears in a
sustained loop:

| Probe workload | Graphics-ledger observation | phys_footprint observation | Sampling / aggregation |
|---|---:|---:|---|
| Before loop starts | 82 KB | 9.0 MB | Single pre-loop sample |
| 60 Hz present loop, 240x110 window | **95.6 MB** (established within the first ~5 frames) | 110.5 MB | Reported steady-state sample; count/window not recorded |
| 1 Hz present loop | **95.5 MB** (held between presents) | 109.2 MB | Reported between-present sample; count/window not recorded |
| 0.2 Hz present loop (5 s gaps) | 0.2-3.3 MB (never establishes) | 12-14 MB | Observed range; count/window not recorded |
| 10 s after any loop stops | ≤1 MB | 13-14 MB | Final sample at the 10-second idle checkpoint |
| Offscreen clears at 60 Hz — no window, no CAMetalLayer, no present | **96.1 MB** | 103.2 MB | Reported steady-state sample; count/window not recorded |
| 60 Hz IOSurface content updates via plain CALayer, no Metal device | **0-16 KB** | 10.0 MB | Observed range plus reported footprint; count/window not recorded |
| One process, N presenting CAMetalLayers (n=1/4/8, 60 Hz) | 95.6 / 103.3 / 112.7 MB | 109.5 / 122.5 / 136.9 MB | One reported value per layer count; window not recorded |

**The name:** the ~85-96 MB "owned physical footprint (unmapped)
(graphics)" is the Apple GPU driver's **per-process command-submission
working set** on this hardware/OS. It is committed as soon as a process
submits Metal command buffers in a sustained cadence — presentation is not
required (offscreen row), a window is not required, and the render target
size barely matters. It is one arena per process (~95 MB) plus ~2.4 MB per
additional presenting layer. The receipt bounds idle reclamation without
pinning an unsupported interval: held at 1-second submissions, never
established across 5-second gaps, and gone within 10 seconds of idle. Weaver
never goes silent because
`renderFrame` presents unconditionally from a 60 Hz display timer
(`appkit_host.m` layer setup / renderFrame), so every widget process pins
the arena forever. The M2 Air's driver sizes this working set near zero for
the same workload (34.3 MiB total footprint there); this is driver policy
per hardware class, not anything Weaver allocates.

**Why the earlier probes missed it:** the Phase 0 probes and this brief's
bare-window floor presented exactly one frame — under the cadence
threshold. The wall was never in window or device *setup*; it is in
sustained *submission*.

**Recommendation (decision stays with Dara):** the numbers point at the
device-less widget process, two independent ways:

1. In-process tuning cannot reach the target on this hardware. Damage-driven
   presenting (stop the unconditional 60 Hz loop) only releases the arena
   for the measured 0.2 Hz workload; the measured 1 Hz seconds clock holds it.
   Intermediate cadences were not measured. Worth doing anyway for
   battery/honesty, but it is not the memory fix for 1 Hz-or-faster widgets.
2. A widget process that submits **no Metal at all** and shows frames via
   IOSurface contents on a plain CALayer measures ~10 MB footprint even at
   60 Hz content updates (probe row above). Whatever process renders pays
   the ~95 MB arena once — that is the shared-renderer shape, now with the
   receipt the 2026-07-30 correction demanded. Marginal cost signals in the
   host look benign (~2.4 MB per extra presenting layer in one process; and
   the host renders to IOSurfaces, not per-widget layers), but per-widget
   host cost and the 30-minute drift check remain to be measured by that
   plan's own gates.

No weaver code was changed in this investigation; rendering and tests are
untouched.
