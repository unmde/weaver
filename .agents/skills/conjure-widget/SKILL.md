---
name: conjure-widget
description: Create or change a Weaver desktop widget, then prove its code, pixels, semantics, and requested interactions. Use for widget authoring requests; framework implementation belongs to Weaver maintainer workflows.
---

# Conjure a Weaver widget

Turn the request into one checked and captured widget while the user watches it
take shape on the desktop. Run the CLI as `weaver …`; it is on `PATH` after
`npm run link` in the Weaver repository. Without that link, `npx --no-install
weaver …` works only from inside the repository tree, and from anywhere else
fails with an unrelated npm message about a missing `weaver` package. Start the **Live loop** before the first source edit.
Its audience is the user. It keeps `weaver dev` running in the background so
each valid save can appear while the next edit is underway. Use the **Render
loop** for the agent's deterministic inspection and interaction proof. Get the
first coherent tree on screen early, then inspect each capture while changing
the code. Preserve the requested visual and interaction intent. Keep the widget
honest. Report any part Weaver does not support as a boundary.

## Workflow

1. Inspect the target before editing. For a new widget, run
   `weaver init <path>` from the Weaver repository root; the
   final path segment becomes the starter display name. For an existing widget,
   read its `widget.tsx`, local modules, assets, and licenses without running
   `init` over it.
2. Read the relevant current sections under **Contract routing** before choosing
   elements, hooks, providers, classes, assets, network access, or capabilities.
   When the request uses interaction, changing time, provider data, or replay,
   read [`docs/agent-widget-capture.md`](../../../docs/agent-widget-capture.md) now.
   Define stable capture inputs and a name for each state the request needs so
   every pass renders the same evidence.
3. Start the **Live loop** before the first source edit. Run
   `weaver dev <path>` in a long-lived background session and
   keep its output available and its widget visible to the user. Return to
   authoring once the command reports that it is watching. Keep observing the
   Live loop for the next 10 seconds while authoring continues. Report the
   user-facing live view as available only if that interval ends without a
   `weaver dev ERROR` presentation-health diagnostic. Rebuilds and hot swaps can
   finish while later edits continue. If the current platform cannot run
   Weaver's desktop host or presentation health fails, record the exact failure,
   use the Render loop, and report the user-facing live view as unavailable.
4. Build the first coherent visual slice in `<path>/widget.tsx` with one literal
   default export:
   `export default widget({ ... }, () => <... />);`. Import Weaver APIs from
   `@weaver/sdk`; keep other modules, assets, and their licenses inside the
   widget source root.
5. Enter the **Render loop** as soon as that slice can render, then after each
   added visual region (header, then each content block, then the controls and
   every requested state), and after any edit that changes semantics or
   interaction behavior. Each pass is a step the user can watch land. When the
   user is not watching the desktop, one pass after the last edit is enough.
   The final pass is never optional: no widget is complete until its last PNG
   has been opened and inspected and its snapshot read. Fix what contradicts
   the request or the contract. When a capture shows renderer behavior that
   contradicts the contract, keep the requested design and report a framework
   reproduction (see **Framework failures**); do not redesign the request
   around the surprise.
6. After the final source save, keep the **Live loop** running until it reports
   that save through `weaver dev bundle ready for in-place hot swap` or
   `weaver dev restarted widget: window config changed`. An `OUT OF DATE`
   message keeps this step open until the source is fixed and `weaver dev`
   reports that it caught up. Then keep the process running when the user wants
   the final widget left open. Otherwise, stop it. Use Render loop artifacts for
   every visual, semantic, and interaction receipt.
7. Report the widget path, captured images, behavior exercised, receipt evidence,
   whether the user-facing live view ran or its exact failure, and each remaining
   boundary. Completion requires the requested result, not merely successful
   commands.

## Render loop

For each defined state:

1. Run `weaver check <path>` until it exits successfully. Fix
   every named widget error. Preserve unsupported intent as a reported boundary
   rather than suppressing unknown utilities, undeclared providers or origins,
   invalid assets, or import failures.
2. Run `weaver capture <path> --out <capture-name>.png` with the
   state's fixed clock, semantic actions, provider fixture, or session journal.
3. Open the PNG with the available image-viewing tool. File creation and a green
   receipt are not visual proof. Inspect layout, overlap, clipping, duplication,
   spacing, alignment, contrast, assets, and the requested state at the actual
   widget dimensions. Secondary text on the dark house surface needs at least
   `/45` opacity to read at 1×; dimmer text is the most common thing a first
   capture reveals.
4. Inspect `<capture-name>.snapshot.txt` and `<capture-name>.receipt.json`. The
   receipt must have `status: "ok"`; the semantic tree must expose the intended
   content and controls; every warning and pending item must be understood.
5. Compare the rendered state with the request. Fix the visible and semantic
   mismatches found in that pass, then restart the loop. For interactions, prove
   both the initial state and every requested post-action state.

## Contract routing

[`sdk/CONTRACT.md`](../../../sdk/CONTRACT.md) is authoritative and chronological;
later amendments supersede earlier scheduling notes. Read only the headings the
widget needs:

- For module shape, literal config, hooks, and reload behavior, read **Module
  shape**, **`widget(config, component)`**, **Hooks**, and **Hot swap**.
- For the current element and class set, read **Consolidated v0.4 authoring
  tables**. Read **Bundled fonts**, **Icons**, and the matching styling amendment
  when those branches apply.
- For buttons, sliders, press coordinates, or interaction styles, read **PR 11:
  native interaction states and press events**. Use native `hover:` and
  `pressed:` classes for visual feedback instead of rendering pointer state
  through JavaScript.
- For fetch, storage, CPU, or memory, read the matching M2 heading. For canvas,
  audio, media observation, artwork, or transport, read the matching M3 or
  **Media v2 amendment** heading. Use `fps="display"` for fluid canvas motion,
  a number only for an intentional fixed cadence, and `0` once animation
  settles.

Read the shipped example closest to the request before writing the first
element; they are the house style and each one proves one slice of the
contract on the current runtime:

- [`examples/clock`](../../../examples/clock/widget.tsx): `time` provider,
  layered gradient surface, a canvas that redraws once per render.
- [`examples/system`](../../../examples/system/widget.tsx): `cpu` and `memory`
  providers, provider history in an effect, canvas charts with explicit sizes.
- [`examples/pomodoro`](../../../examples/pomodoro/widget.tsx): `useStorage`,
  `useInterval`, buttons with `hover:`/`pressed:` states, centered labels.
- [`examples/now-playing`](../../../examples/now-playing/widget.tsx): `media`
  provider, conditional artwork, transport capability, click-to-seek.
- [`examples/weather`](../../../examples/weather/widget.tsx): declared
  `origins`, `wfetch` with honest loading and failure states, literal icons
  chosen per branch.
- [`examples/noro-shell`](../../../examples/noro-shell/widget.tsx) and
  [`examples/visualizer`](../../../examples/visualizer/widget.tsx): bundled
  fonts, tiled image assets, and an `audio` signal driving a display-rate
  canvas.

Use `weaver check` as the final authority for statically knowable widget errors.
Do not infer browser DOM, CSS, package, or network behavior that the contract
does not provide.

## Framework failures

A documented unsupported behavior is a widget boundary. A minimized supported
widget that still fails is a framework reproduction. So is invalid widget input
that produces an opaque or internal error instead of an actionable diagnostic.
Preserve the widget, exact command, complete output, and platform. Inside the
Weaver source checkout, follow the root instructions for framework friction.
Outside it, report the reproduction and blocker without weakening the widget or
claiming completion.
