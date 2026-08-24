# Agent widget capture

`weaver capture` renders a checked widget without opening a desktop window or
starting Weaver's host, registry, provider daemon, or development loop. It is
the deterministic inspection path for agents, tests, and CI:

```sh
node cli/bin/weaver.js capture examples/clock --out /tmp/clock.png
```

A successful run publishes three files together:

- `/tmp/clock.png` — pixels from Native SDK's reference renderer.
- `/tmp/clock.snapshot.txt` — the semantic tree used by automation.
- `/tmp/clock.receipt.json` — provenance, renderer counters, pending work,
  measured timings, input hashes, and warnings.

Standard output is exactly one compact `weaver.capture.v1` receipt. Diagnostics
go to standard error. A failed run also emits one error receipt, exits nonzero,
and does not publish a partial artifact set.

Capture uses a fresh temporary data, storage, geometry, log, and artwork root.
It neither reads nor changes the live widget state. The clock starts at the ISO
instant recorded in `inputs.clock`; pass `--clock <ISO-8601>` when a capture
must reproduce exactly. Time advances only through an action or a replayed
session. No arbitrary wait is used to decide that rendering is done.

```sh
node cli/bin/weaver.js capture examples/clock \
  --clock 2026-08-24T17:30:00.000Z \
  --out /tmp/clock.png
```

## Semantic actions

Pass `--action-file <file>` to drive the ordinary automation dispatcher after
the initial frame. Targets use semantic role and accessible name, not retained
node IDs or screen coordinates:

```json
{
  "schema": "weaver.capture.actions.v1",
  "actions": [
    {
      "action": "click",
      "target": { "role": "button", "name": "Start" }
    },
    { "action": "advance-clock", "milliseconds": 1000 }
  ]
}
```

Supported actions are `click`, `drag`, `wheel`, `text`, `key`, `action`,
`context-menu`, `resize`, and `advance-clock`. A target may match `role`,
`name`, `enabled`, `selected`, and `value`; `role` or `name` is required and
the match must be unique. `drag` takes normalized `from` and `to` values.
`advance-clock` drives eligible Weaver timers synchronously through the null
platform, then renders any frame the widget actually requests.

Examples live in [`test/capture`](../test/capture):

```sh
node cli/bin/weaver.js capture examples/pomodoro \
  --action-file test/capture/pomodoro.actions \
  --out /tmp/pomodoro.png

node cli/bin/weaver.js capture examples/styling-interaction \
  --action-file test/capture/styling-interaction.actions \
  --out /tmp/styling-interaction.png
```

## Provider fixtures

Capture never connects to a live provider endpoint. A widget subscribed to
`cpu`, `memory`, `audio`, or `media` must receive explicit recorded input with
`--provider-fixture <file>`. Every subscribed non-time provider must appear in
the fixture and undeclared providers are rejected.

```json
{
  "schema": "weaver.provider-fixture.v1",
  "frames": [
    {
      "provider": "media",
      "value": {
        "title": "Capture Proof",
        "artist": "Weaver",
        "status": "playing",
        "playing": true,
        "positionMs": 42000,
        "durationMs": 180000
      }
    }
  ]
}
```

Frames enter through the same provider dispatch path as live host frames. The
fixture file's SHA-256 is recorded in the receipt:

```sh
node cli/bin/weaver.js capture examples/noro-shell \
  --provider-fixture test/capture/noro.provider.json \
  --out /tmp/noro.png
```

## Session journals

`--session-journal <file>` replays an existing Native SDK session journal with
verification enabled and captures its final retained state. A journal and an
action file are alternative event sources and cannot be supplied together.
The journal hash is recorded in the receipt.

## Reading the receipt

Treat `status`, `error`, and `pending` as the decision surface. `renderer`
reports the retained revision, driven frames, command and semantic-node counts,
registered images and fonts, and the number of pixels that differ from the
surface clear color. A successful but visibly empty widget therefore has an
explicit receipt instead of relying on a screenshot guess. `pending` reports
timers, fetches, unresolved images, providers, and real queued frame requests;
the capture command does not hide them by sleeping or by imposing a guessed
timeout.

`provenance` records the Weaver and Native SDK commits plus the exact bundled
JavaScript hash. A dirty checkout is allowed but is called out in `warnings`.

After building the runtime, run the repository acceptance corpus with
`npm run test:capture`. It checks non-flat pixels, semantic state changes,
provider failure and fixture behavior, ambiguous-target candidates, artifact
publication, and byte-identical fixed-clock session replay.
