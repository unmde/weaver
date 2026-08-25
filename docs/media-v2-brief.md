# Media provider v2 implementation plan

This is the implementation plan for items 11–13 of
[`docs/api-breadth-orders.md`](api-breadth-orders.md) — album art, transport,
status/sourceApp on Windows; the MediaRemote adapter route on macOS; and the
noro-player port as the acceptance gate. It is written for the agent sessions
doing the work. Read `README.md`, `CONTEXT.md`, `sdk/CONTRACT.md` in full,
ADRs 0002/0005/0013/0014/0015/0016, `docs/ROADMAP.md`,
`docs/api-breadth-orders.md`, and `docs/styling-breadth-brief.md` (whose
autonomy contract and visual gate this plan inherits) before changing code.

This plan was adversarially reviewed (Codex, 2026-07-25) before the run; the
protocol bindings below exist because the first draft would have stranded the
run. Do not relax them.

The slice is complete when `examples/noro-shell` runs against the **real**
media provider on Windows: live title/artist/art, correct playing/paused
rendering, and working prev/play-pause/next/seek — verified by eyes on the
screen, not just tests. macOS code must compile-gate cleanly and ride CI;
attended-Mac verification is out of the unattended run's scope and is
recorded as `UNVERIFIED (needs Mac)`.

## Decisions already made (do not relitigate)

- **Transport is declared-but-quiet** (Dara, 2026-07-25). A widget that calls
  transport verbs must declare `capabilities: ["media-transport"]` in its
  config — auditable at install, printed in the pack/install audit, listable
  by a future gallery — but no consent prompt. Reading now-playing data stays
  under `subscribe: ["media"]` exactly as today.
- **macOS uses the MediaRemote adapter route** (Dara, 2026-07-21: "fine for
  now, we can do better later"). This supersedes ADR 0015 and requires a new
  ADR plus a prerequisite spike (see PR 04). Known-fragile by design: isolate
  it behind the provider boundary so Apple breakage or a later switch to
  per-app scripting changes nothing widget-side.
- **SDK types stay platform-honest.** `artPath` and transport are optional
  capabilities of the provider, never fabricated. A platform that can't
  supply art omits the field; a transport verb that can't be delivered
  fails loudly (see verb semantics), never silently succeeds.

## Reconnaissance facts (verified 2026-07-25)

The current media path, so nobody re-derives it:

- SMTC is read **inside weaverd**, not the runtime:
  `host/src/windows_providers.cpp:154-206` wraps
  `GlobalSystemMediaTransportControlsSessionManager`; C ABI in
  `host/src/windows_providers.h:18-31` (`WeaverMediaState`: title/artist/album
  512-byte buffers, `int playing`, position/duration ms). It is a synchronous
  1 Hz poll — **no SMTC event subscriptions exist today**. No artwork, no
  source app, no controls.
- weaverd polls at 1 Hz and emits newline-delimited JSON
  (`host/src/media.zig:43-67`, `formatFrame:84-108`):
  `{"provider":"media","value":{title,artist,album,playing,positionMs,durationMs}}`.
  The host formats into a **2,048-byte** stack buffer and dedupes against a
  2,048-byte `previous_media` (`host/src/windows_host.zig:111,433`);
  `formatFrame` failure is a silent `catch return`. Runtime lines cap at
  8,192 bytes (`runtime/src/provider_windows.zig:7`); image `src` storage
  caps at 260 bytes (`runtime/src/tree.zig:7`).
- Transport weaverd→runtime is **one-directional outbound**: Windows named
  pipe `PIPE_ACCESS_OUTBOUND` created per subscribed widget
  (`host/src/windows_host.zig:176-182`, env `WEAVER_HOST_PIPE`), written
  synchronously from the supervision thread (`windows_host.zig:744`), set
  blocking after connect (`:758`); runtime opens it `GENERIC_READ` only
  (`runtime/src/provider_windows.zig:44`). macOS is a per-widget UDS
  (`host/src/macos_host.zig`, env `WEAVER_HOST_ENDPOINT`), accept+write only
  (`:170,181`); runtime read-only (`runtime/src/provider_macos.zig:84-89`).
  Both runtime readers push whole lines into a **4-entry drop-oldest queue**
  (`provider_windows.zig:81`, `provider_macos.zig:70`) — fine for
  coalescible frames, fatal for acks.
- JS surface: `native.onProvider` (`runtime/src/bridge.zig:71`; installing a
  second callback **replaces** the first, `bridge.zig:243`) → `hostProviders`
  fan-out (`sdk/src/reconciler.ts:954-1002`, which forwards `frame.value`
  **unchanged** — it derives nothing) → `useProvider("media")`
  (`reconciler.ts:272,298-299`), gated on `subscribe:["media"]`.
- **No widget→host channel of any kind exists.** The only widget-initiated
  exits are `fetch` and `storageWrite` (`runtime/src/bridge.zig:60-82`). The
  macOS `ControlServer` verb/ack protocol (`macos_host.zig:80-110`) is the
  closest architectural template.
- **`<image>` blocks host-cache art as-is:** `isLocalAssetPath`
  (`runtime/src/main.zig:786-791`) rejects absolute paths; images load once
  after initial JS evaluation (`main.zig:910`, `loadLocalImages:769-784`,
  1 MiB read cap at `:780`), register only in the renderer init hook
  (`main.zig:94`), and rendering hardcodes retained node ID = image resource
  ID (`main.zig:725`). Provider dispatch receives no `Effects`
  (`main.zig:270`). `<image>.src` is a **required** string
  (`sdk/index.d.ts:115`) and empty/undefined `src` throws in reconciliation
  (`reconciler.ts:494`).
- Manifest plumbing: `weaver check` currently **requires capabilities to be
  empty** (`cli/src/index.ts:975`); the provider static check matches only
  direct `useProvider(...)` identifier calls (`cli/src/index.ts:1235`);
  `runtime/src/manifest.zig:33-44` parses widget.json with
  `ignore_unknown_fields = false`, so every new manifest key must be added
  there or launch fails. `.weave` packs already carry
  `declared.capabilities` end-to-end (`cli/src/index.ts:277, 611-632`).
  Endpoint creation is subscription-driven on both hosts
  (`windows_host.zig:176`, `macos_host.zig:333`) — a transport-only widget
  gets no channel unless capabilities also drive it (bound below).
- Contract: `sdk/CONTRACT.md:271-285` freezes the media frame and explicitly
  defers control and artwork — amend, don't violate.
- macOS prior art: `spikes/macos-media-observation/main.m` (deliberately
  avoided MediaRemote) and `docs/macos-m11-results.md`.

## Unattended-run autonomy contract

Identical to `docs/styling-breadth-brief.md` — reread it; it is binding here,
including branch/PR authorization, the not-authorized list, failure-as-
routing, and the run-status doc requirement. Differences for this run:

- Branches are `media/01-…` through `media/05-…` in **this repository only**.
  Recon found no Native SDK fork work in this slice; if one genuinely
  appears, stop and record it as `BLOCKED` in the status doc rather than
  opening an unplanned fork stack.
- Live status doc is `docs/media-run-status.md`.
- Work in a fresh clone (e.g. `E:\Projects\weaver-media-run`), never in
  `E:\Projects\weaver`. Verify `npm test`, `npm run typecheck`, and the
  Windows runtime+host builds on virgin `master` before branching.
- Kill running widget/weaverd processes before zig builds (file locks), and
  ensure Git `usr\bin` is on PATH before running fork-style tests.

## Design rules (binding)

- **Idle-zero and honest billing hold (ADR 0005).** The 1 Hz media poll is
  the established, billed heartbeat; art caching and transport must add no
  new polling. SMTC change detection becomes event-driven (dirty flags), the
  poll consumes the flags; transport verbs are request/ack.
- **The capability wall is enforced on both sides.** The runtime refuses to
  expose the transport bridge function unless the manifest declares
  `media-transport`, AND weaverd independently checks the widget's declared
  capabilities before dispatching a verb. A compromised runtime must not be
  able to control media for an undeclared widget.
- **Fail at `weaver check`, never silently no-op.** Source that references
  the SDK transport surface without `capabilities: ["media-transport"]`
  fails `weaver check` with a fix-it naming the exact config line to add.
- **Wire compatibility is preserved.** `playing` stays on the wire (the
  installed-widget SDK forwards `frame.value` unchanged; deleting the field
  breaks every already-installed bundle). `status`, `sourceApp`, `artPath`
  are added alongside.
- **The wire keys, verbs, and protocol constants below are fixed by this
  plan.** If one proves wrong, fix the lowest PR and restack; never rename
  mid-stack.
- **The contract is amended, not violated.** One new section in
  `sdk/CONTRACT.md`: `# Media v2 amendment (v0.5)` in the established
  amendment style; each PR extends it for what it ships. The frozen-frame
  and "control deliberately not in M3" language gets superseded there, not
  edited away.
- **Art files are host-owned.** weaverd writes art to its own cache dir and
  is the only writer; the runtime gets read-only access to exactly that
  root; widgets never see or choose the path shape beyond receiving
  `artPath` as an opaque string.
- **Perf claims are A/B** against master with an identical widget, same
  machine, established policy.

## New wire surface

### Provider frame v2 (weaverd → runtime, all platforms)

```
{"provider":"media","value":{
  "title": string, "artist": string, "album": string,
  "playing": bool,                     // retained for wire compat; always status === "playing"
  "status": "playing" | "paused" | "stopped",
  "sourceApp": string,                 // display-only; see mapping contract; "" if unknown
  "artPath": string,                   // absolute path into the host art cache; KEY ABSENT when no art
  "positionMs": number, "durationMs": number
}}
```

- SMTC status mapping: `Playing`→`playing`, `Paused`→`paused`, everything
  else (`Stopped`/`Closed`/no session)→`stopped`. **"No observable session"
  is the canonical empty frame on every platform**: `status:"stopped"`,
  empty strings, zeros, no `artPath` — this is also what macOS emits once on
  adapter loss (see PR 04), so loss is honest, not fabricated.
- **Frame sizing is a protocol constant, not luck.** Define
  `max_media_frame_bytes` from worst-case JSON escaping of three 512-byte
  metadata fields + `sourceApp` (cap 256 bytes) + `artPath` (cap 259 bytes)
  + fixed overhead; size `formatFrame`'s buffer, `previous_media`, and the
  runtime line accumulators/queues from it; assert the relationship in tests
  on both sides, including maximum-field and escaped-control-character
  cases. A frame that still can't format is a logged error, never a silent
  `catch return`.
- **`sourceApp` mapping contract (display-only, not for widget logic):** the
  package display name when the session's `SourceAppUserModelId()` resolves
  to an installed package without prompting; otherwise the raw AUMID string
  verbatim; `""` only when SMTC supplies none. Fixtures: packaged AUMID,
  Win32 executable-style ID, unresolved ID, empty.
- **Art change detection is event-driven:** subscribe to
  `CurrentSessionChanged` and the active session's `MediaPropertiesChanged`;
  callbacks only set thread-safe dirty flags; the existing 1 Hz poll
  consumes a flag, refreshes properties + thumbnail once, and rebinds events
  on session change. Bind initial fetch on startup, callback teardown,
  duplicate-event coalescing, and failure (clear the flag, retry next
  change, log once).
- **Art cache contract:** root `%LOCALAPPDATA%\weaver\artcache` (macOS
  `~/Library/Caches/weaver/art`), 0700-equivalent. Filename =
  `<sha256-hex>.img` (path length stays far under the 260-byte `src` cap —
  assert it). Max input 1 MiB (matches the runtime decode cap; larger
  thumbnails are skipped, art omitted). Write to a unique temp file → flush →
  atomic no-replace rename; delete temps on any failure and on startup scan.
  Prune LRU by last successful publication to 32 files, never pruning the
  currently published hash, only after successful publication/startup.
  `artPath` is emitted only after the rename completes; a frame never points
  at a partial file.

### SDK surface

```ts
interface MediaData {
  title: string; artist: string; album: string;
  status: "playing" | "paused" | "stopped";
  playing: boolean;        // = status === "playing"; kept for source compat
  sourceApp: string;
  artPath?: string;        // absent when the platform/session has no art
  positionMs: number; durationMs: number;
}

// Existing, unchanged:
const media = useProvider("media");           // requires subscribe: ["media"]

// New, requires capabilities: ["media-transport"]:
const transport = useMediaTransport();
transport.play(); transport.pause(); transport.next(); transport.previous();
transport.seek(ms: number);                    // absolute position
```

- `<image>.src` stays required. **The bound pattern for art is conditional
  rendering** — `{media.artPath ? <image src={media.artPath} … /> : <panel … />}`
  — documented in the contract and used in both examples. Do not loosen
  `src` to optional.
- **Verb semantics (frozen):** each verb returns `Promise<boolean>`.
  Resolve `true` = weaverd delivered the request to the OS API and it
  reported success; resolve `false` = a well-formed request reached weaverd
  but the OS/session declined (no session, `TryX` returned false, capability
  refused). Reject = channel unavailable, malformed protocol, timeout,
  disconnect, or shutdown. `seek(ms)` accepts a finite non-negative number;
  the SDK rounds it to a JavaScript-safe integer before sending `seekMs`, and
  weaverd clamps to known duration when duration is known. Commands execute
  FIFO per widget; at most **4 pending** per widget (a 5th call rejects
  immediately); ack timeout **3 s**; command IDs are runtime-scoped
  monotonically increasing safe integers, never reused while pending. Every
  pending promise settles on ack, timeout, disconnect, malformed ack, or
  shutdown — no promise may hang. weaverd rate-limits to 5 verbs/s per
  widget beyond the pending cap. All constants go in the contract.
- **`weaver check` static gate:** bind to TypeScript symbol resolution, not
  identifier text — flag any call whose symbol originates from the SDK's
  `useMediaTransport` export across **all** project source files (the
  current `useProvider` check at `cli/src/index.ts:1235` matches only direct
  identifier calls and is the anti-pattern). Negative tests:
  `import { useMediaTransport as t }`, `import * as Weaver`, and a helper
  module that calls the hook.

### Transport channel (runtime → weaverd)

Command line (runtime → host), newline-delimited JSON on the existing
channel, reverse direction:
`{"command":"media","verb":"play"|"pause"|"next"|"previous"|"seek","seekMs":number?,"id":number}`
Ack (host → runtime), interleaved with provider frames:
`{"ack":<id>,"ok":bool}`

**Threading/ownership model (binding, both platforms):**

- Host: one dedicated blocking **command-reader thread per widget** that
  only validates framing and enqueues parsed commands to a bounded queue
  (overflow = drop + nack). The host supervision loop drains the queue,
  checks capability + rate limit, dispatches
  (`TryPlayAsync`/`TryPauseAsync`/`TrySkipNextAsync`/
  `TrySkipPreviousAsync`/`TryChangePlaybackPositionAsync` — seek converts ms
  to ticks), and is the **sole writer** of both frames and acks, so bytes
  never interleave. Bind shutdown, broken-pipe, and partial-line behavior
  explicitly. Windows: the per-widget pipe becomes `PIPE_ACCESS_DUPLEX`,
  runtime opens `GENERIC_READ | GENERIC_WRITE`. macOS: the runtime writes
  command lines on the existing UDS; `ProviderEndpoint` gains the same
  reader-thread + single-writer discipline.
- Runtime: the existing reader thread remains the sole reader, but it now
  **demultiplexes by top-level key** before queueing: provider frames go to
  the existing 4-entry coalescing queue (drop-oldest stays correct for
  them); acks go to a separate non-lossy bounded structure that settles the
  matching pending promise (sized by the 4-pending cap, so it cannot
  overflow). Runtime writes take a send mutex. Route both through **one**
  central dispatcher extending the existing single `onProvider` callback —
  never install a second `onProvider` (it replaces the first,
  `bridge.zig:243`).
- Bridge: one new function, `native.mediaCommand(json, cb)`, registered in
  `runtime/src/bridge.zig` **only when** the manifest declares
  `media-transport`.
- **Endpoint creation:** `capabilities: ["media-transport"]` by itself
  causes per-widget endpoint/pipe creation on both hosts (parse capabilities
  before the `needs_endpoint` decision at `windows_host.zig:176` /
  `macos_host.zig:333`). Transport does not require `subscribe:["media"]`.

### Dynamic image reload (runtime, PR 02)

The current pipeline loads once at startup and hardcodes node ID = resource
ID; "swap the texture" is not implementable as-is. Bound lifecycle:

- Track, per image node, the normalized source and registered state.
- After **every JS turn that can mutate the tree** (not just provider
  delivery — provider dispatch currently gets no `Effects`,
  `main.zig:270`; plumb `Effects` through or synchronize at the point where
  it is available), synchronize dirty image nodes: unchanged path = no
  work.
- Load + decode the new file first; **re-register the same node/resource ID
  only after decode succeeds**, keeping the prior image on failure.
  Unregister when the node dies or its source becomes invalid. Handle
  node-ID reuse and dev hot-swap.
- The startup bundle path stays byte-for-byte on its existing code path;
  static widgets pay nothing.
- `isLocalAssetPath` gains exactly one acceptance: the host-provided art
  cache root (env `WEAVER_ART_CACHE`, set by weaverd). **Windows-correct
  containment**: canonicalize the root once; resolve the candidate to an
  absolute normalized path; compare by path components, case-insensitively,
  at a component boundary (so `artcache-evil` is not a child of
  `artcache`); reject drive-relative, UNC, and device-namespace forms and
  `..` regardless. Adversarial tests: `<root>\..\x`, `<root>x\y`,
  mixed separators, case variants, `\\?\` and UNC forms.

## The stack

Weaver PRs on `master`, branches `media/01`–`media/05`, each with tests,
contract-section update, and run-status upkeep. Each PR says `Stack: NN/05`,
states what becomes usable and what is deliberately missing, includes
commands + results, and makes a performance claim or explicitly declines to.

- **01 `media/01-status-sourceapp`** — `status` + `sourceApp` added
  alongside the retained `playing` bool, through the C struct
  (`windows_providers.h:22` grows fields), the C++ derivation
  (`windows_providers.cpp:196` gains the tri-state mapping), the Zig frame
  (`media.zig`), SDK types, and the reconciler seed; the frame-sizing
  protocol constant lands here with its tests. Update
  `examples/now-playing` to render status + source. Contract amendment
  section opens here.
- **02 `media/02-album-art`** — SMTC event subscriptions + dirty flags, the
  art cache per the contract above, `artPath` on the wire; runtime art-root
  acceptance + dynamic image reload per the bound lifecycle. This is the PR
  with real runtime surgery — keep the static path untouched and prove it
  (A/B idle numbers for a static image widget).
- **03 `media/03-transport`** — the duplex channel with the bound
  threading model (both platforms' plumbing; Windows-verifiable),
  `native.mediaCommand`, `useMediaTransport` with frozen verb semantics,
  the `media-transport` capability end-to-end: relax `cli/src/index.ts:975`
  to a whitelist containing exactly `media-transport`, thread the key into
  `RuntimeManifest` (`cli/src/index.ts:210-222`) and
  `runtime/src/manifest.zig` (strict parser — add the field),
  capability-driven endpoint creation, weaverd-side capability check + rate
  limit, the symbol-resolved `weaver check` gate, pack/install audit line.
  Update `examples/now-playing` with play/pause to prove the loop.
- **04 `media/04-macos-adapter`** — **spike-gated.** First, a spike under
  `spikes/` must produce, on CI or with recorded evidence, a reproducible
  answer to: the exact Apple-signed executable/service invoked; the
  invocation + bidirectional IPC protocol; where MediaRemote
  declarations/symbols come from; entitlement behavior on the supported
  macOS floor (the 15.4 gate); signing/notarization/redistribution
  implications; process lifecycle, crash detection, reconnect. **If the
  spike cannot produce a real metadata frame and a delivered command, PR 04
  is `BLOCKED` — record it and finish the Windows slice; do not fake it
  with a compile-only gate.** With the spike proven: **ADR 0017**
  superseding 0015 (scope of system-wide observation, loss behavior = the
  canonical empty frame emitted once + `mediaAvailability:"unavailable"` in
  diagnostics + silence, isolation guarantee behind
  `host/src/providers_macos.zig` + the existing UDS), then the adapter
  implementation feeding the per-widget endpoint with frame v2, art via the
  same cache contract, transport verbs via the adapter. Everything CI can't
  prove is `UNVERIFIED (needs Mac)`.
- **05 `media/05-noro-gate`** — item 13's Windows half: wire
  `examples/noro-shell` to the real provider — art in the screen area via
  the conditional-render pattern (the current static cover is the
  fallback), elapsed from `positionMs`, status-driven play/pause glyph,
  prev/next/play-pause on the existing buttons. **Seek:** the current
  progress bar is a non-interactive `<stack>`+`<panel>`
  (`examples/noro-shell/widget.tsx:29`); replace the track with a
  pixel-matched `<button>` (visual gate must show an identical capture)
  whose `onPress` uses normalized `event.x` for click-to-seek. Click-only
  seek satisfies acceptance; dragging is out of scope.
  `docs/media-v2-results.md` with A/B idle CPU/memory vs master noro-shell,
  visual-gate evidence, and a Windows side-by-side against the Rainmeter
  original. Conjure skill updated to teach media v2 + the capability
  declaration. The macOS side-by-side is the attended-Mac item, recorded as
  open.

## Verification (every PR, mechanically checkable)

- `npm test`, `npm run typecheck` green; `zig build test` green in
  `runtime/` (Windows flags: `-Dweb-layer=exclude -Dtrace=off`) and in
  `host/`.
- Wire changes: update the frame-contract tests (`host/src/media.zig:115-124`,
  `host/src/provider_protocol.zig` pattern) and add command-channel framing
  tests on both sides: interleaved ack/frame parsing, partial lines, the
  demux split (frames coalesce, acks don't drop), promise settlement on
  timeout/disconnect/shutdown, and the frame-sizing constant asserted
  against worst-case fields.
- Capability wall: tests that an undeclared widget (a) fails `weaver check`
  when referencing transport (including the aliased/namespace/helper-module
  cases), (b) gets no `native.mediaCommand` at runtime, (c) is refused by
  weaverd if it forges a command anyway.
- Art cache: tests for hash-dedupe, prune cap + published-hash pinning,
  temp-file cleanup, the never-partial-file guarantee, the 1 MiB skip, and
  the full adversarial path-containment set.
- Live checks on this machine per PR: the PR's example under `weaver dev`
  with a real player (Spotify or Windows Media Player) — art appears within
  one poll of a track change, status flips on pause, each verb visibly
  controls the player, seek lands within ~1s of target.
- **The visual gate from `docs/styling-breadth-brief.md` is binding**: every
  PR that renders pixels captures the widget region, the capture is opened
  and looked at, and a written per-element checklist passes before any
  visual claim. PR 05 additionally captures the Rainmeter original for the
  side-by-side, and the seek-track replacement must produce a capture
  indistinguishable from the pre-change shell.
- The full existing CI matrix is the floor; macOS compile-gates via headless
  CI. Do not disable or weaken any CI step.
