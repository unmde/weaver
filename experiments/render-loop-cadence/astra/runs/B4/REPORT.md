# Focus Week — B4

- Condition: B (final capture). The complete widget was authored before the first capture.
- `weaver check` runs: 3 (first failed on an unbounded dynamic class; two subsequent runs passed).
- `weaver capture` runs: 3, all with status `ok`.
- Defects fixed because of pixels or snapshots: none.
- Spec items not met: none identified. Persistence uses `useStorage` with a record keyed by weekday; restarting a live widget was not exercised because live execution was prohibited. Reset is manual, as specified.
- Confidence: 9/10.

Opened and inspected every PNG at its native 320×200 dimensions and read every snapshot and receipt:

- `captures/01-initial.png`: Friday highlighted, seven zero counts, `0 / 20`, empty bar, equal day cells and aligned header. Text, spacing, contrast, and button bounds are clean.
- `captures/02-after-clicks.png`: Friday 3, every other day 0, `3 / 20`; semantic fill width 31.800001 against track width 212 confirms 15%. Primary native hover color is visible.
- `captures/03-after-reset.png`: three logs followed by Reset week returns every count and the total to zero and empties the bar. Secondary native hover color is visible.

Accessible button names are exactly `Log session` and `Reset week`. Both declare native hover and pressed styles. The widget subscribes only to time and makes no network calls. All receipts report no pending fetches, images, providers, or frame requests; the time subscription accounts for the pending timer. Their sole warning records pre-existing uncommitted checkout changes; no repository files were modified. `weaver dev` was not run.

The static-check fix replaced an arbitrary interpolated progress class with an explicit set of validated width classes for the 20-session goal. It happened before the first capture and was not a pixel-driven repair.
