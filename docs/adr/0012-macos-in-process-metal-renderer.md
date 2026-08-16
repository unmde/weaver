---
status: superseded by ADR-0018
---

# macOS renders healthy Widgets in-process through Metal; software remains the reference and fallback

The macOS M5 bakeoff measured complete production Widget processes, not an
isolated renderer: at ten static Clocks, software, retained packet/Metal, and
Metal composite cost 931, 944, and 990 MB physical footprint respectively,
while the retained and composite paths both used about 2.7% of one core versus
6.7% for software. The 60 Hz synthetic made the decisive trade: one Widget
used 99.0% software, 34.7% retained packet/Metal, or 23.9% Metal composite;
three used 302.9%, 74.0%, or 61.1%. Decision for PR 07: every healthy macOS
Widget uses the in-process binary-packet, retained/damage-aware Metal composite
architecture; CPU raster plus bounded dirty texture upload remains the
pixel/API reference and live fallback. Backend choice is not workload-adaptive
and no shared renderer service is required. The implementation will ship a
precompiled metallib, cache the device/queue/immutable pipelines and sampler at
process lifetime, retain canvas and command textures, bound/reuse upload and
scratch resources, park clean static surfaces, and keep verification readbacks
strictly diagnostic. “Metal composite” is honest: commands that are not native
quads are still rasterized with Core Graphics before Metal composition until a
later measured change replaces them.

The rejected always-software path loses a whole core per 60 Hz Widget. The
rejected retained-packet-only default saves roughly 3–6 MB per active Widget
but spends 18–31% more CPU on the headline animated workload. An adaptive
switch would preserve that small static memory delta at the cost of two live
backings, transition rules, and more recovery states; the static/mixed CPU
results do not earn that complexity. A shared Metal/IOSurface service is also
rejected: ten-process scaling is dominated by each crash-isolated QuickJS +
AppKit runtime at roughly 93–103 MB and 37 descriptors per Widget, while the
shareable Metal/IOSurface portion is only single-digit to low-teens MiB per
process. A service would add its own process, IPC copies/synchronization, and
fallback/window/input failure modes without removing the per-Widget AppKit
presenter. A shared window/compositor owner is still more expensive in failure
scope and platform machinery. This is macOS-specific and does not amend the
measured Windows shared-D3D decision in ADR 0010. PR 06 records the decision
and evidence only; it does not change the production default.
