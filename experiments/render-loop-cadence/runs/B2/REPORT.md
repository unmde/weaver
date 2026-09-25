# Focus Week — B2 report

**Condition:** B (write the whole widget first, capture only at the end, then loop).

## Runs
- `weaver check`: 3 runs (1 failing, 2 passing).
- `weaver capture`: 5 runs (`01`–`05`).

Two extra `npx` invocations aborted before reaching the CLI because the shell cwd
was not the repo; they are not counted as check runs.

## Defects fixed because I saw pixels or a snapshot
1. **Today's cell was under-highlighted.** At 1× the Friday cell read as only
   slightly different from the six idle cells: `bg-[#5eead4]/14` with a
   `border-[#5eead4]/45` edge sat too close to the `#ffffff/4` idle fill.
   Strengthened to `/18` fill and `/55` border after looking at `02`; `03`–`05`
   confirm the cell now reads as the highlighted one at real size.

That is the only change driven by pixels. The two other defects in this build
were caught by `weaver check`, not by looking: `key={day}` is not a valid prop on
an intrinsic element, and `<canvas class="w-full">` fails `CanvasNeedsExplicitSize`.

## Risks the captures retired (no fix needed)
- **Content width is 290, not 288.** The snapshot shows the root column's content
  box as `(15,14 290x172)`, so a 1px border does *not* consume layout space. I had
  hedged the goal bar as `w-[288px] grow` inside a `w-full` row, so it laid out at
  exactly 290 and its right edge aligns with the Sunday cell and the Reset button.
  A bare `w-[288px]` would have been 2px short.
- **Bar geometry.** Measured the fill in `04-after-clicks.png`: teal spans x=15..57
  (43px of 290 = 14.8%), matching 3/20 = 15% within the rounded end cap.
- **Reset actually resets.** The provided `clicks.actions` never exercises it, so I
  added `log-then-reset.actions` (3 logs then one "Reset week") and captured `05`:
  every cell returns to 0 and the label to "0 / 20". `05` also incidentally proves
  the native `hover:` style — the Reset button paints its hovered background because
  the cursor ends there.
- **Accessible names.** Snapshots show `role=button name="Log session"` and
  `role=button name="Reset week"` verbatim; the action file resolves all clicks.

## Spec items I could not meet
None. All five spec items and the accessible-name requirement are met, verified in
both pixels and the semantic tree:
Fri/Sep 4 header, seven equal cells (36.29px each, 7×36.29 + 6×6 = 290) with M T W T
F S S and today highlighted, zeros still shown, the "N / 20" label on its own row
above the bar so overlap is impossible, and two buttons with `hover:`/`pressed:`
background swaps, persisted via `useStorage` keyed by weekday.

Two implementation notes where the contract pushed the design:
- The progress fill is a `<canvas>` rather than a sized box because `weaver check`
  only accepts statically resolvable class strings, so a computed
  `w-[Npx]`/`w-A/B` fill width is not expressible.
- `items-baseline` is documented as an end-alignment approximation. Header title and
  date share a bottom edge at y=32.75, which reads as a shared baseline for these two
  sizes but is not true font-baseline alignment.

## Confidence
**9/10.** Every spec item is confirmed against both the rendered pixels and the
semantic tree at the fixed clock. The reserved point is taste, not correctness:
the idle "0"s at `text-[#f5f6f8]/65` are a little loud across an empty week.
