---
name: verify-gradients
description: Verify Weaver gradient correctness, retained-pipeline behavior, GPU parity, idle behavior, and performance. Use for any gradient model, renderer, authoring, or optimization change.
---

# Verify Weaver gradients

Treat a gradient change as unproven until the applicable lanes below have real
artifacts. Compilation is necessary, never sufficient.

## Name the claim

Before editing, state which contract changes:

- geometry: linear, radial, conic, or mesh;
- spread: pad or repeat;
- interpolation space and hue rule;
- stop normalization and degenerate behavior;
- composition: one paint or an ordered background layer stack;
- transport: retained tree, display list, packet, platform renderer;
- performance: first frame, changed paint, resize, or idle.

Do not use “gradient” as shorthand for all of these. Repeating is spread
behavior, layering is composition, and mesh is a two-dimensional paint rather
than a stop-axis gradient.

## Fast loop

From `runtime/native-sdk`:

```sh
PATH=/Users/dara/.cargo/bin:/opt/homebrew/bin:$PATH zig fmt <changed-zig-files>
PATH=/Users/dara/.cargo/bin:/opt/homebrew/bin:$PATH zig build test
PATH=/Users/dara/.cargo/bin:/opt/homebrew/bin:$PATH zig build gradient-reference -- /tmp/weaver-gradient-reference
PATH=/Users/dara/.cargo/bin:/opt/homebrew/bin:$PATH zig build bench-render -Doptimize=ReleaseFast -- --scenario gradient-grid-update --check tools/bench-render-budgets.txt
```

Open at least the changed catalog PNGs. Read `manifest.json`; it is a
deterministic regression receipt labeled `normative: false`, not the semantics
oracle.

## Correctness lanes

For every supported shape/spread/interpolation combination:

1. Add independent analytic fixtures for endpoints, midpoint, alpha, repeated
   offsets, out-of-range stops, a degenerate axis, and a non-square box.
2. Add it to `tools/gradient_reference_catalog.zig` and inspect the PNG.
3. Prove retained equality/fingerprints, display-list resources, full packet,
   patch packet, and stop/patch limits.
4. Capture the actual platform GPU output and compare sample pixels plus a
   whole-image diff. Never substitute the reference screenshot for GPU output.
5. For CSS-compatible families, compare explicit interpolation cases against a
   browser fixture or the relevant Web Platform Test. For mesh, compare the
   documented Weaver patch evaluator against another implementation of the
   same patch contract; SVG 2 does not currently provide a normative mesh
   contract.

Pixel comparison must report max channel error, differing pixel count, and an
amplified diff image. Use exact pixels for the reference renderer; set a small,
named tolerance for platform color-management/quantization and keep it in the
test rather than in prose.

## Performance lanes

- Engine macrobenchmark: keep `gradient-grid-update` within its committed
  ReleaseFast budget. Extend it when the view-wide paint/stop limits change.
- macOS live renderer: use automation profiling and GPU frame trace against a
  real gradient catalog window; record CPU encode, host decode/draw, command
  buffer GPU duration, upload bytes, and steady process memory.
- Windows live renderer: run the matching catalog through `tools/windows-truth`
  and record D3D timestamp/disjoint GPU duration, CPU present time, upload
  bytes, and process memory.
- Run trunk and candidate interleaved at least three times. Report medians and
  p90; do not infer host GPU cost from the null-platform macrobenchmark.
- Leave the catalog static for an idle observation. It must schedule no timer,
  invalidation, packet, upload, or present after the first settled frame.

For shader alternatives, benchmark at least: 2/4/16 stops, opaque/translucent,
one and 16 paint instances, 1x/2x scale, update/resize/static. Compare direct
stop scan, ramp texture, and any proposed hybrid with identical fixtures.

## Platform truth

On macOS, the production shared Metal renderer is the proof surface. On
Windows, the custom D3D presenter is the proof surface; Direct2D behavior in
upstream Native is research evidence, not proof of Weaver's renderer.

If a live platform lane is unavailable, mark that lane `UNVERIFIED` with the
exact missing surface. Do not collapse it into a CPU fallback success.

## Completion receipt

Return:

- claims proved and unsupported combinations still explicit;
- focused and full test commands with results;
- catalog paths and inspected scenes;
- reference-versus-GPU diff metrics per platform;
- engine and live GPU performance numbers with trunk/candidate provenance;
- idle-zero receipt;
- any budget change with before/after calibration and rationale.
