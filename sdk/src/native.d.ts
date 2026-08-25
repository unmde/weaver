interface WeaverNativeFetchResponse { status: number; body: string }
interface NativePressPayload { x: number; y: number; w: number; h: number }

interface WeaverNativeBridge {
  createNode(type: "column" | "row" | "stack" | "text" | "icon" | "panel" | "button" | "slider" | "image" | "canvas"): number;
  setProp(id: number, key: string, value: string | number | boolean): void;
  setText(id: number, text: string): void;
  appendChild(parentId: number, childId: number): void;
  insertBefore(parentId: number, childId: number, beforeId: number): void;
  removeNode(id: number): void;
  setRoot(id: number): void;
  beginBatch(): void;
  endBatch(): void;
  abortBatch(): void;
  reportError(scope: string, details: string): void;
  setHandler(id: number, kind: "press" | "doublepress" | "rightpress" | "change", enabled: boolean): void;
  onEvent(callback: (id: number, kind: "press" | "doublepress" | "rightpress" | "change", payload: number | NativePressPayload | null) => void): void;
  hostAvailable(): boolean;
  readonly captureMode: boolean;
  onProvider(callback: (jsonLine: string) => void): void;
  mediaCommand?(json: string, callback: (ok: boolean | null, error: string | null) => void): void;
  setInterval(ms: number): number;
  clearInterval(id: number): void;
  onTimer(id: number, callback: (timestampSeconds?: number) => void): void;
  setCanvasCommands(id: number, commands: Float64Array): void;
  onCanvasResize(callback: (id: number, width: number, height: number) => void): void;
  onCanvasFrame(id: number, callback: (timestampSeconds: number) => void): void;
  clearCanvasFrame(id: number): void;
  fetch(url: string, method: "GET" | "POST", headersJson: string, body: string): Promise<WeaverNativeFetchResponse>;
  storageRead(): string | null;
  storageWrite(json: string): void;
  log(message: string): void;
}

declare const native: WeaverNativeBridge;
