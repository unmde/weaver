# Framework finding: a canvas never keeps its layout size

Three Astra agents, working independently, wrote the idiomatic thing for a
progress bar in a flex row, `<canvas class="w-0 grow h-[8px]">`, saw a blank
bar in capture, and "fixed" it by hardcoding a pixel width. Every shipped
example hardcodes canvas widths too, which is why nobody had noticed. This is
a framework defect, not an agent blind spot. Receipts are in `canvas-probe/`.

## What happens

1. **Mount.** The SDK creates the canvas binding with the class-declared size:
   `instance.props.width ?? 0` (`sdk/src/reconciler.ts:719`). For `w-0 grow`
   that is 0. The first draw runs at 0×8 and paints nothing.
2. **Layout.** Native SDK lays the row out and gives the canvas 181×8. The
   snapshot reports those bounds. The runtime has a read-back path for this:
   `syncNativeState` (`runtime/src/main.zig:563`) compares each canvas's layout
   frame with the last one it saw and fires `onCanvasResize` to JS when it
   changed. The SDK handler (`reconciler.ts:217`) updates the binding and
   redraws. So far, correct by design.
3. **Timing.** `syncNativeState` runs only inside Native SDK's `syncModel`,
   which runs at the start of `dispatch`, `drainEffects`, and `rebuild`
   (`runtime/native-sdk/src/runtime/ui_app.zig:1106,1159,1284`). Nothing
   runs it after the layout pass itself. A widget with no timers, providers,
   or input never dispatches after its first frame, so the resize never
   fires. Capture with a fixed clock is exactly that widget.
4. **The clobber.** When a dispatch does happen and the resize fires, the
   canvas draws once at 181×8. Then the component re-renders (a time tick, a
   state change) and `updateCanvasBinding` runs again for the canvas
   (`reconciler.ts:785-789`). It overwrites `binding.width` and
   `binding.height` with the declared size, 0×8, rebuilds the context, and
   redraws immediately at 0×8 (`reconciler.ts:812`). The bar goes blank.
5. **No recovery.** The runtime fires the resize only when the layout value
   changes (`tree.zig:977`). The layout has not changed. The canvas stays
   blank until something else moves the layout.

The draw log from `cp-one` shows the whole sequence. Its label re-renders once
per clock tick and prints every width the draw callback has seen so far:

| Ticks | Draw widths seen | Bar in the PNG |
|---|---|---|
| 0 | 0 | blank |
| 1 | 0, 181 | blank (the post-render redraw at 0 came after the label) |
| 2 | 0, 181, 0, 183 | blank |

The resize refired at tick 2 only because the label text got wider and moved
the layout by 2px. In Focus Week nothing moves, so the bar is blank forever.

## Why the display-rate probes looked fine

`cp-pair` puts a one-shot canvas and an `fps="display"` canvas in the same
widget. Both render full width, before and after ticks. The display canvas
keeps a frame chain running, every frame is a dispatch, every dispatch runs
`syncModel`, and the re-render clobber is repaired on the next frame because
the surface clock redraws with whatever the binding holds at that moment. It
works by accident of cadence. Remove the display canvas and the one-shot
canvas is blank again (`cp-one`).

## This is not capture-only

Live is not verified on screen (my desktop screenshot missed the window), but
the code path is the same: a live Focus Week widget subscribes to `time`, so
the first tick after launch delivers the resize and the same tick's re-render
clobbers it. Live has the same blank bar. Capture did not lie to the agents.
It showed them the real bug, and then the contract's advice to use explicit
pixel sizes taught them to route around it.

`CanvasNeedsExplicitSize` in `cli/src/index.ts:2859` is the tell. Its message
says "a percentage resolves against 0 and every draw silently no-ops
(ctx.width === 0)". The check knows about the silent zero and forbids two of
the ways to reach it. `w-0 grow` is a third way it does not forbid. The check
is a patch over this defect.

## The fix, in order

Landed as unmde/weaver#78, steps 1 to 4 together.

1. **SDK: never overwrite a layout-delivered size with a declared one.**
   `updateCanvasBinding` should treat the declared size as the initial guess
   at mount only. On update, keep `binding.width`/`binding.height` unless the
   declared size itself changed. This alone fixes the clobber and makes
   `w-0 grow` work in every widget that dispatches at least once.
2. **Runtime: deliver canvas layout after every layout pass, not at the next
   dispatch.** Run the canvas part of `syncNativeState` after `rebuild`
   computes layout, and request a frame when any canvas resized. This fixes
   static widgets, including every fixed-clock capture, and removes the
   dependence on a stray tick.
3. **Check: delete `CanvasNeedsExplicitSize`** once 1 and 2 land, and update
   the contract so a canvas is sized by layout like every other element.
   Explicit sizes stay allowed; they stop being required.
4. **Capture: make the receipt say what the pixels cannot.** Record, per
   canvas, the size its last draw used and the size layout gave it. Emit a
   warning when they differ. A blank bar with a receipt line reading
   `canvas #12 drew at 0×8, layout gave 181×8` is a diagnosis. A blank bar
   alone is a guess. This is the capture-mechanic change that would have
   handed three agents the fix instead of a workaround.

## Probes

All in `canvas-probe/`, each with source, PNG, and snapshot:

- `probe1`: lone `w-0 grow` canvas, no dispatch. Blank.
- `cp-display-plain`: lone `fps="display"` grow canvas. Full.
- `cp-pair`: one-shot and display canvases together, 0/1/2 ticks. Both full.
- `cp-one`: lone one-shot canvas with draw log, 0/1/2 ticks. Blank; log shows
  the 181 draw and the 0 redraw.
- `cp-shrink` (`canvas-probe7`): canvas declared 300px, layout gives 144px,
  one tick. Draw callback still sees 300. Declared sizes that disagree with
  layout are wrong in the other direction too.

Toolchain: Weaver `ab20771`, Native SDK `464ff65f`, macOS headless capture.
