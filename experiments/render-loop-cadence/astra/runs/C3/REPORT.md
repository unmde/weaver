# Focus Week report

- Condition: C (progressive capture).
- `weaver check` runs: 7 (6 passed, 1 failed; final run passed).
- `weaver capture` runs: 7 (6 successful, 1 failed before rendering).
- Defects fixed because of pixels or a snapshot: none. Each rendered slice was inspected at its actual 320×200 dimensions and had no observed clipping, overlap, or alignment defect.
- Spec items not met: none known. Persistence uses `useStorage` with a record keyed Mon through Sun; restart persistence relies on the documented hook contract and was not separately exercised by the isolated captures. Reset is manual through Reset week.
- Confidence: 9/10.

The four slices were captured in order: frame/header (01), days (02), progress (04), and buttons/storage (05 initial, 06 after three clicks). Capture 07 additionally verifies Reset week after three clicks. Every published PNG was opened, its semantic snapshot read, and its receipt confirmed `status: "ok"`. Capture 06 shows Friday 3, six zero counts, `3 / 20`, and the 15% bar. Capture 07 returns all counts to zero and clears the bar. Both accessible button names match exactly. The successful receipts report only the expected time-provider timer, no fetches or pending frame requests, and the existing dirty-checkout provenance warning.

One authoring error was fixed from checker diagnostics: a computed width class was not statically enumerable. The progress bar now uses the documented canvas drawing API. Capture attempt 03 was inadvertently invoked after that failed check and also failed with the same actionable diagnostic; it published no PNG or snapshot. The next check passed before capture 04. Capture counters were not reused.

No `weaver dev` was run, as instructed. No repository file was edited.
