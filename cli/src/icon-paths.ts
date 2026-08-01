import { createRequire } from "node:module";
import { SVGPathData, SVGPathDataTransformer, type SVGCommand } from "svg-pathdata";

// Lucide Static 1.26.0 contains 1,749 icons; normalizing the whole catalog
// measured "puzzle" largest at 2,099 UTF-8 bytes (45 path elements), while
// shipped widgets peak at 1,037. 8 KiB leaves 3.9x byte headroom. The runtime
// allocates exact path length, so unused allowance costs no memory. Pinned to
// runtime/src/tree.zig max_icon_path_bytes.
export const MAX_ICON_PATH_BYTES = 8 * 1024;
export const LUCIDE_STATIC_VERSION = "1.26.0";
export const LUCIDE_STATIC_SHA1 = "cdaec64ebb9ba10d9ce0fc065184b9dde3eb992d";
export const DEFAULT_ICON_VIEW_BOX = "0 0 24 24";

type IconNode = readonly [tag: string, attributes: Readonly<Record<string, string>>];
type IconCatalog = Readonly<Record<string, readonly IconNode[]>>;

const require = createRequire(import.meta.url);
const catalog = require("lucide-static/icon-nodes.json") as IconCatalog;
export const iconNames = Object.freeze(Object.keys(catalog).sort((left, right) => left.localeCompare(right, "en")));
const iconNameSet = new Set(iconNames);
const normalizedIconCache = new Map<string, string>();

function finiteCoordinate(value: number): number {
  if (!Number.isFinite(value) || Math.abs(value) > 1_000_000) throw new Error("SVG path coordinates must be finite and no larger than 1000000");
  const rounded = Math.round(value * 1_000_000) / 1_000_000;
  return Object.is(rounded, -0) ? 0 : rounded;
}

function coordinateText(value: number): string {
  return String(finiteCoordinate(value));
}

function numeric(attributes: Readonly<Record<string, string>>, key: string, fallback = 0): number {
  const raw = attributes[key];
  if (raw === undefined) return fallback;
  const value = Number(raw);
  return finiteCoordinate(value);
}

function pointsPath(raw: string, close: boolean): string {
  const values = raw.trim().split(/[\s,]+/).filter(Boolean).map(Number);
  if (values.length < 4 || values.length % 2 !== 0 || values.some((value) => !Number.isFinite(value))) {
    throw new Error("Lucide points data is malformed");
  }
  const commands = [`M ${coordinateText(values[0])} ${coordinateText(values[1])}`];
  for (let index = 2; index < values.length; index += 2) {
    commands.push(`L ${coordinateText(values[index])} ${coordinateText(values[index + 1])}`);
  }
  if (close) commands.push("Z");
  return commands.join(" ");
}

function rectPath(attributes: Readonly<Record<string, string>>): string {
  const x = numeric(attributes, "x");
  const y = numeric(attributes, "y");
  const width = numeric(attributes, "width");
  const height = numeric(attributes, "height");
  let rx = numeric(attributes, "rx", numeric(attributes, "ry"));
  let ry = numeric(attributes, "ry", rx);
  rx = Math.min(Math.abs(rx), Math.abs(width) / 2);
  ry = Math.min(Math.abs(ry), Math.abs(height) / 2);
  if (rx === 0 || ry === 0) {
    return `M ${coordinateText(x)} ${coordinateText(y)} L ${coordinateText(x + width)} ${coordinateText(y)} L ${coordinateText(x + width)} ${coordinateText(y + height)} L ${coordinateText(x)} ${coordinateText(y + height)} Z`;
  }
  return [
    `M ${coordinateText(x + rx)} ${coordinateText(y)}`,
    `L ${coordinateText(x + width - rx)} ${coordinateText(y)}`,
    `A ${coordinateText(rx)} ${coordinateText(ry)} 0 0 1 ${coordinateText(x + width)} ${coordinateText(y + ry)}`,
    `L ${coordinateText(x + width)} ${coordinateText(y + height - ry)}`,
    `A ${coordinateText(rx)} ${coordinateText(ry)} 0 0 1 ${coordinateText(x + width - rx)} ${coordinateText(y + height)}`,
    `L ${coordinateText(x + rx)} ${coordinateText(y + height)}`,
    `A ${coordinateText(rx)} ${coordinateText(ry)} 0 0 1 ${coordinateText(x)} ${coordinateText(y + height - ry)}`,
    `L ${coordinateText(x)} ${coordinateText(y + ry)}`,
    `A ${coordinateText(rx)} ${coordinateText(ry)} 0 0 1 ${coordinateText(x + rx)} ${coordinateText(y)}`,
    "Z",
  ].join(" ");
}

function nodePath([tag, attributes]: IconNode): string {
  switch (tag) {
    case "path":
      if (!attributes.d) throw new Error("Lucide path node is missing d");
      return attributes.d;
    case "line":
      return `M ${coordinateText(numeric(attributes, "x1"))} ${coordinateText(numeric(attributes, "y1"))} L ${coordinateText(numeric(attributes, "x2"))} ${coordinateText(numeric(attributes, "y2"))}`;
    case "polyline":
      return pointsPath(attributes.points ?? "", false);
    case "polygon":
      return pointsPath(attributes.points ?? "", true);
    case "rect":
      return rectPath(attributes);
    case "circle": {
      const cx = numeric(attributes, "cx");
      const cy = numeric(attributes, "cy");
      const radius = Math.abs(numeric(attributes, "r"));
      return `M ${coordinateText(cx - radius)} ${coordinateText(cy)} A ${coordinateText(radius)} ${coordinateText(radius)} 0 1 0 ${coordinateText(cx + radius)} ${coordinateText(cy)} A ${coordinateText(radius)} ${coordinateText(radius)} 0 1 0 ${coordinateText(cx - radius)} ${coordinateText(cy)} Z`;
    }
    case "ellipse": {
      const cx = numeric(attributes, "cx");
      const cy = numeric(attributes, "cy");
      const rx = Math.abs(numeric(attributes, "rx"));
      const ry = Math.abs(numeric(attributes, "ry"));
      return `M ${coordinateText(cx - rx)} ${coordinateText(cy)} A ${coordinateText(rx)} ${coordinateText(ry)} 0 1 0 ${coordinateText(cx + rx)} ${coordinateText(cy)} A ${coordinateText(rx)} ${coordinateText(ry)} 0 1 0 ${coordinateText(cx - rx)} ${coordinateText(cy)} Z`;
    }
    default:
      throw new Error(`Unsupported Lucide SVG node <${tag}>`);
  }
}

function serializeCommand(command: SVGCommand): string {
  switch (command.type) {
    case SVGPathData.MOVE_TO:
      return `M ${coordinateText(command.x)} ${coordinateText(command.y)}`;
    case SVGPathData.LINE_TO:
      return `L ${coordinateText(command.x)} ${coordinateText(command.y)}`;
    case SVGPathData.CURVE_TO:
      return `C ${coordinateText(command.x1)} ${coordinateText(command.y1)} ${coordinateText(command.x2)} ${coordinateText(command.y2)} ${coordinateText(command.x)} ${coordinateText(command.y)}`;
    case SVGPathData.CLOSE_PATH:
      return "Z";
    default:
      throw new Error("SVG path normalization did not eliminate a non-M/L/C/Z command");
  }
}

export function normalizeSvgPath(source: string): string {
  if (source.trim().length === 0) throw new Error("SVG path data must not be empty");
  let path: SVGPathData;
  try {
    path = new SVGPathData(source)
      .transform(SVGPathDataTransformer.TO_ABS())
      .transform(SVGPathDataTransformer.NORMALIZE_ST())
      .transform(SVGPathDataTransformer.QT_TO_C())
      .transform(SVGPathDataTransformer.A_TO_C())
      .transform(SVGPathDataTransformer.NORMALIZE_HVZ(false, true, true, false));
  } catch (error) {
    throw new Error(`Invalid SVG path data: ${error instanceof Error ? error.message : String(error)}`);
  }
  const normalized = path.commands.map(serializeCommand).join(" ");
  if (Buffer.byteLength(normalized, "utf8") > MAX_ICON_PATH_BYTES) {
    throw new Error(`Normalized icon path exceeds the ${MAX_ICON_PATH_BYTES}-byte per-node limit`);
  }
  return normalized;
}

export function normalizedLucidePath(name: string): string {
  const cached = normalizedIconCache.get(name);
  if (cached) return cached;
  const nodes = catalog[name];
  if (!nodes) throw new Error(unknownIconMessage(name));
  const normalized = normalizeSvgPath(nodes.map(nodePath).join(" "));
  normalizedIconCache.set(name, normalized);
  return normalized;
}

export function normalizeViewBox(source = DEFAULT_ICON_VIEW_BOX): string {
  const values = source.trim().split(/[\s,]+/).filter(Boolean).map(Number);
  if (values.length !== 4 || values.some((value) => !Number.isFinite(value) || Math.abs(value) > 1_000_000) || values[2] <= 0 || values[3] <= 0) {
    throw new Error('icon viewBox must be four finite numbers "minX minY width height" with positive width and height');
  }
  return values.map(coordinateText).join(" ");
}

export function normalizedPathElementCount(path: string): number {
  return (path.match(/[MLCZ]/g) ?? []).length;
}

export function isIconName(value: string): boolean {
  return iconNameSet.has(value);
}

function editDistance(left: string, right: string): number {
  let previous = Array.from({ length: right.length + 1 }, (_, index) => index);
  for (let leftIndex = 0; leftIndex < left.length; leftIndex += 1) {
    const current = [leftIndex + 1];
    for (let rightIndex = 0; rightIndex < right.length; rightIndex += 1) {
      current.push(Math.min(
        current[rightIndex] + 1,
        previous[rightIndex + 1] + 1,
        previous[rightIndex] + (left[leftIndex] === right[rightIndex] ? 0 : 1),
      ));
    }
    previous = current;
  }
  return previous[right.length];
}

export function nearestIconName(value: string): string {
  let best = iconNames[0];
  let distance = Number.POSITIVE_INFINITY;
  for (const candidate of iconNames) {
    const candidateDistance = editDistance(value, candidate);
    if (candidateDistance < distance) {
      best = candidate;
      distance = candidateDistance;
    }
  }
  return best;
}

export function unknownIconMessage(value: string): string {
  return `Unknown Lucide icon "${value}". Did you mean "${nearestIconName(value)}"?`;
}
