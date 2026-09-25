# Focus Week — run report

**Condition:** C (progressive capture — four slices, Render loop after each)

**Runs:** 11 `weaver check` runs, 13 `weaver capture` runs (captures 01–13; every
slice captured its initial state, slice 4 also captured the after-clicks state).

## Defects fixed because I saw pixels or a snapshot

1. **Progress fill broke into three pills instead of one bar.** Slice 3 shipped a
   continuous fill: a rounded `overflow-hidden` track holding 20 equal `grow`
   cells, lit ones painted accent, so the fill would land exactly on the session
   count. Capture 07 (and a 6× pixel dump of the bar region) showed the three lit
   cells rendered as three separate rounded pills with notched seams. Capture 08
   removed the rounded mask from the track and capture 09 added explicit
   `rounded-[0px]` to each lit cell; both rendered identically, so the ~2px corner
   rounding on each small box does not come from any utility I wrote and cannot be
   turned off from widget code. Fix: stop fighting it — the meter is now 20
   explicitly gapped ticks (`gap-[3px]`, `rounded-[2px]`), so the seams read as
   intentional ticks. 3 lit of 20 is still exactly 15%, and the count is now
   countable at a glance.
2. **Idle day cells had an invisible border** (`border-[#ffffff]/0`) purely to
   stop today's ring from shifting the text inside. Looking at capture 10 next to
   12, a faint real border (`/8`) does the same job and reads as deliberate
   instead of as a "why is this here?" line.

Everything else (header baseline alignment, seven cells filling the width exactly
via `w-1/7`, the 42px button row landing flush with the bottom padding) came out
right on its first capture and the snapshot bounds confirmed it: cells span
x=18..302 with equal 40.571px pitch, buttons end at y=184 against a 184px content
box, no overlapping or clipped bounds anywhere.

## Spec items I could not meet

None. One deviation worth naming: item 3 asks for "a progress bar", and this is a
20-tick meter rather than a smooth fill. That was forced by the renderer behavior
in defect 1 — a multi-box continuous fill always shows seam artifacts, and a
single-box fill cannot be built because `class` must resolve to at most 32 literal
strings at `weaver check`, so no computed width (`w-${n}/20`, `w-[${px}px]`) is
allowed. The tick meter is the exact same information, drawn cleanly.

## After-clicks verification (capture 13)

Receipt `status: "ok"`, three `click` actions applied. Snapshot names: Friday's
cell shows `3`, the other six show `0`, the label is `3 / 20`, and the buttons
expose `role=button name="Log session"` and `role=button name="Reset week"`.
3 of 20 ticks lit = 15%.

## Confidence

9 / 10. Every spec item is verified in pixels and in the semantic snapshot at the
widget's real 320×200. The missing point is the tick meter versus a smooth bar,
and hover/pressed styles, which `weaver check` accepts and the contract defines
but a static capture cannot exercise.
