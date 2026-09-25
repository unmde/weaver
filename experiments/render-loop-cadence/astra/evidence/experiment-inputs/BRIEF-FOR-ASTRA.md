# Briefing for Astra: the render-loop cadence bench

You are being asked to run the second half of a two-model experiment on Weaver,
a desktop widget platform authored in TSX (repo: `/Users/dara/Dev/Projects/weaver`).
Fable (Claude) ran the first half with 10 Opus sub-agents. You run the same
protocol with your own sub-agents. Fable then grades both sets blind and Dara
synthesizes. This file tells you everything the bench is and why, so you can run
it without asking. Read `PROTOCOL.md` in this folder for the exact spec, and
`common-prompt.md` plus `cond-A.md`, `cond-B.md`, `cond-C.md` for the exact
prompts the Opus agents received. Reuse those prompts verbatim so the two runs
differ only in model.

## The question

Weaver has an agent skill, `.agents/skills/conjure-widget/SKILL.md`, that tells
an authoring agent how to build a widget. Part of that skill is the **Render
loop**: run `weaver check`, run `weaver capture` (a headless renderer that
publishes a PNG, a semantic snapshot, and a JSON receipt), open the PNG, look at
it, fix what you see. The skill currently asks for that loop after every edit
that can change pixels.

Dara wants to know, from measurement rather than intuition:

1. Does an agent build a better widget when it can see rendered pixels at all?
2. If so, is it enough to look once at the end, or does looking during the
   build change the result?
3. What does each cadence cost in tokens, tool calls, and wall time?

There is a second motive. Dara wants the user to watch the widget take shape on
the desktop while the agent works. Agents tend to write the whole widget in one
chunk, so nothing visibly builds. If progressive capture turns out to be free or
better, the skill can ask for it and the incremental build comes along for free.

## The design

One spec, one toolchain, one model, three conditions, fresh directory per
agent, no shared context between agents, no `weaver dev` (the live desktop
view) for anyone.

- **A check-only.** May run `weaver check` freely. Never runs `weaver capture`.
  Never sees pixels or a snapshot.
- **B final-capture.** Writes the whole widget first, then runs the Render loop
  and iterates until satisfied.
- **C progressive-capture.** Runs the Render loop after each of four visual
  slices: frame and header, day cells, progress bar, buttons plus the
  after-clicks state.

Allocation: A×2, B×4, C×4. B versus C is the contrast that matters. A is the
control that tells us whether pixels matter at all.

The widget is "Focus Week": a 320×200 habit tracker with a header, seven
equal-width day cells with today highlighted, a progress bar with a "N / 20"
label, and "Log session" and "Reset week" buttons backed by `useStorage`. It
was chosen for layout traps that static checks cannot catch: seven cells
filling a fixed width, text legibility on a dark surface, a label that must not
overlap the bar, a fixed height budget with four stacked regions.

Capture inputs are fixed so every run produces comparable evidence: clock
`2026-09-04T09:41:00.000Z` (a Friday), an empty storage root for the initial
state, and `clicks.actions` (three clicks on "Log session") for the after-clicks
state. Expected after-clicks: Friday 3, others 0, "3 / 20", bar at 15%.

## What each agent must leave behind

`widget.tsx`, a `captures/` folder with every capture it ran (numbered, never
overwritten, so the file count is a receipt for how often it looked), and a
`REPORT.md` with check count, capture count, defects fixed because of pixels,
unmet spec items, and self-confidence 0 to 10. The prompts already ask for this.

## What the orchestrator (you) must record

These receipts are what make the numbers comparable across the two models:

- **Saves.** A watcher that polls each run's `widget.tsx` mtime and size every
  500 ms and appends a line per change. Fable's is `watch-saves.mjs`, referenced
  in `PROTOCOL.md`; the Opus log is `saves.log` here. Self-reported save counts
  are not accepted.
- **Per-agent usage.** Tokens, tool calls, wall time. Whatever your harness
  exposes; record it in a `usage.tsv` with one line per run.
- **Uniform re-capture.** After all agents finish, you (not the agents) re-run
  `weaver check` and both captures for every run with the fixed inputs, so
  grading uses identical evidence regardless of what the agent captured.
- **Objective gates** per run: check passes, both receipts `status: "ok"`,
  snapshot contains buttons named exactly "Log session" and "Reset week",
  after-clicks snapshot contains "3 / 20".

Fable's `grade-prep.sh` did the re-capture, gates, and anonymization in one
pass; its logic is described in `PROTOCOL.md` under Measurement.

## Grading

Fable grades. Do not grade your own run. Fable copies every run's final
captures and source to anonymized names, scores them on the six-item rubric in
`PROTOCOL.md` (0 to 3 each, 18 max), and only then reads the mapping. Your job
is to leave the raw material in a shape that makes that possible.

## Where to put your run

`experiments/render-loop-cadence/astra/` with the same layout as the Opus run:
`runs/<id>/` (source, report, captures), `usage.tsv`, `saves.log`, `GATES.tsv`,
and a short `NOTES.md` on anything that deviated from the protocol.

## Environment rules

- Run every `npx --no-install weaver ...` command from the repo root. From a
  widget directory `npx` fails with an unrelated resolution error that several
  Opus agents mistook for a widget problem.
- Do not modify any file under the repo other than your `astra/` folder. Do not
  run `weaver dev`. Agents write widgets under `/tmp/weaver-exp-astra/runs/<id>/`
  (not `/tmp/weaver-exp/`, which still holds the Opus run) and you archive
  them into `astra/runs/` afterwards. Substitute that root for `<DIR>` in the
  prompts.
- Your harness runs three children at a time, so your 10 agents run in batches.
  Record the batch schedule in `NOTES.md` and report per-agent wall time from
  dispatch to completion, not from experiment start. The Opus run had all 10
  in parallel.
- Do not update the toolchain. The Opus run used Weaver commit `ab20771` with
  `runtime/native-sdk` at `464ff65f`. Same commits, or the replicate is not a
  replicate. Confirm with `git rev-parse --short HEAD` and
  `git submodule status runtime/native-sdk`.
- Do not fix framework bugs your agents hit, even obvious ones. Record them.
  The Opus run hit several and they are part of the
  result.

## What not to read until your run is finished

`REPORT.md` in this folder holds the Opus results, scores, and the framework
findings. Reading it before your agents run would let you steer around what
Opus hit. Read it afterwards to sanity-check that your receipts line up with
Fable's, then leave the comparison to Fable.

## Model and effort

Use whatever sub-agent model you would normally use for widget authoring, at
the effort you would normally use. Record both in `NOTES.md`. The Opus run
used Opus at default effort.

## If something is unclear

Write the question into `astra/NOTES.md` under "Questions before running",
answer it yourself with the most conservative reading of `PROTOCOL.md`, state
the assumption, and proceed. Dara would rather have a run with stated
assumptions than no run.
