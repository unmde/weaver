export type GradientPoint = readonly [x: number, y: number];
export type GradientInterpolation = "srgb" | "srgb-linear" | "oklab";
export type GradientSpread = "pad" | "repeat" | "reflect";

export interface GradientStop {
  offset: number;
  color: string;
}

interface GradientOptions {
  interpolation?: GradientInterpolation;
}

interface AxisGradientOptions extends GradientOptions {
  spread?: GradientSpread;
  stops: readonly GradientStop[];
}

export interface LinearGradient extends AxisGradientOptions {
  type: "linear";
  start?: GradientPoint;
  end?: GradientPoint;
}

export interface RadialGradient extends AxisGradientOptions {
  type: "radial";
  center?: GradientPoint;
  radius?: GradientPoint;
}

export interface ConicGradient extends AxisGradientOptions {
  type: "conic";
  center?: GradientPoint;
  /** Clockwise degrees from twelve o'clock, matching CSS conic gradients. */
  from?: number;
}

export interface MeshPatch {
  /** Sixteen row-major bicubic control points in normalized box coordinates. */
  points: readonly GradientPoint[];
  /** Corner colors clockwise: top-left, top-right, bottom-right, bottom-left. */
  colors: readonly [string, string, string, string];
}

export interface MeshGradient extends GradientOptions {
  type: "mesh";
  patches: readonly MeshPatch[];
}

export type BackgroundGradient = LinearGradient | RadialGradient | ConicGradient | MeshGradient;
export type BackgroundGradientStack = BackgroundGradient | readonly BackgroundGradient[];

/** Validate and serialize one gradient or a bottom-to-top painter-ordered stack. */
export function serializeBackground(background: BackgroundGradientStack): string;
