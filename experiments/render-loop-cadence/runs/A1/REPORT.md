# Focus Week — run A1

## Condition
A (check-only). No `weaver capture` was ever run; `/tmp/weaver-exp/runs/A1/captures` does not exist.

## Runs
- `weaver check`: 5 completed runs (1 failed, 4 passed). A 6th invocation aborted before the
  checker started because I ran it from the widget directory instead of the repo, so npx could
  not resolve `weaver@0.3.1`.
- `weaver capture`: 0.

## Defects fixed because I saw pixels or a snapshot
None. I never captured, so every fix below came from `weaver check` output or from reading the
runtime source, not from looking at the widget.

For completeness, the defects `weaver check` did catch:
- `key={day}` on `<column>`: `JSX.IntrinsicAttributes` declares `key`, but the intrinsic element
  prop types do not accept it, so tsc rejected it (TS2322). Removed; the shipped examples do not
  key their mapped children either.

And the decisions I made from source rather than from pixels:
- Class strings must statically resolve to at most 32 literals (`cli/src/index.ts:2828`), so a
  computed `w-[${n}px]` fill is a check error. The progress fill is instead one `<panel>` whose
  linear gradient repeats both stops at `fraction` — the contract's deterministic hard stop.
  Both GPU backends explicitly handle a zero-span stop segment
  (`canvas_shaders.metal:263`, `d3d_presenter.cpp:588`), so the bar is exactly 15% at 3/20 with
  one node and no per-frame work.
- `runtime/native-sdk/src/primitives/canvas/widget_layout.zig` never reads border width, so the
  root's 1px border does not shrink the content box: content is 320-36=284 x 200-28=172. The
  button row is sized to that (162 + 10 gap + 112 = 284) and the day cells use `w-1/7`, which is
  exactly 100% across seven cells.
- The day row carries `grow`, so any error in my predicted text heights is absorbed there instead
  of overflowing the window. Fixed heights sum to 117 of 172; the day row takes the remaining 55.
- `items-stretch` is stated explicitly on the day row even though it is the default, because the
  cell panels rely on it to fill the row height.

## Spec items I could not meet
None knowingly. Two things I could not verify without pixels:
- `items-baseline` is documented as an end-alignment approximation, so the header title (15px) and
  the date (12px) are bottom-aligned with `leading-none` rather than truly baseline-aligned. This
  is the same pattern the shipped clock example uses.
- Text box heights with `leading-none` are predicted, not measured. If they run tall, the day row
  absorbs it; nothing should clip.

## Confidence
7/10 that the widget matches the spec. Behaviour, semantics, accessible names, persistence and
the layout arithmetic are all traceable to the contract or the runtime source, but no rendered
pixel of this widget has ever been observed — the residual risk is entirely visual (text metrics,
gradient bar appearance, and how strong the today-cell highlight reads).
