# weaver-renderer

`weaver-renderer.exe` is the Windows-only shared GPU process from ADR 0010.
The widget host starts it, in a job only the host holds, so it never
outlives the host (runtime/src/daemon.zig); users do not launch it directly.
The host sets `WEAVER_RENDERER_PIPE`, starts it lazily for the first GPU
artifact, and stops it after the last GPU widget exits.

The process compiles the Native SDK fork's NSGP/D3D presenter unit directly,
so the command decoder and instanced-SDF shaders have one implementation. It
creates one hardware D3D11 device, one cross-process DirectComposition surface
per connected widget, and answers each framed NSGP request only after the
surface present completes. Widget processes import duplicated composition
handles with a device-less DirectComposition device and never load D3D.

Build on Windows with Zig 0.16:

```powershell
zig build -Doptimize=ReleaseFast
```
