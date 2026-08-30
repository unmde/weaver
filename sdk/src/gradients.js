import { tailwindColors } from "./tailwind-colors.js";
const maxLayers = 8;
const maxStops = 64;
const maxMeshPatches = 16;
const maxWireBytes = 16 * 1024;
const maxCoordinate = 1e6;
function finite(value, label) {
  if (!Number.isFinite(value) || Math.abs(value) > maxCoordinate) {
    throw new Error(`${label} must be finite and no larger than ${maxCoordinate}`);
  }
  return value;
}
function point(value, fallback, label) {
  const source = value ?? fallback;
  if (!Array.isArray(source) || source.length !== 2) throw new Error(`${label} must be [x, y]`);
  return [finite(source[0], `${label}[0]`), finite(source[1], `${label}[1]`)];
}
function color(value, label) {
  if (typeof value !== "string") throw new Error(`${label} must be a hex or Tailwind color`);
  const named = tailwindColors[value];
  if (named !== void 0) return named;
  const match = /^(#[0-9a-fA-F]{3}|#[0-9a-fA-F]{4}|#[0-9a-fA-F]{6}|#[0-9a-fA-F]{8})$/.exec(value);
  if (!match) throw new Error(`${label} must be #RGB, #RGBA, #RRGGBB, #RRGGBBAA, or a Tailwind color name`);
  const hex = match[1].slice(1);
  if (hex.length === 3 || hex.length === 4) {
    return `#${hex.split("").map((digit) => digit + digit).join("")}${hex.length === 3 ? "FF" : ""}`.toUpperCase();
  }
  return `#${hex}${hex.length === 6 ? "FF" : ""}`.toUpperCase();
}
function interpolation(value) {
  if (value === void 0 || value === "srgb-linear") return "srgb_linear";
  if (value === "srgb" || value === "oklab") return value;
  throw new Error(`gradient interpolation must be "srgb", "srgb-linear", or "oklab"`);
}
function spread(value) {
  if (value === void 0) return "pad";
  if (value === "pad" || value === "repeat" || value === "reflect") return value;
  throw new Error(`gradient spread must be "pad", "repeat", or "reflect"`);
}
function stops(values, state, label) {
  if (!Array.isArray(values) || values.length < 2) throw new Error(`${label}.stops requires at least two stops`);
  state.stops += values.length;
  if (state.stops > maxStops) throw new Error(`gradient stack exceeds ${maxStops} total stops`);
  return values.map((stop, index) => ({
    offset: finite(stop.offset, `${label}.stops[${index}].offset`),
    color: color(stop.color, `${label}.stops[${index}].color`)
  }));
}
function serializeBackground(background) {
  const layers = Array.isArray(background) ? background : [background];
  if (layers.length === 0 || layers.length > maxLayers) throw new Error(`background requires 1-${maxLayers} gradient layers`);
  const state = { stops: 0, patches: 0 };
  const wireLayers = layers.map((layer, layerIndex) => {
    const label = `background[${layerIndex}]`;
    if (!layer || typeof layer !== "object") throw new Error(`${label} must be a gradient object`);
    switch (layer.type) {
      case "linear":
        return {
          kind: "linear",
          start: point(layer.start, [0, 0.5], `${label}.start`),
          end: point(layer.end, [1, 0.5], `${label}.end`),
          stops: stops(layer.stops, state, label),
          spread: spread(layer.spread),
          interpolation: interpolation(layer.interpolation)
        };
      case "radial":
        return {
          kind: "radial",
          center: point(layer.center, [0.5, 0.5], `${label}.center`),
          radii: point(layer.radius, [0.5, 0.5], `${label}.radius`),
          stops: stops(layer.stops, state, label),
          spread: spread(layer.spread),
          interpolation: interpolation(layer.interpolation)
        };
      case "conic":
        return {
          kind: "conic",
          center: point(layer.center, [0.5, 0.5], `${label}.center`),
          from_degrees: finite(layer.from ?? 0, `${label}.from`),
          stops: stops(layer.stops, state, label),
          spread: spread(layer.spread),
          interpolation: interpolation(layer.interpolation)
        };
      case "mesh": {
        if (!Array.isArray(layer.patches) || layer.patches.length === 0) throw new Error(`${label}.patches requires at least one patch`);
        state.patches += layer.patches.length;
        if (state.patches > maxMeshPatches) throw new Error(`gradient stack exceeds ${maxMeshPatches} total mesh patches`);
        return {
          kind: "mesh",
          patches: layer.patches.map((patch, patchIndex) => {
            if (!Array.isArray(patch.points) || patch.points.length !== 16) {
              throw new Error(`${label}.patches[${patchIndex}].points must contain exactly 16 points`);
            }
            if (!Array.isArray(patch.colors) || patch.colors.length !== 4) {
              throw new Error(`${label}.patches[${patchIndex}].colors must contain exactly four colors`);
            }
            return {
              points: patch.points.map((value, pointIndex) => point(value, [0, 0], `${label}.patches[${patchIndex}].points[${pointIndex}]`)),
              colors: patch.colors.map((value, colorIndex) => color(value, `${label}.patches[${patchIndex}].colors[${colorIndex}]`))
            };
          }),
          interpolation: interpolation(layer.interpolation)
        };
      }
      default:
        throw new Error(`${label}.type must be "linear", "radial", "conic", or "mesh"`);
    }
  });
  const wire = JSON.stringify({ v: 1, layers: wireLayers });
  // Every value admitted above is canonical ASCII: fixed keys/enums, JSON
  // numbers, and normalized hex colors. Avoid requiring browser Web APIs in
  // Weaver's deliberately small QuickJS environment.
  if (wire.length > maxWireBytes) throw new Error(`background gradient exceeds ${maxWireBytes} wire bytes`);
  return wire;
}
export {
  serializeBackground
};
