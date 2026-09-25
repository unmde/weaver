# Focus Week — B1 report

**Condition:** B (write the whole widget first, capture only at the end).

## Runs
- `weaver check`: 2 runs (both passed; two further invocations aborted in npx because I ran them from the wrong cwd and never reached the CLI).
- `weaver capture`: 4 runs — `01-initial`, `02-after-clicks` (round 1), `03-initial`, `04-after-clicks` (round 2). All four receipts report `status: "ok"`.

## Defects fixed because I saw pixels or a snapshot
Round 1 was structurally correct — no overlap, no clipping, correct counts and label — so the fixes were legibility ones I could only judge from the rendered 320x200 image:
- Weekday letters (M T W T F S S) were set at `text-[#f5f6f8]/35` and read as near-invisible grey at 1x. Raised to `/50`.
- The "THIS WEEK" caption at `/40` had the same problem. Raised to `/45`.
- The progress-bar track was drawn at `#ffffff14`; at 8px tall it barely separated from the panel surface, so an empty bar looked like no bar. Raised to `#ffffff1f`.
- Non-today session counts at `/85` (from `/75`) to keep the numbers ahead of their letters in the hierarchy.

No layout, alignment, overlap or state defect was found in either round.

## Verification receipts
- Semantic tree (round 2): buttons are `role=button name="Log session"` and `role=button name="Reset week"`, exactly as required.
- After three scripted clicks: Friday's cell reads `3`, the other six read `0`, the label reads `3 / 20`.
- Progress fill measured directly out of `04-after-clicks.png` at y=129: an orange run from x=16 to x=58, i.e. 43px of the 288px track = 14.93%, which is 3/20 rounded to the pixel.
- Day cells: 7 x 36px with 6px gaps = 288px, exactly the content width, all equal, all at y=45.5 h=44.
- Content occupies y=16..181 inside a 200px window; nothing is clipped and nothing overlaps.

## Spec items not met
None.

## Implementation notes
- The progress fill is a `<canvas>` (`w-[288px] h-[8px]`, no `fps`, redraws only on render) because `weaver check` requires every `class` to resolve to at most 32 literal strings, so a computed `w-[Npx]` is not available. The canvas puts the fill on an exact pixel instead of a quantized utility.
- Counts persist through `useStorage("sessions", ...)` as a `Record<weekday, number>`, keyed by weekday as specified.
- `time` is the only subscribed provider; there is no network and no other provider.

## Confidence
9 / 10 — every spec item is confirmed by either a pixel measurement or the semantic snapshot. The remaining point is taste: the weekly-goal section could carry more visual weight, and I only verified hover/pressed styling indirectly (the after-clicks snapshot shows the primary button in `state=[focused,hovered]` with an opacity layer in the frame stats, which is the `hover:opacity-90` swap firing).
