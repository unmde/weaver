# QuickJS-NG

- Upstream: https://github.com/quickjs-ng/quickjs
- Version: `v0.15.1`
- Commit: `fd0a0210b7be00957751871e7e01b8291268fc29`
- License: MIT (see `LICENSE`)

M0 embeds only the core engine (`quickjs.c`, `dtoa.c`, `libregexp.c`, and
`libunicode.c`) and their headers. `quickjs-libc.c` is deliberately omitted:
widgets receive Weaver's small `native` global, not QuickJS's OS or std modules.

## Local changes

- Each context queues its own jobs (`JSContext.job_list` in `quickjs.c`).
  Weaver's widgets share one runtime, one context each (ADR 0021); with the
  runtime's single queue, one widget's promise jobs ran in another's turn.
  `JS_EnqueueJob` appends to the job's context; `JS_ExecuteContextJob(ctx)`
  and `JS_IsContextJobPending(ctx)` (`quickjs.h`) run and check one context's
  queue; the runtime-wide `JS_IsJobPending`, `JS_GetPendingJobContext` and
  `JS_ExecutePendingJob` scan contexts in creation order. A context marks
  its queued jobs for the collector and frees them with itself, so a
  dropped context's jobs never outlive it.
- `JS_SwapProgramState(ctx, &state)` (`quickjs.h`): exchanges the
  context's per-program state with the caller's `JSProgramState`: the
  global object and global lexical scope (top-level `let`, `const`,
  `class`), the Error stack settings (`Error.prepareStackTrace`,
  `Error.stackTraceLimit`, which built-in setters store on the context), the
  `Math.random` state and the performance time origin
  (`performance.now()`, and `performance.timeOrigin`, an accessor here so
  each program reads its own). QuickJS reads all of them from the context when
  used, so a program whose state is in the context sees its own, and the
  shared realm's built-ins through its global object's prototype. It also
  drops the context's last-error backtrace, which belongs to the outgoing
  program. Used by Weaver's shared realm: each widget's turn swaps its
  state in. `JS_InitProgramState(ctx, &state)` starts a program's state as
  a new realm would (no stack formatter, a limit of 10, time from now).
  `JS_FreezeRealm(ctx)` freezes every object alive in the runtime: run
  before any program has made one, those are the realm's built-ins,
  including those only a built-in's closure holds, which no property walk
  reaches. It leaves the built-in methods QuickJS makes on first use
  (autoinit properties) unmade, with their flags set frozen; each is made
  frozen, and outside the running program's memory charge, when a program
  first reaches it. Namespace objects (Math, JSON, Reflect, ...) and the
  built-ins written in JavaScript (Array.fromAsync, Iterator.zip,
  Iterator.zipKeyed) are made at once: the latter hold functions in
  closures, and a namespace's property names are atoms a program could
  otherwise create first and keep charged to itself.
- `JS_SetJobTagFunc(rt, func)` (`quickjs.h`): `JS_EnqueueJob` tags each job
  with `func(ctx)`. `JS_ExecuteTaggedJob(ctx, tag)`,
  `JS_IsTaggedJobPending(ctx, tag)` and `JS_FreeTaggedJobs(ctx, tag)` run,
  check and drop only one tag's jobs, so widgets sharing one context (the
  shared realm) each run, and are charged for, only the jobs they queued,
  and a widget's queued jobs go with it. A FinalizationRegistry keeps the
  tag of the program that made it, and its cleanup jobs are queued under
  that tag, not the tag of whichever program's turn ran the collection.
- `JS_SetChargeJobFunc(rt, func)` (`quickjs.h`): `JS_EnqueueJob` calls `func`
  around allocating a job, so a garbage collection in one widget's turn
  charges another widget's queued cleanup job to that widget's heap: a job
  queued under an explicit tag (a FinalizationRegistry cleanup) is charged
  to the program that tag names, any other to its context's program.
- `JS_SetChargeSharedFunc(rt, func)` (`quickjs.h`): QuickJS calls `func`
  around growing a runtime-wide table (atom hash and array, shape hash), so
  the table is charged to the host's heap, not to the widget whose turn grew
  it; otherwise it stayed in that widget's range after the widget was gone,
  and the next widget given the range had less room.
- `JS_SetGCTriggerFunc(rt, func)` (`quickjs.h`): `js_trigger_gc` also
  collects when `func` says so. The runtime-wide threshold follows the total
  of every widget's memory, so one widget could reach its own cap with its
  garbage uncollected while others held a lot.
- `JS_NewContextRaw` unlinks a context from the GC list before freeing it
  when its class table cannot be allocated (upstream left a dangling entry
  that crashed the next collection).
- `JS_AddIntrinsicAToB` adds DOMException to every context. Upstream adds it
  only while the runtime has not registered the class, so with one runtime
  shared by every widget, each realm after the first had no `DOMException`.
- `JS_DropRuntimeException(rt)`: clears the runtime's pending exception when
  a context failed to build and none is left to take it from; the slot is
  shared by every widget.
- `JS_GetDOMExceptionFields(ctx, val, &name, &message)`: reads a
  DOMException's fields without its prototype getters, so diagnostics can
  show one without running code.
- `js_error_set_stackTraceLimit` releases the value it replaces, as
  `js_error_set_prepareStackTrace` already does. Upstream (checked against
  quickjs-ng master, October 2026) keeps every replaced value alive until
  the context is freed, and the context's leak check then fails at teardown.
- `build_backtrace` releases its reference to `Error.prepareStackTrace` when
  the value is not a function (it is ignored then). Upstream released it only
  when it was called, so every error built while a non-function was set kept
  it alive.
