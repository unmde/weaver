# Focus Week report

- Condition: B (final capture).
- `weaver check` runs: 3. First failed on unsupported JSX `key` and a dynamic class; both subsequent runs passed, including the final source.
- `weaver capture` runs: 5. Every receipt has `status: "ok"`.
- Defects fixed because of pixels or snapshots: the progress bar was invisible in captures 01 and 02 even though its semantic canvas bounds were 224×6. Replacing `w-0 grow` on the canvas with explicit `w-[224px]` made both track and fill visible in captures 03 and 04. The width comes from the measured 288px content row minus its 12px gap and 52px label.
- Spec items not met: none known. Persistence uses `useStorage` with a weekday-keyed record; restart persistence was not independently exercised because captures use isolated empty storage.
- Confidence: 9/10.

Final visual and semantic evidence:

- `captures/03-initial.png`: Friday highlighted, all seven counts zero, `0 / 20`, visible empty track.
- `captures/04-after-clicks.png`: Friday 3, other days zero, `3 / 20`, fill at 15% of the 224px track.
- `captures/05-after-reset.png`: three logs followed by Reset week returns every count to zero and empties the track.

All five PNGs were opened and inspected at their 320×200, scale-1 dimensions; all snapshots and receipts were read. The final captures show aligned header text, equal day cells, legible text, distinct controls, and no clipping or overlap. Both button names match exactly. Native hover feedback is visible after clicks; both controls also declare native pressed styles.

The single pending timer is the subscribed time provider. No fetches, external providers, unresolved images, or frame requests remain. Receipts warn that the repository already contains uncommitted changes; no repository files were edited. No live development window was started, as requested.
