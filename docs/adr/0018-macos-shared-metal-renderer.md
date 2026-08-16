---
status: accepted
---

# macOS centralizes Metal submission in one shared render host

ADR 0012 selected an in-process retained Metal renderer from measurements on
an M2 Air, but later cross-hardware work found a workload-scoped Apple GPU
driver cost that the original one-frame probes did not trigger. On a `Mac15,6`
M3 Pro, sustained Metal command submission committed an approximately 95 MiB
graphics working set once per submitting process, independent of presentation;
a device-less process updating IOSurface contents through a plain CALayer did
not commit that arena. Weaver therefore supersedes the in-process decision:
`weaverd` supervises one macOS render host that owns Metal, while each Widget
keeps its isolated QuickJS/runtime process, submits retained render work over
the Native SDK protocol, and presents the returned IOSurface without owning a
Metal device.

The cutover receipt is Weaver commit `c807a12`: eight registered Clock Widgets
measured 32.2–35.8 MiB physical footprint each with zero owned-unmapped
graphics regions, versus a 125.3 MiB in-process baseline containing the 85 MiB
arena per Widget. Across a 31-minute hold, each Widget remained within
±0.3 MiB and the shared host decreased from 168.5 to 158.9 MiB. Killing the
host caused `weaverd` to restart it after one second; retained Widget clients
reconnected and resumed live rendering. These figures are hardware- and
workload-scoped receipts, not universal budgets.

The accepted failure-domain trade is the same as Windows ADR 0010: a render
host crash can blank every GPU Widget briefly, but it does not combine Widget
logic, state, or capabilities. `weaverd` owns recovery, Widgets retain their
frames and reconnect, and the render host remains a separately billed process
in diagnostics. The software path remains the pixel/reference fallback; no
Widget-facing SDK or source contract depends on the platform renderer shape.
