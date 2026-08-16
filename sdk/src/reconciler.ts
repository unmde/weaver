import { compileClass, type ClassProps } from "./class-compiler.js";

// Storage receipt (2026-07-29): serializing a realistic good notes fixture
// (100 records with 900-byte bodies and metadata) measured 103,291 bytes.
// 256 KiB leaves 2.5x headroom, and JSON strings allocate their actual length.
// Pinned to runtime/src/storage.zig quota_bytes.
const STORAGE_QUOTA_BYTES = 256 * 1024;
// The authored-canvas command budget is 2,048 and the measured 336-rect meter
// established that as a good shape. Wire encoding needs at most ~16 values per
// command, so 32,768 is derived rather than independently budgeted. Each
// mounted canvas allocates one 256 KiB Float64Array; unused canvas slots cost
// nothing. Pinned to runtime/src/tree.zig max_canvas_wire_values.
const MAX_CANVAS_WIRE_VALUES = 32_768;
// Shipped widgets author at most 60 fps (m4b-synthetic), matching the native
// surface clock. Faster requests cannot present extra frames, so 60 is a
// scheduler/protocol bound rather than a silently starved animation budget;
// the clamp itself retains no memory.
const MAX_CANVAS_FPS = 60;

export type WidgetChild = VNode | string | number | Signal<string | number> | null | undefined | false;
export type Component = () => VNode;
export type NodeType = "column" | "row" | "stack" | "panel" | "text" | "icon" | "button" | "slider" | "image" | "canvas";
export type ProviderName = "time" | "cpu" | "memory" | "audio" | "media";

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
  subscribe?: ProviderName[];
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
  seek(ms: number): Promise<boolean>;
}
type ProviderValue = TimeData | CpuData | MemoryData | AudioData | MediaData;
export interface WFetchInit { method?: "GET" | "POST"; headers?: Record<string, string>; body?: string }
export interface WFetchResponse { status: number; ok: boolean; text(): Promise<string>; json(): Promise<unknown> }
export interface CanvasFrame { t: number; dt: number }
export interface PressEvent { x: number; y: number; u: number; v: number }
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

interface VNode {
  readonly __weaverElement: true;
  readonly type: NodeType | Component | typeof Fragment;
  readonly props: Record<string, unknown>;
  readonly children: WidgetChild[];
  readonly key?: string | number;
}

type ElementType = VNode["type"];

interface HostInstance {
  kind: "host";
  type: NodeType;
  key?: string | number;
  id: number;
  className?: string;
  props: ClassProps;
  elementProps: HostElementProps;
  text?: string;
  textBinding?: Signal<string | number>;
  textUnsubscribe?: () => void;
  mounted: boolean;
  children: Instance[];
}

interface HostElementProps {
  onPress?: (event?: PressEvent) => void;
  onDoublePress?: (event: PressEvent) => void;
  onRightPress?: (event: PressEvent) => void;
  onChange?: (value: number) => void;
  value?: number;
  max?: number;
  src?: string;
  iconPath?: string;
  iconViewBox?: string;
  iconStroke?: number;
  fit?: "cover" | "contain" | "stretch";
  tile?: boolean;
  onFrame?: (ctx: CanvasCtx, frame: CanvasFrame) => void;
  fps?: number;
}

interface ComponentInstance {
  kind: "component";
  type: Component;
  key?: string | number;
  hooks: Hook[];
  hookIndex: number;
  child: Instance | null;
}

interface FragmentInstance {
  kind: "fragment";
  key?: string | number;
  children: Instance[];
}

type Instance = HostInstance | ComponentInstance | FragmentInstance;
type Hook = StateHook<unknown> | RefHook<unknown> | EffectHook;
interface StateHook<T> { kind: "state"; value: T }
interface RefHook<T> { kind: "ref"; value: { current: T }; initialValueType: HotSwapValueType }
interface EffectHook { kind: "effect"; deps?: unknown[]; cleanup?: () => void; effect?: () => void | (() => void) }

type HotSwapValueType = "undefined" | "null" | "boolean" | "number" | "string" | "bigint" | "symbol" | "function" | "array" | "object";
interface HotSwapSlot { kind: Hook["kind"]; valueType?: HotSwapValueType; value?: unknown; transferable?: boolean }

const encodedHotSwapSeed = (globalThis as typeof globalThis & { __weaverHotSwapSeed?: unknown }).__weaverHotSwapSeed;
const hotSwapSeedProvided = typeof encodedHotSwapSeed === "string";
let hotSwapSeed: HotSwapSlot[] | null = parseHotSwapSeed(encodedHotSwapSeed);
let hotSwapCompatible = !hotSwapSeedProvided || hotSwapSeed !== null;

export const Fragment = Symbol("weaver.fragment");

let rootComponent: Component | null = null;
let rootInstance: Instance | null = null;
let activeConfig: WidgetConfig | null = null;
let renderingComponent: ComponentInstance | null = null;
let renderInProgress = false;
let renderFailureScope: string | null = null;
let renderQueued = false;
let committedRootId = 0;
let widgetFailed = false;
const pendingEffects: EffectHook[] = [];
const handlers = new Map<number, HostElementProps>();
interface CanvasBinding {
  onFrame: (ctx: CanvasCtx, frame: CanvasFrame) => void;
  fps?: number;
  timerId: number;
  surfaceClock: boolean;
  width: number;
  height: number;
  lastT?: number;
  nextT?: number;
  nativeTimestampStarted?: boolean;
  batch: Float64Array;
  batchLength: number;
  active: boolean;
  ctx: CanvasCtx;
}
interface MutableSignal<T> extends Signal<T> { emit(value: T): void }
const canvases = new Map<number, CanvasBinding>();
const signals = new WeakSet<object>();
const signalMaps = new WeakMap<object, WeakMap<Function, Signal<unknown>>>();
const colorCache: Record<string, number> = Object.create(null) as Record<string, number>;

native.onCanvasResize((id, width, height) => runWidgetCallback("canvas resize callback", () => {
  const binding = canvases.get(id);
  if (!binding || !Number.isFinite(width) || !Number.isFinite(height) || width < 0 || height < 0) return;
  if (binding.width === width && binding.height === height) return;
  binding.width = width;
  binding.height = height;
  binding.ctx = createCanvasContext(binding);
  drawCanvasFrame(id, Date.now() / 1000);
}));

export function h(type: ElementType, props: Record<string, unknown> | null, ...children: WidgetChild[]): VNode {
  const source = props ?? {};
  const propChildren = source.children as WidgetChild | WidgetChild[] | undefined;
  const resolvedChildren = flatten(children.length > 0 ? children : propChildren === undefined ? [] : [propChildren]);
  if (type === "icon") {
    if (resolvedChildren.some(isRenderable)) throw new Error("<icon> does not accept children");
    if (typeof source.iconPath !== "string" || source.iconPath.length === 0 ||
        typeof source.iconViewBox !== "string" || typeof source.iconStroke !== "number") {
      throw new Error("<icon> must be lowered to path data by weaver bundle");
    }
    source.class = `w-[24px] h-[24px] ${typeof source.class === "string" ? source.class : ""}`.trim();
  }
  if (type === "image") {
    if (source.fit !== undefined && source.fit !== "cover" && source.fit !== "contain" && source.fit !== "stretch") {
      throw new Error('<image> fit must be "cover", "contain", or "stretch"');
    }
    if (source.tile !== undefined && typeof source.tile !== "boolean") throw new Error("<image> tile must be boolean");
  }
  if (type === "button") {
    if (typeof source.onPress !== "function") throw new Error("<button> requires onPress={() => ...}");
    if (source.onDoublePress !== undefined && typeof source.onDoublePress !== "function") throw new Error("<button> onDoublePress must be a function");
    if (source.onRightPress !== undefined && typeof source.onRightPress !== "function") throw new Error("<button> onRightPress must be a function");
  }
  return {
    __weaverElement: true,
    type,
    props: source,
    key: source.key as string | number | undefined,
    children: resolvedChildren,
  };
}

export function jsx(type: ElementType, props: Record<string, unknown>, key?: string | number): VNode {
  return h(type, key === undefined ? props : { ...props, key });
}

export const jsxs = jsx;
export const jsxDEV = jsx;

export function widget(config: WidgetConfig, component: Component): WidgetModule {
  validateRuntimeConfig(config, component);
  if (rootComponent !== null) throw new Error("A widget bundle may call widget() exactly once");
  activeConfig = config;
  rootComponent = component;
  renderRoot();
  return Object.freeze({ config });
}

export function useState<T>(initial: T | (() => T)): [T, (next: T | ((previous: T) => T)) => void] {
  const component = currentComponent("useState");
  const index = component.hookIndex++;
  let hook = component.hooks[index] as StateHook<T> | undefined;
  if (!hook) {
    const fresh = typeof initial === "function" ? (initial as () => T)() : initial;
    hook = { kind: "state", value: seedHookValue(component, index, "state", fresh) };
    component.hooks[index] = hook as StateHook<unknown>;
  } else if (hook.kind !== "state") {
    throw hookOrderError("useState", index);
  }
  return [hook.value, (next) => {
    const value = typeof next === "function" ? (next as (previous: T) => T)(hook.value) : next;
    if (Object.is(value, hook.value)) return;
    hook.value = value;
    scheduleRender();
  }];
}

export function useRef<T>(initial: T): { current: T } {
  const component = currentComponent("useRef");
  const index = component.hookIndex++;
  let hook = component.hooks[index] as RefHook<T> | undefined;
  if (!hook) {
    hook = {
      kind: "ref",
      value: { current: seedHookValue(component, index, "ref", initial) },
      initialValueType: hotSwapValueType(initial),
    };
    component.hooks[index] = hook as RefHook<unknown>;
  } else if (hook.kind !== "ref") {
    throw hookOrderError("useRef", index);
  }
  return hook.value;
}

export function useEffect(effect: () => void | (() => void), deps?: unknown[]): void {
  const component = currentComponent("useEffect");
  const index = component.hookIndex++;
  let hook = component.hooks[index] as EffectHook | undefined;
  if (!hook) {
    hook = { kind: "effect" };
    component.hooks[index] = hook;
    matchEffectSeed(component, index);
  } else if (hook.kind !== "effect") {
    throw hookOrderError("useEffect", index);
  }
  if (depsEqual(hook.deps, deps)) return;
  hook.deps = deps?.slice();
  hook.effect = effect;
  pendingEffects.push(hook);
}

export function useInterval(callback: () => void, milliseconds: number): void {
  const latest = useRef(callback);
  latest.current = callback;
  useEffect(() => {
    if (!Number.isFinite(milliseconds) || milliseconds <= 0) throw new Error("useInterval requires a positive millisecond interval");
    const id = native.setInterval(milliseconds);
    native.onTimer(id, () => runWidgetCallback("useInterval callback", () => latest.current()));
    return () => native.clearInterval(id);
  }, [milliseconds]);
}

export function useProvider(name: "time"): TimeData;
export function useProvider(name: "cpu"): CpuData;
export function useProvider(name: "memory"): MemoryData;
export function useProvider(name: "audio"): AudioData;
export function useProvider(name: "media"): MediaData;
export function useProvider(name: ProviderName): TimeData | CpuData | MemoryData | AudioData | MediaData {
  requireProvider(name, "useProvider");
  const [value, setValue] = useState<ProviderValue>(() => initialProviderValue(name));
  useEffect(() => subscribeProvider(name, setValue), [name]);
  return value;
}

export function useProviderSignal(name: "time"): Signal<TimeData>;
export function useProviderSignal(name: "cpu"): Signal<CpuData>;
export function useProviderSignal(name: "memory"): Signal<MemoryData>;
export function useProviderSignal(name: "audio"): Signal<AudioData>;
export function useProviderSignal(name: "media"): Signal<MediaData>;
export function useProviderSignal(name: ProviderName): Signal<ProviderValue> {
  requireProvider(name, "useProviderSignal");
  const holder = useRef<MutableSignal<ProviderValue> | null>(null);
  if (!holder.current) holder.current = createSignal(initialProviderValue(name));
  const signal = holder.current;
  useEffect(() => subscribeProvider(name, (next) => signal.emit(next)), [name, signal]);
  return signal;
}

let nextMediaCommandId = 1;

function sendMediaCommand(verb: "play" | "pause" | "next" | "previous" | "seek", seekMs?: number): Promise<boolean> {
  if (!native.mediaCommand) return Promise.reject(new Error("MediaChannelUnavailable"));
  if (nextMediaCommandId > Number.MAX_SAFE_INTEGER) return Promise.reject(new Error("MediaCommandIdExhausted"));
  const id = nextMediaCommandId++;
  const command = seekMs === undefined
    ? { command: "media", verb, id }
    : { command: "media", verb, seekMs, id };
  return new Promise<boolean>((resolve, reject) => {
    native.mediaCommand!(JSON.stringify(command), (ok, error) => {
      if (error) reject(new Error(error));
      else resolve(ok === true);
    });
  });
}

const mediaTransport: MediaTransport = {
  play: () => sendMediaCommand("play"),
  pause: () => sendMediaCommand("pause"),
  next: () => sendMediaCommand("next"),
  previous: () => sendMediaCommand("previous"),
  seek: (ms) => Number.isFinite(ms) && Number.isInteger(ms) && ms >= 0
    ? sendMediaCommand("seek", ms)
    : Promise.reject(new Error("seekMs must be a finite non-negative integer")),
};

export function useMediaTransport(): MediaTransport {
  currentComponent("useMediaTransport");
  if (!activeConfig?.capabilities?.includes("media-transport")) {
    throw new Error('useMediaTransport() requires capabilities: ["media-transport"] in the widget config');
  }
  if (!native.mediaCommand) throw new Error("MediaChannelUnavailable");
  return mediaTransport;
}

let storageValues: Record<string, unknown> | null = null;
let storageDirty = false;
let storageTimerId = 0;

export function useStorage<T>(key: string, initial: T): [T, (next: T | ((previous: T) => T)) => void] {
  if (typeof key !== "string" || key.length === 0) throw new Error("useStorage requires a non-empty string key");
  const values = readStorage();
  const [value, setValue] = useState<T>(() => Object.prototype.hasOwnProperty.call(values, key) ? values[key] as T : initial);
  return [value, (next) => {
    setValue((previous) => {
      const resolved = typeof next === "function" ? (next as (prior: T) => T)(previous) : next;
      const candidate = { ...readStorage(), [key]: resolved };
      const encoded = serializeStorage(candidate);
      storageValues = candidate;
      storageDirty = true;
      scheduleStorageWrite(encoded);
      return resolved;
    });
  }];
}

export function wfetch(url: string, init: WFetchInit = {}): Promise<WFetchResponse> {
  const method = init.method ?? "GET";
  const headers = init.headers ?? {};
  if (method !== "GET" && method !== "POST") return Promise.reject(new Error("wfetch method must be GET or POST"));
  for (const [name, value] of Object.entries(headers)) {
    if (!name || /[:\r\n]/.test(name) || typeof value !== "string" || /[\r\n]/.test(value)) {
      return Promise.reject(new Error("wfetch headers must be string values without CR/LF"));
    }
  }
  return native.fetch(url, method, JSON.stringify(headers), init.body ?? "").then((response) => ({
    status: response.status,
    ok: response.status >= 200 && response.status < 300,
    text: async () => response.body,
    json: async () => JSON.parse(response.body) as unknown,
  }));
}

function renderRoot(): void {
  if (!rootComponent || widgetFailed) return;
  pendingEffects.length = 0;
  let batchStarted = false;
  try {
    native.beginBatch();
    batchStarted = true;
    renderInProgress = true;
    const nextRoot = reconcile(null, rootInstance, h(rootComponent, null));
    const rootId = firstNativeId(nextRoot);
    if (rootId !== committedRootId) {
      native.setRoot(rootId);
    }
    native.endBatch();
    batchStarted = false;
    renderInProgress = false;
    rootInstance = nextRoot;
    committedRootId = rootId;
  } catch (error) {
    renderInProgress = false;
    pendingEffects.length = 0;
    if (batchStarted) {
      try {
        native.abortBatch();
      } catch (abortError) {
        native.log(`render rollback failed: ${errorDetails(abortError)}`);
      }
    }
    const scope = renderFailureScope ?? "render";
    renderFailureScope = null;
    failWidget(scope, error);
    return;
  }
  renderFailureScope = null;
  for (const hook of pendingEffects.splice(0)) {
    runWidgetCallback("effect cleanup callback", () => hook.cleanup?.());
    if (widgetFailed) return;
    const cleanup = runWidgetCallback("effect callback", () => hook.effect?.());
    if (widgetFailed) return;
    hook.cleanup = typeof cleanup === "function" ? cleanup : undefined;
  }
}

function reconcile(parentId: number | null, previous: Instance | null, vnode: VNode): Instance {
  if (typeof vnode.type === "function") return reconcileComponent(parentId, previous, vnode, vnode.type);
  if (vnode.type === Fragment) return reconcileFragment(parentId, previous, vnode);
  return reconcileHost(parentId, previous, vnode, vnode.type);
}

function reconcileComponent(parentId: number | null, previous: Instance | null, vnode: VNode, componentType: Component): ComponentInstance {
  const instance: ComponentInstance = previous?.kind === "component" && previous.type === componentType && previous.key === vnode.key
    ? previous
    : { kind: "component", type: componentType, key: vnode.key, hooks: [], hookIndex: 0, child: null };
  if (instance !== previous && previous) unmount(previous);
  instance.hookIndex = 0;
  const prior = renderingComponent;
  renderingComponent = instance;
  let rendered: VNode;
  try {
    rendered = componentType();
  } finally {
    renderingComponent = prior;
  }
  if (!isVNode(rendered)) throw new Error("A Weaver component must return one JSX element");
  instance.child = reconcile(parentId, instance.child, rendered);
  if (instance.hookIndex !== instance.hooks.length) {
    throw new Error(`Hook order changed in ${componentType.name || "component"}`);
  }
  return instance;
}

function reconcileFragment(parentId: number | null, previous: Instance | null, vnode: VNode): FragmentInstance {
  const instance: FragmentInstance = previous?.kind === "fragment" && previous.key === vnode.key
    ? previous
    : { kind: "fragment", key: vnode.key, children: [] };
  if (instance !== previous && previous) unmount(previous);
  instance.children = reconcileChildren(parentId, instance.children, vnode.children);
  return instance;
}

function reconcileHost(parentId: number | null, previous: Instance | null, vnode: VNode, type: NodeType): HostInstance {
  const reusable = previous?.kind === "host" && previous.type === type && previous.key === vnode.key;
  const instance: HostInstance = reusable
    ? previous
    : { kind: "host", type, key: vnode.key, id: native.createNode(type), props: {}, elementProps: {}, mounted: true, children: [] };
  if (!reusable && previous) unmount(previous);
  const className = typeof vnode.props.class === "string" ? vnode.props.class : "";
  if (instance.className !== className) {
    const nextProps = compileClass(className);
    applyProps(instance.id, instance.props, nextProps);
    instance.props = nextProps;
    instance.className = className;
  }
  applyElementProps(instance, vnode.props);
  if (type === "text") {
    const children = vnode.children.filter(isRenderable);
    const binding = children.find(isSignal);
    if (binding) {
      if (children.length !== 1) throw new Error("A bound <text> must contain exactly one Signal child; format the complete label with signal.map(...)");
      bindHostText(instance, binding);
    } else {
      unbindHostText(instance);
      const text = children.map((child) => {
        if (typeof child !== "string" && typeof child !== "number") {
          throw new Error(`<text> children must be strings, numbers, or one Signal; received ${typeof child}`);
        }
        return String(child);
      }).join("");
      setHostText(instance, text);
    }
  } else if (type === "canvas") {
    if (vnode.children.some(isRenderable)) throw new Error("<canvas> does not accept children");
  } else {
    instance.children = reconcileChildren(instance.id, instance.children, vnode.children);
  }
  if (!reusable && parentId !== null) native.appendChild(parentId, instance.id);
  return instance;
}

function reconcileChildren(parentId: number | null, previous: Instance[], children: WidgetChild[]): Instance[] {
  const vnodes = children.filter(isRenderable).map(toVNode);
  const keyed = new Map<string | number, Instance>();
  const unkeyed: Instance[] = [];
  for (const child of previous) {
    const key = instanceKey(child);
    if (key === undefined) unkeyed.push(child);
    else keyed.set(key, child);
  }
  let unkeyedIndex = 0;
  const used = new Set<Instance>();
  const next = vnodes.map((vnode) => {
    const candidate = vnode.key === undefined ? unkeyed[unkeyedIndex++] ?? null : keyed.get(vnode.key) ?? null;
    if (candidate) used.add(candidate);
    return reconcile(parentId, candidate, vnode);
  });
  for (const child of previous) if (!used.has(child)) unmount(child);
  if (parentId !== null) reorder(parentId, previous.flatMap(nativeIds).filter((id) => next.flatMap(nativeIds).includes(id)), next.flatMap(nativeIds));
  return next;
}

function reorder(parentId: number, currentSource: number[], target: number[]): void {
  const current = currentSource.slice();
  for (const id of target) if (!current.includes(id)) current.push(id);
  for (let index = 0; index < target.length; index += 1) {
    if (current[index] === target[index]) continue;
    const from = current.indexOf(target[index]);
    if (from >= 0) current.splice(from, 1);
    const before = current[index] ?? 0;
    native.insertBefore(parentId, target[index], before);
    current.splice(index, 0, target[index]);
  }
}

function applyProps(id: number, previous: ClassProps, next: ClassProps): void {
  const defaults: Required<ClassProps> = {
    padding: 0, paddingTop: -1, paddingRight: -1, paddingBottom: -1, paddingLeft: -1,
    marginTop: 0, marginRight: 0, marginBottom: 0, marginLeft: 0,
    gap: 0, radius: 0, radiusTopLeft: -1, radiusTopRight: -1, radiusBottomRight: -1, radiusBottomLeft: -1,
    borderWidth: 0, borderColor: "", shadow: "", shadowInset: false, textShadow: "", background: "", textColor: "",
    fontScale: 1, fontWeight: "normal", fontFamily: "sans", textAlign: "start", lineHeight: 0,
    letterSpacing: 0, lineClamp: 0, tabularNums: false, opacity: 1, crossAlign: "stretch",
    hoverBackground: "", hoverTextColor: "", hoverOpacity: -1, hoverBorderColor: "", hoverShadow: "", hoverShadowInset: false,
    pressedBackground: "", pressedTextColor: "", pressedOpacity: -1, pressedBorderColor: "", pressedShadow: "", pressedShadowInset: false,
    mainAlign: "start", grow: 0, shrink: 1, alignSelf: "auto", flexWrap: false, width: -1, height: -1,
    minWidth: 0, minHeight: 0, maxWidth: -1, maxHeight: -1,
    widthPercent: 0, heightPercent: 0, aspectRatio: 0, truncate: false, overflowHidden: false,
  };
  for (const key of Object.keys(defaults) as (keyof ClassProps)[]) {
    const before = previous[key] ?? defaults[key];
    const after = next[key] ?? defaults[key];
    if (!Object.is(before, after)) native.setProp(id, key, after);
  }
}

function applyElementProps(instance: HostInstance, props: Record<string, unknown>): void {
  const previous = instance.elementProps;
  const next: HostElementProps = {};
  if (instance.type === "button") {
    if (typeof props.onPress !== "function") throw new Error("<button> requires onPress={() => ...}");
    next.onPress = props.onPress as (event?: PressEvent) => void;
    next.onDoublePress = props.onDoublePress as ((event: PressEvent) => void) | undefined;
    next.onRightPress = props.onRightPress as ((event: PressEvent) => void) | undefined;
  } else if (instance.type === "slider") {
    if (typeof props.onChange !== "function") throw new Error("<slider> requires onChange={(value) => ...}");
    if (typeof props.value !== "number" || !Number.isFinite(props.value)) throw new Error("<slider> value must be a finite number");
    if (typeof props.max !== "number" || !Number.isFinite(props.max) || props.max <= 0) throw new Error("<slider> max must be positive");
    next.onChange = props.onChange as (value: number) => void;
    next.value = Math.max(0, Math.min(props.value, props.max));
    next.max = props.max;
  } else if (instance.type === "image") {
    if (typeof props.src !== "string" || props.src.length === 0) throw new Error("<image> requires a local src string");
    const windowsAbsolute = /^[a-z]:[\\/]/i.test(props.src);
    if ((!windowsAbsolute && /^[a-z][a-z0-9+.-]*:/i.test(props.src)) || props.src.startsWith("//")) {
      throw new Error("RemoteImageUnsupported: <image> remote sources arrive in M3; use a local widget path");
    }
    next.src = props.src;
    if (props.fit !== undefined && props.fit !== "cover" && props.fit !== "contain" && props.fit !== "stretch") {
      throw new Error('<image> fit must be "cover", "contain", or "stretch"');
    }
    if (props.tile !== undefined && typeof props.tile !== "boolean") throw new Error("<image> tile must be boolean");
    next.fit = (props.fit ?? "stretch") as "cover" | "contain" | "stretch";
    next.tile = (props.tile ?? false) as boolean;
  } else if (instance.type === "icon") {
    if (typeof props.iconPath !== "string" || props.iconPath.length === 0) throw new Error("<icon> requires lowered iconPath");
    if (typeof props.iconViewBox !== "string" || props.iconViewBox.length === 0) throw new Error("<icon> requires lowered iconViewBox");
    if (typeof props.iconStroke !== "number" || !Number.isFinite(props.iconStroke) || props.iconStroke < 0) throw new Error("<icon> iconStroke must be non-negative");
    next.iconPath = props.iconPath;
    next.iconViewBox = props.iconViewBox;
    next.iconStroke = props.iconStroke;
  } else if (instance.type === "canvas") {
    if (typeof props.onFrame !== "function") throw new Error("<canvas> requires onFrame={(ctx, frame) => ...}");
    if (props.fps !== undefined && (typeof props.fps !== "number" || !Number.isFinite(props.fps) || props.fps < 0)) {
      throw new Error("<canvas> fps must be zero or a positive number when provided");
    }
    next.onFrame = props.onFrame as (ctx: CanvasCtx, frame: CanvasFrame) => void;
    next.fps = props.fps === undefined ? undefined : Math.min(MAX_CANVAS_FPS, props.fps as number);
  }
  if (Boolean(previous.onPress) !== Boolean(next.onPress)) native.setHandler(instance.id, "press", Boolean(next.onPress));
  if (Boolean(previous.onDoublePress) !== Boolean(next.onDoublePress)) native.setHandler(instance.id, "doublepress", Boolean(next.onDoublePress));
  if (Boolean(previous.onRightPress) !== Boolean(next.onRightPress)) native.setHandler(instance.id, "rightpress", Boolean(next.onRightPress));
  if (Boolean(previous.onChange) !== Boolean(next.onChange)) native.setHandler(instance.id, "change", Boolean(next.onChange));
  if (!Object.is(previous.value, next.value) && next.value !== undefined) native.setProp(instance.id, "value", next.value);
  if (!Object.is(previous.max, next.max) && next.max !== undefined) native.setProp(instance.id, "max", next.max);
  if (!Object.is(previous.src, next.src) && next.src !== undefined) native.setProp(instance.id, "source", next.src);
  if (!Object.is(previous.iconPath, next.iconPath) && next.iconPath !== undefined) native.setProp(instance.id, "iconPath", next.iconPath);
  if (!Object.is(previous.iconViewBox, next.iconViewBox) && next.iconViewBox !== undefined) native.setProp(instance.id, "iconViewBox", next.iconViewBox);
  if (!Object.is(previous.iconStroke, next.iconStroke) && next.iconStroke !== undefined) native.setProp(instance.id, "iconStroke", next.iconStroke);
  if (!Object.is(previous.fit, next.fit) && next.fit !== undefined) native.setProp(instance.id, "imageFit", next.fit);
  if (!Object.is(previous.tile, next.tile) && next.tile !== undefined) native.setProp(instance.id, "imageTile", next.tile);
  instance.elementProps = next;
  if (instance.type === "canvas" && next.onFrame) {
    updateCanvasBinding(instance.id, next.onFrame, next.fps, instance.props.width ?? 0, instance.props.height ?? 0);
  }
  if (next.onPress || next.onDoublePress || next.onRightPress || next.onChange) handlers.set(instance.id, next);
  else handlers.delete(instance.id);
}

function unmount(instance: Instance): void {
  if (instance.kind === "component") {
    for (const hook of instance.hooks) {
      if (hook.kind === "effect") runWidgetCallback("effect cleanup callback", () => hook.cleanup?.());
    }
    if (instance.child) unmount(instance.child);
    return;
  }
  if (instance.kind === "fragment") {
    for (const child of instance.children) unmount(child);
    return;
  }
  for (const child of instance.children) unmount(child);
  instance.mounted = false;
  unbindHostText(instance);
  handlers.delete(instance.id);
  disposeCanvas(instance.id);
  native.removeNode(instance.id);
}

function bindHostText(instance: HostInstance, binding: Signal<string | number>): void {
  if (instance.textBinding === binding) {
    setHostText(instance, String(binding.value));
    return;
  }
  unbindHostText(instance);
  instance.textBinding = binding;
  setHostText(instance, String(binding.value));
  instance.textUnsubscribe = binding.subscribe((value) => {
    runWidgetCallback("bound <text> update", () => {
      if (instance.mounted) setHostText(instance, String(value));
    });
  });
}

function unbindHostText(instance: HostInstance): void {
  instance.textUnsubscribe?.();
  instance.textUnsubscribe = undefined;
  instance.textBinding = undefined;
}

function setHostText(instance: HostInstance, text: string): void {
  if (instance.text === text) return;
  native.setText(instance.id, text);
  instance.text = text;
}

function updateCanvasBinding(id: number, onFrame: (ctx: CanvasCtx, frame: CanvasFrame) => void, fps: number | undefined, width: number, height: number): void {
  let binding = canvases.get(id);
  const mounted = binding === undefined;
  const intervalChanged = binding?.fps !== fps;
  if (!binding) {
    binding = {
      onFrame, fps, timerId: 0, surfaceClock: false, width, height,
      batch: new Float64Array(MAX_CANVAS_WIRE_VALUES), batchLength: 0, active: false,
      ctx: undefined as unknown as CanvasCtx,
    };
    binding.ctx = createCanvasContext(binding);
    canvases.set(id, binding);
  } else {
    const sizeChanged = binding.width !== width || binding.height !== height;
    binding.onFrame = onFrame;
    binding.width = width;
    binding.height = height;
    if (sizeChanged) binding.ctx = createCanvasContext(binding);
  }
  if (intervalChanged && binding.timerId !== 0) {
    native.clearInterval(binding.timerId);
    binding.timerId = 0;
    binding.lastT = undefined;
    binding.nextT = undefined;
    binding.nativeTimestampStarted = false;
  }
  if (intervalChanged && binding.surfaceClock) {
    native.clearCanvasFrame(id);
    binding.surfaceClock = false;
    binding.lastT = undefined;
    binding.nextT = undefined;
    binding.nativeTimestampStarted = false;
  }
  binding.fps = fps;
  if (fps === 0) {
    if (mounted) drawCanvasFrame(id, Date.now() / 1000);
    return;
  }
  if (fps === undefined) {
    drawCanvasFrame(id, Date.now() / 1000);
    return;
  }
  if (fps >= MAX_CANVAS_FPS) {
    if (!binding.surfaceClock) {
      native.onCanvasFrame(id, (timestampSeconds) => drawCanvasFrame(id, timestampSeconds));
      binding.surfaceClock = true;
      drawCanvasFrame(id, Date.now() / 1000);
    }
    return;
  }
  if (binding.timerId === 0) {
    // Sub-vsync canvases own one exact-rate SDK effect timer. Provider frames
    // are drained immediately before this callback in the same native update,
    // so their state and canvas commands commit as one generation. The native
    // clock is precise below 40 ms; the old one-quantum lead over-drove that
    // clock and made a requested 30 Hz canvas contend at ~50 Hz.
    const interval = Math.max(1, Math.round(1000 / fps));
    binding.timerId = native.setInterval(interval);
    native.onTimer(binding.timerId, (timestampSeconds) => drawCanvasFrame(id, timestampSeconds ?? Date.now() / 1000));
    drawCanvasFrame(id, Date.now() / 1000);
  }
}

function drawTimedCanvasFrame(id: number, timestampSeconds: number): void {
  const binding = canvases.get(id);
  if (!binding || binding.fps === undefined || binding.fps === 0) return;
  const period = 1 / binding.fps;
  if (binding.nextT === undefined) binding.nextT = timestampSeconds;
  if (timestampSeconds + 0.000_001 < binding.nextT) return;
  do binding.nextT += period;
  while (binding.nextT <= timestampSeconds);
  drawCanvasFrame(id, timestampSeconds);
}

function disposeCanvas(id: number): void {
  const binding = canvases.get(id);
  if (!binding) return;
  if (binding.timerId !== 0) native.clearInterval(binding.timerId);
  if (binding.surfaceClock) native.clearCanvasFrame(id);
  canvases.delete(id);
}

function drawCanvasFrame(id: number, nativeTimestamp?: number): void {
  runWidgetCallback("canvas onFrame callback", () => {
    const binding = canvases.get(id);
    if (!binding) return;
    if (nativeTimestamp !== undefined && !binding.nativeTimestampStarted) {
      binding.lastT = undefined;
      binding.nativeTimestampStarted = true;
    }
    const t = typeof nativeTimestamp === "number" && Number.isFinite(nativeTimestamp) && nativeTimestamp > 0
      ? nativeTimestamp
      : Date.now() / 1000;
    const dt = binding.lastT === undefined ? 0 : Math.max(0, t - binding.lastT);
    binding.lastT = t;
    binding.batchLength = 0;
    binding.active = true;
    try {
      binding.onFrame(binding.ctx, { t, dt });
    } finally {
      binding.active = false;
    }
    // Preserve a real empty canvas on glass without making the GPU transport
    // treat the frame as an unsupported packet. The zero-area transparent rect
    // is visually inert in both renderers but gives the retained packet an
    // explicit draw command that clears stale immediate instances.
    if (binding.batchLength === 2 && binding.batch[0] === 0) {
      const at = binding.batchLength;
      binding.batch[at] = 1; binding.batch[at + 1] = 0; binding.batch[at + 2] = 0;
      binding.batch[at + 3] = 0; binding.batch[at + 4] = 0; binding.batch[at + 5] = 0;
      binding.batchLength += 6;
    }
    native.setCanvasCommands(id, binding.batch.subarray(0, binding.batchLength));
  });
}

/// Keep the command writer and its bounded Float64Array stable for the life of
/// the canvas. A frame resets only the write cursor, avoiding four short-lived
/// JS allocations per present while retaining the same compact native wire.
function createCanvasContext(binding: CanvasBinding): CanvasCtx {
  const ensureActive = (): void => { if (!binding.active) throw new Error("CanvasCtx methods may only be called inside onFrame"); };
  const reserve = (count: number): number => {
    if (binding.batchLength + count > binding.batch.length) throw new Error(`Canvas frame needs ${binding.batchLength + count} wire values; the limit (max_canvas_wire_values) is ${binding.batch.length} — draw fewer commands per frame`);
    const offset = binding.batchLength;
    binding.batchLength += count;
    return offset;
  };
  return Object.freeze({
    width: binding.width,
    height: binding.height,
    clear(color = "#00000000"): void {
      ensureActive();
      const at = reserve(2);
      binding.batch[at] = 0; binding.batch[at + 1] = packedColor(color);
    },
    fillRect(x: number, y: number, rectWidth: number, rectHeight: number, color: string): void {
      ensureActive();
      const at = reserve(6);
      binding.batch[at] = 1; binding.batch[at + 1] = x; binding.batch[at + 2] = y;
      binding.batch[at + 3] = rectWidth; binding.batch[at + 4] = rectHeight; binding.batch[at + 5] = packedColor(color);
    },
    fillRoundRect(x: number, y: number, rectWidth: number, rectHeight: number, radius: number, color: string): void {
      ensureActive();
      const at = reserve(7);
      binding.batch[at] = 2; binding.batch[at + 1] = x; binding.batch[at + 2] = y;
      binding.batch[at + 3] = rectWidth; binding.batch[at + 4] = rectHeight;
      binding.batch[at + 5] = radius; binding.batch[at + 6] = packedColor(color);
    },
    fillCircle(cx: number, cy: number, radius: number, color: string): void {
      ensureActive();
      const at = reserve(5);
      binding.batch[at] = 3; binding.batch[at + 1] = cx; binding.batch[at + 2] = cy;
      binding.batch[at + 3] = radius; binding.batch[at + 4] = packedColor(color);
    },
    line(x1: number, y1: number, x2: number, y2: number, lineWidth: number, color: string): void {
      ensureActive();
      const at = reserve(7);
      binding.batch[at] = 4; binding.batch[at + 1] = x1; binding.batch[at + 2] = y1;
      binding.batch[at + 3] = x2; binding.batch[at + 4] = y2;
      binding.batch[at + 5] = lineWidth; binding.batch[at + 6] = packedColor(color);
    },
    polyline(points: number[], lineWidth: number, color: string): void {
      ensureActive();
      if (!Array.isArray(points) || points.length < 4 || points.length % 2 !== 0) throw new Error("CanvasCtx polyline points must be a flat [x,y,...] array with at least two points");
      const at = reserve(4 + points.length);
      binding.batch[at] = 5; binding.batch[at + 1] = lineWidth;
      binding.batch[at + 2] = packedColor(color); binding.batch[at + 3] = points.length / 2;
      for (let index = 0; index < points.length; index += 1) binding.batch[at + 4 + index] = points[index];
    },
  });
}

function packedColor(source: string): number {
  const cached = colorCache[source];
  if (cached !== undefined) return cached;
  if (typeof source !== "string") throw new Error("Canvas colors must be #rgb, #rrggbb, or #rrggbbaa");
  let hex: string;
  if (/^#[0-9a-f]{3}$/i.test(source)) {
    hex = `${source[1]}${source[1]}${source[2]}${source[2]}${source[3]}${source[3]}ff`;
  } else if (/^#[0-9a-f]{6}$/i.test(source)) {
    hex = `${source.slice(1)}ff`;
  } else if (/^#[0-9a-f]{8}$/i.test(source)) {
    hex = source.slice(1);
  } else {
    throw new Error(`Invalid canvas color "${source}": use #rgb, #rrggbb, or #rrggbbaa`);
  }
  const packed = Number.parseInt(hex, 16) >>> 0;
  colorCache[source] = packed;
  return packed;
}

function nativeIds(instance: Instance): number[] {
  if (instance.kind === "host") return [instance.id];
  if (instance.kind === "component") return instance.child ? nativeIds(instance.child) : [];
  return instance.children.flatMap(nativeIds);
}

function firstNativeId(instance: Instance): number {
  const ids = nativeIds(instance);
  if (ids.length !== 1) throw new Error("A widget root must resolve to exactly one native element");
  return ids[0];
}

function instanceKey(instance: Instance): string | number | undefined { return instance.key; }
function isRenderable(value: WidgetChild): value is VNode | string | number | Signal<string | number> { return value !== null && value !== undefined && value !== false; }
function isVNode(value: unknown): value is VNode { return typeof value === "object" && value !== null && (value as { __weaverElement?: boolean }).__weaverElement === true; }
function isSignal(value: unknown): value is Signal<string | number> { return typeof value === "object" && value !== null && signals.has(value); }
function toVNode(value: VNode | string | number | Signal<string | number>): VNode { return isVNode(value) ? value : h("text", null, value); }

function flatten(values: readonly unknown[]): WidgetChild[] {
  const output: WidgetChild[] = [];
  for (const value of values) {
    if (Array.isArray(value)) output.push(...flatten(value));
    else output.push(value as WidgetChild);
  }
  return output;
}

function scheduleRender(): void {
  if (renderQueued || widgetFailed) return;
  renderQueued = true;
  void Promise.resolve().then(() => {
    renderQueued = false;
    renderRoot();
  });
}

function errorDetails(error: unknown): string {
  if (error instanceof Error) {
    const headline = `${error.name}: ${error.message}`;
    if (!error.stack) return headline;
    return error.message && !error.stack.includes(error.message) ? `${headline}\n${error.stack}` : error.stack;
  }
  try {
    return typeof error === "string" ? error : JSON.stringify(error);
  } catch {
    return String(error);
  }
}

function failWidget(scope: string, error: unknown): void {
  if (widgetFailed) return;
  widgetFailed = true;
  renderQueued = false;
  pendingEffects.length = 0;
  const details = errorDetails(error);
  try {
    native.reportError(scope, details);
  } catch (reportError) {
    native.log(`${scope} failed: ${details}\nerror reporting also failed: ${errorDetails(reportError)}`);
  }
}

function runWidgetCallback<T>(scope: string, callback: () => T): T | undefined {
  if (widgetFailed) return undefined;
  try {
    return callback();
  } catch (error) {
    if (renderInProgress) {
      renderFailureScope = scope;
      throw error;
    }
    failWidget(scope, error);
    return undefined;
  }
}

function currentComponent(hook: string): ComponentInstance {
  if (!renderingComponent) throw new Error(`${hook} must be called while rendering a component`);
  return renderingComponent;
}

function hookOrderError(hook: string, index: number): Error { return new Error(`${hook} changed hook order at slot ${index}`); }
function depsEqual(left?: unknown[], right?: unknown[]): boolean {
  if (!left || !right || left.length !== right.length) return false;
  return left.every((value, index) => Object.is(value, right[index]));
}

function validateRuntimeConfig(config: WidgetConfig, component: Component): void {
  if (!config || typeof config !== "object") throw new Error("widget config must be an object");
  if (!config.name?.trim()) throw new Error("widget config.name must be a non-empty string");
  if (!Array.isArray(config.size) || config.size.length !== 2 || config.size.some((value) => !Number.isFinite(value) || value <= 0)) {
    throw new Error("widget config.size must contain two positive numbers");
  }
  if (typeof component !== "function") throw new Error("widget component must be a function");
  if (config.capabilities && config.capabilities.some((capability) => capability !== "media-transport")) {
    throw new Error('Widget capabilities support only "media-transport"');
  }
}

function parseHotSwapSeed(value: unknown): HotSwapSlot[] | null {
  if (typeof value !== "string") return null;
  try {
    const parsed = JSON.parse(value) as unknown;
    if (!Array.isArray(parsed) || parsed.some((slot) => !slot || typeof slot !== "object" || !["state", "ref", "effect"].includes(String((slot as HotSwapSlot).kind)))) {
      native.log("dev hot swap state seed was invalid; candidate must retry with fresh state");
      return null;
    }
    return parsed as HotSwapSlot[];
  } catch {
    native.log("dev hot swap state seed could not be parsed; candidate must retry with fresh state");
    return null;
  }
}

function hotSwapValueType(value: unknown): HotSwapValueType {
  if (value === null) return "null";
  if (Array.isArray(value)) return "array";
  return typeof value;
}

function seedHookValue<T>(component: ComponentInstance, index: number, kind: "state" | "ref", fresh: T): T {
  if (component.type !== rootComponent || !hotSwapSeed) return fresh;
  const slot = hotSwapSeed[index];
  const freshType = hotSwapValueType(fresh);
  if (!slot || slot.kind !== kind || slot.valueType !== freshType || (slot.transferable !== false && hotSwapValueType(slot.value) !== slot.valueType)) {
    hotSwapCompatible = false;
    return fresh;
  }
  return slot.transferable === false ? fresh : slot.value as T;
}

function matchEffectSeed(component: ComponentInstance, index: number): void {
  if (component.type !== rootComponent || !hotSwapSeed) return;
  if (hotSwapSeed[index]?.kind !== "effect") hotSwapCompatible = false;
}

function captureHotSwap(): string | null {
  if (rootInstance?.kind !== "component" || rootInstance.type !== rootComponent) return null;
  try {
    return JSON.stringify(rootInstance.hooks.map((hook): HotSwapSlot => {
      if (hook.kind === "effect") return { kind: "effect" };
      const value = hook.kind === "ref" ? hook.value.current : hook.value;
      if (hook.kind === "ref" && value !== null && typeof value === "object" && signals.has(value)) {
        return { kind: "ref", valueType: hook.initialValueType, transferable: false };
      }
      const valueType = hotSwapValueType(value);
      if (["undefined", "bigint", "symbol", "function"].includes(valueType)) return { kind: hook.kind, valueType, transferable: false };
      return { kind: hook.kind, valueType, value };
    }));
  } catch {
    native.log("dev hot swap state capture could not be serialized; next candidate will use fresh state");
    return null;
  }
}

function hotSwapAccepted(): boolean {
  if (hotSwapSeedProvided && !hotSwapSeed) return false;
  if (!hotSwapSeed) return !widgetFailed;
  return !widgetFailed && hotSwapCompatible && rootInstance?.kind === "component" && rootInstance.type === rootComponent && rootInstance.hooks.length === hotSwapSeed.length;
}

function readStorage(): Record<string, unknown> {
  if (storageValues) return storageValues;
  const raw = native.storageRead();
  if (raw === null) return storageValues = {};
  const parsed = JSON.parse(raw) as unknown;
  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) throw new Error("Stored widget state is not a JSON object");
  return storageValues = parsed as Record<string, unknown>;
}

function serializeStorage(values: Record<string, unknown>): string {
  const encoded = JSON.stringify(values);
  const encodedBytes = utf8ByteLength(encoded);
  if (encodedBytes > STORAGE_QUOTA_BYTES) {
    throw new Error(`StorageQuotaExceeded: max_storage_bytes=${STORAGE_QUOTA_BYTES}, asked for ${encodedBytes}`);
  }
  return encoded;
}

function scheduleStorageWrite(_encoded: string): void {
  if (storageTimerId !== 0) native.clearInterval(storageTimerId);
  storageTimerId = native.setInterval(200);
  native.onTimer(storageTimerId, () => runWidgetCallback("storage flush callback", () => {
    native.clearInterval(storageTimerId);
    storageTimerId = 0;
    flushStorage();
  }));
}

function flushStorage(): void {
  if (!storageDirty || !storageValues) return;
  native.storageWrite(serializeStorage(storageValues));
  storageDirty = false;
}

function utf8ByteLength(value: string): number {
  let bytes = 0;
  for (let index = 0; index < value.length; index += 1) {
    const code = value.charCodeAt(index);
    if (code < 0x80) bytes += 1;
    else if (code < 0x800) bytes += 2;
    else if (code >= 0xd800 && code <= 0xdbff && index + 1 < value.length && value.charCodeAt(index + 1) >= 0xdc00 && value.charCodeAt(index + 1) <= 0xdfff) {
      bytes += 4;
      index += 1;
    } else bytes += 3;
  }
  return bytes;
}

function pressEvent(payload: NativePressPayload): PressEvent {
  const u = payload.w > 0 ? Math.max(0, Math.min(1, payload.x / payload.w)) : 0;
  const v = payload.h > 0 ? Math.max(0, Math.min(1, payload.y / payload.h)) : 0;
  return { x: payload.x, y: payload.y, u, v };
}

native.onEvent((id, kind, payload) => runWidgetCallback(`${kind} event callback`, () => {
  const handler = handlers.get(id);
  if (kind === "press") handler?.onPress?.(payload && typeof payload === "object" ? pressEvent(payload) : undefined);
  else if (kind === "doublepress" && payload && typeof payload === "object") handler?.onDoublePress?.(pressEvent(payload));
  else if (kind === "rightpress" && payload && typeof payload === "object") handler?.onRightPress?.(pressEvent(payload));
  else if (kind === "change" && typeof payload === "number") handler?.onChange?.(payload);
}));
Object.defineProperty(globalThis, "wfetch", { value: wfetch, configurable: false, writable: false });
Object.defineProperty(globalThis, "__weaverFlushStorage", { value: flushStorage, configurable: false, writable: false });
Object.defineProperty(globalThis, "__weaverCaptureHotSwap", { value: captureHotSwap, configurable: false, writable: false });
Object.defineProperty(globalThis, "__weaverHotSwapAccepted", { value: hotSwapAccepted, configurable: false, writable: false });

const weekdays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"] as const;
const months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"] as const;
function pad2(value: number): string { return String(value).padStart(2, "0"); }
function currentTime(): TimeData {
  const now = new Date();
  return {
    hh: pad2(now.getHours()), mm: pad2(now.getMinutes()), ss: pad2(now.getSeconds()),
    weekday: weekdays[now.getDay()], month: months[now.getMonth()], day: now.getDate(),
    year: now.getFullYear(), epochMs: now.getTime(),
  };
}

function requireProvider(name: ProviderName, hook: "useProvider" | "useProviderSignal"): void {
  if (!activeConfig?.subscribe?.includes(name)) {
    throw new Error(`${hook}("${name}") requires subscribe: ["${name}"] in the widget config`);
  }
  if (name !== "time" && !native.hostAvailable()) {
    throw new Error(`Provider "${name}" requires weaverd; run "weaver up"`);
  }
}

function initialProviderValue(name: ProviderName): ProviderValue {
  if (name === "time") return currentTime();
  if (name === "cpu") return { percent: 0, perCore: [] };
  if (name === "memory") return { usedMb: 0, totalMb: 0, percent: 0 };
  if (name === "audio") return { rms: 0, bands: Array.from({ length: 32 }, () => 0) };
  return {
    title: "",
    artist: "",
    album: "",
    status: "stopped",
    playing: false,
    sourceApp: "",
    positionMs: 0,
    durationMs: 0,
  };
}

function subscribeProvider(name: ProviderName, listener: (value: ProviderValue) => void): () => void {
  if (name === "time") return timeProvider.subscribe(listener);
  if (name === "cpu") return hostProviders.subscribeCpu(listener);
  if (name === "memory") return hostProviders.subscribeMemory(listener);
  if (name === "audio") return hostProviders.subscribeAudio(listener);
  return hostProviders.subscribeMedia(listener);
}

function createSignal<T>(initial: T): MutableSignal<T> {
  let current = initial;
  const listeners = new Set<(value: T) => void>();
  const signal: MutableSignal<T> = {
    get value(): T { return current; },
    subscribe(listener: (value: T) => void): () => void {
      if (typeof listener !== "function") throw new Error("Signal.subscribe(listener) requires a function");
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
    map<U>(project: (value: T) => U): Signal<U> {
      if (typeof project !== "function") throw new Error("Signal.map(project) requires a function");
      return mapSignal(signal, project);
    },
    emit(value: T): void {
      current = value;
      let failed = false;
      let firstError: unknown;
      // Deliver one coherent emission to the subscription snapshot before
      // failing the widget. A user listener must not prevent retained text or
      // later listeners from observing the value that was already committed.
      for (const listener of [...listeners]) {
        try {
          listener(value);
        } catch (error) {
          if (!failed) firstError = error;
          failed = true;
        }
      }
      if (failed) failWidget("signal listener", firstError);
    },
  };
  signals.add(signal);
  return signal;
}

function mapSignal<T, U>(source: Signal<T>, project: (value: T) => U): Signal<U> {
  let projections = signalMaps.get(source);
  if (!projections) {
    projections = new WeakMap<Function, Signal<unknown>>();
    signalMaps.set(source, projections);
  }
  const cached = projections.get(project);
  if (cached) return cached as Signal<U>;
  const mapped: Signal<U> = {
    get value(): U { return project(source.value); },
    subscribe(listener: (value: U) => void): () => void {
      if (typeof listener !== "function") throw new Error("Signal.subscribe(listener) requires a function");
      return source.subscribe((value) => listener(project(value)));
    },
    map<V>(next: (value: U) => V): Signal<V> {
      if (typeof next !== "function") throw new Error("Signal.map(project) requires a function");
      return mapSignal(mapped, next);
    },
  };
  signals.add(mapped);
  projections.set(project, mapped as Signal<unknown>);
  return mapped;
}

const timeProvider = (() => {
  const listeners = new Set<(value: TimeData) => void>();
  let timerId = 0;
  const tick = (): void => {
    const value = currentTime();
    for (const listener of listeners) listener(value);
  };
  return {
    subscribe(listener: (value: TimeData) => void): () => void {
      listeners.add(listener);
      if (timerId === 0) {
        timerId = native.setInterval(1000);
        native.onTimer(timerId, () => runWidgetCallback("time provider callback", tick));
      }
      return () => {
        listeners.delete(listener);
        if (listeners.size === 0 && timerId !== 0) {
          native.clearInterval(timerId);
          timerId = 0;
        }
      };
    },
  };
})();

const hostProviders = (() => {
  const cpuListeners = new Set<(value: CpuData) => void>();
  const memoryListeners = new Set<(value: MemoryData) => void>();
  const audioListeners = new Set<(value: AudioData) => void>();
  const mediaListeners = new Set<(value: MediaData) => void>();
  let installed = false;
  const install = (): void => {
    if (installed) return;
    installed = true;
    native.onProvider((line) => runWidgetCallback("host provider callback", () => {
      const frame = JSON.parse(line) as { provider?: unknown; value?: unknown };
      if (frame.provider === "cpu") {
        const value = frame.value as CpuData;
        for (const listener of cpuListeners) listener(value);
      } else if (frame.provider === "memory") {
        const value = frame.value as MemoryData;
        for (const listener of memoryListeners) listener(value);
      } else if (frame.provider === "audio") {
        const value = frame.value as AudioData;
        for (const listener of audioListeners) listener(value);
      } else if (frame.provider === "media") {
        const value = frame.value as MediaData;
        for (const listener of mediaListeners) listener(value);
      }
    }));
  };
  return {
    subscribeCpu(listener: (value: CpuData) => void): () => void {
      install();
      cpuListeners.add(listener);
      return () => cpuListeners.delete(listener);
    },
    subscribeMemory(listener: (value: MemoryData) => void): () => void {
      install();
      memoryListeners.add(listener);
      return () => memoryListeners.delete(listener);
    },
    subscribeAudio(listener: (value: AudioData) => void): () => void {
      install();
      audioListeners.add(listener);
      return () => audioListeners.delete(listener);
    },
    subscribeMedia(listener: (value: MediaData) => void): () => void {
      install();
      mediaListeners.add(listener);
      return () => mediaListeners.delete(listener);
    },
  };
})();
