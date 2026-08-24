# Noro Signal capture evaluation

This is a dogfood pass for `weaver capture`: build a materially different
version of the Noro media player, inspect its fixed-input pixels and semantic
tree, and then drive its controls through the capture action protocol. The
original [`examples/noro-shell`](../examples/noro-shell) is unchanged. The
alternative lives in [`examples/noro-signal`](../examples/noro-signal).

## Outcome

The alternative design works for deterministic visual and semantic capture.
It is a 430 x 248 signal-console layout using the same `time`, `media`, and
`media-transport` contracts as Noro. With the fixed clock and the recorded
media provider frame, `weaver check` passes and capture publishes the expected
track, time, progress, state, and PREV / PAUSE / NEXT controls.

![Working Noro Signal capture](noro-signal-evaluation/noro-signal.png)

The working receipt reported:

- status `ok`, 430 x 248 pixels, and no warnings;
- 118 draw commands and 65 semantic nodes;
- 106,200 pixels different from the transparent clear color;
- no pending providers or images.

Reproduce it with:

```sh
node cli/bin/weaver.js check examples/noro-signal
node cli/bin/weaver.js capture examples/noro-signal \
  --clock 2026-08-24T17:30:00.000Z \
  --provider-fixture test/capture/noro.provider.json \
  --out /tmp/noro-signal.png
```

The pass found two framework breaks and one semantic authoring gap.

## Break 1: a shadow turns a content stack into a leaf

The first design put `shadow-inner` on the 150 x 150 artwork `<stack>`. Capture
still returned `status: "ok"`, 87 draw commands, 63 semantic nodes, no warning,
and the same total non-clear pixel count, but the entire artwork subtree was
missing from the image:

![Stack shadow failure](noro-signal-evaluation/shadow-failure.png)

The semantic snapshot retained the artwork stack and all its children with
correct bounds. Removing only `shadow-inner` restored every child. This is not
a clipping or reference-rasterizer problem:

1. [`sdk/src/class-compiler.ts`](../sdk/src/class-compiler.ts) compiles
   `shadow-inner` into an inset box-shadow.
2. `attachEffects` in [`runtime/src/main.zig`](../runtime/src/main.zig) places
   that shadow in `Widget.immediate_commands`.
3. Both stack branches in
   [`widget_render.zig`](../runtime/native-sdk/src/primitives/canvas/widget_render.zig)
   call `emitImmediateCanvas` and then skip or return before emitting children
   whenever a stack has any immediate command.

That means every `shadow-*` utility can erase the children of a TSX `<stack>`;
`overflow-hidden` only made the initial symptom look like bad compositing.

Implemented framework fix:

- A styled TSX stack projects as a painted panel containing an unstyled stack,
  matching the existing styled row and column projection in `buildNode`. The
  panel owns background, border, radius, and shadow; the inner stack keeps
  overlay layout. This also gives inset shadows an explicit paint order.
- Retained-tree and lowered-budget regressions cover a shadowed stack with
  overlapping children and assert that the shadow, fill, border, and every
  child command are present, including the `shadow-inner` plus rounded clip
  case.
- Noro Signal now uses its original `shadow-inner`; capture retains the artwork
  subtree and reports 31 more draw commands than the failure receipt.

A total non-clear-pixel count cannot catch this class of partial blanking, so a
focused renderer regression is the useful tripwire; raising a global pixel
minimum is not.

## Break 2: media actions published a successful error screen

The semantic driver resolves the PAUSE button correctly. The reproduction file
is [`test/capture/noro-signal.actions`](../test/capture/noro-signal.actions):

```sh
node cli/bin/weaver.js capture examples/noro-signal \
  --clock 2026-08-24T17:30:00.000Z \
  --provider-fixture test/capture/noro.provider.json \
  --action-file test/capture/noro-signal.actions \
  --out /tmp/noro-signal-action.png
```

After the click, the media command rejects with `MediaChannelUnavailable` and
the widget is replaced by its unhandled-promise error panel. This screenshot is
the original false-success artifact retained as the regression receipt:

![Media action failure](noro-signal-evaluation/action-failure.png)

The provider fixture marks the provider client connected so provider hooks can
receive recorded frames, but it opens no socket or pipe. A media command then
reaches `send` in `provider_macos.zig` or `provider_windows.zig`, finds no live
transport, and rejects. Before the dogfood fix, the more dangerous part was the
receipt: it still said
`status: "ok"`, had an empty warnings array, and published the error screen as
a valid result. The post-action tree dropped from 63 nodes and 112 commands to
3 nodes and 6 commands.

The capture-health half is fixed in this PR. Apps can now expose degraded
runtime state through Native's capture seam; Weaver reports the JS engine's
`renderFailed()` state there. The capture driver checks it after actions and
session replay, before rendering or publishing artifacts. The same command now
exits nonzero with `CaptureWidgetFailed`, emits an error receipt, and publishes
no PNG, snapshot, or on-disk receipt.

Remaining framework proposal:

- Extend the provider fixture with deterministic expected media commands and
  acknowledgements. A capture should be able to assert the verb and seek value,
  resolve the SDK promise, and optionally apply recorded provider frames after
  the acknowledgement.
- Refine the current general `CaptureWidgetFailed` result to a transport-specific
  error when no command fixture exists, without relying on the widget's
  unhandled-promise boundary.
- Record driven actions and command outcomes in the receipt so an agent can
  distinguish “the click resolved” from “the side effect succeeded.”

Until that exists, capture can verify the Noro player's media-driven pixels and
button semantics and correctly rejects this action pass, but it cannot verify a
successful media transport side effect.

## Solved: the seek overlay has an accessible name

The seek overlay is a transparent button with no text child. It now declares
`accessibilityLabel="Seek"`, and the snapshot reports
`role=button name="Seek"` so an agent can identify the control without pixels.

Implemented framework fix:

- `accessibilityLabel` is available on buttons and sliders and projects ahead
  of descendant-text fallback. It reuses the measured authored-text storage,
  so the retained `Node` size does not grow.
- `weaver check` rejects controls it can prove unnamed and gives the concrete
  visible-text or `accessibilityLabel` fix. Dynamic/component output remains a
  runtime decision instead of producing a static false positive.

## Baseline observation

The static Noro Signal capture reports one queued frame request. A capture of
the original Noro shell under the same fixture reports the same value, while
the action pass drains it to zero. It is therefore existing capture scheduling
behavior, not a regression introduced by this alternative style. The receipt
surfaces it honestly, so this evaluation does not turn it into a new limit or
silence it.
