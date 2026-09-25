# Render-loop cadence: Opus run, 2026-09-04

> Combined two-model synthesis is in `SYNTHESIS.md`. Astra's replicate and its blind grades are under `astra/`.

Ten Opus agents, one spec (Focus Week, 320×200), one toolchain, three capture
cadences. See `PROTOCOL.md` for the design, `common-prompt.md` and `cond-*.md`
for the exact agent prompts, `runs/<id>/` for each agent's `widget.tsx` and
self-report, `final-captures/` for the grader's uniform re-captures, and
`GATES.tsv`, `usage.tsv`, `saves.log` for the receipts behind every number.

Grading was done on anonymized copies (`MAPPING.txt`) before unmasking.

## Result table

| Run | Cond | Score /18 | Captures | Saves | Tokens | Tool uses | Wall (min) | Self-confidence |
|---|---|---|---|---|---|---|---|---|
| A1 | check-only | **10** | 0 | 6 | 109.5k | 56 | 10.6 | 7 |
| A2 | check-only | 18 | 0 | 5 | 97.3k | 44 | 8.1 | 7 |
| B1 | final | 17 | 4 | 5 | 68.4k | 33 | 3.8 | 9 |
| B2 | final | 18 | 5 | 4 | 80.7k | 48 | 6.0 | 9 |
| B3 | final | 18 | 8 | 3 | 90.2k | 44 | 6.5 | 9 |
| B4 | final | 17 | 5 | 4 | 84.7k | 42 | 6.6 | 9 |
| C1 | progressive | 16 | 13 | 12 | 80.8k | 55 | 8.2 | 9 |
| C2 | progressive | 17 | 11 | 15 | 84.9k | 59 | 7.8 | 9 |
| C3 | progressive | 18 | 6 | 7 | 67.7k | 40 | 4.8 | 9 |
| C4 | progressive | 17 | 8 | 12 | 62.6k | 38 | 5.0 | 9 |

| Cond | Mean score | Worst | Mean tokens | Mean wall | Mean captures | Mean saves |
|---|---|---|---|---|---|---|
| A check-only | 14.0 | 10 | 103k | 9.3 min | 0 | 5.5 |
| B final | 17.5 | 17 | 81k | 5.7 min | 5.5 | 4.0 |
| C progressive | 17.0 | 16 | 74k | 6.4 min | 9.5 | 11.5 |

All ten passed every objective gate: `weaver check` ok, both receipts
`status: "ok"`, both buttons exposed by exact name, after-clicks label "3 / 20".
The gates cannot tell A1 from the others. Only pixels can.

## Rubric notes per run

- **A1 (10).** Weekday letters render underneath the counts at identical bounds
  and both are pinned top-left in 55px-tall cells. Cause: `<panel>` stacks its
  children instead of laying them out as a column, contrary to
  `sdk/CONTRACT.md` lines 127 and 604. Reproduced in `panel-probe/`. The agent
  derived its layout from the Zig layout source and never saw the result.
  Self-confidence 7/10 did not flag it.
- **A2 (18).** Clean. Canvas progress bar. Proof that a blind agent *can* land
  it; A1 is proof there is no net when it does not.
- **B1 (17).** Clean; dimmest weekday letters of the set.
- **B2, B3 (18).** Clean. B3's captures caught a 2px width error from assuming
  the 1px border consumed layout space.
- **B4 (17).** Clean; outlined secondary button at equal visual weight to the
  primary weakens hierarchy slightly.
- **C1 (16).** Shipped a 20-tick meter instead of a continuous bar after
  concluding a continuous fill was impossible. It is not (C2, C4, A1, A2 and all
  B runs did it four different ways), so this is a wrong conclusion drawn from
  a real renderer quirk, see framework findings.
- **C2 (17).** Clean; 21-branch literal ladder for the fill width.
- **C3 (18).** Clean; used slice-3 snapshot bounds to size the buttons to the
  space that was actually left.
- **C4 (17).** Clean; 21-branch ladder. Slice-2 capture caught a `grow` day row
  that had swallowed the whole widget.

## What pixels caught, by condition

- **Every capturing agent (7 of 8) raised text alphas after seeing 1× pixels.**
  Secondary text at `/35` to `/40` opacity is illegible on the house dark
  surface, and no agent predicted that from source. Both A agents shipped at
  those alphas.
- **B (final) found:** legibility (B1, B2, B4), 2px width miscalculation (B3),
  label crowding the bar (B4). No structural defects, so nothing that would
  have benefited from an earlier look.
- **C (progressive) found:** a `grow` row eating the layout (C4, slice 2), a
  would-be button clip caught from snapshot bounds before the buttons existed
  (C3, slice 3), the segmented-bar pill artifact (C1, C2, slice 3), plus the
  same legibility fixes. C agents also used intermediate snapshot bounds as a
  budget for the next slice.

## Reading

1. **Seeing pixels is necessary.** Worst case without them is a broken widget
   that passes every static and semantic gate with 7/10 self-confidence. The
   two A agents also spent the most tokens and time of any condition, because
   they compensated by reading runtime source to predict layout.
2. **Final-only and progressive tie on final quality at n=4.** 17.5 vs 17.0 is
   inside the noise of one rubric point. Both have a worst case of 16 or 17.
3. **Progressive is not more expensive in tokens.** It runs roughly twice the
   captures and three times the saves, yet averaged fewer tokens than B (74k vs
   81k) and similar wall time. Captures are cheap; the agent's reasoning is the
   cost, and early pixels appear to shorten it.
4. **Progressive catches structural mistakes when they are cheap.** C4's `grow`
   row and C3's height budget were fixed with two elements on screen. A B agent
   making the same mistake would fix it in a full tree. None did in this run,
   so this is mechanism, not a measured effect.
5. **Progressive can also mislead.** C1 saw a renderer quirk mid-build and
   redesigned the spec item around it. More looks means more chances to
   over-react to what is seen.
6. **Progressive produces the visible incremental build for free.** Every C
   run saved 7 to 15 times in slices that each rendered. That is exactly the
   "watch it take shape" effect the Live loop wants, with no quality or token
   penalty measured here.

## Framework findings surfaced by the run

1. **`<panel>` stacks children.** Contract says column layout. Minimal repro in
   `panel-probe/`: two texts inside a `<panel>` get identical bounds; the same
   texts inside a `<column>` lay out correctly. Landmine: A1 detonated it.
2. **The 32-literal class cap has no obvious route for a data-driven width.**
   Ten agents produced five workarounds: `<canvas>` (5 runs), 21-branch literal
   ladder (2), `w-N/20` fraction table (1), gradient hard stop (1), tick meter
   (1). The check error names the cap but not a supported path. DX gap.
3. **Small boxes get ~2px corner rounding that `rounded-[0px]` does not
   remove.** Observed independently by C1 and C2 on 14px-wide segments inside
   an `overflow-hidden` track. Worth a renderer look.
4. **`key` on an intrinsic element is a TS error.** Hit by 4 of 10 agents; each
   lost a check round to it.
5. **`CanvasNeedsExplicitSize` rejects `w-full`.** Hit by 2 agents. The message
   worked; both fixed it in one round.
6. **`npx --no-install weaver` fails from the widget directory.** Several agents
   lost a call to a wrong-cwd npx error. Not a widget error, so easy to misread.

## Recommendation for the conjure-widget skill

- Keep the Render loop mandatory at completion. Condition A is the argument.
- Move from "capture after every pixel-changing edit" to a slice cadence:
  capture the first coherent frame, capture each added visual region, capture
  every requested state at the end. This is condition C, which cost nothing
  measurable and is the honest source of a progressive build on the desktop.
- Add one line to the skill: when a capture shows a renderer behavior that
  contradicts the contract, report it as a framework reproduction and keep
  the spec item; do not redesign around it (the C1 failure mode).
- Add a legibility floor to the house-style guidance: secondary text on the
  dark surface at `/45` or above. Seven of eight agents converged on this
  number after looking.

## Limits

n=2/4/4 on one spec and one model. The spec had one layout trap the pixels
were needed for (dim text) and one the contract lied about (panel). A spec with
more layout risk would likely widen the B vs C gap in C's favor; a simpler one
would narrow A's deficit. The GPT run on the same protocol is the second
sample.
