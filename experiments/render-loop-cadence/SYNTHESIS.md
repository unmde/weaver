# Render-loop cadence: two-model synthesis

Twenty agents built the same widget from the same spec on the same toolchain
under three capture cadences. Ten were Opus (default effort, orchestrated by
Fable, all ten in parallel). Ten were gpt-6-astra (high effort, orchestrated by
Astra, batches of three). Fable graded all twenty blind on the same rubric.
Receipts: `REPORT.md` and `runs/` for Opus, `astra/SCORES.md` and `astra/` for
Astra, `PROTOCOL.md` for the design.

## Scores, all twenty runs

| Cond | n | Opus | Astra | Combined mean | Worst |
|---|---|---|---|---|---|
| A check-only | 4 | 10, 18 | 18, 18 | 16.0 | **10** |
| B final capture | 8 | 17, 18, 18, 17 | 18, 17, 18, 18 | 17.6 | 17 |
| C progressive | 8 | 16, 17, 18, 17 | 18, 18, 18, 16 | 17.25 | 16 |

## Cost by condition, relative to B within each model

| | Opus wall | Opus tokens | Astra wall | Astra tool calls | Astra output tokens |
|---|---|---|---|---|---|
| A | 1.6× | 1.3× | 0.8× | 0.7× | 0.7× |
| B | 1.0× | 1.0× | 1.0× | 1.0× | 1.0× |
| C | 1.1× | 0.9× | 1.4× | 1.6× | 1.3× |

Absolute numbers are in each model's table. Opus's tokens are the harness
aggregate; Astra's output tokens are the closest comparable column.

## Answers to the three questions

**1. Do agents build better widgets when they can see pixels?**
Pixels are a net, not a lift. Three of four blind runs scored a perfect 18.
The fourth shipped day cells with the letters drawn under the counts, passed
every static and semantic gate, and reported 7/10 confidence. Nothing but a
PNG catches that. Whether the net is worth its cost depends on how often the
blind agent falls, and at n=4 the answer is "one in four, with a wide interval".
For Opus the blind runs were also the most expensive: the agents read Zig
layout source to predict what a capture shows in half a second.

**2. Is looking once at the end enough, or does looking during the build
change the result?**
On final quality, no difference. B led C by a fraction of a point in both
models, inside noise. The lowest-scoring capturing run in each model was a C
run, and both lost points the same way: they saw something mid-build and
redesigned around it. Opus C1 replaced the progress bar with a tick meter after
a renderer quirk; Astra C4 shrank the title to match the date's text metrics
and flattened its own hierarchy. Two data points, same mechanism: more looks
means more chances to over-fit to the current frame. On the other side, Opus C4
caught a `grow` row swallowing the widget at slice 2, and Opus C3 sized its
buttons from slice-3 snapshot bounds. Progressive catches structural mistakes
while they are cheap, and also invites cosmetic churn.

**3. What does each cadence cost?**
Model-dependent. Opus C was cost-neutral against B. Astra C cost 1.4× the
wall time and 1.6× the tool calls of B. Astra's blind runs were the cheapest
of all twenty; Opus's blind runs were the most expensive of its ten.

## What pixels caught, by model

The catch lists barely overlap, which says the value of looking is in the
agent's blind spots, not in a fixed checklist:

- **Opus:** legibility at 1× in seven of eight capturing runs, a `grow` row
  eating the layout, a 2px border-arithmetic error, and the segmented-bar pill
  artifact. Zero legibility fixes were needed by Astra; every Astra draft
  shipped secondary text at `/60` or above.
- **Astra:** a `w-0 grow` canvas that has layout bounds but paints nothing, in
  three of eight capturing runs. No Opus run used a grow-sized canvas. Also one
  2px canvas-versus-track mismatch and one header-metrics alignment.

Both models needed the PNG and the snapshot together. The Opus panel bug was
visible in snapshot bounds (two texts, identical bounds) but the agent never
looked. The Astra canvas bug was invisible in the snapshot (correct nonzero
bounds) and only the PNG showed the blank.

## The visible-build motive

Progressive capture produced 7 saves per widget for Astra and 11.5 for Opus,
against 4 for final-capture in both models. Each save under condition C
rendered a coherent partial widget. That is the "watch it take shape" effect,
produced by the honest loop. The price is zero to 40% more wall time depending
on the model, and no measured quality change.

## Framework findings, both runs

1. **`<panel>` stacks its children.** Contract says column layout. Repro in
   `panel-probe/`. Detonated by Opus A1. Astra used `<panel>` once, for a bar
   fill with no children, so it never triggered.
2. **A canvas never keeps its layout size.** The SDK seeds the canvas with
   its class-declared size, the runtime delivers the real layout size only at
   the next dispatch, and every re-render overwrites the delivered size with
   the declared one and redraws blank. `w-0 grow` therefore paints nothing in
   any static widget and in any time-driven widget after its first tick, in
   capture and live alike. Every shipped example hardcodes canvas widths,
   which is why it went unnoticed. Full mechanism, draw-log receipts, and a
   four-step fix in `CANVAS-LAYOUT-SIZE.md`; probes in `canvas-probe/`. Hit
   by three Astra agents, who were then steered by the contract into
   hardcoding widths. `CanvasNeedsExplicitSize` is a patch over this defect.
3. **The 32-literal class cap has no obvious route for a data-driven width.**
   Twenty agents, six workarounds: `<canvas>` (14 runs), literal ladder (3),
   `w-N/20` fraction table (1), gradient hard stop (1), tick meter (1). The
   error names the cap but not a supported path.
4. **Small boxes get ~2px corner rounding that `rounded-[0px]` does not
   remove.** Two independent Opus observations.
5. **`key` on an intrinsic element is a TypeScript error.** Hit by 4 Opus and
   at least 4 Astra agents. Cheapest fix in the whole list.
6. **`npx --no-install weaver` fails from the widget directory** with an error
   that reads like a widget problem. Several Opus agents lost a call to it.
7. **All four Astra C agents ran capture while check was failing.** Capture
   published nothing and the agents recovered, so the DX held. Noted because
   it shows agents treat check and capture as one step.

## Recommendation for the conjure-widget skill

- **Final Render loop is mandatory, with both the PNG and the snapshot read.**
  The one broken widget in twenty passed everything else.
- **Replace "capture after every pixel-changing edit" with the four-slice
  cadence tested here** when the user is meant to watch the build, and allow
  final-only when they are not. Quality is the same either way; the slice
  cadence buys the visible build for zero to 40% more wall time.
- **Add one guard against over-fitting to a frame:** fix what contradicts the
  spec or the contract; report renderer behavior that contradicts the contract
  as a framework reproduction and keep the spec item; do not redesign a spec
  item to smooth over something that merely looks unfamiliar. Both models'
  weakest capturing run broke this.
- **State a legibility floor for secondary text on the dark surface** (`/45`
  or above). Seven of eight Opus agents converged on it after looking; Astra
  was already there.
- **Fix findings 1, 2, and 5 before the next run.** They are the cheapest
  wins and two of them are silent.

## Fixes landed as PRs (2026-09-05)

- Finding 1, `<panel>` stacks children: unmde/weaver#76.
- Finding 2, canvas never keeps its layout size: unmde/weaver#78 (SDK size
  retention, runtime post-layout dispatch, `CanvasNeedsExplicitSize` retired,
  `CanvasDrewForStaleLayout` capture warning, pixel-probe smoke fixture).
- Finding 5, `key` on intrinsic elements: unmde/weaver#77.
- Finding 4, small-box rounding: unmde/weaver#79. Evidence showed it was a bug
  (unset radius mapped to the native theme default) with zero pixel impact on
  shipped examples, not a decision.
- Finding 3, data-driven widths: unmde/weaver#80 adds a number-typed pixel
  hole to `weaver check`. Finding 6, npx outside the tree: unmde/weaver#82
  puts `weaver` on PATH and scopes the package. The skill recommendations
  above landed as unmde/weaver#81. Evidence and options in `DECISIONS.md`.

## Limits

Two models, one spec, n=2/4/4 per model. The spec had two landmines the
contract did not warn about, and each model tripped a different one. A spec
with more layout risk would likely separate B from C in C's favor; a simpler
spec would erase A's deficit entirely, as it nearly did for Astra. Astra ran
at high effort and Opus at default, so the cross-model comparison is
indicative, not controlled. Within-model comparisons are the ones to trust.
