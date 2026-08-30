# Windows gradient GPU handoff

This pass tests the current Weaver gradient implementation. Upstream Native
work is deliberately out of scope.

## What the run proves

The script checks the exact Weaver and Native submodule commits, runs the
authoring and semantic suites, builds the Windows runtime, host, and shared
renderer, and then exercises D3D11 on a hardware adapter. It records nine
independent GPU timestamp samples for the worst current paint, a 512 by 512
Oklab mesh with 16 patches. It also installs the complete gradient showcase,
requires the live status to report `backend=gpu`, captures both the reference
renderer and the real window, and records a ten-second settled CPU and memory
sample. Every showcase panel also carries retained label text and a text
shadow above its gradient, so `backend: "gpu"` proves the mixed-content path
did not demote the frame.

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

## Run

```powershell
git clone https://github.com/unmde/weaver.git
cd weaver
git fetch origin agent/gradient-exploration
git switch --track origin/agent/gradient-exploration
git submodule update --init --recursive
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
the real GPU window capture, and each command log. A failed run still writes a
ZIP, so return it as-is instead of retrying blindly. The failure evidence is
usually more useful than a clean second attempt.

The acceptance gate is:

- `results.json` has `status: "passed"`;
- every recorded command exits zero;
- all timestamp samples name one stable hardware adapter and contain finite
  microseconds per draw;
- the bundled showcase selects `renderBackend: "gpu"`;
- the live widget reports `backend: "gpu"`; and
- every panel label and text shadow remains visible above its GPU gradient;
- `gradient-stack-gpu.png` visibly agrees with
  `gradient-stack-reference.png` for the linear, radial, conic, repeating,
  layered, and mesh panels.

The screenshot still needs human inspection. The script intentionally does not
pretend that a high unique-color count proves gradient semantics.
