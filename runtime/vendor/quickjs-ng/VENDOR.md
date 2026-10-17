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
- `JS_SetChargeJobFunc(rt, func)` (`quickjs.h`): `JS_EnqueueJob` calls `func`
  around allocating a job, so a garbage collection in one widget's turn
  charges another widget's queued cleanup job to that widget's heap.
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
- `JS_AddLazyIntrinsicTypedArrays(ctx)` and `JS_AddLazyIntrinsicAToB(ctx)`
  (`quickjs.h`): a widget realm builds the typed array family (ArrayBuffer,
  SharedArrayBuffer, the typed arrays, DataView, Atomics) and the base64 one
  (atob, btoa, DOMException) the first time widget code touches one of their
  globals, saving about 21 KiB in a realm that uses neither. Each global is
  a QuickJS autoinit property with the new id `JS_AUTOINIT_ID_LAZY_GLOBAL`,
  so JavaScript sees the data property it will become: reading, assigning,
  describing or redefining it builds the family first, and deleting it
  does not. The ids now take three low bits of the realm pointer (mask
  `JS_AUTOINIT_ID_MASK`), not two.
  - A family is built once per realm, into its own object
    (`JSContext.lazy_family`, marked and freed with the context), never onto
    the global object, and its values are read from there. So building it
    neither reads nor replaces the family's other globals: a global the
    widget deleted, redefined or made non-configurable stays as the widget
    left it. For the same reason `js_uint8array_funcs_init` takes the
    Uint8Array constructor it is building, not the global.
  - `TypedArray.prototype.toString` is `JSContext.array_proto_to_string`,
    Array.prototype.toString as `JS_AddIntrinsicBaseObjects` made it, not
    the property's current value (a widget may have replaced it before the
    family is built).
  - A build that fails (out of memory) frees what it built, resets the
    family's class prototypes and leaves the global lazy, so the next use
    builds it again; `JS_AutoInitProperty` keeps a property of this id
    autoinit when its init fails (other ids still become undefined). The
    family's own autoinit values (atob, btoa, Atomics) are read during the
    build, so their failure is the build's too. A build that returns
    success with an exception pending counts as failed:
    `JS_SetPropertyFunctionList` does not report a failed definition.
  - The DOMException setup (`js_add_domexception`, behind
    `JS_AddIntrinsicDOMException`) and `JS_AddIntrinsicAToB` check every
    allocation; upstream ignored their failures.
  - `JS_AddIntrinsicTypedArrays` and `JS_AddIntrinsicAToB` are unchanged for
    `JS_NewContext`: they build the same family onto the global object.
  - Before its family is built, C code that makes an ArrayBuffer or a typed
    array in that realm (`JS_NewArrayBuffer`, `JS_NewTypedArray`) gets one
    with a null prototype, and `JS_ThrowDOMException` asserts until some
    realm has built DOMException. Weaver calls none of them.
