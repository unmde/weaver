# macOS Visualizer rendering cost — 2026-07-31

Recorded on an Apple M2 running macOS 26.5.1 (25F80), arm64, Zig 0.16.0,
and Node 23.11.0. Every workload used two production Widget processes, one
host-owned deterministic 48 kHz mono audio source, the production provider
pipe/FFT/fan-out, Metal presentation, and ten one-second cumulative-CPU
samples from `scripts/macos-audio-cost.py`. CPU is percent of one core summed
across `weaverd` and both Widget processes. WindowServer is recorded beside
each run as the system-wide background control.

## Pixel-aligned translucent rectangle quads

Both variants used the Native renderer with direct premultiplied-alpha flat
quads. The control read the fractional-width Visualizer from Weaver
`4e97a4a`; the treatment changed only its bar geometry to integral points.

| Variant | Mean CPU | Per-process CPU: host / widget / widget | WindowServer | Frames | Physical footprint | RSS |
|---|---:|---:|---:|---:|---:|---:|
| Fractional bar geometry | 16.316% | 0.685% / 7.719% / 7.913% | 42.981% | 293 | 54,589,099.2 B | 231,324,057.6 B |
| Pixel-aligned bar geometry | 13.225% | 0.784% / 6.466% / 5.976% | 43.693% | 293 | 53,058,833.6 B | 230,214,860.8 B |

The aligned geometry reduced the complete active workload by **18.9%** under
adjacent, equally busy WindowServer conditions. A five-second process sample
of the aligned treatment contained zero
`rasterCacheBuildEntryForCommand`/`compositeScratchTextureForCommand` frames;
the fractional control entered that CPU-raster/texture-upload path.

Raw total-CPU samples:

- fractional: `17.631200, 18.661772, 16.644116, 14.726483, 12.670263, 14.578599, 16.590786, 17.550643, 18.518812, 15.586492`
- aligned: `14.771535, 11.759939, 14.650708, 15.633389, 13.715161, 12.719057, 13.761920, 10.797748, 11.755784, 12.685285`

## Retained Canvas update versus full view rebuild

These runs were immediately adjacent at Weaver `5c4dbba`, with identical
aligned Visualizer source and renderer. The full-rebuild control was built
from the same working tree with only the two opt-in `WidgetApp` entries
(`view_revision` and `project_update`) removed. The treatment enabled them and
used the batched retained-immediate-command update. Both were ReleaseFast with
the normal production trace configuration.

| Variant | Mean CPU | Per-process CPU: host / widget / widget | WindowServer | Frames | Physical footprint | RSS |
|---|---:|---:|---:|---:|---:|---:|
| Full TSX + layout rebuild per Canvas frame | 6.425% | 0.778% / 2.728% / 2.920% | 2.142% | 264 | 47,915,896.0 B | 224,200,294.4 B |
| Retained Canvas command update | 3.597% | 0.778% / 1.458% / 1.361% | 2.431% | 264 | 43,875,553.6 B | 222,919,065.6 B |

The retained update reduced the complete workload by **44.0%** and the two
Widget processes' combined CPU by **50.1%**, without dropping provider frames.
The treatment sample contained no `UiApp.rebuild` or raster-cache build frame;
the remaining visible loop cost is primarily the JS Canvas callback/command
decode, display-list diff, tracing, and presentation.

Raw total-CPU samples:

- full rebuild: `5.868174, 7.737061, 6.794842, 6.864278, 4.869452, 6.811353, 5.816060, 6.839024, 6.832127, 5.822501`
- retained update: `2.932559, 3.889978, 3.885490, 3.904691, 3.888527, 2.906125, 3.872326, 3.881980, 3.890509, 2.918751`

## Widget trace default

After the retained-update run, the same treatment was rebuilt
with `-Dtrace=off`. The ordinary Native SDK `events` mode writes every runtime
event to `native-sdk.jsonl`; for a Canvas Widget that means an open/stat/
append/close cycle at every completion frame. Weaver already has a dedicated
per-widget diagnostic log, and explicit profiling builds retain
`-Dtrace=events|runtime|all`, so the production Widget default now omits this
continuous event journal.

| Variant | Mean CPU | Per-process CPU: host / widget / widget | WindowServer | Frames | Physical footprint | RSS |
|---|---:|---:|---:|---:|---:|---:|
| Retained update, event trace | 3.597% | 0.778% / 1.458% / 1.361% | 2.431% | 264 | 43,875,553.6 B | 222,919,065.6 B |
| Retained update, trace off | 2.818% | 0.875% / 0.972% / 0.972% | 2.430% | 268 | 44,042,716.0 B | 223,266,406.4 B |

Disabling the continuous event journal reduced total CPU by **21.7%** and the
two Widget processes' combined CPU by **31.0%**, while the treatment delivered
four more frames. Memory differences at this size are run noise, not a claim.

Raw trace-off total-CPU samples:

- `2.900773, 2.935771, 1.941347, 2.905832, 2.919207, 2.927449, 2.907781, 2.920701, 2.916573, 2.904058`

Do not compare the absolute CPU values between the two sections: the first
pair ran while WindowServer was consuming about 43% of a core and the later
runs while it consumed about 2%. The within-section adjacent A/B comparisons
are the receipts.
