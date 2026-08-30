# Windows gradient GPU handoff

This pass owns the Windows implementation loop for the current Weaver gradient
work. The Windows agent may diagnose failures, edit both repositories, add
tests, commit, push, and rerun until the hardware receipt is honest. Upstream
contribution and merging remain out of scope.

## Agent operating contract

Work on these branches only:

- Weaver: `agent/gradient-exploration`
- Native: `agent/windows-gradient-gpu-spike`

Do not merge either PR, rebase shared history, force-push, or modify `master`.
Preserve unrelated work. A verifier failure is work to diagnose, not a reason
to weaken the check.

When a run fails or an image is wrong:

1. Keep the failed ZIP unchanged. Read `results.json`, the named command log,
   `windows-dpi.log`, and both PNGs.
2. Reproduce the narrow failure before editing.
3. Fix the owning layer. Weaver owns the acceptance script, CLI, runtime, host,
   renderer, and outer integration. Native owns the Windows D3D presenter,
   shared-renderer client, window styles, and packet decoding.
4. Add a regression check that fails on the observed behavior.
5. Run the focused test first, then the relevant repository suite.
6. Commit and push Native first if it changed. Update Weaver's Native gitlink
   and `expectedNativeCommit` in `scripts/release-audit.mjs`, run
   `npm run audit:release`, then commit and push Weaver.
7. Watch both PRs. Fix real Greptile findings. If Greptile fails only because
   its cached submodule is stale or its runner times out, retrigger it on the
   unchanged head with `@greptileai` and cite the exact-pin CI check.
8. Rerun this script. Open both PNGs yourself. Return the final ZIP, the exact
   Weaver and Native commits, and a short list of fixes you pushed.

The loop ends only when the v2 receipt passes, every command log is clean, the
GPU screenshot visibly matches the reference, both worktrees are clean, and
both PR heads are pushed. Do not stop after compilation or `backend=gpu`.

## Current Windows work

The previous v2 receipt passed on an RTX 4070 after the Windows implementation
fixed D3D bootstrap, transformed conic axes, hybrid presentation invalidation,
the standalone hardware benchmark, and DirectComposition capture through
Windows Graphics Capture. Preserve those fixes; do not return to desktop
`CopyFromScreen`, WARP, a CPU widget backend, or ambiguous build-run steps.

This rerun closes the two changes made after that receipt:

- Native moved large renderer scratch buffers out of static TLS. Confirm the
  Windows host still starts cleanly and record the settled working set.
- Asymmetric corner overrides moved from every hot `WidgetStyle` into rare
  retained metadata. Confirm the complete mixed-content showcase still renders
  correctly and the receipt remains 57/57.

Start from the pushed branch heads, not hashes copied from an older receipt.
Before every full run, require both diff checks to exit zero, the two Weaver
heads to match, and all three Native heads to match. If another agent pushed a
fix, fetch and repeat them:

```powershell
git diff --exit-code
git -C runtime/native-sdk diff --exit-code
git rev-parse HEAD
git rev-parse origin/agent/gradient-exploration
git -C runtime/native-sdk rev-parse HEAD
git -C runtime/native-sdk rev-parse origin/agent/windows-gradient-gpu-spike
git rev-parse HEAD:runtime/native-sdk
```

## What the run proves

The script checks the exact Weaver and Native submodule commits, runs the
authoring and semantic suites, builds the Windows runtime, host, and shared
renderer, and then exercises D3D11 on a hardware adapter. It records nine
independent GPU timestamp samples for the worst current paint, a 512 by 512
Oklab mesh with 16 patches. It also installs the complete gradient showcase,
requires the live status to report `backend=gpu`, captures both the reference
renderer and the real window, and records a ten-second settled CPU and memory
sample. It does not accept the status marker alone: `windows-dpi.log` must also
record the widget's completed shared D3D11 surface. Every showcase panel also
carries retained label text and a text shadow above its gradient, so the pair
of receipts proves the mixed-content path did not demote the frame.

The D3D test calls `D3D11CreateDevice` with `D3D_DRIVER_TYPE_HARDWARE` and
rejects adapters marked `DXGI_ADAPTER_FLAG_SOFTWARE`. WARP is not an accepted
result. The run reports median and p90 timing but applies no universal GPU
budget. This first receipt establishes the budget for this machine.

## Machine setup

Use a normal signed-in Windows desktop session, not Remote Desktop. Remote
Desktop can replace the active display adapter and makes the window capture a
bad receipt.

Install:

- Git for Windows
- Node.js 20.11 or newer
- Zig 0.16.0
- PowerShell 7

Make sure `git`, `node`, `npm`, `zig`, and `pwsh` resolve in a fresh PowerShell
window. Update the display driver before the run, then reboot if the installer
asks.

## Start or resume the branches

```powershell
git fetch origin
git switch agent/gradient-exploration
git pull --ff-only origin agent/gradient-exploration
git submodule update --init --recursive

git -C runtime/native-sdk fetch origin
git -C runtime/native-sdk switch agent/windows-gradient-gpu-spike
git -C runtime/native-sdk pull --ff-only origin agent/windows-gradient-gpu-spike

git rev-parse HEAD
git -C runtime/native-sdk rev-parse HEAD
```

For a fresh checkout, clone Weaver first and create the tracking Weaver branch
with `git switch --track origin/agent/gradient-exploration`.

Run the complete receipt after focused fixes pass:

```powershell
pwsh -NoProfile -File .\scripts\verify-gradient-gpu.ps1
```

Do not use `WEAVER_FORCE_SOFTWARE`. Close games, video calls, GPU profilers,
and overlays before running. Leave the desktop unlocked while the showcase is
captured. The script may take several minutes because it starts from `npm ci`
and builds the native Windows programs in ReleaseFast mode.

## Return exactly one file

The final console line prints a ZIP path like:

```text
...\artifacts\windows-gradient-gpu-20260830-153000.zip
```

Return that ZIP without unpacking or editing it. It contains `results.json`,
the real GPU window capture, `windows-dpi.log`, and each command log. A failed
run still writes a ZIP, so return it as-is instead of retrying blindly. The
failure evidence is usually more useful than a clean second attempt.

The acceptance gate is:

- `results.json` has schema `weaver.windows-gradient-gpu.v2` and
  `status: "passed"`;
- every recorded command exits zero;
- no benchmark log contains `failed command:`;
- all timestamp samples name one stable hardware adapter and contain finite
  microseconds per draw;
- the bundled showcase selects `renderBackend: "gpu"`;
- the live widget reports `backend: "gpu"`;
- `windows-dpi.log` records a completed shared-renderer surface for that exact
  widget PID;
- the GPU capture has the same dimensions as the deterministic reference and
  passes the sampled similarity gate;
- every panel label and text shadow remains visible above its GPU gradient;
- `gradient-stack-gpu.png` visibly agrees with
  `gradient-stack-reference.png` for the linear, radial, conic, repeating,
  layered, and mesh panels.

The screenshot still needs human inspection. The script intentionally does not
pretend that a high unique-color count or a similarity score proves gradient
semantics.
