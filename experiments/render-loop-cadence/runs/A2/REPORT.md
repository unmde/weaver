# Focus Week — run A2

## Condition
A (check-only). No captures were run; /tmp/weaver-exp/runs/A2/captures does not exist.

## Runs
- `weaver check`: 4 (the first failed, the last three passed; the final state passes).
- `weaver capture`: 0.

## Defects fixed because I saw pixels or a snapshot
None — condition A never captures, so I saw neither pixels nor a snapshot.

For the record, the one defect `weaver check` did catch: `key={day.key}` on a
`<column>` inside `days.map(...)` is a TS error (`key` is not on
`GradientBoxProps` under this jsx runtime typing). Removed; the seven cells are
positional and never reorder, so position diffing is correct.

## Spec items I could not meet
None outright. Two decisions worth naming, both forced by the contract:

1. The progress bar is a `<canvas>`, not a sized box. `weaver check` requires
   `class` to resolve to at most 32 *literal* strings, so a fill width derived
   from a runtime count (`w-[43px]`, `w-3/20`) is a check error. The sanctioned
   path for runtime geometry is the immediate-mode canvas (ADR 0009), which both
   shipped examples use. It has no `fps`, so it draws once per render and stays
   idle-zero between provider ticks. The track is a full-width pill at
   #ffffff14; the fill is #ff7a59 at logged/20, clamped to 0..1 and never
   narrower than the 8px cap height so one session still reads as a bar.
2. The "12 / 20" label sits in its own row above the bar, right-aligned opposite
   a "Sessions this week" caption. It is a sibling row, not an overlay, so it
   cannot overlap the bar in any state.

## Layout receipts (derived from source, not from pixels)
runtime/src/main.zig lowers `border` to `style.stroke_width` — a paint property
only; layout insets by padding alone. So a `size-full` root at 320x200 with
`px-[16px] py-[14px]` has exactly 288 x 172 content px and the 1px rim costs no
layout.

- Day row: 7 cells of `w-[36px]` + 6 gaps of 6 = 288 exactly. Equal width,
  full-bleed, no reliance on shrink.
- Buttons: 186 + 8 + 94 = 288 exactly.
- Canvas: `w-[288px]` matches the content box exactly.
- Column: 18 (header) + 58 (days) + 28 (label 14 + gap 6 + bar 8) + 36 (buttons)
  + 3 gaps of 10 = 170 of 172. The day row carries `grow`, so it absorbs the
  remaining 2px instead of leaving a dangle, and it is also the row that gives
  way first if any assumption above is off by a pixel.
- Header baseline: `items-baseline` lowers to end-alignment (`.baseline => .end`
  in main.zig), so both header texts use the same 13px size and the same
  `leading-[18px]` line box. Under either alignment rule they land on the same
  baseline.
- `time.weekday` is one of Sun..Sat (sdk/src/reconciler.ts:1221), which is
  exactly the key set stored by `useStorage("sessions", ...)`, so today's
  lookup, the highlight, and the increment all key off the same strings.

Accessible names are set explicitly with accessibilityLabel="Log session" and
accessibilityLabel="Reset week"; main.zig prefers the explicit label over
descendant text, and the visible labels are the same strings either way.

## Confidence
7 / 10.

Confident about: box arithmetic (read out of the runtime lowering rather than
guessed), the state model, persistence keying, accessible names, hover/pressed
channels, and that nothing overflows its container.

Cannot know without pixels: glyph advance widths (label fits have 13-110px of
slack, so they should be safe, but "Reset week" in a 94px button is the
tightest), whether the 8px canvas bar paints as expected at its cap radius, and
whether the /45 and /75 text alphas read as legible at 1x on the dark surface
rather than merely plausible in the numbers.
