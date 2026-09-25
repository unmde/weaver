# Windows DPI scaling contract and verification

Status: complete on 2026-07-14. The implementation, deterministic
production-path scale transitions, real current-monitor smoke, shared-renderer
failure/recovery checks, and repository gates are green. The machine-readable
evidence and captures are in [`dpi-evidence`](dpi-evidence).

## Coordinate contract

One DIP is 1/96 inch. Public widget geometry, layout, view frames, accumulated
nested origins, anchors and anchor offsets, dirty rectangles, pointer
coordinates, canvas packets, and protocol logical geometry are DIPs. These
values remain stable when a window changes monitor.

Every top-level HWND owns one effective DPI and device scale:

```text
scale = effective window DPI / 96
```

After HWND creation the DPI comes from that window, never from a cached system
DPI. A child inherits its owning top-level window's scale. A real
`WM_DPICHANGED`, a destination-frame change, or the diagnostic transition seam
creates a new nonzero geometry generation. Create-time placement resolves the
target monitor first and uses that monitor's effective DPI.

Logical rectangles become physical rectangles by rounding edges, not origins
and extents:

```text
left_px   = round(left_dip * scale)
top_px    = round(top_dip * scale)
right_px  = round((left_dip + width_dip) * scale)
bottom_px = round((top_dip + height_dip) * scale)
width_px  = right_px - left_px
height_px = bottom_px - top_px
```

Nested logical origins are accumulated before this conversion. This preserves
shared edges at fractional coordinates and prevents seams, overlaps, and
one-pixel drift. `dpi_geometry.h` is the single C++ implementation used by
window/view geometry, presentation, protocol validation, and the tests.

Input crosses the boundary once: child-client physical coordinates are divided
by the current owning-window scale and emitted as logical DIPs. Pointer, wheel,
drag, right/bottom-edge hit testing, native accessibility bounds, and IME/caret
placement therefore use the same current geometry rather than a stale global
scale.

Dirty rectangles remain logical through layout and packet generation. At the
upload/present boundary their start edges use `floor`, end edges use `ceil`,
and all edges clamp to the exact physical texture. Empty boxes are discarded.

## Windows boundaries

| Boundary | Input unit | Output/owned unit |
|---|---|---|
| Widget API, layout, view tree | DIP | DIP |
| Target-monitor anchor placement | physical work-area edges plus DIP size/offset | physical virtual-desktop rectangle |
| `SetWindowPos`, client/child HWNDs | rounded physical edges | physical pixels |
| GPU surface event and render packet | logical DIP geometry plus authoritative scale/generation | logical packet coordinates |
| Shared-renderer texture | explicit source extent | physical pixels |
| DirectComposition child target | explicit clip and identity transform | physical child-client rectangle |
| Layered/software bitmap and `UpdateLayeredWindow` | exact child destination inside top-level client | physical pixels |
| Pointer/wheel/drag input | physical child-client pixels | DIP |
| Retained dirty upload | DIP dirty rectangle | outward-rounded, clamped physical box |

The runtime manifest still exposes `monitor: "primary"`; this work does not
invent a monitor-selection API. The existing contract is now truthful:
`MonitorFromPoint`/`GetMonitorInfo` supplies the primary monitor's physical work
area and `GetDpiForMonitor` supplies that target's effective DPI. The physical
work-area origin is never scaled, so negative virtual-desktop coordinates are
preserved. All four corners subtract or add DIP offsets after converting those
distances at the target scale. Taskbar exclusions remain those of the selected
monitor's `rcWork`.

Standard, hidden-titlebar, chromeless, transparent layered, and
no-redirection/shared-GPU windows all pass through the same content-frame edge
conversion. The non-client adjustment is applied only where a style owns OS
chrome. `WM_DPICHANGED` accepts the suggested physical outer rectangle, keeps
the authored logical content size, updates descendants from accumulated DIP
frames, and does not recreate the top-level HWND.

## Presentation ownership

The shared renderer has two explicit geometries:

1. The source texture is an exact physical pixel extent.
2. The destination is the GPU view's logical frame and its already rounded
   physical edges inside the owning top-level client.

DirectComposition is bound to the actual `gpu_surface` child HWND. That child
client rectangle naturally owns destination position, clipping, and z-order.
The root visual still explicitly installs offset `(0,0)`, an identity 2D
transform, and a clip equal to the physical child-client extent. There is no
inverse-scale or stretch compensation. The imported surface is rebound only
when its shared handle changes; a same-generation frame reuses the visual.

The renderer allocates the exact protocol source extent. Packet coordinates
remain DIPs and are rasterized at `device_scale`. Retained textures and shared
destination textures must have identical physical dimensions; protocol
validation rejects disagreement. Retained uploads use the same dirty-box
conversion as immediate presentation.

The software path allocates a top-level physical BGRA bitmap, copies the exact
physical GPU-view buffer into the rounded child destination, and passes the
top-level physical client size to `UpdateLayeredWindow`. A destination change
clears the old bounds before the full repaint. Rounded corners and alpha cover
the same destination edges as shared GPU presentation, so demotion does not
move or resize content.

On a scale or destination change the host updates cached edges, advances the
generation, emits one resize, invalidates runtime texture/baseline state, and
forces one full repaint. The renderer recreates a surface only if the physical
extent changed, then the client rebinds the replacement handle and commits the
visual. Normal pacing resumes afterward. No per-frame DPI query, allocation,
geometry message, visual commit, or surface recreation was added.

## Renderer protocol v3

Protocol version 3 adds a fixed `WeaverRendererHello`/reply handshake so
version skew is rejected before either process reads a differently sized frame.
Frames use these unambiguous fields:

| Field | Unit/meaning |
|---|---|
| `logical_surface_width_dip`, `logical_surface_height_dip` | authored logical raster extent in DIPs |
| `device_scale` | owning top-level window DPI divided by 96 |
| `destination_*_dip` | destination view frame in the top-level logical coordinate space |
| `destination_left_px` ... `destination_bottom_px` | once-rounded physical destination edges |
| `source_texture_width_px`, `source_texture_height_px` | exact physical shared-surface extent, equal to destination edge differences |
| `geometry_generation` | nonzero lifecycle generation |
| `retained_width`, `retained_height` | physical pixels; must exactly match the source texture when retained content is present |
| `retained_dirty_rects` | logical DIPs, converted outward at upload |

Both sides validate magic, version, structure sizes, finite values, scale and
surface bounds, edge ordering, exact edge/extent agreement, retained agreement,
packet limits, and dirty-rectangle counts. A stale v2 peer receives/observes a
clean version-mismatch failure instead of framing deadlock.

## Deterministic and live verification

`test/fixtures/dpi-diagnostic` is a transparent 480 x 320 DIP fixture with a
retained card, immediate canvas, four colored edge markers and corners, content
crossing the retained/immediate seam, and right/bottom clickable targets.
`scripts/verify-dpi.ps1` launches the real host, widget runtime, named pipe,
renderer process, duplicated surface handle, and DirectComposition visual.

The machine exposed one 2560 x 1440 monitor at 96 DPI. The real current-monitor
smoke therefore ran at 100%. The other scales use a test-only message enabled
only by `WEAVER_DPI_DIAGNOSTIC=1`; it injects effective DPI and suggested
physical destination geometry into the same production transition,
resize/repaint, renderer, handle-import, and DirectComposition code paths. It
is not an arithmetic-only renderer.

### DPI matrix

All 186 assertions passed. Every capture passed all four edge and corner pixel
probes, the retained/immediate seam probe, exact client/surface extent checks,
right/bottom input checks, GPU/software logical-occupancy parity, and bounded
surface lifecycle checks.

| Scale | DPI | Expected/actual physical client and texture | GPU PID / HWND | Right-edge logical x | Bottom-edge logical y |
|---:|---:|---:|---|---:|---:|
| 1.00 | 96 | 480 x 320 | 49160 / `0x1c3c1186` | 478.0000 | 318.0000 |
| 1.25 | 120 | 600 x 400 | 49160 / `0x1c3c1186` | 478.4000 | 318.4000 |
| 1.50 | 144 | 720 x 480 | 49160 / `0x1c3c1186` | 478.6667 | 318.6667 |
| 1.75 | 168 | 840 x 560 | 49160 / `0x1c3c1186` | 478.8571 | 318.8571 |
| 2.00 | 192 | 960 x 640 | 49160 / `0x1c3c1186` | 479.0000 | 319.0000 |

The forced-software matrix used PID 54908 and HWND `0x8c41328` throughout and
matched all five extents and logical occupancy checks. The real monitor smoke
used PID 39216, HWND `0x1e409de`, DPI 96, and 480 x 320 physical pixels. The
transition log shows generations 1 through 11 and exact root-client,
child-client, destination-edge, texture, and retained dimensions. The GPU
process handle count was 234 before and after the transition matrix. No second
surface survived a resize and no continuous recreation was observed.

Representative captures:

- GPU: [100%](dpi-evidence/gpu-100.png), [125%](dpi-evidence/gpu-125.png),
  [150%](dpi-evidence/gpu-150.png), [175%](dpi-evidence/gpu-175.png),
  [200%](dpi-evidence/gpu-200.png)
- Software: [100%](dpi-evidence/software-100.png),
  [125%](dpi-evidence/software-125.png),
  [150%](dpi-evidence/software-150.png),
  [175%](dpi-evidence/software-175.png),
  [200%](dpi-evidence/software-200.png)
- [Real current-monitor GPU smoke](dpi-evidence/current-monitor-gpu.png)
- [Machine-readable assertions](dpi-evidence/dpi-results.json) and
  [geometry/input lifecycle log](dpi-evidence/gpu-dpi-events.txt)

The built ReleaseFast `weaver-widget.exe` manifest was extracted with the
Windows SDK `mt.exe`; it contains `true/pm` and `PerMonitorV2, PerMonitor`.
Runtime logs independently reported `awareness=per-monitor-v2`, OS window DPI
96, effective window DPI 96, and scale 1.0 in the real smoke. See the
[extracted manifest](dpi-evidence/weaver-widget.manifest.xml) and
[current-monitor log](dpi-evidence/current-monitor-dpi-events.txt).

### Lifecycle, idle, and performance

`scripts/verify-runtime-regressions.ps1` passed renderer kill to software
demotion, renderer recovery/promotion, Win+D survival, state-preserving dev hot
swap, forced-software Clock, audio-fed shared-GPU Visualizer, true `fps={0}`
idle, and clean shutdown. The mixed widget stayed PID 62176 / HWND
`0x45309de` across DPI transition, demotion, recovery, and Win+D. Renderer PID
changed 19216 -> 17888 during forced recovery while widget identity remained
stable. Hot swap stayed PID 63040 / HWND `0x2a109d2`. The idle renderer log
stayed exactly 209 bytes before and after the sample. The production renderer's
300-present samples measured 59.441 fps at 100% (5,047 ms) and 60.000 fps at
150% (5,000 ms).

| ReleaseFast sample (10 seconds) | CPU, one core | Private bytes | Handles |
|---|---:|---:|---:|
| mixed widget, 100% | 5.463% | 17.449 MiB | 234 |
| shared renderer, 100% | 2.182% | 54.879 MiB | 456 |
| mixed widget, 150% | 7.795% | 21.258 MiB | 236 |
| shared renderer, 150% | 2.495% | 57.750 MiB | 458 |
| active Visualizer | 5.618% | 18.168 MiB | 238 |
| `fps={0}` widget | 0.000% | 17.426 MiB | 234 |
| `fps={0}` renderer | 0.000% | 54.148 MiB | 446 |

The 100% control remains in the same or better class than M4b's 8.03% widget
and 3.27% renderer measurements. At 150%, widget raster work rises with pixel
count while renderer control-flow CPU remains flat. Geometry logs occur only at
lifecycle changes. See [regression results](dpi-evidence/runtime-regression-results.json),
[demotion](dpi-evidence/renderer-demotion-software.png),
[recovery](dpi-evidence/renderer-recovery-gpu.png), and
[hot swap](dpi-evidence/hot-swap-preserved.png).

## Automated test matrix

Pure geometry tests cover 1.0, 1.25, 1.5, 1.75, and 2.0 scales; integer and
fractional origins/extents; nested origins; negative desktop coordinates; all
anchor corners; edge rounding; input conversion; outward dirty conversion and
clamping; surface reuse; generation transitions; retained size agreement;
protocol validation/version mismatch; and GPU/software parity. The broader
platform/runtime/canvas suites cover native child creation/update, window
styles, resize, presentation, input, hot swap, and failure behavior.

Final commands and exit codes:

| Repository | Command | Exit |
|---|---|---:|
| Native SDK | `zig build test-windows-dpi-geometry` | 0 |
| Native SDK | `zig build test` | 0 |
| Native SDK | `zig build test -Dwidget-profile=true` | 0 |
| Native SDK | `zig build test-canvas` | 0 |
| Native SDK | `zig build test-desktop-canvas-frame` | 0 |
| Native SDK | `zig build test-desktop-platform` | 0 |
| Native SDK | `zig build test-desktop-runtime-core` | 0 |
| Native SDK | `zig build test-desktop-canvas-widget` | 0 |
| Native SDK | `scripts/gate.sh fast ce3e42df` | 0 |
| Weaver | `npm test` | 0 |
| Weaver | `npm run typecheck` | 0 |
| Weaver | `npm run build` | 0 |
| Weaver runtime | `zig build test -Doptimize=ReleaseFast` | 0 |
| Weaver runtime | `zig build -Doptimize=ReleaseFast` | 0 |
| Weaver host | `zig build test -Doptimize=ReleaseFast` | 0 |
| Weaver host | `zig build -Doptimize=ReleaseFast` | 0 |
| Weaver renderer | `zig build -Doptimize=ReleaseFast` | 0 |
| Live DPI | `powershell -File scripts/verify-dpi.ps1` | 0 (186/186) |
| Live regressions | `& .\scripts\verify-runtime-regressions.ps1` | 0 (15/15) |

On Windows, the two broad Native SDK commands require Git's POSIX utilities on
`PATH`; the recorded runs prepended
`E:\Projects\native-spike\zig\zig-x86_64-windows-0.16.0` and
`C:\Program Files\Git\usr\bin`. The gate ran through Git Bash with the same
Zig toolchain. All commands used the isolated worktree and pushed nothing.
