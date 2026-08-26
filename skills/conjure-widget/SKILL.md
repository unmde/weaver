---
name: conjure-widget
description: Create or remix a Weaver desktop widget from a natural-language request and take it through scaffold, TSX editing, static checking, deterministic capture, and optional live desktop preview. Use for "make me a widget", "build a desktop widget", "conjure a clock/status surface", or requests to change an existing Weaver widget.
---

# Conjure a Weaver widget

Turn a natural-language request into one checked `widget.tsx`, capture its
pixels and semantic tree, then launch the real desktop surface only when live
OS behavior needs inspection. Preserve visual intent and keep unsupported
requests loud. Read `sdk/CONTRACT.md` when exact props, provider shapes,
security rules, or the complete utility table matter; it is authoritative.

## Workflow

1. From the Weaver repository root, scaffold with
   `npx --no-install weaver init <path>` unless the directory exists. The final
   path segment becomes the widget's starter display name.
2. Edit `<path>/widget.tsx`. Keep one literal default export:
   `export default widget({ ... }, () => <... />);`. Do not compute config.
3. Keep local images/fonts/licenses inside the widget source root. Reference
   images with relative paths and fonts as `font-[file-stem]`.
4. Run `npx --no-install weaver check <path>` and fix every error. Never
   suppress an unknown utility, undeclared provider/origin, or asset failure.
5. Choose any convenient `<capture-name>`, then run
   `npx --no-install weaver capture <path> --out <capture-name>.png`. Inspect
   the PNG, `<capture-name>.snapshot.txt`, and `<capture-name>.receipt.json`;
   a successful receipt must describe nonblank pixels, the semantic tree, and
   any pending work.
   Use semantic `--action-file` steps for interaction and an explicit
   `--provider-fixture` for every subscribed provider except `time`. See
   `docs/agent-widget-capture.md` for both schemas.
6. Run `npx --no-install weaver dev <path>` only when the request needs live
   desktop placement, OS integration, or interactive visual inspection. Leave
   it running for inspection; saving `widget.tsx` validates and hot-swaps when
   window config is unchanged.
7. Report the captured result, interaction behavior, receipt evidence, and any
   explicit boundary.

## Elements and events

Import from `@weaver/sdk`.

| Element | Purpose and special props |
|---|---|
| `<column>`, `<row>` | flex flow containers |
| `<stack>` | overlay children in paint order; use full-size children for layers |
| `<panel>` | painted box with column children |
| `<text>` | string/number children only |
| `<icon name="…">` / `<icon d="…">` | full-catalog Lucide name or custom SVG path; no children; size with `w-*`/`h-*`, color with `text-*` |
| `<image src="…">` | local source; `fit="cover|contain|stretch"`, optional `tile` |
| `<button>` | required `onPress`; optional `onDoublePress`, `onRightPress` |
| `<slider>` | `value`, positive `max`, `onChange` |
| `<canvas>` | `onFrame(ctx, frame)`, optional `fps`; use `fps="display"` for fluid motion, a number only for an intentional fixed cadence, and `0` once animation settles |

Press callbacks receive `{x,y,u,v}`: local logical pixels plus normalized
0–1 coordinates. A zero-argument `onPress` remains valid. Prefer native
`hover:`/`pressed:` classes for visual feedback; do not round-trip state
through JS.

## Hooks, providers, and network

Available hooks: `useState`, `useRef`, `useEffect`, `useInterval`,
`useStorage`, `useProvider`, and `useMediaTransport`. Providers are `time`,
`cpu`, `memory`, `audio`, and `media`; every provider must also appear in
literal `config.subscribe`. Audio is change/silence-aware.

`useProvider("media")` returns title, artist, album, tri-state `status`,
source-compatible `playing`, display-only `sourceApp`, optional local
`artPath`, and position/duration milliseconds. Keep `<image>.src` required and
render art conditionally:

```tsx
{media.artPath
  ? <image src={media.artPath} fit="cover" />
  : <panel class="bg-zinc-800" />}
```

Media control is separate from observation. Declare literal
`capabilities: ["media-transport"]`, then call `useMediaTransport()` for
`play`, `pause`, `next`, `previous`, and absolute `seek(ms)`. Every verb
returns `Promise<boolean>`: `true` means the OS reported success, `false`
means a valid request was declined, and channel/protocol/timeout failures
reject. Transport-only widgets do not need `subscribe: ["media"]`.

Use `wfetch` only for HTTPS hosts listed exactly in `config.origins`.
`media-transport` is the only supported capability; keep `capabilities`
absent unless those verbs are required. Plain TSX is bundled automatically;
do not add external imports beyond `@weaver/sdk` and widget-local
modules/assets.

## Styling surface

Tailwind semantics apply left-to-right; one scale unit is 4 logical px.
Arbitrary lengths use bracketed pixel forms. Named colors use the Tailwind v4
palette and accept `/NN` alpha.

- Spacing: `p/px/py/pt/pr/pb/pl-*`, `m/mx/my/mt/mr/mb/ml-*` (negative margins
  allowed), `gap-*`.
- Sizing: `w-*`, `h-*`, `size-*`, full/fractions/auto, min/max bounds, and
  `aspect-square|video|[W/H]|auto`.
- Flex: `items-*`, `justify-start|center|end|between|around|evenly`, numeric
  `grow-*`, `shrink|shrink-0`, `self-*`, `flex-wrap|flex-nowrap`.
- Surfaces: uniform/directional/per-corner `rounded-*`, `border` widths/colors,
  `bg-*`, `opacity-*`, outset/inset/arbitrary `shadow-*`, and `overflow-hidden`.
- Text: named/arbitrary sizes, five `font-*` weights, `font-sans|mono|[stem]`,
  alignment, `leading-*`, `tracking-*`, `line-clamp-*`, `truncate`,
  `tabular-nums`, and `text-shadow-*`.
- Interaction: only `hover:` and `pressed:` + `bg-<color>`, `text-<color>`,
  `opacity-N`, `border-<color>`, or `shadow-*`. Pressed wins over hover.

For a non-pressable child inside a `<button>` or `<slider>`, `hover:` and
`pressed:` automatically follow the nearest pressable ancestor; do not add a
`group` class. A state variant outside any pressable ancestor fails
`weaver check` with `NearestPressableAncestor`.

Use `<stack>` plus ordinary size/alignment classes for overlays. Apply
`rounded-*` directly to images for masks; `tile` repeats at natural size and
overrides fit geometry. Pair `overflow-hidden` with radii to clip descendants.

Unknown utilities are errors. Gradients, transforms, transitions, animations,
blur/backdrop blur, absolute positioning, grid, scrolling, and responsive
variants are not in this surface; redesign with supported primitives or state
the boundary instead of inventing a no-op.

## Asset bounds

- Bundle at most two parseable TrueType-outline faces, each at most 512 KiB.
  Path-backed icons consume no font slot.
- Font family stems must match `font-[stem]`; keep adjacent license files.
- Images remain widget-local. Remote/provider image URLs are unsupported;
  media artwork arrives only as the optional host-cache local `artPath`.
