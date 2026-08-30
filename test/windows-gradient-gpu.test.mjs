import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const scriptUrl = new URL("../scripts/verify-gradient-gpu.ps1", import.meta.url);
const captureUrl = new URL("../renderer/src/window_capture.cpp", import.meta.url);
const rendererBuildUrl = new URL("../renderer/build.zig", import.meta.url);
const sharedClientUrl = new URL(
  "../runtime/native-sdk/src/platform/windows/shared_renderer_client.cpp",
  import.meta.url,
);

test("Windows gradient receipt uses unambiguous benchmark and composed capture lanes", async () => {
  const [script, capture, rendererBuild, sharedClient] = await Promise.all([
    readFile(scriptUrl, "utf8"),
    readFile(captureUrl, "utf8"),
    readFile(rendererBuildUrl, "utf8"),
    readFile(sharedClientUrl, "utf8"),
  ]);

  assert.match(script, /bench-windows-d3d-gradient/);
  assert.doesNotMatch(script, /NATIVE_SDK_D3D_GRADIENT_BENCH/);
  assert.match(script, /weaver-window-capture\.exe/);
  assert.doesNotMatch(script, /CopyFromScreen/);

  assert.match(rendererBuild, /b\.step\("window-capture"/);
  assert.match(capture, /GraphicsCaptureItem::CreateForWindow/);
  assert.match(capture, /CreateSurfaceFromHandle/);
  assert.match(capture, /DuplicateHandle/);
  assert.match(capture, /CreateFreeThreaded/);
  assert.match(capture, /TryGetNextFrame/);
  assert.match(capture, /D3D_DRIVER_TYPE_HARDWARE/);
  assert.match(sharedClient, /SetPropW\(client->window/);
  assert.match(sharedClient, /RemovePropW\(client->window/);
});
