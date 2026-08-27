# Review: the agent widget capture blueprint

Review of the "Weaver can give agents real widget pixels without putting a
widget on the desktop" blueprint (generated 2026-08-24 against Weaver
`e69a0997` and Native SDK `4c5c0999`). The direction is right and its safety
fact holds. The cost estimate and the slice order are wrong in a way that
matters: most of slices B and C already ship inside the pinned SDK, and the
one high-cost item — extracting a `WidgetSession` out of `runtime/src/main.zig`
— buys capture nothing.

Everything below was measured in this worktree, not read off the source.

## The monolith is not in the way

The blueprint's slice A extracts manifest, state, provider, image, font,
QuickJS, and `WidgetApp` setup out of `main.zig` before capture can exist, and
prices it Medium likelihood / High cost against live desktop startup, dev
reload, and image lifetime. That refactor is not a prerequisite. Weaver's
existing bootstrap already runs headless.

Building the real runtime against the null backend fails on one line, and it
is not the bootstrap:

```
$ cd runtime && zig build -Dplatform=null -Dautomation=true
error: undefined symbol: _native_sdk_appkit_render_host_run
    note: referenced by .../weaver-widget_zcu.o:_main.main
```

`main.zig:1246` reaches for the AppKit render-host extern under
`builtin.os.tag == .macos`, but only the macOS *backend* links that
Objective-C source. The condition needs to test the backend, not the OS — a
one-line comptime gate, and worth fixing regardless of capture, since today
any non-macOS-backend build of the runtime fails to link.

With that gated, the whole bootstrap ran on the real clock bundle — manifest
load, storage, geometry, QuickJS evaluation, `app_start` — and stopped at
exactly one place:

```
$ HOME=/tmp/wcap ./runtime/zig-out/bin/weaver-widget examples/clock/dist
# /tmp/wcap/Library/Logs/Weaver/Clock.log
info: widget runtime starting pid=67886
info: widget renderer selected=metal-composite presenter=host
warning: dispatch error: UnsupportedViewKind (event app_start)
error: widget runtime stopped after platform callback failure: UnsupportedViewKind
```

365 ms, cold, ReleaseFast. `UnsupportedViewKind` is
`app_runner/root.zig`'s `runNull` constructing
`NullPlatform.initWithOptions(.{}, ...)` and leaving `gpu_surfaces = false`,
so `createView` refuses Weaver's `.gpu_surface` canvas
(`null_platform.zig:913`). One platform toggle, not a refactor.

Do slice A later if a measurement says `main.zig` is blocking something. It
should not be the entry fee.

## Capture belongs next to session replay, and the SDK already has one

`runSessionReplay` (`runtime/native-sdk/src/app_runner/root.zig:693`) is
already a headless null-platform runner living in the shipping widget binary,
selected by one environment read at startup. It sets `gpu_surfaces = true`,
renders through `renderCanvasScreenshot`, encodes PNG, and can dump those PNGs
to a directory (`NATIVE_SDK_SESSION_REPLAY_DUMP`). The blueprint never
mentions it, and proposes a new `runtime/src/capture_main.zig`, a
`runtime/build.zig` change, and a session extraction to reach the same place.

Capture is a sibling of that function. Prototyped here as
`runHeadlessCapture`, roughly 90 lines beside `runSessionReplay`, gated on
`NATIVE_SDK_CAPTURE_PNG`, with zero changes to Weaver's own code:

```
$ node cli/bin/weaver.js bundle examples/clock
$ HOME=/tmp/wcap NATIVE_SDK_CAPTURE_PNG=/tmp/wcap/clock.png \
    ./runtime/zig-out/bin/weaver-widget examples/clock/dist
capture path=/tmp/wcap/clock.png width=240 height=110 frames=2 \
  inked_pixels=26400 png_bytes=105783 elapsed_us=734
```

240 x 110 matches `examples/clock/dist/widget.json` (`size: [240, 110]`)
exactly. Five consecutive runs put the capture phase — startup dispatch
through PNG bytes on disk — at 500 to 930 us, with total process wall time
under 10 ms per run.

This also settles the separate-executable question the blueprint decides by
assertion. Session replay is compiled into the production widget binary
today, gated by one `getenv`, so idle cost is already zero and the precedent
is set. If a separate artifact is still wanted, it needs a binary-size
receipt, not an argument.

## The drive sequence is the part nobody wrote down

The first prototype produced flat black PNGs for `examples/clock`,
`examples/styling-text`, and `examples/pomodoro` — correct dimensions, no
content. That was my bug, and it is the most useful thing this exercise
found: I drove `.frame_requested`, but Weaver's canvas is driven by the GPU
surface. A capture has to report a drawable size and then tick presents:

- `.gpu_surface_resized` with the view's frame, scale, and physical size
- `.gpu_surface_frame` per frame, carrying `frame_index` and `timestamp_ns`

Drive the wrong event and capture exits 0, writes a well-formed PNG of the
clear color, and says nothing is wrong. Nobody reading the blueprint would
know this seam exists, and an agent handed that black PNG cannot act on it.
Whatever ships must name what drove the frame and what was still pending in
its receipt. (The corrected sequence is in the prototype; its verification run
was interrupted, so treat corrected-but-unconfirmed as the current state.)

Two more null-platform defaults matter for the same reason: `image_decode` is
off (`null_platform.zig:242`), so image widgets capture without their images
until it is turned on, and `requested_frames` defaults to 1.

## The text-parity choice is already made, and it has a cost

The blueprint lists text measurement as "Platform-dependent ... needs an
explicit parity choice" and native text measurement in a windowless process
as an unproven gate. It ships already:
`installHeadlessTextServices` (`src/platform/macos/root.zig:968`) registers
the bundled faces and points `measure_text_fn` at CoreText with no window and
no run loop, and session replay installs it precisely so headless pixels match
the recording host (`app_runner/root.zig:711`). The fidelity table should read
High on macOS.

The real costs sit next to it, and neither is in the blueprint:

1. That function is comptime-gated on the macOS backend, so a parity capture
   is the normal macOS build with a runtime switch, not a `-Dplatform=null`
   build. The macOS backend needs the Metal toolchain, which this machine
   does not have, so the parity capture could not be measured here at all:
   `error: cannot execute tool 'metal' due to missing Metal Toolchain`. A
   capture that requires the Metal toolchain to get text right, while never
   touching Metal, is a real developer-experience decision that should be made
   deliberately rather than discovered.
2. There is no Windows equivalent. A Windows capture measures with the
   engine's estimator, so a Windows developer's agent sees different pixels
   than a macOS one for the same widget. That is the parity landmine, and the
   blueprint does not name it.

## Two protocols for one job

The automation `Server` and `Watcher` already carry a transport with a command
dropbox, snapshot publish, `screenshot(view, scale)` publish, and verbs for
click, drag, wheel, key, text, context menu, and resize, with a watcher thread
that wakes frames (`src/automation/server.zig`, `src/runtime/flow.zig:101-130`,
`automation_commands.zig`). The proposed JSON Lines protocol is a second
protocol for that job. JSON Lines is genuinely nicer for an agent than a
filesystem dropbox, so pick it and say it replaces the dropbox for headless —
but do not ship both and let them drift.

Same pattern for fixtures. The session journal is already the recorded-input
format, with fingerprint checkpoints, screenshot marks, a verify mode, and a
mismatch reporter that names the diverging event ordinal. "Record on a real
desktop run, replay headless" beats inventing hashed provider fixture files.
The one input that genuinely needs a new format is Weaver's own provider
channel (CPU, memory, media over the host pipe), because that is Weaver's, not
an SDK effect, and nothing journals it today. The blueprint should scope
fixtures to that instead of proposing them for everything.

## Slice C may not need to exist

Capture is fast enough that a live session looks like a liability rather than
a feature: under 1 ms for the capture phase and under 10 ms for the whole
process on the clock widget. If that holds for heavier widgets, a
deterministic action script on one-shot capture — something shaped like
`weaver capture ./clock --act 'click role=button[name=Start]' --act 'clock +5s'`
— deletes the revision protocol, `StaleWidgetRevision`, the long-lived
process, and the entire stale-node-ID class of bug, because every capture is a
fresh run and targets resolve by role and label rather than by a number that
has to survive a rebuild. It also produces something attachable to a bug
report and replayable in CI.

The live session then belongs to the human viewer in slice D, not to the agent
contract.

## Gaps worth closing

- **No `weaver check` story.** Failures should surface at check when they are
  knowable there. Capture is the obvious way to make every example
  pixel-gated, and replay already shows the shape: store hashes, dump PNGs
  only on mismatch.
- **The receipt lists inputs but not pending work.** Plenty of widgets have an
  empty first committed root because a timer, image, fetch, or subscription
  has not landed, so the default capture will often look broken. An agent
  holding only the receipt should read "empty because 2 images and 1 fetch
  were still pending". Without that, this fails the project's own "could a
  fresh agent fix it" test on the most common confusing case.
- **No latency budget or receipt**, even though capture latency is the metric
  that decides whether agents use this at all.
- **Windows text parity** is unowned (above).

## Suggested order

1. Headless capture mode in the SDK runner beside session replay, with the GPU
   surface drive sequence, the null-platform toggles, and a latency receipt.
2. `weaver capture` in the CLI, with pending work in the receipt.
3. The deterministic action script; decide slice C on the measured latency.
4. The Windows text-parity decision.
5. The loopback viewer.

Slice A only if a measurement says `main.zig` is blocking something.

## State of this worktree

- `runtime/native-sdk/src/app_runner/root.zig` carries the uncommitted
  `runHeadlessCapture` prototype (submodule `SunkenInTime/native`, pinned at
  `4c5c0999`). It is a measurement, not a shipping shape: it duplicates
  `NullPlatform.run`'s startup dispatch, which should instead be factored into
  one helper the null runner and capture share so they cannot drift.
- The temporary `main.zig` stub used to get past the render-host link error was
  reverted. The proper comptime gate is still unwritten.
- Receipts above were taken with `-Dplatform=null -Doptimize=ReleaseFast` on
  macOS with Zig 0.16.0, so they carry estimator text metrics, not CoreText.
