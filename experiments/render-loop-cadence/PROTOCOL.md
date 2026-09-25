# Render-loop cadence experiment

Question: does an authoring agent produce a better Weaver widget when it looks
at rendered pixels during the build, only at the end, or never?

Every run builds the same widget from the same spec on the same toolchain.
Only the capture cadence changes. Agents never run `weaver dev`.

## Conditions

- **A check-only.** The agent may run `weaver check` as often as it likes. It
  never runs `weaver capture` and never sees pixels or a snapshot. It stops
  when it believes the widget matches the spec.
- **B final-capture.** The agent writes the whole widget first. Only when it
  believes the widget is complete does it run the Render loop (check, capture
  both states, open the PNGs, read the snapshots). It may then fix and
  re-capture as many rounds as it wants.
- **C progressive-capture.** The agent runs the Render loop after each visual
  slice, in this order: (1) frame and header, (2) day cells, (3) progress bar,
  (4) buttons and the after-clicks state. It may re-capture within a slice.

Allocation for a 10-agent run: A×2, B×4, C×4. Same model, same effort, fresh
directory per agent, no shared context between agents.

## Widget spec (identical for every run)

Name: **Focus Week**. Size **320×200**. Anchor top-right, offset 24,24.

1. Header row. Left: the title "Focus week". Right, aligned to the same
   baseline: the current weekday and date, for example "Fri, Sep 4".
2. Seven day cells in one row, Monday through Sunday, equal width, filling the
   available width. Each cell shows the weekday letter (M T W T F S S) above
   that day's session count. Today's cell is visibly highlighted. Days with
   zero sessions still show "0".
3. A progress bar showing sessions logged this week against a goal of 20,
   with a label of the form "12 / 20" placed so that it never overlaps the bar.
4. Two buttons in one row. Primary: "Log session" adds one session to today.
   Secondary: "Reset week" sets every day to zero. Both have native `hover:`
   and `pressed:` styles. Counts persist across restarts with `useStorage`.
5. Visual bar: the shipped examples' house style. Dark translucent surface,
   rounded corners, restrained palette, clear hierarchy, nothing clipped or
   overlapping, text legible at 1× scale.

Data: `time` provider for today. Weekday comes from `time.weekday` (short
name). Session counts keyed by weekday. No other providers, no network.

## Capture inputs (fixed for every run)

- Clock: `--clock 2026-09-04T09:41:00.000Z` (a Friday).
- State `initial`: no actions, isolated empty storage.
- State `after-clicks`: action file `clicks.actions`:

```json
{
  "schema": "weaver.capture.actions.v1",
  "actions": [
    { "action": "click", "target": { "role": "button", "name": "Log session" } },
    { "action": "click", "target": { "role": "button", "name": "Log session" } },
    { "action": "click", "target": { "role": "button", "name": "Log session" } }
  ]
}
```

Expected after-clicks state: Friday shows 3, every other day 0, label "3 / 20",
bar at 15%.

## Commands

From the Weaver repository root, with `<dir>` the run's widget directory:

```sh
npx --no-install weaver init <dir>
npx --no-install weaver check <dir>
npx --no-install weaver capture <dir> --clock 2026-09-04T09:41:00.000Z --out <dir>/captures/NN-initial.png
npx --no-install weaver capture <dir> --clock 2026-09-04T09:41:00.000Z --action-file <dir>/clicks.actions --out <dir>/captures/NN-after-clicks.png
```

`NN` is a zero-padded counter that increments on every capture the agent
runs, so the capture files are the receipt for how many times it looked.

## What each agent must leave behind

- `<dir>/widget.tsx` (the deliverable).
- `<dir>/captures/` (every capture it ran; empty for condition A).
- `<dir>/REPORT.md` with: condition letter, number of `weaver check` runs,
  number of `weaver capture` runs, a list of every defect it fixed *because it
  saw pixels or a snapshot* (B and C only), any spec item it could not meet
  and why, and its own confidence (0 to 10) that the widget matches the spec.

## Measurement (done by the grader, not the agent)

- A watcher records every `widget.tsx` save (mtime and byte size) per run, so
  save counts and wall time do not rely on self-report.
- After all runs finish the grader re-captures both states for every run with
  the same inputs, so grading uses identical evidence for every condition.
- Captures are copied to anonymized names and graded before the condition
  mapping is unmasked.

## Rubric (0 to 3 each, 18 max)

1. Spec completeness: every numbered item present and behaving.
2. Layout: no overlap, clipping, or misalignment; the seven cells fill the row.
3. Hierarchy and type: title, date, counts, labels read in the intended order.
4. Surface and color: house style, contrast, highlight of today is obvious.
5. Interaction proof: after-clicks state is exactly as expected; semantic tree
   exposes both buttons by name.
6. Code: one literal `widget()` export, no dead code, no hacks around the
   contract.

Objective gates recorded alongside: `weaver check` passes; both receipts have
`status: "ok"`; snapshot contains buttons named "Log session" and "Reset week";
after-clicks snapshot shows "3 / 20".
