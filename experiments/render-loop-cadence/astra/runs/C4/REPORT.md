# Focus Week report

- Condition: C (progressive capture).
- `weaver check` runs: 9 (7 passed, 2 failed with actionable authoring diagnostics; final check passed).
- `weaver capture` runs: 8 (7 successful, 1 failed before rendering).
- Confidence: 9 / 10.

## Defects fixed because of pixels or snapshots

- Slice 1: the original 16px title and 12px date had different vertical text metrics in capture 01. Changed both to 14px, retaining the title's semibold weight. Capture 02 confirms matching y=20.5 and height=17.5 text bounds and visually aligned text.

## Evidence

- Slice 1: captures 01 and 02, frame and header.
- Slice 2: capture 03, seven equal-width weekday cells (37.714287px each), Friday highlighted, all counts zero.
- Slice 3: capture 05, goal label above the bar with a clear gap. Capture attempt 04 failed static validation of a computed class and produced no artifacts. Replaced the computed class with the documented canvas drawing API, then fixed its width to the measured 288px content width after the checker rejected percentage canvas sizing.
- Slice 4: capture 06, full initial widget. Capture 07, three Log session clicks: Friday 3, all other days 0, label 3 / 20, bar 15% (43.2 / 288px).
- Additional interaction: capture 08, three Log session clicks followed by Reset week: all seven counts zero, label 0 / 20, empty bar.
- Opened and inspected every successful PNG at 320x200, read every semantic snapshot and receipt. All successful receipts have status `ok`. Both exact button names appear in semantics. Both buttons have native hover and pressed classes; post-action captures show their hover feedback.
- Counts use `useStorage` with a JSON object keyed Mon through Sun. Restart persistence relies on that documented SDK contract; capture deliberately uses fresh isolated storage each run.
- Receipts report the pre-existing dirty repository warning. No repository files were modified. One pending timer is consistent with the time subscription; no fetches, images, other providers, or pending frame requests appear.
- No live view was started, as the task explicitly forbids `weaver dev`.

## Unmet spec items

None identified. No automatic calendar-week rollover was added; Reset week explicitly clears the stored weekday counts as requested.
