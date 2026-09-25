# Focus Week — run report

**Condition:** B (final capture — whole widget written before any capture)

## Runs
- `weaver check`: 3 runs (1 failing, 2 passing; final state passes)
- `weaver capture`: 5 runs
  - `01-initial.png`, `02-after-clicks.png` — first Render loop
  - `03-initial.png`, `04-after-clicks.png` — after the pixel-driven fixes
  - `05-after-reset.png` — extra state, 3× "Log session" then 1× "Reset week", from `reset.actions`

## Defects fixed because I saw pixels or a snapshot
1. **Inactive weekday letters were illegible.** `text-[#f5f6f8]/40` at 10px on the dark surface washed out in `01-initial.png`; the M/T/W/T/S/S row read as smudges at 1× scale. Raised to `/50`.
2. **The "WEEKLY GOAL" caption was illegible.** Same failure at `/35`, worse because the caption sits directly above the bar and had no neighbouring bright element. Raised to `/45`.
3. **The label sat too close to the bar.** A 3× zoom of the progress block in `02-after-clicks.png` showed the caption crowding the track even though the layout proved no overlap (caption 110–120, bar 127–134). Raised the block gap from 7px to 8px.

Everything else the captures confirmed rather than corrected: 36px-wide cells at x = 16/58/100/142/184/226/268 (equal, last edge exactly on the 304px content bound), header baselines both ending at y = 27, buttons at 140×40 filling the row, `3 / 20` with the fill ending at x ≈ 59 (15% of the 288px track), and `state=[focused,hovered]` on the pressed button proving `hover:` resolves natively.

One defect was caught by `weaver check` rather than pixels and is listed for completeness: the first draft sized the progress fill with a computed `` class={`w-[${filled}px] …`} ``, which fails `class must resolve to at most 32 literal strings so weaver check can validate every utility`.

## Spec items I could not meet
None. One implementation note:

- **The progress bar is drawn on a `<canvas>`, not laid out.** A fill of "sessions / 20" needs 21 distinct widths, and `class` must resolve to at most 32 static literals, so a computed width utility is not expressible. `drawProgress` paints two `fillRoundRect`s (track and fill) once per render with no `fps`, so it costs nothing between provider ticks — the same shape as the shipped `clock` example's dial. This gives an exact continuous 15% fill rather than a quantised approximation.
- The trade this makes: the bar contributes no semantic node beyond its 288×7 group, so a snapshot reader sees the `3 / 20` text but not the fill. The pixels are the receipt for the fill.

## Verified states
| Capture | Expectation | Result |
|---|---|---|
| `03-initial` | all days 0, `0 / 20`, empty bar | ✓ |
| `04-after-clicks` | Fri = 3, others 0, `3 / 20`, fill at 15% | ✓ |
| `05-after-reset` | 3 logged then reset ⇒ all 0, `0 / 20` | ✓ |

Receipt `status` was `"ok"` on all five captures.

## Confidence
**9 / 10.** Every spec item is confirmed by a snapshot and by pixels at 1× scale, and the two interactive paths are driven end to end. The remaining point is taste rather than correctness: the 36×58 day cells carry more internal dead space than the shipped examples would, because the day row takes `grow` and absorbs all the column's slack.
