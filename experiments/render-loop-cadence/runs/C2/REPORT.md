# Focus Week — build report

**Condition:** C (progressive capture — four visual slices, Render loop after each)

**Runs:** 14 `weaver check` runs, 11 `weaver capture` runs (captures 01–11).

## Defects fixed because I saw pixels or a snapshot

1. **Progress bar rendered as a row of pills, not a bar.** My first bar was 20
   equal-width, gapless segments (one per goal session) inside a
   `rounded-full overflow-hidden` track. Capture 03 showed a scalloped strip
   rather than a continuous fill. A per-column height profile of the accent
   pixels confirmed it: every 14.2px segment boundary loses 4px of height at
   the top and bottom rows, so each segment is painted with its own rounded
   ends. Captures 04 and 05 ruled out the track: the profile is byte-identical
   with `rounded-full`, with `rounded-full` and no `overflow-hidden`, and with
   `rounded-[3px]`. Replaced with a single fill child sized by a `w-N/20`
   fraction (capture 06 verified one continuous 99.4px pill for 7/20, and the
   final captures show 42.6px = exactly 15% for 3/20).
2. **Low-contrast secondary text.** At 1x in capture 08 the weekday letters
   (`/35`) and the "Weekly goal" label (`/40`) were near-illegible against the
   dark surface. Raised to `/45` and `/50`, and lifted today's cell tint from
   `bg-[#ff7a59]/16` to `/18` so the highlight reads at a glance (capture 10).

Also used, without a defect: the slice-3 snapshot bounds told me the content
column ended at y=141.5 with only 44.5px left, so I sized the frame padding,
gaps and button height (12/12/36) from measured numbers before adding the
button row. The final tree ends at y=185.5 inside a content box that runs to
y=188 — nothing clipped, nothing overlapping.

## Spec items I could not meet

None. One implementation note: `weaver check` requires a `class` to resolve to
at most 32 literal strings, so a computed pixel width for the bar fill is a
check error (`class must resolve to at most 32 literal strings...`). The fill
is therefore a table over the 21 reachable session counts using `w-N/20`
fractions. For a goal of 20 every reachable value is exact, so nothing is lost
to quantization; the bar is continuous, not segmented.

## Verified in the final captures (10 and 11)

- Header: "Focus week" and "Fri, Sep 4" share a baseline (both bottoms at
  y=30.75).
- Seven cells, exactly 38px each on a 41px pitch spanning the full 284px
  content width; letters M T W T F S S; every day shows a number; Friday is
  tinted and accented.
- Label "3 / 20" sits on its own row 6px above the 8px track — no overlap.
- Bar fill 42.6px of 284px = 15%.
- Buttons expose `role=button name="Log session"` and
  `role=button name="Reset week"`; after the three-click action file, Friday
  shows 3 and every other day 0.
- Both capture receipts report `status: "ok"`.

**Confidence the widget matches the spec: 9/10.**
