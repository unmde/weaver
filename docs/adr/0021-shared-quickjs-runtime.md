---
status: proposed
---

# Widgets share one QuickJS runtime, each in its own realm

ADR 0020 put every Widget in one host process but kept a QuickJS runtime per
Widget, and named the engine as the next per-Widget cost. Dara chose
(2026-10-15) to share the runtime and keep a realm per Widget: one
`JSRuntime` for the process, one `JSContext` (built-ins, globals) per Widget.
Sharing the realm as well was set aside: Widgets could then reach each other's
globals.

A shared runtime alone did not save memory. QuickJS's per-runtime malloc
accounting cannot cap one realm, so every Widget's allocations go through a
heap (`runtime/src/js_heap.zig`) that gives each Widget its own reserved
address range: a pointer names its owner, so the cap stays exact (32 MiB, as
before) and a Widget's bytes are countable on their own. Small blocks come
from 1 KiB granules with their own free lists, and a granule goes back to the
range when its last block is freed (each size keeps one empty granule, so
allocating and freeing at the edge does not churn). But compiling a bundle
leaves thousands of freed parser blocks between the Widget's long-lived
ones, and those pages stay resident: a clock Widget held 270 KiB live in
473 KiB committed. So
bundles compile in the shared host range, which every compile reuses, and
only the finished bytecode is copied into the Widget's range (QuickJS's own
bytecode writer and reader, in memory; no bytecode is ever read from disk).
The Widget now commits 311 KiB for the same 270 KiB.

| `examples/clock`, Windows, private working set | per-Widget runtime | shared runtime |
|---|---:|---:|
| one Widget, no `weaverd` | 4.14–4.16 MiB | 3.97 MiB |
| ten Widgets in one host, no `weaverd` | 11.14–11.30 MiB | 9.56 MiB |
| ten Widgets under `weaverd`: host | 11.30–11.37 MiB | 9.61–9.64 MiB |
| ten Widgets under `weaverd`: host CPU, six 60 s windows | 0.16–0.55%, mean 0.38% | 0.10–0.39%, mean 0.24% |

Same session, alternating builds, `E:\w\rm-bench\multi-measure.ps1` and
`weaver-measure.ps1`.

QuickJS keeps its promise job queue in the runtime. Shared, that queue
would run one Widget's jobs in another Widget's turn, on the wrong budget,
heap and log. So each realm keeps its own queue, a small change to the
vendored QuickJS (`runtime/vendor/quickjs-ng/VENDOR.md`): a Widget's jobs run
only in its own turns, as they did with a runtime each. The context owns
its queue like its other fields, so a destroyed Widget's leftover jobs are
collected with its realm. The pending-exception slot is the runtime's too:
every turn and every teardown leaves it empty, logging whatever widget code
left in it, so one Widget's exception neither reaches another's error
report nor keeps a destroyed realm alive.

## What this gives up

- **A QuickJS fault reaches every Widget.** A bug inside the engine (not a
  Widget's exception) can now corrupt state shared by every realm. The host
  already shares one process and thread (ADR 0020), so this widens nothing
  the crash breadcrumb and restart don't already cover.
- **Collection is runtime-wide.** A garbage collection walks every realm,
  so one Widget's churn costs its neighbours' objects a visit. Ten clocks
  over 60 s still measured less CPU than ten runtimes.
- **Cleanup callbacks wait for their Widget.** A collection in one Widget's
  turn can find another Widget's garbage; that Widget's
  `FinalizationRegistry` callback then waits in its queue for its next
  turn. The language promises nothing about when those callbacks run.
- **Shared atoms are charged to whoever made them.** Interned strings
  created while compiling land in the host range. Ones a Widget creates at
  run time land in its range and can outlive it when another Widget uses
  the same string; a later Widget reusing that range sees those few bytes
  as taken.

The memory cap, the interrupt budget and exceptions stay per Widget: a
Widget that fills its range gets `InternalError: out of memory` while its
neighbours keep running (`runtime/src/js_engine.zig` tests this).
