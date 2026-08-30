# Gradient exploration

Status: executable Weaver Native-fork spike, not a production contract

## Verdict

We should not build a Weaver-only gradient rasterizer. Native already has the
right low-level primitive for linear gradients: a `Fill.linear_gradient` value,
gradient stops, deterministic reference rendering, display-list resources,
macOS packet rendering, and a Direct2D implementation in official upstream.

The missing layer is retained widget authoring. Native's `WidgetStyle` accepts
only a solid background color, and Weaver's class compiler rejects every
gradient utility before it reaches the runtime. Radial and conic gradients do
not exist in Native yet.

Weaver's Native pin has diverged from current official upstream. The fork has a
rare retained metadata channel for text styles, shadows, icon paths, and
interaction styles; official upstream does not. The spike uses that channel and
is the right low-risk adapter for Weaver today, but it does not cherry-pick
cleanly onto current `vercel-labs/native`. An official contribution needs the
same sparse-paint idea expressed in upstream's current widget architecture.

The best route is:

1. Finish linear gradients as a small Native widget-paint contribution.
2. Expose that primitive through Weaver's compiler, bridge, and retained tree.
3. Make color interpolation explicit and consistent before claiming Tailwind
   parity.
4. Add radial and then conic gradients as new Native paint shapes, not as
   Weaver-side approximations.

## What exists now

| Layer | Linear | Radial | Conic | Important qualification |
| --- | --- | --- | --- | --- |
| Native canvas model | Yes | No | No | `Fill` has solid color and linear gradient arms. |
| Native reference renderer | Yes | No | No | Linear-light RGB interpolation is implemented. |
| Native macOS renderer | Yes | No | No | `NSGradient` fills clipped paths. Gradient strokes fall back to the first stop. |
| Official Native Windows renderer | Yes | No | No | Direct2D creates a linear-gradient brush. |
| Weaver fork Windows D3D presenter | CPU fallback | No | No | It deliberately rejects gradient GPU packets rather than flattening them to a color. |
| Native retained `WidgetStyle` | No | No | No | The background channel is `?Color`, not a paint value. |
| Weaver classes and bridge | No | No | No | `bg-gradient`, `from-`, `via-`, and `to-` currently check-error. |

Native also ships gradient-heavy examples such as `deck` and `gpu-dashboard`.
This is mature canvas capability that needs a retained-widget adapter, not a
new renderer.

## Gradient families

There are three core shape families:

- Linear: color changes along a line. This covers directional backgrounds,
  progress fills, fades, and most current Weaver preview art.
- Radial: color radiates from a center as a circle or ellipse. This covers
  spotlights, soft glows, and depth behind content.
- Conic: color rotates around a center. This covers color wheels, rings, dials,
  and angular progress.

Repeating linear, radial, and conic gradients are spread behavior on those
shapes, not three unrelated rendering models. Multiple background gradients
are composition. Mesh and noise gradients are useful later, but they are not
part of the core CSS gradient model and should not distort the first contract.

## Recommended public contract

Use current Tailwind v4 spellings as the canonical syntax:

```tsx
<View className="bg-linear-to-r from-cyan-500 via-violet-500 to-fuchsia-500" />
<View className="bg-linear-135 from-[#0891b2] to-[#d946ef]" />
<View className="bg-radial-[at_30%_20%] from-white/40 to-transparent" />
<View className="bg-conic-90 from-cyan-500 via-violet-500 to-cyan-500" />
```

Keep `bg-gradient-to-r` as a compatibility alias because Weaver's existing API
backlog already names it. Do not make the old spelling the primary contract.

The internal model should be a paint union, even if the first Native bridge
uses rare metadata to preserve the compact common widget shape:

```text
BackgroundPaint =
  Solid(color)
  Linear(line, stops, interpolation, spread)
  Radial(center, radii, stops, interpolation, spread)
  Conic(center, startAngle, stops, interpolation, spread)
```

Gradient coordinates stay box-relative until layout resolves the final frame.
Cardinal and corner directions can use normalized endpoints. Arbitrary CSS
angles need gradient-line geometry based on the final box aspect ratio. A
fixed `(0, 0)` to `(1, 1)` diagonal is not equivalent on non-square widgets.

Stops should retain normalized offsets and RGBA color. Allocate their storage
only for nodes that have a gradient. Weaver's retained `Node` is intentionally
large and fixed-capacity, so an inline stop array on every node is the wrong
tradeoff. A final stop limit must be justified with example and app data, not
chosen by convenience.

## Color and alpha correctness

This is the main unresolved design decision.

Current Tailwind v4 gradients default to Oklab interpolation. CSS gradient
interpolation also requires premultiplied alpha handling. Native's reference
renderer currently interpolates in linear-light RGB, while macOS delegates to
`NSGradient` and Windows Direct2D requests gamma 2.2. Those paths can produce
different midpoints.

The production model should carry an interpolation enum and all backends
should share observable semantics. For Tailwind parity, use premultiplied Oklab
as the default and map explicit modifiers such as `/srgb` to supported spaces.
If Oklab is deferred, document linear sRGB as an intentional Weaver subset.
Do not call the result exact Tailwind behavior until the pixels agree.

## Exploratory Native implementation

The spike adds `WidgetLinearGradient` to Native's existing rare retained
metadata channel. This preserves the current `Widget` size and does not put a
pointer or stop array on every widget. The panel renderer:

1. Resolves normalized start and end points against the laid-out frame.
2. Emits the existing `Fill.linear_gradient` display-list value.
3. Treats a gradient as opaque only when it has stops and every stop is opaque.
4. Lets a solid pressed or hover background override the base gradient.
5. Skips the metadata in the immediate-canvas paint walk.

The tests exercise post-layout endpoint resolution and the pressed-state
override. This proves the adapter seam without adding a partial public Weaver
API that silently does nothing.

The metadata approach fits Native's existing treatment of rare text styles,
shadows, icon paths, and interaction styles. A follow-up should generalize all
widget background emitters to consume `widgetBackgroundFill`, not just panels.

The local Native spike is commit `6fc505d1`. `zig build test` passes on the
unmodified official upstream head and, separately, on the Weaver-fork spike
branch. A direct cherry-pick exposed conflicts in the fork-only metadata,
interaction-style, and panel-shadow work, so the official adapter must be
authored against upstream rather than presented as a clean backport. Native's
test suite prints expected diagnostics from negative-path fixtures, but exits
successfully.

## Delivery sequence

### 1. Native linear widget paint

- Land the retained metadata in Weaver's fork. For official upstream, propose
  an equivalent sparse paint channel or a reviewed `WidgetStyle` paint change
  with an explicit retained-footprint receipt.
- Cover every widget surface that authors can give a background.
- Validate resizing, clipping, rounded corners, opacity, shadows, hover,
  pressed, disabled, and display-list damage.
- Decide the interpolation contract and make reference, macOS, and Windows
  produce matching fixtures.

### 2. Weaver linear authoring

- Compile direction or angle plus `from`, `via`, and `to` colors and positions
  into one normalized value.
- Parse once at the bridge boundary.
- Store gradient data sparsely in the retained tree.
- Attach Native metadata only to painted nodes.
- Preserve a solid background as the CSS-style fallback beneath the gradient.
- Add one real example and screenshot fixtures on macOS and Windows.

### 3. Windows D3D fast path

The Weaver fork currently routes gradient packets through the correct CPU
fallback. Keep that correctness fallback, but add gradient parameters and a
real shader or brush path before treating gradients as performance-complete.
Static gradients must retain Weaver's idle-zero behavior and should only
invalidate on paint, size, or interaction-state changes.

### 4. Radial, then conic

Radial needs a new Native paint arm, reference sampler, resource accounting,
serialization and fingerprinting, plus native backend implementations. Conic
needs the same model work and likely a shader-backed platform path. Build both
in Native first so canvas and retained widgets share one implementation.

### 5. Repeating and layered backgrounds

Add a spread enum such as `pad` and `repeat` before creating repeating syntax.
Add multiple background layers only after one gradient has stable geometry,
interpolation, caching, and damage behavior.

## Acceptance receipts

- Native full test suite is green.
- `@sizeOf(Widget)` remains unchanged for the sparse metadata design.
- Gradient resource counts and display-list fingerprints change only when
  gradient data changes.
- Transparent-stop and rounded-clip fixtures match on the reference renderer,
  macOS, and Windows.
- A resized arbitrary-angle gradient follows CSS gradient-line geometry.
- A static gradient produces no timer, frame loop, or idle invalidation.
- CPU and GPU frame timings are captured for a realistic dashboard rather than
  a one-rectangle microbenchmark.

## Sources

- [Native gradient paint model](https://github.com/vercel-labs/native/blob/48629b3f15c5f6b9858e2f7d45c4c3074a1816f1/src/primitives/canvas/drawing.zig)
- [Native deterministic reference renderer](https://github.com/vercel-labs/native/blob/48629b3f15c5f6b9858e2f7d45c4c3074a1816f1/src/primitives/canvas/reference.zig)
- [Native macOS canvas packet renderer](https://github.com/vercel-labs/native/blob/48629b3f15c5f6b9858e2f7d45c4c3074a1816f1/src/platform/macos/appkit_host.m)
- [Native Windows Direct2D renderer](https://github.com/vercel-labs/native/blob/48629b3f15c5f6b9858e2f7d45c4c3074a1816f1/src/platform/windows/gpu_surface_renderer.cpp)
- [Weaver fork D3D presenter](https://github.com/SunkenInTime/native/blob/df245eb82065ebddac66698829c0fc875b28257e/src/platform/windows/d3d_presenter.cpp)
- [CSS Images Level 4 gradient model](https://drafts.csswg.org/css-images-4/#gradients)
- [CSS Color Level 4 interpolation](https://drafts.csswg.org/css-color-4/#interpolation-space)
- [Tailwind CSS background-image utilities](https://tailwindcss.com/docs/background-image)
