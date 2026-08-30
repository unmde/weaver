# Gradient architecture and verification

Status: implemented on `agent/gradient-exploration`; hardware Windows GPU
timing remains an opt-in receipt that must run on a Windows machine.

## Verdict

Weaver should own the authoring contract and Native should own gradient
semantics and rendering. That split is now executable:

- Weaver exposes typed linear, radial, conic, repeating, layered, and mesh
  backgrounds, validates them, and stores one sparse canonical document on the
  retained node.
- Native resolves normalized geometry after layout, emits ordinary display-list
  paints, and renders the same model through its reference, macOS, and Windows
  paths.
- Repeating and reflecting are spread modes on linear, radial, and conic
  gradients. They are not separate shape implementations.
- Layering is ordinary painter order. Each layer becomes a same-shape draw from
  bottom to top, preserving alpha composition, clipping, damage, and stable
  command identity.
- Mesh is a tensor-product bicubic patch model. It is intentionally a separate
  two-dimensional paint, not a pile of radial approximations.

The original Windows CPU fallback was caused by Weaver's fork-specific D3D
presenter. Official `vercel-labs/native` has a Direct2D linear-gradient brush;
it does not contain Weaver's D3D presenter. Our packet renderer previously
refused gradient packets and fell back to reference pixels. The implementation
on this branch removes that restriction for linear, radial, conic, and mesh
paints, including repeat/reflect and all three interpolation spaces.

That makes the work upstreamable in two different ways:

1. The gradient model, reference semantics, serialization, resource bounds,
   retained adapter, and conformance catalog are a focused Native contribution.
2. The D3D shader is directly useful to Weaver's Native fork. It is only a
   direct official-Native contribution if upstream wants this presenter as a
   backend; otherwise its semantic tests should be applied to the existing
   Direct2D backend instead.

## Upstream comparison

Current official `vercel-labs/native` `main` is
`48629b3f15c5f6b9858e2f7d45c4c3074a1816f1`. At that revision:

| Capability | Official Native | Weaver branch |
| --- | --- | --- |
| Canvas linear model | yes | yes |
| Reference linear renderer | yes | yes |
| Windows linear GPU | Direct2D | D3D11 packet shader |
| Retained widget gradient | no | yes, sparse metadata |
| Radial and conic | no | yes |
| Repeat and reflect | no | yes |
| Explicit sRGB / linear-sRGB / Oklab | no | yes |
| Layered backgrounds | no | yes, bottom-to-top |
| Bicubic mesh | no | yes |
| Deterministic gradient catalog | no | yes, 15 scenes |

The official linear primitive was useful prior art, not a complete stack. The
Weaver branch extends that primitive rather than installing a second rasterizer
above Native.

## Public authoring contract

Container surfaces (`column`, `row`, `stack`, `panel`, and `button`) accept one
typed gradient or a painter-ordered array:

```tsx
<panel background={[
  {
    type: "linear",
    start: [0, 1],
    end: [1, 0],
    interpolation: "oklab",
    stops: [
      { offset: 0, color: "indigo-950" },
      { offset: 1, color: "violet-500" },
    ],
  },
  {
    type: "radial",
    center: [0.25, 0.2],
    radius: [0.7, 0.8],
    stops: [
      { offset: 0, color: "#4DF4FFCC" },
      { offset: 1, color: "#4DF4FF00" },
    ],
  },
]} />
```

The compact class path handles the common linear case:

```tsx
<panel class="bg-linear-to-tr from-cyan-400 via-violet-500 to-fuchsia-500" />
<panel class="bg-repeating-linear-to-r from-amber-400 from-0% to-rose-500 to-25%" />
```

Typed authoring is the canonical complete API. It keeps radial geometry,
conic angle, interpolation, mesh control points, and painter order obvious
instead of inventing a CSS parser. `bg-gradient-to-*` remains a compatibility
alias for `bg-linear-to-*`.

### Shapes and defaults

| Shape | Geometry | Default |
| --- | --- | --- |
| Linear | normalized `start`, `end` | `[0,.5]` to `[1,.5]` |
| Radial | normalized `center`, strictly positive elliptical `radius` | center `[.5,.5]`, radius `[.5,.5]` |
| Conic | normalized `center`, `from` angle | center `[.5,.5]`, CSS zero at twelve o'clock |
| Mesh | 16 row-major bicubic control points and four clockwise corner colors per patch | none |

Linear, radial, and conic take `spread: "pad" | "repeat" | "reflect"`.
All shapes take `interpolation: "srgb" | "srgb-linear" | "oklab"`, defaulting
to linear sRGB. Colors interpolate with premultiplied alpha. Mesh patches
share boundary control points and colors for seamless joins; if patches
overlap, the later patch wins deterministically.

The boundary is intentionally finite: 8 layers, 64 total one-dimensional
stops, 16 total mesh patches, 16 control points per patch, finite coordinates
whose absolute value is at most 1,000,000, strictly positive radial radius
components, and a 16 KiB canonical wire value. Zero-radius CSS degenerates are
rejected until every backend can implement their special rendering identically.
The SDK rejects bad inputs before an operation is emitted and the Zig bridge
validates the same document again before retained-tree mutation.

## Native implementation

### One semantic model

Native's `Fill` union now carries linear, radial, conic, and mesh paints.
Linear/radial/conic share:

- arbitrary authored stop offsets, including hard stops;
- pad, repeat, and reflect spread;
- sRGB, linear-sRGB, and Oklab interpolation;
- premultiplied-alpha mixing; and
- deterministic degenerate behavior.

The reference mesh sampler solves the inverse bicubic mapping with bounded
Newton iterations, rejects a patch miss, and interpolates its four corner
colors in the selected space. That is the correctness oracle for tests and
screenshots, not the production fast path.

### Retained projection and layering

Weaver stores only the canonical bytes on a node. During frame projection it
decodes into the frame arena. Geometry stays normalized until Native has the
final laid-out box, avoiding wrong diagonals on non-square widgets and avoiding
retained pointers into short-lived JS memory.

Repeated `background_gradient` commands on a widget become bottom-to-top draw
commands. A single layer retains the original command ID; additional layer IDs
are stable hashes, so an unchanged stack does not manufacture damage. Solid
hover or pressed backgrounds retain their existing override behavior.

Mesh authoring uses a bounded builder-side patch store, also capped at 16 per
view. This preserves the common `Widget` footprint and makes exhaustion an
explicit `MeshPatchListFull` error.

### Platform behavior

- Reference: implements the complete model and produces deterministic RGBA8
  screenshots and samples.
- macOS: uses the native fast path only where its behavior matches the model.
  Unsupported shape/spread/interpolation combinations refuse the native packet
  and use deterministic reference pixels instead of silently changing colors.
- Windows D3D11: decodes packet v9 into structured stop/mesh buffers and shades
  linear, radial, conic, and bicubic mesh paints on the GPU. It applies spread,
  interpolation, and output premultiplication in the shader.

Refusing an unsupported packet is a correctness feature. It gives a slow but
accurate frame rather than a fast, subtly different frame. The platform work
can replace those refusals incrementally as each native path earns conformance.

## Verification loop

The loop follows three independent evidence lanes. Passing one lane does not
substitute for either of the others.

### 1. Semantics

`zig build test-canvas` covers the algebra directly: shape parameters, spread
at positive and negative coordinates, hard and degenerate stops, premultiplied
alpha, color-space midpoints, mesh inverse mapping, resource accounting,
fingerprints, serialization, packet bytes, retained layering, and post-layout
mesh resolution.

`zig build gradient-reference -- <output>` renders 15 named scenes to PNG plus
a sample manifest:

- opaque and transparent linear;
- Oklab and hard-stop linear;
- arbitrary-angle and repeating linear;
- elliptical and repeating radial;
- conic and repeating conic;
- layered linear plus radial;
- bicubic mesh; and
- degenerate line, one stop, and empty stops.

The catalog is a regression receipt. It is deliberately marked non-normative:
the expected math and targeted tests remain independent from the renderer that
produces the images.

### 2. Integration and portability

- SDK tests pin serialization, painter order, aliases, repeating syntax,
  malformed inputs, and resource ceilings.
- Runtime tests pin sparse ownership, exact no-op generation behavior, bridge
  validation, CSS conic-angle conversion, and end-to-end retained projection.
- Desktop canvas-frame tests pin packet/resource behavior.
- macOS Objective-C syntax checking compiles the AppKit decoder.
- The Windows GNU cross-build compiles and links the D3D presenter tests and
  calls `D3DCompile` on both HLSL stages. Hostile packets and over-budget stop
  lists are rejected.
- `examples/gradient-stack` passes both TypeScript and `weaver check`, then
  captures through the real QuickJS bridge and Native reference renderer. The
  current receipt is 760×460, one retained revision, 21 nodes, 30 commands,
  349,294 non-clear pixels, two event-driven startup frames, and zero pending
  timers, providers, fetches, images, or frame requests.

### 3. Performance

`mesh-grid-update` drives the maximum 16 retained mesh patches (256 control
points and 64 corner colors) through rebuild, layout materialization, diff,
binary encode, and packet present. The current Apple Silicon measurement is
182, 206, and 277 microseconds across the three check passes: a 206-microsecond
median p50 against a 500-microsecond regression gate.

That benchmark measures engine overhead, not shader time. On Windows, setting
`NATIVE_SDK_D3D_GRADIENT_BENCH=1` enables a hardware-only D3D11 timestamp test:

```powershell
$env:NATIVE_SDK_D3D_GRADIENT_BENCH = "1"
$env:NATIVE_SDK_D3D_GRADIENT_BUDGET_US = "<machine-specific-budget>"
zig build test-windows-d3d-presenter
```

It renders a 512×512, 4×4, 16-patch Oklab mesh, warms up 8 draws, and timestamps
64 draws with `D3D11_QUERY_TIMESTAMP` inside a disjoint query. It never uses
WARP. There is no universal checked-in microsecond budget because GPU classes
are not interchangeable; a known Windows runner should establish and own its
budget. This lane compiles on macOS through the cross-build but cannot produce
an honest hardware number there.

Static gradients preserve idle-zero: they create no timer and schedule no
frame. GPU work occurs only when a frame is already being presented.

## Contribution sequence

The clean upstream series is smaller and more reviewable than one giant port:

1. Add shared spread/interpolation semantics and independent reference tests.
   Bring the existing Direct2D linear path into conformance first.
2. Add radial and conic model arms, resource/fingerprint/packet support, and
   catalog scenes, followed by native platform fast paths.
3. Add bicubic mesh model/reference/resource/packet support and the bounded
   builder store.
4. Add sparse retained background paints and bottom-to-top layer composition
   against official Native's current widget architecture.
5. Keep the Weaver D3D presenter patch in the fork, or propose it separately as
   a new official backend. Do not claim it fixes official Direct2D code.

Every contribution should carry its own semantic fixtures, visual catalog
change, packet compatibility assertion, retained-footprint receipt, and focused
benchmark. A backend is complete when it agrees with those receipts, not when
it merely draws something gradient-like.

## Primary sources

- [Official Native repository](https://github.com/vercel-labs/native)
- [Official linear paint model](https://github.com/vercel-labs/native/blob/48629b3f15c5f6b9858e2f7d45c4c3074a1816f1/src/primitives/canvas/drawing.zig)
- [Official Direct2D renderer](https://github.com/vercel-labs/native/blob/48629b3f15c5f6b9858e2f7d45c4c3074a1816f1/src/platform/windows/gpu_surface_renderer.cpp)
- [CSS Images gradient model](https://drafts.csswg.org/css-images-4/#gradients)
- [CSS Color interpolation](https://drafts.csswg.org/css-color-4/#interpolation-space)
- [Cairo mesh pattern model](https://www.cairographics.org/manual/cairo-cairo-pattern-t.html)
- [Direct2D gradient meshes](https://learn.microsoft.com/en-us/windows/win32/api/d2d1_3/nf-d2d1_3-id2d1devicecontext2-creategradientmesh)
- [D3D11 timestamp queries](https://learn.microsoft.com/en-us/windows/win32/api/d3d11/ne-d3d11-d3d11_query)
