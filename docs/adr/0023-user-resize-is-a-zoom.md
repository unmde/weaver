---
status: proposed
---

# A user resize is a zoom; the zoom is user state beside the position

Every Widget window resizes by its edges and corners, with no developer
opt-in and no SDK surface — the same posture as the whole-surface drag
(ADR 0016). The resize does not hand the Widget more room. It scales the
Widget: the content keeps the manifest `size` as its LOGICAL size, the
aspect ratio is locked, and the user's zoom multiplies into the device
scale. Text, paths and canvases re-rasterize at the new density, so a 2x
clock is as crisp as a clock authored at twice the size; the tree never
relayouts, JS never runs, and `config.size` stays the only size an author
designs for.

Rejected: reflowing into the new size. Widgets are authored in fixed
pixels (`w-[Npx]`, `text-[Npx]`), so a larger window would leave almost
every existing Widget sitting in a corner of empty space, and making it
work would add a window-size API every Widget must then handle. Rejected:
scaling with a render transform on the root. Layout frames feed the
OS drag mirror and the press exclusions (`WM_NCHITTEST`), so a transformed
root would drag where its buttons are drawn. The zoom lives in the
platform host, where one per-window content scale already feeds views,
input, drag regions and GPU surfaces.

The zoom is user state, like the dragged position (ADR 0004, ADR 0011,
ADR 0016). It rides the same per-Widget geometry record
(`<data-root>/geometry/<name-hash>.json`, now `{x, y, scale, zoom}`),
debounced behind the same one-shot timer, never in the manifest and never
in `useStorage`. Records written before resizing existed read as zoom 1.
Deleting the record restores both the anchor and the authored size. A
stale record (monitor unplugged) falls back to the anchor at zoom 1. The
zoom is relative to `config.size`, so it stays meaningful when an author
or a remix changes the size: the Widget opens at the new size times the
user's zoom. This narrows ADR 0003 rather than contradicting it: making a
Widget a different *design* is still a remix of its source; making it
bigger on one desk is placement, like moving it.

## Range

Zoom is clamped to 0.5–4 (`platform.min_content_zoom`/`max_content_zoom`
in the Native SDK) on every path to a new size: the interactive sizing
loop (`WM_SIZING`), and Windows snapping or any `SetWindowPos`
(`WM_WINDOWPOSCHANGING`). Below half size text stops being legible and
the resize band stops being grabbable; past 4x a desk widget has become a
wall poster. Pixel cost grows as the zoom squared.

Receipt (2026-10-21, Windows 11, 100% DPI, `examples/clock` as a
360x132 topmost Widget, software presenter, one process, after 2 s
settle; CPU is process time over the next 10 s):

| zoom | window px | private KiB | CPU ms / 10 s |
|---:|---:|---:|---:|
| 1 | 360x132 | 4212 | 47 |
| 2 | 720x264 | 6392 | 109 |
| 4 | 1440x528 | 13116 | 297 |
| asked 8, clamped to 4 | 1440x528 | 13120 | — |
| asked 0.25, clamped to 0.5 | 180x66 | — | 16 |

The layered-window scratch DIB grows to the largest window and never
shrinks, so private memory stays at the session's peak zoom after a
shrink. That is existing behavior, not new with zoom.

## Platform status

Windows only. A transparent widget is a `WS_POPUP` with no system frame.
The resize band is the draggable surface's edge (the sizing-frame
thickness at the window's DPI, capped at a quarter of the short side);
buttons on the edge keep their press. The canvas child window covers the
whole client area, so it answers `HTTRANSPARENT` in the band and the
parent answers the sizing code, which gives the resize cursor. Without
`WS_THICKFRAME` the system sizing loop (`SC_SIZE`) never starts, so the
host runs the gesture itself: capture on the press, one `SetWindowPos`
per delivered mouse move, shaped by the same rules as `WM_SIZING`
(`dpi_geometry.h`, tested in `dpi_geometry_tests.cpp`).

The zoomed device scale is rounded to a value an f32 carries exactly
(`weaverContentScale`). The runtime takes the scale as an f32 and returns
it with every frame, and the pixel presenter drops a frame drawn at a
scale other than the surface's. DPI scales are exact in f32; an arbitrary
zoom is not, so without the rounding every fractional zoom kept showing
the last frame drawn at an exact one.

The macOS host has no content zoom yet, so Weaver keeps macOS windows
non-resizable: an AppKit resize would reflow fixed-size layouts instead
of scaling them.

## Fixed on the way

The Windows host never refreshed a window's origin after creation, so
every `window_frame_changed` carried the create-time origin. Weaver saw
no move and never wrote a geometry record: ADR 0016's drag persistence
did not work on Windows. `WM_MOVE` now re-reads the origin (the inverse of
the create-time placement) before reporting.
