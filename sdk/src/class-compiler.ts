import { tailwindColors } from "./tailwind-colors.js";
import { serializeBackground } from "./gradients.js";

export type CrossAlign = "start" | "center" | "end" | "baseline" | "stretch";
export type MainAlign = "start" | "center" | "end" | "between" | "around" | "evenly";
export type SelfAlign = "auto" | "start" | "center" | "end" | "stretch";

export interface ClassProps {
  padding?: number;
  paddingTop?: number;
  paddingRight?: number;
  paddingBottom?: number;
  paddingLeft?: number;
  marginTop?: number;
  marginRight?: number;
  marginBottom?: number;
  marginLeft?: number;
  gap?: number;
  radius?: number;
  radiusTopLeft?: number;
  radiusTopRight?: number;
  radiusBottomRight?: number;
  radiusBottomLeft?: number;
  borderWidth?: number;
  borderColor?: string;
  shadow?: string;
  shadowInset?: boolean;
  textShadow?: string;
  background?: string;
  backgroundGradient?: string;
  textColor?: string;
  fontScale?: number;
  fontWeight?: "light" | "normal" | "medium" | "semibold" | "bold";
  fontFamily?: string;
  textAlign?: "start" | "center" | "end";
  lineHeight?: number;
  letterSpacing?: number;
  lineClamp?: number;
  tabularNums?: boolean;
  opacity?: number;
  hoverBackground?: string;
  hoverTextColor?: string;
  hoverOpacity?: number;
  hoverBorderColor?: string;
  hoverShadow?: string;
  hoverShadowInset?: boolean;
  pressedBackground?: string;
  pressedTextColor?: string;
  pressedOpacity?: number;
  pressedBorderColor?: string;
  pressedShadow?: string;
  pressedShadowInset?: boolean;
  crossAlign?: CrossAlign;
  mainAlign?: MainAlign;
  grow?: number;
  shrink?: number;
  alignSelf?: SelfAlign;
  flexWrap?: boolean;
  width?: number;
  height?: number;
  minWidth?: number;
  minHeight?: number;
  maxWidth?: number;
  maxHeight?: number;
  widthPercent?: number;
  heightPercent?: number;
  aspectRatio?: number;
  truncate?: boolean;
  overflowHidden?: boolean;
}

export class UtilityError extends Error {
  readonly utility: string;

  constructor(utility: string, message: string) {
    super(message);
    this.name = "UtilityError";
    this.utility = utility;
  }
}

const fontScales: Readonly<Record<string, number>> = {
  xs: 12 / 14,
  sm: 1,
  base: 16 / 14,
  lg: 18 / 14,
  xl: 20 / 14,
  "2xl": 24 / 14,
  "3xl": 30 / 14,
  "4xl": 36 / 14,
};

const defaultLineHeightPixels: Readonly<Record<string, number>> = {
  xs: 16,
  sm: 20,
  base: 24,
  lg: 28,
  xl: 28,
  "2xl": 32,
  "3xl": 36,
  "4xl": 40,
};

const lineHeights: Readonly<Record<string, number>> = {
  none: 1,
  tight: 1.25,
  snug: 1.375,
  normal: 1.5,
  relaxed: 1.625,
  loose: 2,
};

const trackingEms: Readonly<Record<string, number>> = {
  tighter: -0.05,
  tight: -0.025,
  normal: 0,
  wide: 0.025,
  wider: 0.05,
  widest: 0.1,
};

type CompileOutput = ClassProps & {
  lineHeightPx?: number;
  letterSpacingEm?: number;
  lineHeightExplicit?: boolean;
  shadowGeometry?: string;
  shadowColor?: string;
  hoverShadowGeometry?: string;
  hoverShadowColor?: string;
  pressedShadowGeometry?: string;
  pressedShadowColor?: string;
  textShadowGeometry?: string;
  gradientDirection?: readonly [number, number, number, number];
  gradientSpread?: "pad" | "repeat";
  gradientFrom?: string;
  gradientVia?: string;
  gradientTo?: string;
  gradientFromOffset?: number;
  gradientViaOffset?: number;
  gradientToOffset?: number;
  gradientUtility?: string;
};

const boxShadows: Readonly<Record<string, string>> = {
  shadow: "0 1 3 0",
  "shadow-sm": "0 1 2 0",
  "shadow-md": "0 4 6 -1",
  "shadow-lg": "0 10 15 -3",
  "shadow-xl": "0 20 25 -5",
  "shadow-inner": "0 2 4 0",
};

const boxShadowColors: Readonly<Record<string, string>> = {
  shadow: "#0000001A",
  "shadow-sm": "#0000000D",
  "shadow-md": "#0000001A",
  "shadow-lg": "#0000001A",
  "shadow-xl": "#0000001A",
  "shadow-inner": "#0000000F",
};

const textShadows: Readonly<Record<string, string>> = {
  "text-shadow": "0 1 2",
  "text-shadow-sm": "0 1 1",
  "text-shadow-md": "0 2 4",
  "text-shadow-lg": "0 4 8",
};

const radii: Readonly<Record<string, number>> = {
  rounded: 4,
  "rounded-md": 6,
  "rounded-lg": 8,
  "rounded-xl": 12,
  "rounded-2xl": 16,
  "rounded-3xl": 24,
  "rounded-full": 9999,
};

const maxUtilityNumber = 1_000_000;
const gradientDirectionPattern = /^bg-(repeating-)?(?:gradient|linear)-to-(r|tr|t|tl|l|bl|b|br)$/;

function utilityNumber(raw: string, utility: string, multiplier = 1): number {
  const value = Number(raw) * multiplier;
  if (!Number.isFinite(value) || Math.abs(value) > maxUtilityNumber) {
    throw new UtilityError(
      utility,
      `Class utility "${utility}" has a non-finite or absurd numeric value (maximum ${maxUtilityNumber})`,
    );
  }
  return value;
}

const exampleUtilities = [
  "p-4", "p-[13px]", "px-4", "py-4", "pt-4", "pr-4", "pb-4", "pl-4",
  "m-4", "mx-4", "my-4", "mt-4", "mr-4", "mb-4", "ml-4", "-mt-4",
  "gap-2", "gap-[13px]", "rounded", "rounded-md",
  "rounded-lg", "rounded-xl", "rounded-2xl", "rounded-3xl", "rounded-full",
  "rounded-[13px]", "bg-[#11141c]/86", "text-[#ffffff]", "text-xs",
  "text-sm", "text-base", "text-lg", "text-xl", "text-2xl", "text-3xl",
  "text-4xl", "font-light", "font-normal", "font-medium", "font-semibold",
  "font-bold", "opacity-70", "items-start", "items-center", "items-end",
  "items-baseline", "items-stretch", "justify-start", "justify-center", "justify-end",
  "font-bold", "font-sans", "font-mono", "font-[CozetteVector]", "text-left", "text-center", "text-right", "text-[13px]",
  "leading-tight", "tracking-wide", "line-clamp-2", "tabular-nums",
  "shadow", "shadow-sm", "shadow-md", "shadow-lg", "shadow-xl", "shadow-inner",
  "shadow-red-500", "shadow-[0_4px_12px_-2px_#00000066]",
  "text-shadow", "text-shadow-sm", "text-shadow-md", "text-shadow-lg",
  "hover:bg-zinc-800", "hover:text-white", "hover:opacity-90", "hover:border-zinc-600",
  "pressed:bg-zinc-950", "pressed:text-white", "pressed:opacity-70", "pressed:border-zinc-400",
  "justify-between", "justify-around", "justify-evenly", "grow", "grow-2", "shrink", "shrink-0",
  "self-auto", "self-start", "self-center", "self-end", "self-stretch", "flex-wrap", "flex-nowrap",
  "w-12", "w-[48px]", "w-full", "w-1/2", "w-auto",
  "h-12", "h-[48px]", "h-full", "size-12", "min-w-12", "max-w-[160px]",
  "min-h-12", "max-h-[160px]", "aspect-square", "aspect-video", "aspect-[4/3]",
  "truncate",
  "overflow-hidden",
] as const;

export function compileClass(className: string): ClassProps {
  const output: CompileOutput = {};
  for (const utility of className.trim().split(/\s+/).filter(Boolean)) {
    applyUtility(output, utility);
  }
  const fontPixels = 14 * (output.fontScale ?? 1);
  if (output.lineHeightPx !== undefined) output.lineHeight = output.lineHeightPx / fontPixels;
  if (output.letterSpacingEm !== undefined) output.letterSpacing = output.letterSpacingEm * fontPixels;
  if (output.shadowGeometry !== undefined) output.shadow = `${output.shadowGeometry} ${output.shadowColor ?? "#0000001A"}`;
  if (output.hoverShadowGeometry !== undefined) output.hoverShadow = `${output.hoverShadowGeometry} ${output.hoverShadowColor ?? "#0000001A"}`;
  if (output.pressedShadowGeometry !== undefined) output.pressedShadow = `${output.pressedShadowGeometry} ${output.pressedShadowColor ?? "#0000001A"}`;
  if (output.textShadowGeometry !== undefined) output.textShadow = `${output.textShadowGeometry} #00000026`;
  if (output.gradientDirection !== undefined) {
    if (output.gradientFrom === undefined || output.gradientTo === undefined) {
      throw new UtilityError(output.gradientUtility ?? "bg-gradient", "A linear gradient requires both from-<color> and to-<color>");
    }
    const [startX, startY, endX, endY] = output.gradientDirection;
    const stops = [
      { offset: output.gradientFromOffset ?? 0, color: output.gradientFrom },
      ...(output.gradientVia === undefined ? [] : [{ offset: output.gradientViaOffset ?? 0.5, color: output.gradientVia }]),
      { offset: output.gradientToOffset ?? 1, color: output.gradientTo },
    ];
    output.backgroundGradient = serializeBackground({
      type: "linear",
      start: [startX, startY],
      end: [endX, endY],
      stops,
      spread: output.gradientSpread ?? "pad",
    });
  } else if (output.gradientFrom !== undefined || output.gradientVia !== undefined || output.gradientTo !== undefined) {
    throw new UtilityError(output.gradientUtility ?? "from", "Gradient stop utilities require bg-gradient-to-* or bg-linear-to-*");
  }
  delete output.lineHeightPx;
  delete output.letterSpacingEm;
  delete output.lineHeightExplicit;
  delete output.shadowGeometry;
  delete output.shadowColor;
  delete output.hoverShadowGeometry;
  delete output.hoverShadowColor;
  delete output.pressedShadowGeometry;
  delete output.pressedShadowColor;
  delete output.textShadowGeometry;
  delete output.gradientDirection;
  delete output.gradientSpread;
  delete output.gradientFrom;
  delete output.gradientVia;
  delete output.gradientTo;
  delete output.gradientFromOffset;
  delete output.gradientViaOffset;
  delete output.gradientToOffset;
  delete output.gradientUtility;
  return output;
}

export function classUsesGradientBackground(className: string): boolean {
  if (!className.includes("bg-")) return false;
  return className.trim().split(/\s+/).some((utility) => gradientDirectionPattern.test(utility));
}

function applyUtility(output: CompileOutput, utility: string): void {
  const stateMatch = /^(hover|pressed):(.+)$/.exec(utility);
  if (stateMatch) {
    applyStateUtility(output, stateMatch[1] as "hover" | "pressed", stateMatch[2], utility);
    return;
  }
  if (/^(?:focus:|active:|transition)/.test(utility)) {
    throw new UtilityError(utility, `Class utility "${utility}" arrives in M2+`);
  }

  let match: RegExpExecArray | null;
  if ((match = gradientDirectionPattern.exec(utility))) {
    const directions: Record<string, readonly [number, number, number, number]> = {
      r: [0, 0.5, 1, 0.5], tr: [0, 1, 1, 0], t: [0.5, 1, 0.5, 0], tl: [1, 1, 0, 0],
      l: [1, 0.5, 0, 0.5], bl: [1, 0, 0, 1], b: [0.5, 0, 0.5, 1], br: [0, 0, 1, 1],
    };
    output.gradientDirection = directions[match[2]];
    output.gradientSpread = match[1] === undefined ? "pad" : "repeat";
    output.gradientUtility = utility;
    return;
  }
  if ((match = /^(from|via|to)-\[(#[0-9a-fA-F]{3}|#[0-9a-fA-F]{6}|#[0-9a-fA-F]{8})\](?:\/(\d{1,3}))?$/.exec(utility))) {
    setGradientColor(output, match[1], normalizeColor(match[2], match[3]), utility);
    return;
  }
  if ((match = /^(from|via|to)-([a-z]+(?:-\d+)?)(?:\/(\d{1,3}))?$/.exec(utility))) {
    const resolved = tailwindColors[match[2]];
    if (resolved !== undefined) {
      setGradientColor(output, match[1], namedColorWithAlpha(resolved, match[3]), utility);
      return;
    }
  }
  if ((match = /^(from|via|to)-(?:\[(\d+(?:\.\d+)?)%\]|(\d+(?:\.\d+)?)%)$/.exec(utility))) {
    const percent = utilityNumber(match[2] ?? match[3], utility);
    if (percent <= 100) {
      if (match[1] === "from") output.gradientFromOffset = percent / 100;
      else if (match[1] === "via") output.gradientViaOffset = percent / 100;
      else output.gradientToOffset = percent / 100;
      output.gradientUtility = utility;
      return;
    }
  }
  if (utility in boxShadows) {
    output.shadowGeometry = boxShadows[utility];
    output.shadowColor ??= boxShadowColors[utility];
    output.shadowInset = utility === "shadow-inner";
    return;
  }
  if (utility === "shadow-none") {
    delete output.shadowGeometry;
    delete output.shadowColor;
    output.shadow = "";
    output.shadowInset = false;
    return;
  }
  if ((match = /^shadow-\[(-?\d+(?:\.\d+)?)(?:px)?_(-?\d+(?:\.\d+)?)(?:px)?_(\d+(?:\.\d+)?)(?:px)?_(-?\d+(?:\.\d+)?)(?:px)?_(#[0-9a-fA-F]{3}|#[0-9a-fA-F]{6}|#[0-9a-fA-F]{8})\](?:\/(\d{1,3}))?$/.exec(utility))) {
    output.shadowGeometry = `${utilityNumber(match[1], utility)} ${utilityNumber(match[2], utility)} ${utilityNumber(match[3], utility)} ${utilityNumber(match[4], utility)}`;
    output.shadowColor = normalizeColor(match[5], match[6]);
    output.shadowInset = false;
    return;
  }
  if ((match = /^shadow-\[(#[0-9a-fA-F]{3}|#[0-9a-fA-F]{6}|#[0-9a-fA-F]{8})\](?:\/(\d{1,3}))?$/.exec(utility))) {
    output.shadowColor = normalizeColor(match[1], match[2]);
    return;
  }
  if ((match = /^shadow-([a-z]+(?:-\d+)?)(?:\/(\d{1,3}))?$/.exec(utility))) {
    const color = tailwindColors[match[1]];
    if (color !== undefined) {
      output.shadowColor = namedColorWithAlpha(color, match[2]);
      return;
    }
  }
  if (utility in textShadows) {
    output.textShadowGeometry = textShadows[utility];
    return;
  }
  if (utility === "text-shadow-none") {
    delete output.textShadowGeometry;
    output.textShadow = "";
    return;
  }
  if ((match = /^p-(\d+(?:\.\d+)?)$/.exec(utility))) {
    output.padding = utilityNumber(match[1], utility, 4);
    clearPaddingSides(output);
    return;
  }
  if ((match = /^p-\[(\d+(?:\.\d+)?)px\]$/.exec(utility))) {
    output.padding = utilityNumber(match[1], utility);
    clearPaddingSides(output);
    return;
  }
  if ((match = /^(px|py|pt|pr|pb|pl)-(\d+(?:\.\d+)?)$/.exec(utility))) {
    applyPaddingSides(output, match[1], utilityNumber(match[2], utility, 4));
    return;
  }
  if ((match = /^(px|py|pt|pr|pb|pl)-\[(\d+(?:\.\d+)?)px\]$/.exec(utility))) {
    applyPaddingSides(output, match[1], utilityNumber(match[2], utility));
    return;
  }
  if ((match = /^(-)?(m|mx|my|mt|mr|mb|ml)-(\d+(?:\.\d+)?)$/.exec(utility))) {
    applyMarginSides(output, match[2], utilityNumber(match[3], utility, 4) * (match[1] ? -1 : 1));
    return;
  }
  if ((match = /^(-)?(m|mx|my|mt|mr|mb|ml)-\[(\d+(?:\.\d+)?)px\]$/.exec(utility))) {
    applyMarginSides(output, match[2], utilityNumber(match[3], utility) * (match[1] ? -1 : 1));
    return;
  }
  if ((match = /^gap-(\d+(?:\.\d+)?)$/.exec(utility))) {
    output.gap = utilityNumber(match[1], utility, 4);
    return;
  }
  if ((match = /^gap-\[(\d+(?:\.\d+)?)px\]$/.exec(utility))) {
    output.gap = utilityNumber(match[1], utility);
    return;
  }
  if (utility in radii) {
    output.radius = radii[utility];
    clearRadiusCorners(output);
    return;
  }
  if ((match = /^rounded-\[(\d+(?:\.\d+)?)px\]$/.exec(utility))) {
    output.radius = utilityNumber(match[1], utility);
    clearRadiusCorners(output);
    return;
  }
  if ((match = /^rounded-(t|r|b|l|tl|tr|br|bl)(?:-(md|lg|xl|2xl|3xl|full|\[(\d+(?:\.\d+)?)px\]))?$/.exec(utility))) {
    const value = match[3] === undefined ? (match[2] === undefined ? radii.rounded : radii[`rounded-${match[2]}`]) : utilityNumber(match[3], utility);
    applyRadiusCorners(output, match[1], value);
    return;
  }
  if (utility === "border") {
    output.borderWidth = 1;
    output.borderColor ??= "#E5E7EBFF";
    return;
  }
  if ((match = /^border-(\d+(?:\.\d+)?)$/.exec(utility))) {
    output.borderWidth = utilityNumber(match[1], utility);
    output.borderColor ??= "#E5E7EBFF";
    return;
  }
  if ((match = /^border-\[(\d+(?:\.\d+)?)px\]$/.exec(utility))) {
    output.borderWidth = utilityNumber(match[1], utility);
    output.borderColor ??= "#E5E7EBFF";
    return;
  }
  if ((match = /^border-\[(#[0-9a-fA-F]{3}|#[0-9a-fA-F]{6}|#[0-9a-fA-F]{8})\](?:\/(\d{1,3}))?$/.exec(utility))) {
    output.borderColor = normalizeColor(match[1], match[2]);
    return;
  }
  if ((match = /^bg-\[(#[0-9a-fA-F]{3}|#[0-9a-fA-F]{6}|#[0-9a-fA-F]{8})\](?:\/(\d{1,3}))?$/.exec(utility))) {
    output.background = normalizeColor(match[1], match[2]);
    return;
  }
  if ((match = /^text-\[(#[0-9a-fA-F]{3}|#[0-9a-fA-F]{6}|#[0-9a-fA-F]{8})\](?:\/(\d{1,3}))?$/.exec(utility))) {
    output.textColor = normalizeColor(match[1], match[2]);
    return;
  }
  if ((match = /^text-\[(\d+(?:\.\d+)?)px\]$/.exec(utility))) {
    const pixels = utilityNumber(match[1], utility);
    if (pixels > 0) {
      output.fontScale = pixels / 14;
      return;
    }
  }
  if ((match = /^(bg|text|border)-([a-z]+(?:-\d+)?)(?:\/(\d{1,3}))?$/.exec(utility))) {
    const color = tailwindColors[match[2]];
    if (color !== undefined) {
      const resolved = namedColorWithAlpha(color, match[3]);
      if (match[1] === "bg") output.background = resolved;
      else if (match[1] === "text") output.textColor = resolved;
      else output.borderColor = resolved;
      return;
    }
  }
  if ((match = /^text-(xs|sm|base|lg|xl|2xl|3xl|4xl)$/.exec(utility))) {
    output.fontScale = fontScales[match[1]];
    if (!output.lineHeightExplicit) {
      output.lineHeightPx = defaultLineHeightPixels[match[1]];
      delete output.lineHeight;
    }
    return;
  }
  if ((match = /^font-(light|normal|medium|semibold|bold)$/.exec(utility))) {
    output.fontWeight = match[1] as ClassProps["fontWeight"];
    return;
  }
  if ((match = /^opacity-(\d{1,3})$/.exec(utility))) {
    const percent = utilityNumber(match[1], utility);
    if (percent <= 100) {
      output.opacity = percent / 100;
      return;
    }
  }
  if ((match = /^items-(start|center|end|baseline|stretch)$/.exec(utility))) {
    output.crossAlign = match[1] as CrossAlign;
    return;
  }
  if ((match = /^justify-(start|center|end|between|around|evenly)$/.exec(utility))) {
    output.mainAlign = match[1] as MainAlign;
    return;
  }
  if (utility === "grow") {
    output.grow = 1;
    return;
  }
  if (utility === "font-sans" || utility === "font-mono") {
    output.fontFamily = utility.slice("font-".length);
    return;
  }
  if ((match = /^font-\[([A-Za-z0-9][A-Za-z0-9_-]{0,62})\]$/.exec(utility))) {
    output.fontFamily = match[1];
    return;
  }
  if ((match = /^text-(left|center|right)$/.exec(utility))) {
    output.textAlign = match[1] === "left" ? "start" : match[1] === "right" ? "end" : "center";
    return;
  }
  if ((match = /^leading-(none|tight|snug|normal|relaxed|loose)$/.exec(utility))) {
    output.lineHeight = lineHeights[match[1]];
    delete output.lineHeightPx;
    output.lineHeightExplicit = true;
    return;
  }
  if ((match = /^leading-(\d+(?:\.\d+)?)$/.exec(utility))) {
    output.lineHeightPx = utilityNumber(match[1], utility, 4);
    delete output.lineHeight;
    output.lineHeightExplicit = true;
    return;
  }
  if ((match = /^leading-\[(\d+(?:\.\d+)?)px\]$/.exec(utility))) {
    output.lineHeightPx = utilityNumber(match[1], utility);
    delete output.lineHeight;
    output.lineHeightExplicit = true;
    return;
  }
  if ((match = /^leading-\[(\d+(?:\.\d+)?)\]$/.exec(utility))) {
    const multiplier = utilityNumber(match[1], utility);
    if (multiplier > 0) {
      output.lineHeight = multiplier;
      delete output.lineHeightPx;
      output.lineHeightExplicit = true;
      return;
    }
  }
  if ((match = /^tracking-(tighter|tight|normal|wide|wider|widest)$/.exec(utility))) {
    output.letterSpacingEm = trackingEms[match[1]];
    delete output.letterSpacing;
    return;
  }
  if ((match = /^tracking-\[(-?\d+(?:\.\d+)?)px\]$/.exec(utility))) {
    output.letterSpacing = utilityNumber(match[1], utility);
    delete output.letterSpacingEm;
    return;
  }
  if ((match = /^tracking-\[(-?\d+(?:\.\d+)?)em\]$/.exec(utility))) {
    output.letterSpacingEm = utilityNumber(match[1], utility);
    delete output.letterSpacing;
    return;
  }
  if ((match = /^line-clamp-([1-9]\d*)$/.exec(utility))) {
    output.lineClamp = utilityNumber(match[1], utility);
    return;
  }
  if (utility === "line-clamp-none") {
    output.lineClamp = 0;
    return;
  }
  if (utility === "tabular-nums") {
    output.tabularNums = true;
    return;
  }
  if (utility === "normal-nums") {
    output.tabularNums = false;
    return;
  }
  if ((match = /^grow-(\d+(?:\.\d+)?)$/.exec(utility))) {
    output.grow = utilityNumber(match[1], utility);
    return;
  }
  if ((match = /^grow-\[(\d+(?:\.\d+)?)\]$/.exec(utility))) {
    output.grow = utilityNumber(match[1], utility);
    return;
  }
  if (utility === "shrink") {
    output.shrink = 1;
    return;
  }
  if (utility === "shrink-0") {
    output.shrink = 0;
    return;
  }
  if ((match = /^self-(auto|start|center|end|stretch)$/.exec(utility))) {
    output.alignSelf = match[1] as SelfAlign;
    return;
  }
  if (utility === "flex-wrap") {
    output.flexWrap = true;
    return;
  }
  if (utility === "flex-nowrap") {
    output.flexWrap = false;
    return;
  }
  if ((match = /^(w|h)-(\d+(?:\.\d+)?)$/.exec(utility))) {
    setAxisSize(output, match[1], utilityNumber(match[2], utility, 4));
    return;
  }
  if ((match = /^(w|h)-\[(\d+(?:\.\d+)?)px\]$/.exec(utility))) {
    setAxisSize(output, match[1], utilityNumber(match[2], utility));
    return;
  }
  if ((match = /^(w|h)-full$/.exec(utility))) {
    setAxisPercent(output, match[1], 100);
    return;
  }
  if ((match = /^(w|h)-(\d+)\/(\d+)$/.exec(utility))) {
    const numerator = utilityNumber(match[2], utility);
    const denominator = utilityNumber(match[3], utility);
    if (denominator > 0 && numerator > 0 && numerator <= denominator) {
      setAxisPercent(output, match[1], numerator * 100 / denominator);
      return;
    }
  }
  if ((match = /^(w|h)-auto$/.exec(utility))) {
    clearAxisSize(output, match[1]);
    return;
  }
  if ((match = /^size-(\d+(?:\.\d+)?)$/.exec(utility))) {
    const value = utilityNumber(match[1], utility, 4);
    setAxisSize(output, "w", value);
    setAxisSize(output, "h", value);
    return;
  }
  if ((match = /^size-\[(\d+(?:\.\d+)?)px\]$/.exec(utility))) {
    const value = utilityNumber(match[1], utility);
    setAxisSize(output, "w", value);
    setAxisSize(output, "h", value);
    return;
  }
  if (utility === "size-full") {
    setAxisPercent(output, "w", 100);
    setAxisPercent(output, "h", 100);
    return;
  }
  if ((match = /^(min|max)-(w|h)-(\d+(?:\.\d+)?)$/.exec(utility))) {
    setBound(output, match[1], match[2], utilityNumber(match[3], utility, 4));
    return;
  }
  if ((match = /^(min|max)-(w|h)-\[(\d+(?:\.\d+)?)px\]$/.exec(utility))) {
    setBound(output, match[1], match[2], utilityNumber(match[3], utility));
    return;
  }
  if (utility === "aspect-square") {
    output.aspectRatio = 1;
    return;
  }
  if (utility === "aspect-video") {
    output.aspectRatio = 16 / 9;
    return;
  }
  if (utility === "aspect-auto") {
    delete output.aspectRatio;
    return;
  }
  if ((match = /^aspect-\[(\d+(?:\.\d+)?)\/(\d+(?:\.\d+)?)\]$/.exec(utility))) {
    const numerator = utilityNumber(match[1], utility);
    const denominator = utilityNumber(match[2], utility);
    if (denominator > 0) {
      const ratio = numerator / denominator;
      if (!Number.isFinite(ratio) || ratio > maxUtilityNumber) {
        throw new UtilityError(utility, `Class utility "${utility}" has an absurd aspect ratio`);
      }
      output.aspectRatio = ratio;
      return;
    }
  }
  if ((match = /^aspect-\[(\d+(?:\.\d+)?)\]$/.exec(utility))) {
    const ratio = utilityNumber(match[1], utility);
    if (ratio > 0) {
      output.aspectRatio = ratio;
      return;
    }
    throw new UtilityError(utility, `Class utility "${utility}" requires an aspect ratio greater than zero`);
  }
  if (utility === "truncate") {
    output.truncate = true;
    return;
  }
  if (utility === "overflow-hidden") {
    output.overflowHidden = true;
    return;
  }
  throw unknownUtility(utility);
}

function setGradientColor(output: CompileOutput, position: string, color: string, utility: string): void {
  if (position === "from") output.gradientFrom = color;
  else if (position === "via") output.gradientVia = color;
  else output.gradientTo = color;
  output.gradientUtility = utility;
}

function applyStateUtility(output: CompileOutput, state: "hover" | "pressed", utility: string, authored: string): void {
  if (utility === "shadow" || utility.startsWith("shadow-")) {
    const shadowKey = state === "hover" ? "hoverShadow" : "pressedShadow";
    const insetKey = state === "hover" ? "hoverShadowInset" : "pressedShadowInset";
    const geometryKey = state === "hover" ? "hoverShadowGeometry" : "pressedShadowGeometry";
    const colorKey = state === "hover" ? "hoverShadowColor" : "pressedShadowColor";
    const variant: CompileOutput = {
      shadow: output[shadowKey] === "none" ? "" : undefined,
      shadowInset: output[insetKey],
      shadowGeometry: output[geometryKey],
      shadowColor: output[colorKey],
    };
    try {
      applyUtility(variant, utility);
    } catch {
      // Replace the lower-level utility parse error with the authored state variant and its supported forms.
      throw unsupportedStateUtility(authored, state);
    }
    const keys = Object.keys(variant) as (keyof CompileOutput)[];
    if (keys.some((key) => !["shadow", "shadowInset", "shadowGeometry", "shadowColor"].includes(key))) {
      throw unsupportedStateUtility(authored, state);
    }
    if (variant.shadow === "" && variant.shadowGeometry === undefined) {
      output[shadowKey] = "none";
      delete output[geometryKey];
      delete output[colorKey];
      output[insetKey] = false;
      return;
    }
    if (variant.shadowGeometry !== undefined) {
      delete output[shadowKey];
      output[geometryKey] = variant.shadowGeometry;
      if (variant.shadowColor === undefined) delete output[colorKey];
      else output[colorKey] = variant.shadowColor;
      output[insetKey] = variant.shadowInset ?? false;
      return;
    }
    // A color-only shadow utility composes with an earlier geometry, or
    // preserves an earlier explicit shadow-none when no geometry exists.
    if (variant.shadow === "") output[shadowKey] = "none";
    if (variant.shadowColor === undefined) delete output[colorKey];
    else output[colorKey] = variant.shadowColor;
    return;
  }
  const variant: CompileOutput = {};
  try {
    applyUtility(variant, utility);
  } catch {
    // Replace the lower-level utility parse error with the authored state variant and its supported forms.
    throw unsupportedStateUtility(authored, state);
  }
  const keys = Object.keys(variant) as (keyof CompileOutput)[];
  if (keys.length !== 1) throw unsupportedStateUtility(authored, state);
  const key = keys[0];
  const target = state === "hover"
    ? { background: "hoverBackground", textColor: "hoverTextColor", opacity: "hoverOpacity", borderColor: "hoverBorderColor" }
    : { background: "pressedBackground", textColor: "pressedTextColor", opacity: "pressedOpacity", borderColor: "pressedBorderColor" };
  const targetKey = target[key as keyof typeof target] as keyof CompileOutput | undefined;
  if (targetKey === undefined) throw unsupportedStateUtility(authored, state);
  (output as Record<string, unknown>)[targetKey] = variant[key];
}

function unsupportedStateUtility(authored: string, state: "hover" | "pressed"): UtilityError {
  return new UtilityError(
    authored,
    `State variant "${authored}" supports only ${state}:bg-<color>, ${state}:text-<color>, ${state}:opacity-N, ${state}:border-<color>, or ${state}:shadow-*`,
  );
}

type PaddingSide = "paddingTop" | "paddingRight" | "paddingBottom" | "paddingLeft";
type MarginSide = "marginTop" | "marginRight" | "marginBottom" | "marginLeft";
type RadiusCorner = "radiusTopLeft" | "radiusTopRight" | "radiusBottomRight" | "radiusBottomLeft";

function clearRadiusCorners(output: ClassProps): void {
  delete output.radiusTopLeft;
  delete output.radiusTopRight;
  delete output.radiusBottomRight;
  delete output.radiusBottomLeft;
}

function applyRadiusCorners(output: ClassProps, side: string, value: number): void {
  const corners: Record<string, RadiusCorner[]> = {
    t: ["radiusTopLeft", "radiusTopRight"], r: ["radiusTopRight", "radiusBottomRight"],
    b: ["radiusBottomLeft", "radiusBottomRight"], l: ["radiusTopLeft", "radiusBottomLeft"],
    tl: ["radiusTopLeft"], tr: ["radiusTopRight"], br: ["radiusBottomRight"], bl: ["radiusBottomLeft"],
  };
  for (const corner of corners[side]) output[corner] = value;
}

function clearPaddingSides(output: ClassProps): void {
  delete output.paddingTop;
  delete output.paddingRight;
  delete output.paddingBottom;
  delete output.paddingLeft;
}

function applyPaddingSides(output: ClassProps, axis: string, value: number): void {
  const sides: Record<string, PaddingSide[]> = {
    px: ["paddingLeft", "paddingRight"], py: ["paddingTop", "paddingBottom"],
    pt: ["paddingTop"], pr: ["paddingRight"], pb: ["paddingBottom"], pl: ["paddingLeft"],
  };
  for (const side of sides[axis]) output[side] = value;
}

function applyMarginSides(output: ClassProps, axis: string, value: number): void {
  const sides: Record<string, MarginSide[]> = {
    m: ["marginTop", "marginRight", "marginBottom", "marginLeft"],
    mx: ["marginLeft", "marginRight"], my: ["marginTop", "marginBottom"],
    mt: ["marginTop"], mr: ["marginRight"], mb: ["marginBottom"], ml: ["marginLeft"],
  };
  for (const side of sides[axis]) output[side] = value;
}

function setAxisSize(output: ClassProps, axis: string, value: number): void {
  if (axis === "w") {
    output.width = value;
    delete output.widthPercent;
  } else {
    output.height = value;
    delete output.heightPercent;
  }
}

function setAxisPercent(output: ClassProps, axis: string, value: number): void {
  if (axis === "w") {
    output.widthPercent = value;
    delete output.width;
  } else {
    output.heightPercent = value;
    delete output.height;
  }
}

function clearAxisSize(output: ClassProps, axis: string): void {
  if (axis === "w") {
    delete output.width;
    delete output.widthPercent;
  } else {
    delete output.height;
    delete output.heightPercent;
  }
}

function setBound(output: ClassProps, bound: string, axis: string, value: number): void {
  const key = `${bound}${axis === "w" ? "Width" : "Height"}` as "minWidth" | "minHeight" | "maxWidth" | "maxHeight";
  output[key] = value;
}

function normalizeColor(source: string, alphaPercent?: string): string {
  let hex = source.slice(1);
  if (hex.length === 3) hex = hex.split("").map((part) => part + part).join("");
  if (hex.length === 6) hex += "ff";
  if (alphaPercent !== undefined) {
    const percent = Number(alphaPercent);
    if (percent > 100) throw new UtilityError(source, `Color alpha must be between 0 and 100, received ${percent}`);
    hex = hex.slice(0, 6) + Math.round(percent * 255 / 100).toString(16).padStart(2, "0");
  }
  return `#${hex.toUpperCase()}`;
}

function namedColorWithAlpha(color: string, alphaPercent?: string): string {
  if (alphaPercent === undefined) return color;
  const percent = Number(alphaPercent);
  if (percent > 100) throw new UtilityError(color, `Color alpha must be between 0 and 100, received ${percent}`);
  const baseAlpha = Number.parseInt(color.slice(7, 9), 16);
  const alpha = Math.round(baseAlpha * percent / 100).toString(16).padStart(2, "0").toUpperCase();
  return `${color.slice(0, 7)}${alpha}`;
}

function unknownUtility(utility: string): UtilityError {
  const pad = /^pad-(\d+(?:\.\d+)?)$/.exec(utility);
  const suggestion = pad ? `p-[${pad[1]}px]` : nearest(utility, exampleUtilities);
  return new UtilityError(utility, `Unknown class utility "${utility}". Did you mean "${suggestion}"?`);
}

function nearest(value: string, candidates: readonly string[]): string {
  let best = candidates[0];
  let score = Number.POSITIVE_INFINITY;
  for (const candidate of candidates) {
    const candidateScore = editDistance(value, candidate);
    if (candidateScore < score) {
      best = candidate;
      score = candidateScore;
    }
  }
  return best;
}

function editDistance(left: string, right: string): number {
  const row = Array.from({ length: right.length + 1 }, (_, index) => index);
  for (let i = 1; i <= left.length; i += 1) {
    let diagonal = row[0];
    row[0] = i;
    for (let j = 1; j <= right.length; j += 1) {
      const previous = row[j];
      row[j] = Math.min(row[j] + 1, row[j - 1] + 1, diagonal + (left[i - 1] === right[j - 1] ? 0 : 1));
      diagonal = previous;
    }
  }
  return row[right.length];
}
