export type WidgetChild = JSX.Element | string | number | Signal<string | number> | null | undefined | false;
export interface PressEvent { x: number; y: number; u: number; v: number }

export interface WidgetConfig {
  name: string;
  size: [width: number, height: number];
  anchor?: {
    monitor?: "primary";
    corner: "top-left" | "top-right" | "bottom-left" | "bottom-right";
    offset?: [x: number, y: number];
  };
  layer?: "desktop" | "normal" | "topmost";
  clickThrough?: boolean;
  subscribe?: ("time" | "cpu" | "memory" | "audio" | "media")[];
  origins?: string[];
  capabilities?: ("media-transport")[];
}

export interface WidgetModule {
  readonly config: WidgetConfig;
}

export interface TimeData {
  hh: string;
  mm: string;
  ss: string;
  weekday: string;
  month: string;
  day: number;
  year: number;
  epochMs: number;
}

export interface CpuData { percent: number; perCore: number[] }
export interface MemoryData { usedMb: number; totalMb: number; percent: number }
export interface AudioData { rms: number; bands: number[] }
export interface Signal<out T> {
  readonly value: T;
  subscribe(listener: (value: T) => void): () => void;
  map<U>(project: (value: T) => U): Signal<U>;
}
export interface MediaData {
  title: string;
  artist: string;
  album: string;
  status: "playing" | "paused" | "stopped";
  playing: boolean;
  sourceApp: string;
  artPath?: string;
  positionMs: number;
  durationMs: number;
}
export interface MediaTransport {
  play(): Promise<boolean>;
  pause(): Promise<boolean>;
  next(): Promise<boolean>;
  previous(): Promise<boolean>;
  /** Seeks to the nearest whole millisecond. */
  seek(ms: number): Promise<boolean>;
}

export interface WFetchInit {
  method?: "GET" | "POST";
  headers?: Record<string, string>;
  body?: string;
}

export interface WFetchResponse {
  status: number;
  ok: boolean;
  text(): Promise<string>;
  json(): Promise<unknown>;
}

export interface CanvasFrame { t: number; dt: number }
export type CanvasFrameRate = number | "display";
export interface CanvasCtx {
  readonly width: number;
  readonly height: number;
  clear(color?: string): void;
  fillRect(x: number, y: number, width: number, height: number, color: string): void;
  fillRoundRect(x: number, y: number, width: number, height: number, radius: number, color: string): void;
  fillCircle(cx: number, cy: number, radius: number, color: string): void;
  line(x1: number, y1: number, x2: number, y2: number, width: number, color: string): void;
  polyline(points: number[], width: number, color: string): void;
}

export type GradientPoint = readonly [x: number, y: number];
export type GradientInterpolation = "srgb" | "srgb-linear" | "oklab";
export type GradientSpread = "pad" | "repeat" | "reflect";
export interface GradientStop { offset: number; color: string }
interface GradientOptions { interpolation?: GradientInterpolation }
interface AxisGradientOptions extends GradientOptions { spread?: GradientSpread; stops: readonly GradientStop[] }
export interface LinearGradient extends AxisGradientOptions { type: "linear"; start?: GradientPoint; end?: GradientPoint }
export interface RadialGradient extends AxisGradientOptions { type: "radial"; center?: GradientPoint; radius?: GradientPoint }
export interface ConicGradient extends AxisGradientOptions { type: "conic"; center?: GradientPoint; from?: number }
export interface MeshPatch {
  points: readonly GradientPoint[];
  colors: readonly [string, string, string, string];
}
export interface MeshGradient extends GradientOptions { type: "mesh"; patches: readonly MeshPatch[] }
export type BackgroundGradient = LinearGradient | RadialGradient | ConicGradient | MeshGradient;
export type BackgroundGradientStack = BackgroundGradient | readonly BackgroundGradient[];
export function serializeBackground(background: BackgroundGradientStack): string;

export function widget(config: WidgetConfig, component: () => JSX.Element): WidgetModule;
export function useState<T>(initial: T | (() => T)): [T, (next: T | ((prev: T) => T)) => void];
export function useRef<T>(initial: T): { current: T };
export function useEffect(fn: () => void | (() => void), deps?: unknown[]): void;
export function useInterval(fn: () => void, ms: number): void;
export function useProvider(name: "time"): TimeData;
export function useProvider(name: "cpu"): CpuData;
export function useProvider(name: "memory"): MemoryData;
export function useProvider(name: "audio"): AudioData;
export function useProvider(name: "media"): MediaData;
export function useProviderSignal(name: "time"): Signal<TimeData>;
export function useProviderSignal(name: "cpu"): Signal<CpuData>;
export function useProviderSignal(name: "memory"): Signal<MemoryData>;
export function useProviderSignal(name: "audio"): Signal<AudioData>;
export function useProviderSignal(name: "media"): Signal<MediaData>;
export function useMediaTransport(): MediaTransport;
export function useStorage<T>(key: string, initial: T): [T, (next: T | ((prev: T) => T)) => void];
export function wfetch(url: string, init?: WFetchInit): Promise<WFetchResponse>;

export function h(type: unknown, props: Record<string, unknown> | null, ...children: WidgetChild[]): JSX.Element;
export const Fragment: unique symbol;

declare global {
  namespace JSX {
    interface Element {
      readonly __weaverElement: true;
    }

    interface ElementChildrenAttribute {
      children: {};
    }

    interface IntrinsicAttributes {
      key?: string | number;
    }

    /**
     * `key` on an intrinsic element. Under `jsx: "react-jsx"` TypeScript
     * checks a keyed intrinsic's props against `IntrinsicElements[tag]`
     * directly, so `IntrinsicAttributes` alone does not admit `key` there.
     * The reconciler reads `key` for positional diffing of mapped children.
     */
    interface KeyedProps {
      key?: string | number;
    }

    interface BoxProps extends KeyedProps {
      class?: string;
      children?: WidgetChild | WidgetChild[];
    }

    interface GradientBoxProps extends BoxProps {
      /** One gradient or a bottom-to-top painter-ordered gradient stack. */
      background?: BackgroundGradientStack;
    }

    interface TextProps extends KeyedProps {
      class?: string;
      children?: string | number | Signal<string | number> | (string | number)[];
    }

    type IconProps = KeyedProps & (
      | { class?: string; name: string; d?: never; viewBox?: never; stroke?: never }
      | { class?: string; d: string; viewBox?: string; stroke?: number; name?: never });

    interface IntrinsicElements {
      column: GradientBoxProps;
      row: GradientBoxProps;
      stack: GradientBoxProps;
      panel: GradientBoxProps;
      text: TextProps;
      icon: IconProps;
      image: BoxProps & { src: string; fit?: "cover" | "contain" | "stretch"; tile?: boolean };
      button: GradientBoxProps & {
        accessibilityLabel?: string;
        onPress: (event?: PressEvent) => void;
        onDoublePress?: (event: PressEvent) => void;
        onRightPress?: (event: PressEvent) => void;
      };
      slider: BoxProps & { accessibilityLabel?: string; value: number; max: number; onChange: (value: number) => void };
      canvas: BoxProps & { fps?: CanvasFrameRate; onFrame: (ctx: CanvasCtx, frame: CanvasFrame) => void };
    }
  }
}

declare global {
  function wfetch(url: string, init?: WFetchInit): Promise<WFetchResponse>;
}
