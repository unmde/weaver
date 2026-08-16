# Error-propagation pass — the seams

Brief for a detailed pass over every place an error can be born, swallowed, or
presented. The governing rule is the one this repo already committed to
(#39, "Name every silent failure where the developer looks"): a failure must
surface **where the developer is looking** — `weaver check` output, the dev CLI
stream, the per-widget log, or the widget window itself — and it must name the
budget/cause, not just exist as a bare error name.

Everything below was reproduced live on 2026-07-29 against noro-shell unless
marked speculative. The single worst end-to-end demo: add ~6 retained nodes to
`examples/noro-shell/widget.tsx` and the widget window renders a flat field of
**uninitialized GPU memory** (a different random color every launch), with
`weaver check` passing and zero error lines in any log.

## Seam 1 — the SDK render path has no error boundary (highest leverage)

- `sdk/src/reconciler.ts:835` `scheduleRender()` runs `renderRoot()` inside
  `void Promise.resolve().then(...)`. Any throw inside a re-render (including
  every budget error the Zig bridge deliberately throws) becomes an unhandled
  promise rejection.
- No `JS_SetHostPromiseRejectionTracker` is installed anywhere
  (`rg PromiseRejection runtime/` is empty), so QuickJS drops the rejection on
  the floor. Confirmed: over-budget fresh start logs *nothing*, hot swap logs
  only a bare `error: CallbackFailed`.
- `renderRoot()` (`sdk/src/reconciler.ts:403`) has `try/finally` around the
  batch but no catch: a throw mid-reconcile leaves a **half-built tree already
  committed** via `native.endBatch()`. There is no rollback and no "don't
  present a tree whose build threw."

Wanted: a render error boundary that (a) catches, (b) logs the message + stack
through a bridge call so it lands in the per-widget log, (c) puts the widget
into a visible error state (even a solid color + name is fine), and (d) never
commits a partially-built generation. Same treatment for effect callbacks,
`useInterval` callbacks, and `onFrame` canvas callbacks.

## Seam 2 — platform callback failures lose their name

- `runtime/native-sdk/src/platform/macos/root.zig:763` intends to log
  `platform callback failed: <name> (event <tag>)`, but what actually reaches
  the widget log is a bare `error: CallbackFailed` (observed three times
  today). Find where that line is emitted (likely the runtime's top-level exit
  path in `runtime/src/main.zig`) and make the *named* line the one that lands
  in the per-widget log before the process dies.
- After the runtime process dies, the host keeps the widget window alive
  showing whatever memory the surface had. That's both a UX bug and arguably an
  info leak (stale GPU memory). The host should clear the surface and/or show a
  tombstone when the runtime for a window is gone.

## Seam 3 — budget errors: born loud, dying silent

The bridge does the right thing at the throw site — `failFmt`
(`runtime/src/bridge.zig:142`) even documents that budget errors must name the
budget, the limit, and the ask. But:

- `runtime/src/bridge.zig:166` `createNode` → "node capacity exhausted" names
  neither `max_nodes` nor 128 nor the node count. Same for the generic
  "appendChild failed" / "insertBefore failed" (`bridge.zig:185,195`) which is
  how `max_children = 24` surfaces. Bring these up to the `failFmt` standard.
- All of them then die in Seam 1 anyway. Both halves need fixing.
- `runtime/src/tree.zig` budgets (`max_nodes 1024`, `max_children 64`,
  `max_text_bytes 1024`, `max_canvases 8`) are statically checked for the
  initial tree. `weaver check` validates the lowered representation—not just
  authored JSX—so generated layout/text nodes and canvases count. Every
  `max_nodes`, `max_children`, `max_text_bytes`, and `max_canvases` failure
  reports the configured limit, requested amount, and remaining headroom.

## Seam 4 — image failures are log-only, screen-silent

- `runtime/src/main.zig:119` and `:1012` log `ImageTooLarge` etc. to the
  per-widget log, then render proceeds with a black hole where the image was.
  Nothing on screen, nothing in the dev CLI stream, `weaver check` passes.
- The pinned Native widget profile permits 1 MiB of decoded RGBA. A 256×256
  image is 256 × 256 × 4 = 262,144 bytes (256 KiB), so it passes. `weaver check`
  reads local image dimensions and reports the decoded-byte calculation without
  decoding pixels. Runtime failures report dimensions plus requested bytes.
  Images over 1 MiB need downscaling or an on-widget placeholder that says why.

## Seam 5 — dev loop failure modes

- `cli/src/index.ts:431-460`: rebuild failures print once via `printFailure`,
  but the runtime keeps hot-swapping/serving the **stale bundle** with no
  banner that what's on screen no longer matches the file. Persist an "out of
  date since <time>: <first error>" state in the dev stream (and ideally on the
  widget).
- The watcher (`cli/src/index.ts:458`) watches only `widget.tsx` — asset and
  font edits silently do nothing until an unrelated source change.
- Hot swap of a bundle that then throws mid-render: observed
  `dev hot swap applied (preserved root hook state)` immediately followed by
  process death (`CallbackFailed`) and an auto-restart that comes back blank.
  The hot-swap path already knows how to reject a bad candidate
  (`runtime/src/main.zig:362` evaluateCandidate) — extend that rejection to
  candidates whose *first render* throws, and keep the old bundle running.

## Seam 6 — dynamic canvas denial remains screen-silent

- `weaver check` already reports statically knowable clipping and opacity
  violations as `CanvasNeedsUnclippedAncestors` and
  `CanvasNeedsOpaqueAncestors`; the relevant validators live in
  `cli/src/index.ts:1527-1681`. The remaining gap is a runtime diagnostic when
  the host denies a canvas surface dynamically, so the widget cannot blank
  without a named reason.

## Seam 7 — empty-catch inventory

Each of these should either handle-and-log, narrow to the specific expected
error, or grow a comment proving silence is correct (some already have one —
those are fine and are the model):

- `sdk/src/reconciler.ts:873, 910` — hot-swap seed parse/capture: silence is
  probably right, but a swap that falls back to fresh state should say so in
  the log (today "preserved root hook state" prints even when seeding failed).
- `sdk/src/class-compiler.ts:610, 642`
- `cli/src/host-tools.ts:195, 200, 206, 224`, `cli/src/origin.ts:5, 15`,
  `cli/src/index.ts:733, 812, 913, 1127`, `cli/src/weave.ts:344`
- Zig: 18 hits of `catch {}` in `runtime/src` (`rg 'catch \{\}' runtime/src`),
  plus `catch return null` / `catch return` sites in `geometry.zig:38,65`
  (corrupt geometry file → silently repositioned widget),
  `dev_reload.zig:61` (accept failure → dev reload just stops working),
  `js_engine.zig:100,110` (hot-swap capture failure → silent fresh state).
- `runtime/src/main.zig` msg-handler catches (lines 140-240) all log — good —
  but several then continue with stale state where a degrade should be marked
  once (e.g. repeated `provider dispatch failed` every 33 ms would flood; needs
  latch-and-summarize).

## Seam 8 — status surfaces that lie by omission

- `weaver dev` stream prints provider/present milestones but not their
  absence: a widget that never logs `presenter path=` never presented a frame —
  after N seconds that should be an explicit error line (it was the only
  signal, and today it's an *absence*).
- `~/Library/Application Support/Weaver/status.json.backend-*` orphan files
  accumulate silently; `weaver status` doesn't reconcile them.
- Uninstall/registry restore paths (`cli/src/index.ts:414, 486, 616, 694`)
  swallow the second-order failure by design (comments present) but nothing
  ever reports the widget/registry divergence at the *next* `weaver status`.

## Suggested acceptance test for the whole pass

One integration test per seam that used to be silent, each asserting a named
error is visible at the correct surface. The canonical one: a widget whose
tree exceeds `max_nodes` must (a) fail `weaver check` naming the budget and
count, and if forced through anyway (b) log
`node capacity exhausted: max_nodes=1024, asked for 1025` and (c) render an
error surface — never uninitialized memory, never a silent flat fill. A failed
first render must commit only the error surface with no partially built nodes;
a failed hot-swap first render must keep the previously active tree and bundle
unchanged.
