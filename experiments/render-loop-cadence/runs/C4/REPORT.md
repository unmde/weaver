# Focus Week — build report

**Condition:** C (progressive capture — four visual slices, Render loop after each)

## Runs
- `weaver check`: **11** runs (5 of them deliberate probes of what `class` expressions the checker can resolve).
- `weaver capture`: **8** runs (`01`–`08` in `captures/`). Every receipt reported `status: "ok"`.

Slice boundaries: 01 = frame + header, 02 = day cells, 03/04 = progress bar (03 with counts temporarily seeded so the fill was visible, 04 the real empty state), 05/06 = buttons + storage, 07/08 = final pair after the last polish.

## Defects fixed because I saw pixels or a snapshot
1. **Day strip ate the whole widget.** Slice 2's PNG showed the seven cells 142px tall — I had given the row `grow`, so it absorbed all the space the bar and buttons had not claimed yet. Replaced with a fixed `h-[48px]` row, which also made the remaining vertical budget arithmetic explicit (170px content = 17.5 header + 48 days + 23 bar block + 38 buttons + 3×14 gaps + 1.5 slack).
2. **Day letters were too dim at 1×.** In the slice 2 capture the `M T W T F S S` row at `text-[#f5f6f8]/35` was barely separable from the cell background. Raised to `/45`.
3. **Progress caption was too dim at 1×.** In the slice 3 capture "Sessions this week" at `/40` read as noise next to the `0 / 20` value. Raised to `/50`.

The three `check` failures I hit (template-literal class, array-indexed class, both rejected with "class must resolve to at most 32 literal strings") were caught statically, not by pixels, so they are not in this list — but they set the bar's implementation: the fill width is a 21-branch literal ladder (`total === N ? "… w-[Npx]"`), one class per session count, with a comment saying why. 3 sessions renders a 43px fill in a 284px track = 15.1%.

## Spec items I could not meet
None. All five items are in: header with baseline-aligned title and "Fri, Sep 4"; seven equal-width cells (37.14px each, gap 4, summing to exactly 284) with today highlighted in amber; progress bar with its `N / 20` label on a separate row above the track, so overlap is structurally impossible; two buttons with `hover:bg-*` and `pressed:bg-*` and `useStorage` keyed by short weekday name.

Verified in the `08` snapshot: `role=button name="Log session"` and `role=button name="Reset week"` — exact accessible names. After the three scripted clicks, Friday shows 3, every other day 0, label "3 / 20", fill 43px.

## Confidence
**9 / 10.** Pixels and semantics both confirm the initial and after-clicks states at the real 320×200 size. The point I did not directly observe is the hover/pressed *swap* isolated from a click — the after-clicks capture leaves the pointer resting on "Log session", so the PNG shows its hover fill (`#fbbf24`) rather than its base fill, which is evidence the native state resolves but not a controlled test of `pressed:`.
