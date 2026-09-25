# Focus Week

- Condition: B (final capture).
- `weaver check` runs: 3. First failed because `column` does not accept a `key` prop; the following two passed.
- `weaver capture` runs: 5. All receipts have status `ok`; every PNG was opened at its native 320×200 dimensions and every snapshot was read.
- Defects fixed because pixels or snapshots exposed them:
  - The progress canvas had `w-[0px] grow`: its semantic bounds grew, but its drawing remained invisible. Changed it to an explicit 232 px drawing width, following the examples' explicit canvas dimensions, and reserved a separate 44 px label region with a 12 px gap. Captures 03 and 04 show the empty track and 15% fill respectively.
- Spec items not met: none identified. Persistence uses `useStorage` with a weekday-keyed object; capture isolates storage, so restart persistence was not separately exercised. No live dev session was run, as instructed.
- Confidence: 9/10.

Final evidence: `captures/03-initial.png` shows Friday highlighted and seven zeros; `captures/04-after-clicks.png` shows Friday 3, six zeros, `3 / 20`, and 15% fill. `captures/05-after-reset.png` verifies three logs followed by Reset week returns all seven days and the total to zero. The semantic trees expose exactly `Log session` and `Reset week` as button names. Both buttons use native hover and pressed styles. No clipping or overlap was observed at 1× scale.

The receipts' sole warning reports pre-existing uncommitted repository changes; this task modified no repository files. The one pending timer is the subscribed time provider; there are no fetches, unresolved images, external providers, or queued frames.
