import { useEffect, useProvider, widget, type CanvasCtx, type CpuData } from "@weaver/sdk";

// CPU and memory from the host at 1 Hz. The text nodes update in the retained
// tree; the three canvases redraw once per provider frame (no `fps`, so no
// frame clock of their own).

const historyLength = 60;
const history: number[] = [];

const accent = "#2dd4bf";
const accentSoft = "#2dd4bf33";
const track = "#ffffff14";

function gigabytes(mb: number): string {
  return (mb / 1024).toFixed(1);
}

function drawHistory(ctx: CanvasCtx): void {
  ctx.clear();
  const step = ctx.width / (historyLength - 1);
  const floor = ctx.height - 1;
  const points: number[] = [];
  const offset = historyLength - history.length;
  for (let index = 0; index < history.length; index += 1) {
    const x = (offset + index) * step;
    const y = floor - (history[index] / 100) * (ctx.height - 4);
    // Area under the line: one thin column per sample.
    ctx.fillRect(x, y, Math.max(1, step), floor - y, accentSoft);
    points.push(x, y);
  }
  ctx.line(0, floor, ctx.width, floor, 1, track);
  if (points.length >= 4) ctx.polyline(points, 1.5, accent);
}

function drawCores(ctx: CanvasCtx, cpu: CpuData): void {
  ctx.clear();
  const count = Math.max(1, cpu.perCore.length);
  const gap = 3;
  const width = (ctx.width - gap * (count - 1)) / count;
  for (let index = 0; index < count; index += 1) {
    const x = index * (width + gap);
    const load = Math.max(0, Math.min(1, (cpu.perCore[index] ?? 0) / 100));
    ctx.fillRoundRect(x, 0, width, ctx.height, 2, track);
    const height = Math.max(2, load * ctx.height);
    ctx.fillRoundRect(x, ctx.height - height, width, height, 2, load > 0.85 ? "#fb7185" : accent);
  }
}

function drawMemory(ctx: CanvasCtx, percent: number): void {
  ctx.clear();
  ctx.fillRoundRect(0, 0, ctx.width, ctx.height, ctx.height / 2, track);
  const width = Math.max(ctx.height, (Math.max(0, Math.min(100, percent)) / 100) * ctx.width);
  ctx.fillRoundRect(0, 0, width, ctx.height, ctx.height / 2, "#f5f6f8");
}

export default widget({
  name: "System Monitor",
  size: [340, 196],
  anchor: { corner: "top-left", offset: [24, 24] },
  subscribe: ["cpu", "memory"],
}, () => {
  const cpu = useProvider("cpu");
  const memory = useProvider("memory");
  useEffect(() => {
    history.push(cpu.percent);
    if (history.length > historyLength) history.shift();
  }, [cpu]);

  return (
    <column
      class="size-full px-[22px] py-[18px] gap-[14px] border border-[#ffffff]/10 rounded-[28px]"
      background={[
        { type: "linear", stops: [{ offset: 0, color: "#0b0d12e6" }, { offset: 1, color: "#0b0d12e6" }] },
        { type: "linear", start: [0, 0], end: [0, 1], stops: [{ offset: 0, color: "#ffffff12" }, { offset: 0.6, color: "#ffffff00" }] },
      ]}
    >
      <row class="w-full items-end justify-between">
        <column class="gap-[2px]">
          <text class="text-[11px] tracking-[2px] text-[#f5f6f8]/45">CPU</text>
          <row class="items-baseline gap-[3px]">
            <text class="text-[40px] leading-none font-light tabular-nums text-[#f5f6f8]">{cpu.percent.toFixed(0)}</text>
            <text class="text-[16px] leading-none text-[#f5f6f8]/45">%</text>
          </row>
        </column>
        <canvas class="w-[176px] h-[48px]" onFrame={drawHistory} />
      </row>

      <canvas class="w-[296px] h-[22px]" onFrame={(ctx) => drawCores(ctx, cpu)} />

      <column class="w-full gap-[8px]">
        <row class="w-full items-baseline justify-between">
          <text class="text-[11px] tracking-[2px] text-[#f5f6f8]/45">MEMORY</text>
          <row class="items-baseline gap-[4px]">
            <text class="text-[13px] tabular-nums text-[#f5f6f8]">{gigabytes(memory.usedMb)}</text>
            <text class="text-[11px] tabular-nums text-[#f5f6f8]/45">/ {gigabytes(memory.totalMb)} GB</text>
          </row>
        </row>
        <canvas class="w-[296px] h-[6px]" onFrame={(ctx) => drawMemory(ctx, memory.percent)} />
      </column>
    </column>
  );
});
