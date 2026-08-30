import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { serializeBackground } from "../src/gradients.js";

const meshPoints = Array.from({ length: 16 }, (_, index) => [index % 4 / 3, Math.floor(index / 4) / 3]);

test("typed backgrounds serialize every gradient family and painter order", () => {
  const document = JSON.parse(serializeBackground([
    { type: "linear", start: [0, 0], end: [1, 1], stops: [{ offset: 0, color: "red-500" }, { offset: 1, color: "#00f" }] },
    { type: "radial", center: [0.25, 0.5], radius: [0.8, 1], spread: "reflect", interpolation: "oklab", stops: [{ offset: 0, color: "#fff8" }, { offset: 1, color: "transparent" }] },
    { type: "conic", from: 90, spread: "repeat", interpolation: "srgb", stops: [{ offset: 0, color: "#ff0" }, { offset: 0.25, color: "#0ff" }] },
    { type: "mesh", patches: [{ points: meshPoints, colors: ["red-500", "green-500", "blue-500", "white"] }] },
  ]));
  assert.deepEqual(document.layers.map((layer) => layer.kind), ["linear", "radial", "conic", "mesh"]);
  assert.equal(document.layers[1].spread, "reflect");
  assert.equal(document.layers[1].interpolation, "oklab");
  assert.equal(document.layers[2].from_degrees, 90);
  assert.equal(document.layers[3].patches[0].points.length, 16);
  assert.deepEqual(document.layers[3].patches[0].colors, ["#FB2C36FF", "#00C950FF", "#2B7FFFFF", "#FFFFFFFF"]);
});

test("typed backgrounds reject malformed and unbounded resources before native mutation", () => {
  assert.throws(() => serializeBackground({ type: "linear", stops: [{ offset: 0, color: "red-500" }] }), /at least two stops/);
  assert.throws(() => serializeBackground({ type: "mesh", patches: [{ points: meshPoints.slice(0, 15), colors: ["#000", "#000", "#000", "#000"] }] }), /exactly 16 points/);
  assert.throws(() => serializeBackground(Array.from({ length: 9 }, () => ({ type: "linear", stops: [{ offset: 0, color: "#000" }, { offset: 1, color: "#fff" }] }))), /1-8 gradient layers/);
  assert.throws(() => serializeBackground({ type: "radial", radius: [Number.NaN, 1], stops: [{ offset: 0, color: "#000" }, { offset: 1, color: "#fff" }] }), /must be finite/);
});

test("gradient serialization has no browser Web API dependency", () => {
  const source = readFileSync(new URL("../src/gradients.js", import.meta.url), "utf8");
  assert.doesNotMatch(source, /TextEncoder|Buffer\./);
  assert.equal(
    JSON.parse(serializeBackground({
      type: "linear",
      stops: [{ offset: 0, color: "#000" }, { offset: 1, color: "#fff" }],
    })).v,
    1,
  );
});
