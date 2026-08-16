# @weaver/sdk — public API contract (v0.2 — M1 surface + the M2 amendment at the end)

This is the authoring contract for Weaver widgets. It is the product's face:
agents learn Weaver from this file. Implementation must match it exactly;
anything not implementable in M1 must fail at `weaver check` with a clear
"arrives in M2" message — never silently no-op.

Design invariants (from ADRs 0001/0003/0005/0009):
- One TSX module per widget; `widget()` is the default export.
- Styling is Tailwind-shaped `class` strings; arbitrary values allowed;
  unknown utilities are check-time errors with fix-its.
- Idle-zero: no state change → no ops → no repaint. The SDK never polls.
- The reconciler runs in JS and emits retained-tree ops (never full frames).
- `weaver check` estimates the exported widget's lowered Native tree through
  local components and one level of relative imports, taking the maximum across
  conditional JSX returns and counting statically evident implicit text nodes.
  Dynamic collections and unresolved component output remain subject to the
  authoritative Native runtime node/depth limits.

## Module shape

```tsx
import { widget, useProvider, useState } from "@weaver/sdk";

export default widget({
  name: "Clock",
  size: [240, 110],
  anchor: { corner: "top-right", offset: [24, 24] },
}, () => {
  const time = useProvider("time");
  return (
    <column class="p-4 gap-1 bg-[#11141c]/86 rounded-2xl">
      <row class="items-baseline gap-2">
        <text class="text-3xl font-light">{time.hh}:{time.mm}</text>
        <text class="text-sm opacity-70">{time.ss}</text>
      </row>
      <text class="text-xs opacity-60">{time.weekday}, {time.month} {time.day}</text>
    </column>
  );
});
```

## `widget(config, component)`

```ts
export function widget(config: WidgetConfig, component: () => JSX.Element): WidgetModule;

export interface WidgetConfig {
  name: string;
  size: [width: number, height: number];          // logical px
  anchor?: {
    monitor?: "primary";                          // M1: primary only
    corner: "top-left" | "top-right" | "bottom-left" | "bottom-right";
    offset?: [x: number, y: number];              // default [24, 24]
  };
  layer?: "desktop" | "normal" | "topmost";       // default "desktop"
  clickThrough?: boolean;                         // default false
  subscribe?: ("time")[];                         // M1: "time" only; full list M2
  origins?: string[];                             // declared API hosts; M1: parsed+validated, fetch arrives M2
  capabilities?: never[];                         // M1: must be empty; ladder arrives M2
}
```

`weaver check` validates config statically (it is extracted from the default
export at bundle time; config must be a literal object — no computed values).

`anchor` is the widget's placement until the user drags it. Every widget is
draggable by its whole surface (buttons and sliders keep their interactions);
the dragged position is user state stored outside the widget — it survives
restarts and reinstalls, outranks `anchor`, and falls back to `anchor` when it
goes stale (e.g. its monitor was unplugged). Widget code cannot read or write
it (ADR 0016).

## Hooks

```ts
export function useState<T>(initial: T | (() => T)): [T, (next: T | ((prev: T) => T)) => void];
export function useRef<T>(initial: T): { current: T };
export function useEffect(fn: () => void | (() => void), deps?: unknown[]): void;
export function useInterval(fn: () => void, ms: number): void;   // native-clocked, auto-cleaned
export function useProvider(name: "time"): TimeData;             // M1: "time" only
export function useProviderSignal(name: "time"): Signal<TimeData>;

export interface Signal<T> {
  readonly value: T;
  subscribe(listener: (value: T) => void): () => void;
  map<U>(project: (value: T) => U): Signal<U>;
}

export interface TimeData {   // updates once per second while subscribed
  hh: string; mm: string; ss: string;             // zero-padded locale-agnostic
  weekday: string; month: string;                 // short names ("Sun", "Jul")
  day: number; year: number;
  epochMs: number;
}
```

Rules: hooks follow React's rules (top level, stable order). `useProvider`
requires the provider in `config.subscribe` — checked at `weaver check`,
error: `useProvider("time") requires subscribe: ["time"] in the widget config`.
`useProviderSignal` carries the same requirement and names the hook in its
error: `useProviderSignal("audio") requires subscribe: ["audio"] in the widget
config`.

`useProvider` is the declarative path: each value schedules a component render.
`useProviderSignal` is the high-frequency retained path: it updates `.value`
without rendering the component. A canvas samples `.value` inside `onFrame`.
A `<text>` may contain one mapped signal, which updates only that native text
node; format the whole label in `signal.map(...)`. `subscribe` is for edge
transitions such as waking a paused canvas, not for rebuilding the tree on each
provider frame. `map` memoizes by source signal and projector identity. Define a
projector once outside the component (`const label = signal.map(format)`) so
unrelated renders reuse the binding instead of unsubscribing and resubscribing.

## Hot swap
`weaver dev` evaluates a valid changed bundle in a fresh JS context before replacing the running one.
Root hook slots are seeded by position when slot kind and value type all match; refs keep `current`, while effects restart.
Any slot-count, kind, or type mismatch remounts every root hook; non-serializable values alone initialize fresh.
Evaluation failure leaves the prior context, window, and state running; window-config changes restart the process.

## Elements (JSX intrinsics)

| Element | M1 renders | Props beyond `class`/`children` |
|---|---|---|
| `<column>` | yes | — |
| `<row>` | yes | — |
| `<panel>` | yes | — (a styled box; column layout) |
| `<text>` | yes | — (children: strings/numbers, or one `Signal<string \| number>`) |
| `<icon>` | yes | exactly one of literal `name` or literal `d`; custom paths also accept `viewBox`/`stroke`; no children |
| `<image>` | check-error "arrives in M2" | `src` |
| `<button>` | check-error "arrives in M2" | `onPress` |
| `<slider>` | check-error "arrives in M2" | `value` `max` `onChange` |
| `<canvas>` | check-error "arrives in M3" | `onFrame(draw, fps)` |

Declared now, implemented on schedule — agents get correct types today and a
loud, dated refusal instead of a silent nothing.

## `class` utilities (M1 set)

Utilities apply left to right; the last conflicting utility wins.

Tailwind semantics and scale (1 unit = 4px). Arbitrary values in brackets.
Anything not in this table is a check-time error naming the nearest supported
utility.

| Utility | Maps to |
|---|---|
| `p-N`, `p-[Npx]` | uniform padding |
| `gap-N`, `gap-[Npx]` | flex gap |
| `rounded`, `rounded-{md,lg,xl,2xl,3xl,full}`, `rounded-[Npx]` | corner radius |
| `rounded-{t,r,b,l,tl,tr,br,bl}[-{md,lg,xl,2xl,3xl,full}]`, arbitrary `[Npx]` | selected corner radii; later classes win per corner |
| `border`, `border-N`, `border-[Npx]` | border width in pixels; width-only utilities default to `#E5E7EBFF` (gray-200) |
| `border-[#rgb/#rrggbb/#rrggbbaa]`, optional `/NN` alpha suffix | border color; color alone does not create width |
| `bg-`, `text-`, `border-` + Tailwind v4 named color (`red-50` through `taupe-950`, `white`, `black`, `transparent`), optional `/NN` | official v4.3.3 palette converted from OKLCH to the runtime's sRGB8 wire format; alpha multiplies the named color's alpha |
| `bg-[#rgb/#rrggbb/#rrggbbaa]`, optional `/NN` alpha suffix | background color |
| `text-[#…]` | text color |
| `text-{xs,sm,base,lg,xl,2xl,3xl,4xl}` | font scale |
| `text-[Npx]` | arbitrary font size (`N / 14` font scale) |
| `font-{light,normal,medium,semibold,bold}` | font weight |
| `font-sans`, `font-mono` | reserved built-in proportional and monospaced faces |
| `font-[file-stem]` | a validated font file next to `widget.tsx`; the extension is omitted |
| `text-{left,center,right}` | horizontal text alignment |
| `leading-{none,tight,snug,normal,relaxed,loose}`, `leading-N`, `leading-[Npx]`, `leading-[multiplier]` | line-height multiplier; pixel forms resolve against final font size |
| `tracking-{tighter,tight,normal,wide,wider,widest}`, `tracking-[Npx]`, `tracking-[Nem]` | letter spacing in logical pixels; negative arbitrary values are accepted |
| `line-clamp-N`, `line-clamp-none` | wrapped text capped at N lines with a last-line ellipsis |
| `tabular-nums`, `normal-nums` | fixed-width ASCII digit advances on/off |
| `shadow`, `shadow-{sm,md,lg,xl}` | one outset box-shadow preset, packed to the native renderer |
| `shadow-inner` | inset box shadow |
| `shadow-[X_Y_BLUR_SPREAD_#hex]` | one arbitrary box shadow; lengths are logical px, optional `px` suffixes use underscores as spaces, and blur must be non-negative |
| `shadow-<palette>`, `shadow-[#hex]`, optional `/NN` | replace the current box-shadow color; color and geometry utilities are order-independent |
| `shadow-none` | remove the box shadow |
| `text-shadow`, `text-shadow-{sm,md,lg}`, `text-shadow-none` | one native text-shadow preset or removal |
| `opacity-NN` | node opacity |
| `items-{start,center,end,baseline,stretch}` | cross-axis align; the default is `stretch` |
| `justify-{start,center,end,between}` | main-axis align |
| `grow` | flex grow 1 |
| `w-N`, `w-[Npx]`, `h-N`, `h-[Npx]` | fixed size |
| `truncate` | single-line ellipsis (text only) |

Named text sizes use Tailwind's paired size/line-height defaults:
`xs` 12/16, `sm` 14/20, `base` 16/24, `lg` 18/28, `xl` 20/28,
`2xl` 24/32, `3xl` 30/36, and `4xl` 36/40 (logical pixels). An explicit
`leading-*` utility overrides the paired default regardless of class order.

Still deliberately absent (check-error): gradients, hover/state variants,
and transitions. The shadow surface intentionally supports one shadow per
node; comma-separated CSS shadow lists are not part of the packed wire form.

### Bundled fonts

`weaver check` discovers `.ttf` and `.otf` files directly beside
`widget.tsx`. The widget profile permits at most two faces, each at most
512 KiB. Faces must contain bounded TrueType `glyf` outlines and a Unicode
format-4 cmap; OTF files using CFF outlines are rejected with a conversion
fix-it because the deterministic reference renderer cannot paint CFF.
Ordinary font files and their license files travel as readable `.weave`
source, are copied into `dist`, and are registered before first layout.

The exact stem always works (`GeistPixel-Square.ttf` becomes
`font-[GeistPixel-Square]`). A terminal `-Light`, `-Regular`, `-Medium`,
`-Semibold`, or `-Bold` (underscore also accepted) additionally groups
faces into a family alias: `Display-Regular.ttf` plus `Display-Bold.ttf`
can be selected with `font-[Display] font-bold`. The closest available
registered weight is used. An exact file-stem match wins over family/weight
resolution. A single custom face therefore deliberately
degrades every requested weight to that face rather than fabricating or
silently switching families. Built-in sans maps five requested weights to
the three bundled Native rungs (regular, medium, bold); built-in mono has
one face.

### Icons

`<icon name="play" class="w-6 h-6 text-white" />` resolves at bundle time
against the complete pinned `lucide-static` catalog. Unknown names are check
errors with a nearest-name fix-it over the full set. Only referenced geometry
is embedded in the widget bundle. Named icons use Lucide's 24-unit viewBox,
2-unit stroke, round caps/joins, and the node's text color (`currentColor`).

`<icon d="M 9 5 L 21 12 L 9 19 Z" />` authors a filled custom path.
`viewBox` defaults to `"0 0 24 24"`; `stroke={2}` switches custom geometry
from fill to a round-capped/round-joined stroke of that width. `name` and `d`
are mutually exclusive and one is required. All authored SVG commands are
normalized during check/bundle to explicit absolute M/L/C/Z: relative
commands, H/V, Q/T, S, and A are expanded before Native sees the path.
Normalized data is capped at 8192 UTF-8 bytes per icon node.

An icon is a normal geometry box: 24x24 logical pixels by default, with
`w-*`/`h-*` scaling the viewBox contain-style and centering it in the box.
It has no text baseline or glyph metrics; `text-*` color utilities color it,
while text-size utilities do not size it. Icons consume no registered font
face, so custom-font users retain both widget-profile slots. Weaver bundles
the Lucide/Feather license beside bundles containing named Lucide geometry.

## CLI

```
weaver init <name>       scaffold: <name>/widget.tsx (working starter clock) + tsconfig
weaver check <dir>       tsc --noEmit + config/class/subscribe validation; agent-readable errors
weaver dev <dir>         bundle → run in weaver-widget.exe → watch → rebundle+restart on change
weaver bundle <dir>      esbuild → dist/bundle.js (local output; install rebuilds an owned copy)
```

`weaver dev` restart-on-change is acceptable for M1 (state loss OK); true
hot-swap is M2. All CLI errors must be single-block, copy-pastable, and
actionable — the primary reader is an agent in a fix-it loop.

## The conjure skill

`skills/conjure-widget/SKILL.md` in this repo: teaches an agent to go from a
user's description to `weaver init` → edit widget.tsx → `weaver check` →
`weaver dev`, including this contract inline or by reference, the class table,
and the M1 boundaries (no providers beyond time, no input elements yet).

## v0 done-condition (unchanged)

On a machine that has never seen this repo: `weaver init clock` + one agent
prompt editing widget.tsx + `weaver dev clock` → ticking translucent clock on
the desktop.

---

# M3 amendment (v0.3)

## `<canvas>` — immediate mode (the ADR 0009 exception)

```tsx
<canvas class="w-[288px] h-[64px]" fps={30} onFrame={(ctx, frame) => { … }} />
```

```ts
interface CanvasFrame { t: number; dt: number }        // seconds
interface CanvasCtx {
  width: number; height: number;                       // logical px
  clear(color?: string): void;                         // default: transparent
  fillRect(x: number, y: number, w: number, h: number, color: string): void;
  fillRoundRect(x: number, y: number, w: number, h: number, r: number, color: string): void;
  fillCircle(cx: number, cy: number, r: number, color: string): void;
  line(x1: number, y1: number, x2: number, y2: number, width: number, color: string): void;
  polyline(points: number[], width: number, color: string): void;  // flat x,y pairs
}
```

- `fps` capped at 60; omitted → draws once per React render. `fps={0}` pauses
  the frame clock entirely (0% cost) while keeping the last frame on screen —
  the intended idle pattern for data-driven canvases: `fps={active ? 30 : 0}`.
- `onFrame` runs on the native frame clock; commands batch into one
  immediate-mode buffer per frame. Colors are `#rgb/#rrggbb/#rrggbbaa`.
- A canvas with `fps > 0` is an *animated* widget and is billed accordingly
  (ADR 0005); everything outside the canvas stays retained/idle-zero.

## Providers: `audio` and `media` (host-fed)

```ts
useProvider("audio")  // { rms: number, bands: number[] }   32 bands 0..1, 30 Hz,
                      // system loopback — silence sends nothing (idle-zero)
useProviderSignal("audio") // same data without scheduling a root render;
                           // canvas reads .value, text binds with .map(...)
useProvider("media")  // { title: string, artist: string, album: string,
                      //   playing: boolean, positionMs: number, durationMs: number }
                      // change-pushed; 1 Hz position while playing
```

If the host cannot access system loopback, `audio` emits no fabricated frames.
Authorization and route availability remain host diagnostics; they do not add
platform-specific values or branches to Widget source.

Media *control* (play/seek) is deliberately not in M3.

---

# M2 amendment (v0.2)

Everything above stands. M2 turns on the following.

## Interactive elements (were "arrives in M2")

```ts
<button onPress={() => …} class="…">{children}</button>   // pressable box
<slider value={n} max={n} onChange={(v: number) => …} />  // horizontal, drag+click
<image src="./assets/foo.png" class="…" />                // LOCAL widget assets only in M2;
                                                          // remote images arrive in M3
```

Handlers run in the widget's JS context; events route through the retained
tree (node id → handler). No hover/focus styling in M2 (arrives with state
variants, unscheduled).

## `weaver.fetch` — the declared-origins network (ADR 0002)

```ts
// Global in widget context (also exported from @weaver/sdk for typing):
function wfetch(url: string, init?: {
  method?: "GET" | "POST";
  headers?: Record<string, string>;
  body?: string;
}): Promise<{ status: number; ok: boolean; text(): Promise<string>; json(): Promise<unknown> }>;
```

- HTTPS only. The URL's host must exactly match an entry in `config.origins`;
  otherwise the promise rejects with
  `OriginNotDeclared: add "api.example.com" to origins in your widget config`.
- `weaver check` statically flags string-literal fetch URLs whose host is not
  declared. Runtime enforcement is authoritative.
- Timeout 15s. No cookies; redirects are returned rather than followed; total
  request and response caps are 5 MB each.

## `useStorage` — scoped persistence (quiet standard surface)

```ts
function useStorage<T>(key: string, initial: T): [T, (next: T | ((prev: T) => T)) => void];
```

JSON-serializable values only; persisted per widget (survives restarts and
`weaver dev` reloads); 64 KB total quota per widget, over-quota writes throw.

## Providers: `cpu` and `memory` (host-fed)

```ts
useProvider("cpu")    // { percent: number, perCore: number[] }      1 Hz
useProvider("memory") // { usedMb: number, totalMb: number, percent: number }  1 Hz
```

Delivered by `weaverd` (the host). `time` remains SDK-local. Subscribing
without the host running is a runtime error that names the fix (`weaver up`);
`weaver dev` auto-starts the host.

`cpu.percent` is whole-machine utilization from 0–100, not the sum of cores;
`perCore` reports the same 0–100 utilization for each logical core. Memory
`usedMb` is physical memory that is not currently free or reclaimable idle
cache, `totalMb` is installed physical memory, and `percent` is their ratio.
These meanings stay platform-neutral even though each host uses its public OS
counters to project them.

## The host and its CLI verbs

```
weaver up | down            start/stop weaverd (singleton, tray-less in M2)
weaver pack <dir>           write portable source to <dir>.weave
weaver install <dir|file.weave> validate, own, build, register, and run source
weaver uninstall <name>     stop + unregister
weaver status               table: name · pid · private-MB · cpu% · uptime (ADR 0005 billing)
```

Portable install amendment: `weaver pack <dir>` writes a deterministic
`.weave` containing source, assets, declared surface, provenance, and lineage.
`weaver install <dir|file.weave>` validates that artifact, builds a
Weaver-owned source copy, and registers the owned path. Only `weaver dev`
registers a developer workspace by reference (ADR 0011).

weaverd supervises widget processes (crash → restart with backoff, 3 strikes
→ stopped + noted in status), fans out providers over local IPC, and samples
per-widget cost. Registrations persist across host restarts.

---

# Styling breadth amendment (v0.4)

Everything above stands. This section grows with the numbered styling stack;
utilities not yet listed here remain loud `weaver check` errors.

## PR 01: spacing and sizing

The scale remains 1 unit = 4 logical px. Bracketed pixel values are accepted
where shown. Utilities are applied left-to-right; a later utility wins on the
same side or axis. Negative margins are supported; padding and sizes are
non-negative.

| Utility | Maps to |
|---|---|
| `p-N`, `p-[Npx]` | uniform padding |
| `px/py/pt/pr/pb/pl-N`, bracketed `Npx` forms | directional padding; side values override uniform padding |
| `m/mx/my/mt/mr/mb/ml-N`, bracketed `Npx` forms, optional leading `-` | external per-side margin |
| `w-N`, `h-N`, bracketed `Npx` forms | fixed width or height |
| `w-full`, `h-full`, `w-A/B`, `h-A/B` | percentage of the parent's content box |
| `w-auto`, `h-auto` | clear an earlier size on that axis |
| `size-N`, `size-[Npx]`, `size-full` | set both axes together |
| `min-w/max-w/min-h/max-h-N`, bracketed `Npx` forms | per-axis size bounds |
| `aspect-square`, `aspect-video`, `aspect-[W/H]`, `aspect-[N]` | derive the missing axis when exactly one axis is definite |
| `aspect-auto` | clear an earlier aspect ratio |

Percentage sizes are calculated from the parent's content box before margins;
min/max bounds then clamp the laid-out frame. `aspect-*` does nothing when both
axes are definite or both are automatic.

## PR 02: flex completeness

| Utility | Maps to |
|---|---|
| `justify-around`, `justify-evenly` | Tailwind main-axis free-space distribution |
| `grow-N`, `grow-[N]` | numeric flex-grow factor (`grow` remains 1) |
| `shrink`, `shrink-0` | opt in/out of compression below the preferred size |
| `self-auto/start/center/end/stretch` | per-child cross-axis alignment |
| `flex-wrap`, `flex-nowrap` | enable/disable row or column line wrapping |

Weaver elements default to `shrink: 1`, matching Tailwind. When preferred
sizes overflow a line, eligible children give up space in proportion to their
available shrink capacity (preferred size minus min-size floor); `shrink-0`
children never compress. If all floors still exceed the container, overflow
remains explicit and the Native debug diagnostic fires. Wrapped lines use the
container's `gap` on both axes. `items-baseline` remains an end-alignment
approximation; true font baseline layout is outside this styling slice.

## PR 09: overlay stacks and bounded overflow

`<stack>` is the overlay sibling of `<row>` and `<column>`. Every child starts
at the stack's content-box origin, paints in child order, and uses its own
width, height, margin, and alignment utilities. Overlay composition therefore
uses ordinary child utilities such as `w-full h-full`; there is no positioned
layout API.

| Utility | Maps to |
|---|---|
| `overflow-hidden` | clip descendant painting to this element's resolved rounded bounds |

The clip applies to images, text, panels, and nested content. Per-corner
`rounded-*` utilities shape the mask, including asymmetric corners.

## PR 10: image fitting, rounded masks, and tiling

```ts
<image src="./cover.png" fit="cover" class="rounded-xl" />
<image src="./texture.png" tile />
```

`fit` accepts `cover`, `contain`, or `stretch`; omitted `fit` preserves the
existing `stretch` behavior. Existing uniform and per-corner `rounded-*`
utilities are applied directly to the image mask. `tile` repeats the image at
its natural logical-pixel size from the image element's top-left and takes
precedence over fit geometry; rounding still masks the tiled result. Image
sources remain local widget assets.

## PR 11: native interaction states and press events

`hover:` and `pressed:` are supported only for the five native-swappable
visual channels below. Every other state-prefixed utility is a loud
`weaver check` error naming these supported forms.

| Utility | Native override |
|---|---|
| `hover:bg-<color>`, `pressed:bg-<color>` | background color |
| `hover:text-<color>`, `pressed:text-<color>` | foreground/text color |
| `hover:opacity-N`, `pressed:opacity-N` | node opacity (`N` is 0–100) |
| `hover:border-<color>`, `pressed:border-<color>` | border color; border width remains the base style |
| `hover:shadow-*`, `pressed:shadow-*` | complete box-shadow replacement, including named shadows, arbitrary shadows, `shadow-inner`, and `shadow-none` |

Named Tailwind v4 colors, bracketed hex colors, and `/NN` alpha use the same
forms and values as their unprefixed counterparts. Overrides inherit every
base channel they do not name. Pressed wins over hover when both native states
are active; disabled elements use the base style. Swaps use retained native
state and its existing invalidation path: no JS callback, timer, polling, or
per-frame work is introduced. The earlier M2 note that hover styling was
unscheduled is superseded by this bounded surface.

On a non-pressable node, `hover:` and `pressed:` utilities resolve against
the nearest pressable ancestor (`<button>` or `<slider>`). This is Weaver's
implicit group-state rule: no `group` class or `group-*` prefix is needed.
A state variant on a non-pressable node outside any pressable ancestor is a
`weaver check` error with the `NearestPressableAncestor` fix-it when the
entry-file JSX proves that ancestry. Component boundaries are accepted because
the static check cannot prove their rendered ancestry; Native runtime
resolution remains authoritative.

```ts
interface PressEvent {
  x: number; y: number; // node-local logical pixels
  u: number; v: number; // x/width and y/height, clamped to 0–1
}

<button
  onPress={(event?: PressEvent) => { /* a zero-argument handler remains valid */ }}
  onDoublePress={(event: PressEvent) => {}}
  onRightPress={(event: PressEvent) => {}}
  class="bg-zinc-900 hover:bg-zinc-800 pressed:bg-black pressed:shadow-inner"
>
  <icon name="play" class="text-white pressed:text-zinc-300" />
</button>
```

`onPress` remains required on `<button>` and its parameter is optional for
source compatibility. `onDoublePress` and `onRightPress` are optional. A
double click sends the ordinary press for its first release, then prefers the
double-press handler on the double release. Right press uses the dedicated
handler when present. Coordinates are computed from the native laid-out hit
bounds before entering JS. `<slider>` retains its existing `onChange` surface
and can use the same `pressed:` visual channels during its native drag state.

## Consolidated v0.4 authoring tables

These tables supersede the M1 scheduling notes for the shipped surface. They
are the close-of-stack review index; details and bounds remain normative in
the sections above.

| Element | Shipped props beyond `class` and `children` | Content model |
|---|---|---|
| `<column>` | none | box children, vertical flex |
| `<row>` | none | box children, horizontal flex |
| `<stack>` | none | box children, overlay layout; paint the backdrop on a child |
| `<panel>` | none | box children, vertical flex with a painted surface |
| `<text>` | none | strings and numbers only |
| `<icon>` | required literal `name` from `iconNames` | no children |
| `<image>` | required local `src`; optional `fit="cover/contain/stretch"`, `tile` | no rendered children |
| `<button>` | required `onPress`; optional `onDoublePress`, `onRightPress` | box children |
| `<slider>` | required `value`, `max`, `onChange` | no rendered children |
| `<canvas>` | required `onFrame`; optional `fps` | no rendered children |

| Class family | Complete shipped forms |
|---|---|
| spacing | `p-N`, `p-[Npx]`, `px/py/pt/pr/pb/pl-N`, bracketed directional padding, `m/mx/my/mt/mr/mb/ml-N`, bracketed margins, negative margins, `gap-N`, `gap-[Npx]` |
| sizing | `w/h-N`, `w/h-[Npx]`, `w/h-full`, `w/h-A/B`, `w/h-auto`, `size-N`, `size-[Npx]`, `size-full`, `min/max-w/h-N`, bracketed bounds, `aspect-square/video/auto`, `aspect-[W/H]`, `aspect-[N]` |
| flex | `items-start/center/end/baseline`, `justify-start/center/end/between/around/evenly`, `grow`, `grow-N`, `grow-[N]`, `shrink`, `shrink-0`, `self-auto/start/center/end/stretch`, `flex-wrap`, `flex-nowrap` |
| radii | `rounded`, `rounded-md/lg/xl/2xl/3xl/full`, `rounded-[Npx]`, directional and corner `rounded-t/r/b/l/tl/tr/br/bl` forms with the same suffixes |
| borders | `border`, `border-N`, `border-[Npx]`, `border-<named-color>`, `border-[#hex]`, optional `/NN` color alpha |
| colors | `bg/text/border-<Tailwind-v4-color>`, `bg/text/border-[#hex]`, optional `/NN` alpha |
| typography | `text-xs/sm/base/lg/xl/2xl/3xl/4xl`, `text-[Npx]`, `font-light/normal/medium/semibold/bold`, `font-sans/mono`, `font-[file-stem]`, `text-left/center/right`, all documented `leading-*` and `tracking-*` forms, `line-clamp-N/none`, `tabular-nums`, `normal-nums`, `truncate` |
| effects | `shadow`, `shadow-sm/md/lg/xl/inner/none`, `shadow-[X_Y_BLUR_SPREAD_#hex]`, `shadow-<color>`, `text-shadow`, `text-shadow-sm/md/lg/none`, `opacity-N` |
| overflow | `overflow-hidden` |
| native state | `hover/pressed:bg-<color>`, `hover/pressed:text-<color>`, `hover/pressed:opacity-N`, `hover/pressed:border-<color>` |

The contract-table unit test freezes both row sets and compiles a representative
for every syntax branch. Gradients, transitions, positioned layout, arbitrary
state prefixes, and every utility absent from these tables remain loud
`UtilityError` failures with a fix-it.

---

# Media v2 amendment (v0.5)

This amendment supersedes the M3 media frame's boolean-only playback state.
Everything else above stands.

## PR 01: playback status and source application

```ts
interface MediaData {
  title: string;
  artist: string;
  album: string;
  status: "playing" | "paused" | "stopped";
  playing: boolean;
  sourceApp: string;
  positionMs: number;
  durationMs: number;
}
```

`playing` remains on the wire and in the SDK for source and installed-bundle
compatibility. It is always exactly `status === "playing"`. The host maps the
platform's playing state to `"playing"`, paused state to `"paused"`, and every
other playback state to `"stopped"`.

`sourceApp` is display-only. The host uses the installed package's display
name when the source identifier resolves to a package without prompting;
otherwise the raw identifier is returned verbatim. It is `""` only when the
platform supplies no source identifier. Widget logic must not branch on this
display string.

No observable media session has one canonical frame: empty title, artist,
album, and source; zero position and duration; `status: "stopped"`;
`playing: false`.

The newline-terminated provider frame has a protocol maximum of 12,502 bytes.
That bound covers worst-case six-byte JSON escaping for each byte of three
512-byte metadata fields, the 256-byte source field, and the reserved 259-byte
host art-cache path, plus the longest fixed fields and two 20-digit unsigned
timeline values. Host formatting, host dedupe storage, and runtime line
accumulators use this same bound. Encoding failure is logged and never silently
dropped.

Media transport is deliberately absent at this layer; it lands in a subsequent
v0.5 stack amendment.

## PR 02: album art and dynamic image sources

`MediaData` gains one optional field:

```ts
interface MediaData {
  artPath?: string;
}
```

The field is absent when the platform or current session supplies no artwork.
When present it is an opaque absolute path into the host-owned art cache.
Widgets must use conditional rendering because `<image>.src` remains required:

```tsx
{media.artPath
  ? <image src={media.artPath} fit="cover" />
  : <panel class="bg-zinc-800" />}
```

weaverd is the cache's sole writer. On hosts with per-user LocalAppData, the
root is `%LOCALAPPDATA%\weaver\artcache`, inheriting that access boundary; the
runtime receives that one root in `WEAVER_ART_CACHE` only for widgets
subscribed to media. Filenames are lowercase SHA-256 hex plus `.img`.
Inputs over 1 MiB are skipped. A new file is written to a unique exclusive
temporary file, flushed and synchronized, then atomically renamed without
replacement. Temporary files are removed on failure and startup. Only a
complete successfully published file can enter a provider frame. Successful
publication updates the LRU timestamp; pruning retains at most 32 images and
never removes the currently published hash.

The widget profile reserves 256 KiB of decoded RGBA per registered image.
Host artwork whose decoded dimensions exceed that fixed slot is aspect-fit
downsampled with the host image decoder to at most 256×256 and encoded as PNG
before publication. The 1 MiB limit applies to both the original provider
payload and the normalized cache file. This transformation never expands a
runtime memory bound or touches the Native SDK dependency.

SMTC manager/session property events only set coalescing dirty flags. The
existing one-second host poll consumes those flags, refreshes metadata and art,
and continues to sample playback/timeline state. Event callbacks never perform
I/O or block. Refresh failure clears the consumed flag, preserves the prior
snapshot, logs once, and retries only after another property change.

Static widget images keep their startup load and registration path. After each
JS turn that can mutate the retained tree, the runtime compares image node
lifetimes and normalized sources. A changed source is read and decoded before
replacing the same node/resource ID, so a transient read or decode failure
keeps the prior image. Removed, non-image, invalid-source, hot-swapped, and
reused-ID nodes unregister stale resources. An unchanged tree exits by one
generation comparison.

The runtime canonicalizes the widget root and host art-cache root once. Widget
assets must remain within the widget root. Host art paths must be ordinary
drive-absolute paths within the cache at a case-insensitive component boundary.
Drive-relative, rooted-current-drive, UNC, device-namespace, `..`, missing, and
prefix-collision paths are rejected. Widgets cannot nominate an additional
readable root.

## PR 03: media transport capability

Media control is a separate, explicit capability. A widget must declare
`capabilities: ["media-transport"]`; `subscribe: ["media"]` is not required
for transport-only widgets. The SDK surface is:

```ts
interface MediaTransport {
  play(): Promise<boolean>;
  pause(): Promise<boolean>;
  next(): Promise<boolean>;
  previous(): Promise<boolean>;
  seek(ms: number): Promise<boolean>;
}

const transport = useMediaTransport();
```

`seek` is absolute and accepts only finite, non-negative integer
milliseconds. The host clamps it to a known session duration. A promise
resolves `true` only when the OS media API reports success. It resolves
`false` when a valid request reaches weaverd but the capability is refused,
there is no session, or the OS declines the operation. Channel
unavailability, malformed protocol, a three-second timeout, disconnect, and
shutdown reject.

Each runtime owns one monotonically increasing safe-integer command-ID
sequence. At most four commands may be pending per widget; a fifth rejects
immediately. Commands are FIFO, and weaverd accepts at most five verbs per
widget in any one-second sliding window.

The existing provider endpoint is duplex. Runtime-to-host command lines and
host-to-runtime acknowledgement lines are newline-delimited JSON:

```json
{"command":"media","verb":"play","id":1}
{"command":"media","verb":"seek","seekMs":42000,"id":2}
{"ack":1,"ok":true}
```

The command object has exactly `command`, `verb`, optional `seekMs`, and `id`;
`command` is `"media"` and verbs are `play`, `pause`, `next`, `previous`, or
`seek`. `seekMs` is present only for `seek`. The acknowledgement object has
exactly `ack` and `ok`.

The host accepts an endpoint only when the operating system reports that its
peer PID is the child process launched for that widget slot. A mismatch is
disconnected before any frame or command is served, and the endpoint is
recreated or continues accepting the expected child.

One blocking host reader thread per widget validates incremental newline
framing and enqueues commands without calling platform media APIs or writing
to the endpoint. EOF with a buffered partial record is a protocol failure;
the residual is never executed. The host supervision loop is the sole writer
of provider frames and acknowledgements; it independently checks the declared
capability and rate limit. Platform operations run on a bounded command
worker, so an OS API stall cannot block supervision. The negative-
acknowledgement lane is sized for the four-command pending limit plus the
five-command rate-limit burst; backpressure prevents accepting another
command until its required acknowledgement can be represented.

The runtime reader is the sole endpoint reader. It demultiplexes complete
newline-terminated records by top-level key; EOF residuals are discarded as
protocol failures. Provider frames retain their four-entry drop-oldest queue.
Acknowledgements are placed directly into one of four slots reserved by the
pending command ID. An acknowledgement for an unknown, expired, or duplicate
ID is counted and dropped without affecting current commands. Runtime writes
are serialized by a send mutex, and reader arrival wakes the existing app-loop
provider dispatcher. A transport-only widget creates no repeating provider
timer. Each pending command arms the earliest exact three-second deadline as a
one-shot timer; acknowledgement arrival settles it immediately.
`native.mediaCommand` is absent unless the runtime manifest declares
`media-transport`.

Every shipping adapter implements verbs through system media request APIs.
Spawn/load failure, timeout, signal death, malformed output, and disconnect
reject; only a request that reached the current system media session and was
declined resolves `false`.

An adapter whose elapsed-time setter has no success result must verify seek by
read-back: it keeps observing until success or a two-second deadline and must
observe the requested position within 2000 ms, accounting for playback advance
at the reported playback rate. Only that verified observation resolves `true`;
no session, unavailable read-back, and an out-of-tolerance observation at the
deadline resolve `false`.

## PR 05: noro acceptance surface

`examples/noro-shell` is the executable system-media acceptance surface for
this amendment. It subscribes to `media` and `time`, declares
`capabilities: ["media-transport"]`, conditionally renders `artPath` with a
widget-local fallback, and derives the play/pause glyph from `status`.

Click-to-seek uses the event's normalized local `u` coordinate. The handler
clamps `event.u` to `[0, 1]`, multiplies by `durationMs`, rounds to an integer,
and passes that absolute value to `seek(ms)`. Click-only seek is the contracted
example behavior; dragging is not implied.
