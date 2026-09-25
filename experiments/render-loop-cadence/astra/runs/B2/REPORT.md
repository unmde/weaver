# Focus Week report

- Condition: B (final capture).
- Explicit `weaver check` runs: 4. The final check passed.
- `weaver capture` runs: 5. Every receipt has status `ok`.
- Defects fixed because pixels or a snapshot exposed them:
  - The progress canvas was 286 px wide inside a 288 px track. The first snapshots exposed the mismatch; corrected the canvas to 288 px, so three sessions fill exactly 15% of the track.
- Spec items not met: none known.
- Confidence: 9 / 10.

The complete widget was written before the first capture. Static diagnostics first corrected an unsupported JSX `key`, a computed utility string, and a percentage-sized canvas; those fixes were not discovered through pixels or snapshots.

Opened and inspected all five PNGs at their real 320×200 dimensions. Final evidence is `captures/03-initial.png`, `captures/04-after-clicks.png`, and `captures/05-after-reset.png`, with their matching snapshots and receipts. Friday is highlighted, all seven initial counts are visible zeros, three Log session clicks produce Friday 3 and `3 / 20`, and Reset week restores every count to zero. Text and controls are legible without overlap or clipping, and the progress label stays above the bar. The snapshots confirm seven equal-width cells and both exact accessible button names.

Both buttons declare native hover and pressed styles. Hover feedback is visible in the corresponding interaction captures. Storage uses the documented persistent `useStorage` hook with a weekday-keyed object; cross-process persistence was not separately exercised because capture creates isolated empty storage each run.

The single pending timer is the subscribed time provider. There are no pending fetches, images, external providers, or frame requests. Receipts warn that the shared Weaver checkout already contains uncommitted changes; this task modified no repository files. No live view was started, as instructed.
