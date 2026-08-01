# Receipt sweep results

Date: 2026-07-30

Scope: numeric widget/runtime/package limits in `runtime/src`, `cli/src`, and
`sdk/src`, plus the Weaver-pinned image and tree-depth limits in the Native
SDK. Native SDK limits unrelated to Weaver remain governed by that repository's
existing receipt blocks.

Every surviving item below now has a definition-site receipt or is explicitly
classified as a derived protocol/OS invariant. This pass did not add an error
path or a new `weaver check` rule.

## Measurement ruler

The CLI's lowered-tree accounting was reused, then every shipped bundle was
executed against an instrumented native-bridge shim so dynamic arrays and
conditional JSX were counted after reconciliation. Counts below are reachable
nodes after painted row/column lowering.

| Shipped widget | Nodes | Depth | Max children | Max text bytes | Max icon bytes | Images | Canvases |
|---|---:|---:|---:|---:|---:|---:|---:|
| clock | 6 | 4 | 2 | 11 | 0 | 0 | 0 |
| dpi-diagnostic | 17 | 7 | 2 | 11 | 0 | 0 | 1 |
| m4b-hybrid-parity | 6 | 4 | 2 | 18 | 0 | 0 | 1 |
| m4b-mixed-synthetic | 6 | 4 | 2 | 24 | 0 | 0 | 1 |
| noro-shell | 54 | 8 | 24 | 11 | 66 | 6 | 0 |
| now-playing | 39 | 5 | 24 | 25 | 0 | 0 | 1 |
| pomodoro | 17 | 5 | 3 | 14 | 0 | 0 | 0 |
| retro-player-shell | 29 | 7 | 4 | 27 | 384 | 2 | 0 |
| styling-fonts | 7 | 3 | 5 | 122 | 0 | 0 | 0 |
| styling-icons | 28 | 6 | 5 | 48 | 1,037 | 0 | 0 |
| styling-images | 15 | 5 | 3 | 45 | 0 | 3 | 0 |
| styling-interaction | 13 | 5 | 4 | 72 | 0 | 0 | 0 |
| styling-shadows | 8 | 4 | 3 | 28 | 0 | 0 | 0 |
| styling-spacing | 12 | 5 | 3 | 58 | 0 | 0 | 0 |
| styling-stack | 11 | 6 | 3 | 23 | 734 | 0 | 0 |
| styling-text | 15 | 7 | 2 | 107 | 0 | 0 | 0 |
| system-monitor | 11 | 5 | 3 | 15 | 0 | 0 | 0 |
| visualizer | 13 | 7 | 2 | 8 | 0 | 3 | 1 |

Other direct measurements:

- Retained noro-shell is 52 nodes before its two painted-layout nodes. Its
  historical `+6` failure shape is therefore 60 lowered nodes under the new
  1,024-node tripwire.
- The Native SDK's previously measured realistic three-pane view is about 500
  nodes.
- The longest shipped source path is 24 bytes and font family is 17 bytes.
- Lucide Static 1.26.0 has 1,749 icons. Normalizing the full catalog measured
  `puzzle` largest at 2,099 UTF-8 bytes and 45 path elements.
- Shipped album art peaks at 256x256 RGBA = 262,144 decoded bytes, exactly the
  old cap. `styling-images` peaks at 217,000 bytes.
- The historical generated grille was 1,025,239 encoded bytes after commit
  `c67b4e3` squeezed it below 1 MiB (2,433,485 bytes before the squeeze). The
  redesigned current grille tile is 4x4 and 75 encoded bytes.
- The largest shipped font is 94,800 bytes.
- `retro-player-shell` is the largest source bundle: 170,214 bytes, six files,
  94,800-byte largest file, 171,011-byte `.weave`, and 414-byte `weave.json`.
- A realistic 100-record notes-storage fixture with 900-byte bodies measured
  103,291 serialized bytes.
- A synthetic 1,024-record QuickJS view measured 553,712 live bytes / 629,335
  allocator bytes and 8-11 ms to evaluate in the Debug Windows runner.
- QuickJS's upstream 1 MiB stack guard measured 16 trivial recursive JS calls;
  4 MiB measured 70.
- `@sizeOf(Node) = 1,928`, `@sizeOf(CanvasState) = 294,960`, and
  `@sizeOf(Tree) = 4,334,144`. `TimerSlot` is 40 bytes, `FetchSlot` 160,
  `PendingRejection` 32, and provider `Framer` 25,016.

## Inventory

`Receipt now` is Y for every surviving definition. `Prior` records the state at
the start of this sweep.

### Retained tree, canvas, and images

| Constant | Value | Definition / mirror | Receipt now | Prior | Measured worst good case | Verdict |
|---|---:|---|:---:|:---:|---|---|
| `max_nodes` | 1,024 | `runtime/src/tree.zig:14`; CLI `index.ts:1075`; Native SDK `canvas_limits.zig:149` | Y | N | 54 Weaver; ~500 Native SDK | resize 128 → 1,024 |
| `max_widget_depth` | 32 | Native SDK `widget_limits.zig:9`; CLI `index.ts:1076` | Y | N | 8 | keep; one canonical Native source |
| `max_children` | 64 | `runtime/src/tree.zig:19`; CLI `index.ts:1077` | Y | N | 24 | resize 24 → 64 |
| `max_text_bytes` | 1,024 | `runtime/src/tree.zig:24`; CLI `index.ts:1078` | Y | N | 122 shipped; 512-byte provider field | resize 192 → 1,024 |
| `max_source_bytes` | 1,024 | `runtime/src/tree.zig:32`; CLI `index.ts:1079` | Y | N | 24 shipped; 259-byte provider path | resize 260 → 1,024; exact heap allocation; static check mirror audit-pinned |
| `max_icon_path_bytes` | 8 KiB | `runtime/src/tree.zig:37`; `cli/src/icon-paths.ts:9` | Y | N | 2,099 catalog; 1,037 shipped | keep |
| `max_font_family_bytes` | 63 | `runtime/src/tree.zig:42`; CLI `index.ts:95` | Y | N | 17 | keep as shared font-stem format bound |
| `max_canvases` | 8 | `runtime/src/tree.zig:48`; CLI `index.ts:1080` | Y | N | 1 | keep |
| canvas commands / points / wire | 2,048 / 8,192 / 32,768 | `runtime/src/tree.zig:57-59`; SDK `reconciler.ts:13` | Y | Y | 336-rect meter | keep; wire is derived |
| `max_images` | 16 | `runtime/src/main.zig:78`; CLI `index.ts:1084`; Native SDK `canvas_limits.zig:120` | Y | N/Y | 6 | keep |
| decoded image bytes | 1 MiB | `main.zig:81`; CLI `index.ts:1679`; Native SDK `canvas_limits.zig:121`, `platform/types.zig:264` | Y | N | 262,144 exactly | resize 256 KiB → 1 MiB |
| encoded image stream | 2 MiB | `main.zig:86`; CLI `index.ts:1684` | Y | N | 1,025,239 historical | resize 1 MiB → 2 MiB |
| `max_image_load_attempts` | 3 | `runtime/src/main.zig:89` | Y | N | initial attempt + atomic-save race retries | keep |

The node/canvas arenas now have explicit occupancy bitsets. Normal transaction
snapshots copy only occupied Nodes and used canvas commands/points; unoccupied
capacity remains undefined. One node arena reserves 1,974,272 bytes and the
reusable snapshot reserves a second, while pages are touched as slots become
live. The eight canvas states reserve about 2.25 MiB per Tree, also untouched
until their slots draw.

### Runtime execution, I/O, and providers

| Constant | Value | Definition | Receipt now | Prior | Measured worst good case | Verdict |
|---|---:|---|:---:|:---:|---|---|
| `max_timers` | 16 | `runtime/src/bridge.zig:33` | Y | N | 1 active | keep |
| `max_fetches` | 4 | `runtime/src/bridge.zig:38` | Y | N | modeled 2 concurrent APIs | keep |
| QuickJS memory | 32 MiB | `runtime/src/js_engine.zig:14` | Y | N | 629,335 allocator bytes at 1,024 records | keep |
| JS turn watchdog | 100 ms | `runtime/src/js_engine.zig:18` | Y | N | 8-11 ms at 1,024 records | keep |
| QuickJS / process stack | 4 MiB / 16 MiB | `runtime/src/js_engine.zig:23`; `runtime/build.zig:16` | Y | N | 70 recursive calls vs 16 before | resize default 1 MiB guard; pin process reserve |
| pending rejections | 8 | `runtime/src/js_engine.zig:27` | Y | N | modeled four-fetch rejection burst | keep |
| request / response | 5 MiB each | `runtime/src/network.zig:18-19` | Y | N | modeled 2 MiB JSON payload | keep |
| network timeout | 15 s | `runtime/src/network.zig:13` | Y | N | modeled 5 s slow-good exchange | keep |
| provider frame queue | 4 | `runtime/src/provider_protocol.zig:11` | Y | N | CPU + memory + audio + media cycle | keep |
| provider ack queue | tracker-derived 4 | `provider_protocol.zig:14`; `media_pending.zig:7` | Y | N | four-command transport burst | keep; derive |
| provider command line | 256 B | `provider_protocol.zig:18` | Y | N | 86-byte maximal legal command | keep |
| provider reader stack | 256 KiB | `provider_macos.zig:13`; `provider_windows.zig:13` | Y | N | 29,112-byte dominant locals | keep |
| media ack deadline | 3,000 ms | `runtime/src/media_pending.zig:10` | Y | N | 2,500 ms host execution + 500 ms delivery | keep |
| geometry file | 512 B | `runtime/src/geometry.zig:22` | Y | N | 33-byte fixture; 128-byte encoder | keep |
| manifest / bundle read | 64 KiB / 1 MiB | `runtime/src/manifest.zig:10,14` | Y | N | 570 / 45,818 bytes | keep |
| storage document | 256 KiB | `runtime/src/storage.zig:9`; SDK `reconciler.ts:7` | Y | N | 103,291-byte notes fixture | resize 64 KiB → 256 KiB |
| log rotation | 1 MiB | `runtime/src/widget_log.zig:8` | Y | N | ≥128 maximum-size diagnostic lines | keep |

### CLI and packaging

| Constant | Value | Definition | Receipt now | Prior | Measured worst good case | Verdict |
|---|---:|---|:---:|:---:|---|---|
| widget fonts | 2 faces / 512 KiB each | `cli/src/index.ts:90-91`; Native SDK `canvas_limits.zig:141-142` | Y | N/Y | 1 face / 94,800 bytes | keep |
| weave archive/source/unpacked | 64 MiB | `cli/src/weave.ts:13-15` | Y | N | 171,011 / 170,214 bytes | keep |
| weave file | 16 MiB | `cli/src/weave.ts:16` | Y | N | 94,800 bytes | keep |
| weave manifest | 64 KiB | `cli/src/weave.ts:20` | Y | N | 414 bytes | keep |
| weave entries | 1,024 | `cli/src/weave.ts:21` | Y | N | 6 | keep |
| weave name / author | — | former `cli/src/weave.ts` | — | N | manifest already globally bounded | delete both 256-byte caps |
| install slug | 48 ASCII bytes | `cli/src/index.ts` (`installDirectoryName`) | Y | N | 19 bytes; 111-byte full component | keep as portable OS filename bound |
| canvas FPS | 60 | `sdk/src/reconciler.ts:18` | Y | N | 60 authored / 60 native surface clock | keep as scheduler invariant |
| CLI log tail | — | former `cli/src/index.ts` | — | N | runtime files already bounded to 2 MiB | delete 200-line cap |

### Protocol/OS invariants (not widget budgets)

| Constant | Value | Definition | Receipt now | Classification |
|---|---:|---|:---:|---|
| media text / source-app | 512 / 256 B | `runtime/src/media_protocol.zig:8,12` | Y | frozen host/runtime wire fields |
| media art path | 259 B | `runtime/src/media_protocol.zig:16` | Y | Windows `MAX_PATH` payload + NUL contract |
| JSON escape | 6 B | `runtime/src/media_protocol.zig:19` | Y | grammar maximum `\u00XX` |
| media frame | derived 12,502 B | `runtime/src/media_protocol.zig:28` | Y | full newline-terminated wire formula |
| safe command ID | 9,007,199,254,740,991 | `media_pending.zig:13`; `provider_protocol.zig:21` | Y | IEEE-754 exact-integer invariant |
| canvas/provider aliases | derived | `bridge.zig:41,44`; `provider.zig:15,18`; `provider_protocol.zig:7,14` | Y | aliases, not independent limits |

## Limits removed

- The separate 256-byte `.weave` display-name and author caps. The 64 KiB
  manifest cap already bounds their aggregate storage.
- The 200-line `weaver logs` tail. The command had already loaded the current
  and rotated files, so the slice saved no memory and only hid diagnostics.
- The two 32,768-byte widget-log path arrays and `LogPathTooLong`. Paths now
  allocate exact process-lifetime strings.

The safe-ID, JSON-escape, art-path, and derived frame constants remain because
wire parsing needs them, but their comments now prevent anyone from treating
them as tunable widget budgets.

## Verification

- `zig build test` in `runtime`: passed.
- `npm run typecheck`: passed.
- CLI build plus all 46 CLI tests: passed.
- Native SDK `test-canvas` and `test-widget-profile`: passed.
- Native SDK `scripts/gate.sh fast`: `zig-test`, `zig-validate`, frontend
  examples, and mobile examples passed. The gate's native-examples step still
  fails on pre-existing example drift in unchanged files (`window_frame`
  switches, removed `clip_content`, and gpu-dashboard assertions).
