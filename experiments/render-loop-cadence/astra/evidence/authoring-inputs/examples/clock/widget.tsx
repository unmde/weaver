import { useProvider, widget, type CanvasCtx, type TimeData } from "@weaver/sdk";

// The first widget: one provider, one canvas, no timers of its own.
// The `time` provider ticks once per second while subscribed; each tick
// re-renders the text nodes and redraws the dial. Nothing else runs.

const weekdays: Record<string, string> = {
  Sun: "Sunday", Mon: "Monday", Tue: "Tuesday", Wed: "Wednesday",
  Thu: "Thursday", Fri: "Friday", Sat: "Saturday",
};
const months: Record<string, string> = {
  Jan: "January", Feb: "February", Mar: "March", Apr: "April", May: "May", Jun: "June",
  Jul: "July", Aug: "August", Sep: "September", Oct: "October", Nov: "November", Dec: "December",
};

function longDate(time: TimeData): string {
  return `${weekdays[time.weekday] ?? time.weekday}, ${months[time.month] ?? time.month} ${time.day}`;
}

// Draws a small analog dial. Runs once per render (no `fps`), so it costs
// nothing between provider ticks.
function drawDial(ctx: CanvasCtx, time: TimeData): void {
  ctx.clear();
  const cx = ctx.width / 2;
  const cy = ctx.height / 2;
  const radius = Math.min(cx, cy) - 2;
  const hours = Number(time.hh) % 12;
  const minutes = Number(time.mm);
  const seconds = Number(time.ss);

  for (let index = 0; index < 12; index += 1) {
    const angle = (index / 12) * Math.PI * 2 - Math.PI / 2;
    const outer = radius;
    const inner = index % 3 === 0 ? radius - 7 : radius - 4;
    ctx.line(
      cx + Math.cos(angle) * inner, cy + Math.sin(angle) * inner,
      cx + Math.cos(angle) * outer, cy + Math.sin(angle) * outer,
      index % 3 === 0 ? 2 : 1, index % 3 === 0 ? "#ffffffb3" : "#ffffff4d",
    );
  }

  const hand = (turns: number, length: number, width: number, color: string) => {
    const angle = turns * Math.PI * 2 - Math.PI / 2;
    ctx.line(cx, cy, cx + Math.cos(angle) * length, cy + Math.sin(angle) * length, width, color);
  };
  hand((hours + minutes / 60) / 12, radius * 0.52, 3, "#f5f6f8");
  hand((minutes + seconds / 60) / 60, radius * 0.78, 2, "#f5f6f8");
  hand(seconds / 60, radius * 0.86, 1, "#f59e0b");
  ctx.fillCircle(cx, cy, 3, "#f59e0b");
}

export default widget({
  name: "Clock",
  size: [320, 132],
  anchor: { corner: "top-right", offset: [24, 24] },
  subscribe: ["time"],
}, () => {
  const time = useProvider("time");
  return (
    <row
      class="size-full px-[24px] py-[20px] items-center justify-between border border-[#ffffff]/10 rounded-[28px]"
      background={[
        { type: "linear", stops: [{ offset: 0, color: "#0b0d12e6" }, { offset: 1, color: "#0b0d12e6" }] },
        { type: "linear", start: [0, 0], end: [0, 1], stops: [{ offset: 0, color: "#ffffff12" }, { offset: 0.6, color: "#ffffff00" }] },
      ]}
    >
      <column class="gap-[6px]">
        <row class="items-baseline gap-[8px]">
          <text class="text-[56px] leading-none font-light tracking-[-2px] tabular-nums text-[#f5f6f8]">{time.hh}:{time.mm}</text>
          <text class="text-[18px] leading-none tabular-nums text-[#f5f6f8]/45">{time.ss}</text>
        </row>
        <text class="text-[14px] text-[#f5f6f8]/60">{longDate(time)}</text>
      </column>
      <canvas class="size-[88px]" onFrame={(ctx) => drawDial(ctx, time)} />
    </row>
  );
});
