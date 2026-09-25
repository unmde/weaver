# Astra render-loop cadence replicate

Complete: ten independent `gpt-6-astra` agents at `high` reasoning effort, with allocation A×2 / B×4 / C×4. All ten pass every uniform objective gate. No subjective scores or cross-model quality conclusions were assigned; Fable owns blind grading.

## Questions before running

- **How to schedule ten agents with three child slots?** Four batches, listed below; each batch finished before the next began. C4 ran alone. Opus ran ten concurrently, so concurrency differs.
- **How to reuse prompts and isolate context?** Each agent used `fork_turns="none"`. Only `/tmp/weaver-exp` → `/tmp/weaver-exp-astra` and `<DIR>` were substituted in the original prompt text. An identical one-sentence wrapper directed each agent to its own prompt file. Exact copies and verification hashes are archived. No agent received another run's findings, follow-up coaching, or the Opus results.
- **How to reconcile normal widget workflows?** The explicit benchmark rules override live rendering and framework repair: no `weaver dev`, only the assigned capture cadence, and no framework repairs.
- **What about condition A's folder?** Its exact prompt required `captures/` absent during authoring. It remains absent in both temporary A runs; an empty directory was added only to each archived copy. The A agents never received grader captures.
- **What does the watcher count?** The original watcher, with only paths substituted, polled mtime and size every 500 ms. `saves.log` records observed changes, including initialization. Multiple saves within one poll can coalesce; it is not a lossless filesystem trace.
- **What about existing checkout edits?** Both required commits matched: Weaver `ab20771`, Native SDK `464ff65f`. Existing contract/example and other edits were preserved. Their snapshots, hashes, and the pre/post tracked diff are archived. The tracked diff and recorded authoring inputs remained unchanged throughout. Matching commits does not establish that uncommitted inputs match Opus's earlier run.
- **What usage can be measured?** Harness token events, emitted model tool calls, and dispatch/completion timestamps were available for every run. No missing value was replaced with an estimate.

## Batch schedule

All times are UTC on 2026-09-05. Each run's precise dispatch, harness start, completion, and wall duration are in `usage.tsv`.

| Batch | Runs | First dispatch | Last completion |
|---|---|---|---|
| 1 | A1, B1, C1 | 15:29:35 | 15:36:16 |
| 2 | A2, B2, C2 | 15:36:26 | 15:41:56 |
| 3 | B3, C3, B4 | 15:42:04 | 15:47:18 |
| 4 | C4 | 15:47:28 | 15:52:53 |

## Measurements and provenance

The agents made 47 checks and 48 capture attempts, producing 44 successful captures; four failed attempts produced no PNG. The watcher observed 50 saves. These totals exclude the orchestrator's subsequent ten checks and twenty uniform captures. Per-run values are in `MEASUREMENTS.tsv`; raw commands, token events, and textual tool outputs are in `evidence/`.

`usage.tsv` uses final harness `total_token_usage` events. Input tokens include cached input; reasoning output is a subset of output. Neither subset should be added again. `model_tool_calls` counts emitted function/custom calls: one `functions.exec` call can contain several shell or image-tool operations. The AST command audit separately extracts literal shell-command inputs; all ten agents' reported check/capture counts match them. Wall time is harness completion minus the timestamp immediately before dispatch, including spawn latency, never time since experiment start.

The Opus report and usage file were first read only after all Astra agents and the uniform recapture completed. Both sets report all objective gates passing; those gates do not establish visual quality. Opus's usage file exposes aggregate `tokens` and `tool_uses` without cache/accounting breakdown. Direct cross-model token or tool-count equivalence is therefore unverified. The models also use different platform/tool contexts and effort settings (Astra high, Opus default).

## Protocol deviations and retained observations

- Every C agent attempted one capture after a failed check: C1/02, C2/03, C3/03, C4/04. Each failed static validation, published no artifacts, and left a numbering gap. C2–C4 then attempted to open the absent image. These are recorded ordering failures, not successful render-loop passes. All agents recovered and inspected the required slices before proceeding. Reports, original tool outputs, and extracted failure receipts are preserved; none of the runs was restarted or coached.
- All eight B/C agents additionally captured three logs followed by Reset week. These extra captures remain in their usage totals and archives. Uniform grading uses only the two prescribed states and the unchanged three-click action file.
- B1, B3, and C1 reported an invisible grow-sized canvas despite nonzero semantic bounds, then used explicit canvas widths. The original captures and source-edit commands are retained. No framework diagnosis, repair, toolchain update, or PR was performed.
- Restart persistence was not independently tested: every capture intentionally uses isolated empty storage. The agents document that boundary and use the specified storage hook.

## Handoff to Fable

- `runs/<id>/`: unchanged submitted source, report, and every successful agent capture. Failed capture receipts live in `evidence/failed-captures/` because Weaver did not publish those attempts.
- `final-captures/<id>-initial.*` and `<id>-after.*`: flat copies matching the Opus grading layout. They are byte-identical to the uniform evidence under `final/<id>/`, which also retains full commands, exit codes, stdout, and stderr. Receipt paths refer to those original evidence files.
- `GATES.tsv`: all objective gates. `MEASUREMENTS.tsv`, `usage.tsv`, and `saves.log`: per-run receipts. `evidence/artifact-sha256.json` and `verification.json`: archive integrity and fixed-input checks.
- `prompts/`, `harness/`, and `evidence/experiment-inputs/`: reproducible inputs and measurement scripts. Authoring input snapshots are in `evidence/authoring-inputs/`.

All twenty uniform PNGs are 320×200. Every receipt has the pinned commits, the specified clock, and `storage: "isolated-empty"`. All sources match their archived hashes and were unchanged by uniform verification. The watcher has been stopped. Raw material is ready for Fable to anonymize and grade; no mapping or subjective score has been generated by Astra.
