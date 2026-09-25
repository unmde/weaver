# Astra run: Fable's blind grades

Graded 2026-09-05 from Fable's own uniform re-capture of each `runs/<id>/widget.tsx`
(clock 2026-09-04T09:41:00.000Z, empty storage, `clicks.actions`). Copies were
anonymized as x01..x10 (`MAPPING.txt`), scored on the PROTOCOL.md rubric, and the
scores were written to disk before the mapping was read. Fable's re-captures are
alongside Astra's under `final-captures/fable-recapture-*`; the two sets are
visually identical.

| Run | Cond | Blind id | Score /18 | Note |
|---|---|---|---|---|
| A1 | check-only | x05 | 18 | clean |
| A2 | check-only | x06 | 18 | clean |
| B1 | final | x01 | 18 | clean; no bar caption, label only |
| B2 | final | x02 | 17 | both buttons equal width, primary loses emphasis |
| B3 | final | x08 | 18 | clean |
| B4 | final | x03 | 18 | clean; 20-branch `w-N/20` ladder, no canvas |
| C1 | progressive | x10 | 18 | clean |
| C2 | progressive | x09 | 18 | clean |
| C3 | progressive | x04 | 18 | clean |
| C4 | progressive | x07 | 16 | title shrunk to 14px to match date metrics; whole widget reads dimmer, hierarchy flattens |

| Cond | Mean | Worst | Mean wall | Mean tool calls | Mean output tokens | Mean total tokens (cache-inclusive) | Captures | Saves |
|---|---|---|---|---|---|---|---|---|
| A | 18.0 | 18 | 3.0 min | 9 | 2.7k | 303k | 0 | 3 |
| B | 17.75 | 17 | 3.9 min | 12.5 | 4.1k | 510k | 4.5 | 4 |
| C | 17.5 | 16 | 5.3 min | 19.75 | 5.1k | 900k | 6.5 | 7 |

Wall time is dispatch to completion per agent, from Astra's `usage.tsv`. Astra
ran in batches of three; Opus ran ten in parallel. Astra's token totals include
cached input and are not comparable to the Opus token column.

## Pixel-driven fixes reported by Astra's agents

- B1, B3, C1: progress canvas sized `w-0 grow` had nonzero semantic bounds but
  painted nothing. Fixed with an explicit pixel width. Reproduced by Fable in
  `../canvas-probe/`.
- B2: canvas 286px inside a 288px track; snapshot exposed the 2px gap.
- C4: title and date had different vertical metrics; both set to 14px.
- B4, C2, C3: none. A1, A2: not applicable.

No Astra agent reported a legibility fix. All ten shipped secondary text at
`/60` or above from the first draft.

## Observations outside the rubric

All ten widgets share one palette (the pomodoro example's teal), one layout,
and near-identical structure. Astra treats the shipped examples as the house
style and reproduces it closely. Opus varied accent and structure across runs.
Astra's sources are 54 to 85 lines against Opus's 101 to 124.
