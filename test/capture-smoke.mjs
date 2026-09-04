import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const root = process.cwd();
const cli = join(root, "cli", "bin", "weaver.js");
const outputRoot = mkdtempSync(join(tmpdir(), "weaver-capture-smoke-"));
const fixedClock = "2026-08-24T17:30:00.000Z";

try {
  const clock = capture("clock", "examples/clock");
  assert.deepEqual([clock.output.widthPx, clock.output.heightPx], [240, 110]);

  const resizedClock = capture("clock-resized", "examples/clock", [
    "--action-file", join(root, "test", "capture", "resize.actions"),
  ]);
  assert.deepEqual([resizedClock.output.widthPx, resizedClock.output.heightPx], [962, 719]);

  const text = capture("styling-text", "examples/styling-text");
  assert.ok(text.renderer.pixelsDifferentFromClear > 0);

  const images = capture("styling-images", "examples/styling-images");
  assert.equal(images.renderer.images, 3);
  assert.equal(images.pending.images, 0);

  const pomodoroBefore = capture("pomodoro-before", "examples/pomodoro");
  const pomodoroAfter = capture("pomodoro-after", "examples/pomodoro", [
    "--action-file", join(root, "test", "capture", "pomodoro.actions"),
  ]);
  assert.notEqual(imageHash(pomodoroBefore), imageHash(pomodoroAfter));
  assert.match(snapshotText(pomodoroAfter), /role=button name="Pause"/);
  assert.match(snapshotText(pomodoroAfter), /role=text name="24:59"/);

  const interactionBefore = capture("interaction-before", "examples/styling-interaction");
  const interactionAfter = capture("interaction-after", "examples/styling-interaction", [
    "--action-file", join(root, "test", "capture", "styling-interaction.actions"),
  ]);
  assert.notEqual(imageHash(interactionBefore), imageHash(interactionAfter));
  assert.match(snapshotText(interactionAfter), /role=slider .* value=0\.9/);
  assert.match(snapshotText(interactionAfter), /role=text name="90%"/);

  const tideglassBefore = capture("tideglass-before", "examples/tideglass");
  const tideglassAfter = capture("tideglass-after", "examples/tideglass", [
    "--action-file", join(root, "test", "capture", "tideglass.actions"),
  ]);
  assert.notEqual(imageHash(tideglassBefore), imageHash(tideglassAfter));
  assert.match(snapshotText(tideglassAfter), /role=text name="63%"/);
  assert.match(snapshotText(tideglassAfter), /role=text name="5 glasses logged"/);
  assert.deepEqual(tideglassAfter.interactions.actions, ["click", "click"]);
  assert.equal(tideglassAfter.pending.timers, 0);

  const noro = capture("noro", "examples/noro-shell", [
    "--provider-fixture", join(root, "test", "capture", "noro.provider.json"),
  ]);
  assert.ok(noro.renderer.images > 0);
  assert.ok(noro.renderer.fonts > 0);
  assert.match(snapshotText(noro), /name="CAPTURE PROOF"/);
  assert.match(snapshotText(noro), /role=button name="Seek"/);
  assert.match(snapshotText(noro), /name="00:42"/);

  const noroSignal = capture("noro-signal", "examples/noro-signal", [
    "--provider-fixture", join(root, "test", "capture", "noro.provider.json"),
  ]);
  assert.match(snapshotText(noroSignal), /name="Capture Proof"/);
  assert.match(snapshotText(noroSignal), /role=button name="Seek"/);
  assert.match(snapshotText(noroSignal), /role=button name="PAUSE"/);
  assert.match(snapshotText(noroSignal), /name="00:42"/);

  const noroSignalAction = capture("noro-signal-action", "examples/noro-signal", [
    "--provider-fixture", join(root, "test", "capture", "noro-action.provider.json"),
    "--action-file", join(root, "test", "capture", "noro-signal.actions"),
  ]);
  assert.match(snapshotText(noroSignalAction), /role=button name="Seek"/);
  assert.deepEqual(noroSignalAction.interactions, {
    actions: ["click"],
    mediaCommands: [{ verb: "pause", ok: true }],
  });

  const unexpectedTransport = captureFailure("noro-signal-action-unexpected", "examples/noro-signal", [
    "--provider-fixture", join(root, "test", "capture", "noro.provider.json"),
    "--action-file", join(root, "test", "capture", "noro-signal.actions"),
  ]);
  assert.equal(unexpectedTransport.error?.name, "CaptureMediaCommandUnexpected");

  const mismatchProviderFixture = join(outputRoot, "mismatch-provider.json");
  writeFileSync(mismatchProviderFixture, JSON.stringify({
    ...JSON.parse(readFileSync(join(root, "test", "capture", "noro.provider.json"), "utf8")),
    commands: [{ verb: "play" }],
  }));
  const mismatchedTransport = captureFailure("noro-signal-action-mismatch", "examples/noro-signal", [
    "--provider-fixture", mismatchProviderFixture,
    "--action-file", join(root, "test", "capture", "noro-signal.actions"),
  ]);
  assert.equal(mismatchedTransport.error?.name, "CaptureMediaCommandMismatch");

  const missingTransport = captureFailure("noro-signal-action-missing", "examples/noro-signal", [
    "--provider-fixture", join(root, "test", "capture", "noro-action.provider.json"),
  ]);
  assert.equal(missingTransport.error?.name, "CaptureMediaCommandMissing");

  const missingProvider = captureFailure("missing-provider", "examples/noro-shell");
  assert.equal(missingProvider.error?.name, "CaptureProviderUnavailable");
  assert.deepEqual(missingProvider.pending.providers, ["media"]);

  const invalidProviderFixture = join(outputRoot, "undeclared-provider.json");
  writeFileSync(invalidProviderFixture, JSON.stringify({
    schema: "weaver.provider-fixture.v1",
    frames: [{ provider: "cpu", value: { percent: 42 } }],
  }));
  const invalidProvider = captureFailure("invalid-provider", "examples/noro-shell", [
    "--provider-fixture", invalidProviderFixture,
  ]);
  assert.equal(invalidProvider.error?.name, "CaptureProviderFixtureUndeclared");

  const invalidCommandFixture = join(outputRoot, "invalid-command-provider.json");
  writeFileSync(invalidCommandFixture, JSON.stringify({
    ...JSON.parse(readFileSync(join(root, "test", "capture", "noro.provider.json"), "utf8")),
    commands: [{ verb: "seek" }],
  }));
  const invalidCommand = captureFailure("invalid-provider-command", "examples/noro-shell", [
    "--provider-fixture", invalidCommandFixture,
  ]);
  assert.equal(invalidCommand.error?.name, "CaptureProviderFixtureCommandInvalid");

  const unsafeSeekFixture = join(outputRoot, "unsafe-seek-provider.json");
  writeFileSync(unsafeSeekFixture, JSON.stringify({
    ...JSON.parse(readFileSync(join(root, "test", "capture", "noro.provider.json"), "utf8")),
    commands: [{ verb: "seek", seekMs: Number.MAX_SAFE_INTEGER + 1 }],
  }));
  const unsafeSeek = captureFailure("unsafe-provider-seek", "examples/noro-shell", [
    "--provider-fixture", unsafeSeekFixture,
  ]);
  assert.equal(unsafeSeek.error?.name, "CaptureProviderFixtureCommandInvalid");

  const undeclaredCapabilityFixture = join(outputRoot, "undeclared-capability-provider.json");
  writeFileSync(undeclaredCapabilityFixture, JSON.stringify({
    schema: "weaver.provider-fixture.v1",
    frames: [],
    commands: [{ verb: "play" }],
  }));
  const undeclaredCapability = captureFailure("invalid-provider-capability", "examples/clock", [
    "--provider-fixture", undeclaredCapabilityFixture,
  ]);
  assert.equal(undeclaredCapability.error?.name, "CaptureProviderFixtureCapabilityRequired");

  const ambiguous = captureFailure("ambiguous", "examples/pomodoro", [
    "--action-file", join(root, "test", "capture", "ambiguous-button.actions"),
  ]);
  assert.equal(ambiguous.error?.name, "CaptureTargetAmbiguous");
  assert.deepEqual(ambiguous.error?.candidates?.map(({ role, name }) => ({ role, name })), [
    { role: "button", name: "Start" },
    { role: "button", name: "Reset" },
  ]);

  const renderThrows = captureFailureRun("render-throws", "test/fixtures/render-throws");
  assert.equal(renderThrows.receipt.error?.name, "CaptureWidgetFailed");
  assert.match(renderThrows.receipt.error?.diagnostic ?? "", /^widget render failed:\nError: boom: deliberate render failure\n\s+at /);
  assert.match(renderThrows.stderr, /^diagnostic: widget render failed:\nError: boom: deliberate render failure\n\s+at /m);

  const pressThrows = capture("press-throws", "test/fixtures/press-throws");
  assert.match(snapshotText(pressThrows), /role=button name="Detonate"/);
  const pressThrowsClicked = captureFailureRun("press-throws-clicked", "test/fixtures/press-throws", [
    "--action-file", join(root, "test", "capture", "press-throws.actions"),
  ]);
  assert.equal(pressThrowsClicked.receipt.error?.name, "CaptureWidgetFailed");
  assert.match(pressThrowsClicked.receipt.error?.diagnostic ?? "", /^widget .+ failed:\nError: boom: deliberate press failure\n\s+at /);
  assert.match(pressThrowsClicked.stderr, /^diagnostic: widget .+ failed:\nError: boom: deliberate press failure\n\s+at /m);

  const recorded = recordClockSession();
  const replayed = capture("clock-replayed", "examples/clock", ["--session-journal", recorded.journal]);
  assert.equal(fileHash(recorded.image), imageHash(replayed));
  assert.deepEqual(replayed.renderer.eventsDriven, ["session_journal"]);
  assert.ok(replayed.inputs.sessionJournalSha256);

  process.stdout.write("weaver capture smoke passed: pixels, resize, semantics, actions, providers, isolation, widget diagnostics, and session replay\n");
} finally {
  rmSync(outputRoot, { recursive: true, force: true });
}

function capture(name, directory, extra = []) {
  const result = runCapture(name, directory, extra);
  assert.equal(result.process.status, 0, result.process.stderr);
  assert.equal(result.receipt.status, "ok");
  assert.ok(result.receipt.renderer.nodes > 0);
  assert.ok(result.receipt.renderer.commands > 0);
  assert.ok(result.receipt.renderer.pixelsDifferentFromClear > 0);
  assert.ok(existsSync(result.receipt.output.image));
  assert.ok(existsSync(result.receipt.output.snapshot));
  assert.deepEqual(JSON.parse(readFileSync(result.receiptPath, "utf8")), result.receipt);
  return result.receipt;
}

function captureFailure(name, directory, extra = []) {
  return captureFailureRun(name, directory, extra).receipt;
}

function captureFailureRun(name, directory, extra = []) {
  const result = runCapture(name, directory, extra);
  assert.equal(result.process.status, 1, result.process.stderr);
  assert.equal(result.receipt.status, "error");
  assert.equal(existsSync(result.image), false);
  assert.equal(existsSync(result.snapshot), false);
  assert.equal(existsSync(result.receiptPath), false);
  return { receipt: result.receipt, stderr: result.process.stderr };
}

function runCapture(name, directory, extra = []) {
  const image = join(outputRoot, `${name}.png`);
  const snapshot = join(outputRoot, `${name}.snapshot.txt`);
  const receiptPath = join(outputRoot, `${name}.receipt.json`);
  const processResult = spawnSync(process.execPath, [
    cli, "capture", join(root, directory), "--clock", fixedClock, "--out", image, ...extra,
  ], {
    cwd: root,
    encoding: "utf8",
    env: process.env,
  });
  const stdoutLines = processResult.stdout.trimEnd().split("\n");
  assert.equal(stdoutLines.length, 1, processResult.stdout);
  return {
    image,
    snapshot,
    receiptPath,
    process: processResult,
    receipt: JSON.parse(stdoutLines[0]),
  };
}

function imageHash(receipt) {
  return fileHash(receipt.output.image);
}

function fileHash(path) {
  return createHash("sha256").update(readFileSync(path)).digest("hex");
}

function recordClockSession() {
  const image = join(outputRoot, "clock-recorded.png");
  const snapshot = join(outputRoot, "clock-recorded.snapshot.txt");
  const resultPath = join(outputRoot, "clock-recorded.native-result.json");
  const journal = join(outputRoot, "clock.nsjournal");
  const stateRoot = join(outputRoot, "clock-recorded-state");
  mkdirSync(stateRoot);
  const environment = {
    ...process.env,
    WEAVER_CAPTURE_STATE_ROOT: stateRoot,
    WEAVER_CAPTURE_CLOCK_EPOCH_MS: String(Date.parse(fixedClock)),
    NATIVE_SDK_CAPTURE_IMAGE: image,
    NATIVE_SDK_CAPTURE_SNAPSHOT: snapshot,
    NATIVE_SDK_CAPTURE_RESULT: resultPath,
    NATIVE_SDK_SESSION_RECORD: journal,
  };
  delete environment.WEAVER_HOST_PIPE;
  delete environment.WEAVER_HOST_ENDPOINT;
  delete environment.WEAVER_ART_CACHE;
  delete environment.WEAVER_BACKEND_FILE;
  const result = spawnSync(join(root, "runtime", "zig-out", "bin", process.platform === "win32" ? "weaver-widget.exe" : "weaver-widget"), [
    join(root, "examples", "clock", "dist"),
  ], { cwd: root, encoding: "utf8", env: environment });
  assert.equal(result.status, 0, result.stderr);
  assert.ok(existsSync(journal));
  assert.equal(JSON.parse(readFileSync(resultPath, "utf8")).status, "ok");
  return { image, journal };
}

function snapshotText(receipt) {
  return readFileSync(receipt.output.snapshot, "utf8");
}
