# Focus Week report

- Condition: C (progressive capture).
- `weaver check` runs: 8 (6 passed, 2 failed while authoring). Final source passed.
- `weaver capture` runs: 8 (7 succeeded, 1 failed at static validation). Capture 02 produced no artifacts because an unsupported `key` prop remained; numbering was preserved.
- Confidence: 9 / 10.

## Defects fixed because of pixels or snapshots

- Capture 04 showed no progress track despite a 224×6 semantic canvas bound. The canvas had `w-0 grow`, so its drawing width was zero. Changed it to explicit `w-[224px]`, consistent with the shipped canvas examples. Capture 05 visibly confirmed the track; capture 07 confirmed the filled portion at 15%.

## Verification

Built and inspected each slice before starting the next: frame/header (01), day cells (03), progress (04 then 05), buttons/storage (06 initial, 07 after three clicks). Also captured reset after three clicks (08).

Opened every successful PNG at its actual 320×200 size, read its semantic snapshot and receipt, and confirmed `status: "ok"`. Captures show equal-width Monday–Sunday cells, Friday highlighted, visible zero counts, separated bar and total, readable button labels, and no clipping or overlap. Capture 07 shows Friday 3, six zeros, `3 / 20`, and a 15% fill. Capture 08 shows seven zeros and `0 / 20`. Exact accessible names are `Log session` and `Reset week`.

Storage uses `useStorage` with a record keyed by weekday. Persistence across restarts follows that SDK contract; captures intentionally use isolated empty storage and do not independently prove a live restart. Native hover and pressed classes are defined on both buttons; the post-action snapshots and pixels show each button's hover state.

The one pending timer is the subscribed time provider. There are no fetches, other providers, unresolved images, or queued frame requests. The only successful-receipt warning is that the existing Weaver checkout has uncommitted changes. No repository file was edited and `weaver dev` was not run, as instructed.

## Unmet spec items

None identified. The week is reset through the specified Reset week button; no automatic rollover was requested.
