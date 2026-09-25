import { useProvider, useStorage, widget, type CanvasCtx } from "@weaver/sdk";

// Focus Week — a week of logged focus sessions against a weekly goal.
// One provider (`time`) tells us the date and which cell is today.

const goal = 20;
const accent = "#ff7a59";

const surface = [
  { type: "linear" as const, stops: [{ offset: 0, color: "#0b0d12e6" }, { offset: 1, color: "#0b0d12e6" }] },
  { type: "linear" as const, start: [0, 0] as [number, number], end: [0, 1] as [number, number], stops: [{ offset: 0, color: "#ffffff12" }, { offset: 0.6, color: "#ffffff00" }] },
];

// Monday-first week. `key` matches TimeData.weekday, `letter` is the cell head.
const week = [
  { key: "Mon", letter: "M" },
  { key: "Tue", letter: "T" },
  { key: "Wed", letter: "W" },
  { key: "Thu", letter: "T" },
  { key: "Fri", letter: "F" },
  { key: "Sat", letter: "S" },
  { key: "Sun", letter: "S" },
];

type Counts = Record<string, number>;

const emptyWeek: Counts = { Mon: 0, Tue: 0, Wed: 0, Thu: 0, Fri: 0, Sat: 0, Sun: 0 };

// The fill needs a pixel-exact width, so it is drawn rather than classed.
// No `fps`: this runs once per render and costs nothing between renders.
function drawBar(ctx: CanvasCtx, done: number): void {
  ctx.clear();
  const radius = ctx.height / 2;
  ctx.fillRoundRect(0, 0, ctx.width, ctx.height, radius, "#ffffff14");
  if (done <= 0) return;
  const fraction = Math.min(1, done / goal);
  ctx.fillRoundRect(0, 0, Math.max(ctx.height, ctx.width * fraction), ctx.height, radius, accent);
}

export default widget({
  name: "Focus Week",
  size: [320, 200],
  anchor: { corner: "top-right", offset: [24, 24] },
  subscribe: ["time"],
}, () => {
  const time = useProvider("time");
  const [counts, setCounts] = useStorage<Counts>("week", emptyWeek);
  const done = week.reduce((total, day) => total + (counts[day.key] ?? 0), 0);

  return (
    <column class="size-full px-[20px] py-[16px] gap-[12px] border border-[#ffffff]/10 rounded-[24px]" background={surface}>
      <row class="w-full items-baseline justify-between">
        <text class="text-[15px] font-semibold tracking-[0.2px] text-[#f5f6f8]">Focus week</text>
        <text class="text-[12px] tabular-nums text-[#f5f6f8]/45">{time.weekday}, {time.month} {time.day}</text>
      </row>

      <row class="w-full gap-[6px]">
        {week.map((day) => {
          const today = day.key === time.weekday;
          return (
            <column
              class={today
                ? "w-[0px] grow py-[6px] gap-[3px] items-center rounded-[10px] border border-[#ff7a59]/45 bg-[#ff7a59]/16"
                : "w-[0px] grow py-[6px] gap-[3px] items-center rounded-[10px] border border-[#ffffff]/0 bg-[#ffffff]/6"}
            >
              <text class={today ? "text-[10px] tracking-[0.6px] font-medium text-[#ff9d7f]" : "text-[10px] tracking-[0.6px] font-medium text-[#f5f6f8]/55"}>{day.letter}</text>
              <text class={today ? "text-[15px] leading-none tabular-nums font-semibold text-[#f5f6f8]" : "text-[15px] leading-none tabular-nums text-[#f5f6f8]/70"}>{counts[day.key] ?? 0}</text>
            </column>
          );
        })}
      </row>

      <column class="w-full gap-[5px]">
        <row class="w-full items-baseline justify-between">
          <text class="text-[11px] tracking-[0.4px] text-[#f5f6f8]/45">Sessions</text>
          <text class="text-[12px] tabular-nums font-medium text-[#f5f6f8]/80">{done} / {goal}</text>
        </row>
        <canvas class="w-[280px] h-[8px]" onFrame={(ctx) => drawBar(ctx, done)} />
      </column>

      <row class="w-full gap-[8px]">
        <button
          accessibilityLabel="Log session"
          class="w-[168px] h-[34px] rounded-[12px] bg-[#ff7a59] hover:bg-[#ff8d70] pressed:bg-[#e56745] pressed:shadow-inner"
          onPress={() => setCounts((current) => ({ ...current, [time.weekday]: (current[time.weekday] ?? 0) + 1 }))}
        >
          <row class="size-full items-center">
            <text class="w-full text-center text-[13px] font-semibold text-[#1a0d07]">Log session</text>
          </row>
        </button>
        <button
          accessibilityLabel="Reset week"
          class="w-[104px] h-[34px] rounded-[12px] border border-[#ffffff]/10 bg-[#ffffff]/8 hover:bg-[#ffffff]/14 pressed:bg-[#ffffff]/20"
          onPress={() => setCounts({ ...emptyWeek })}
        >
          <row class="size-full items-center">
            <text class="w-full text-center text-[13px] font-medium text-[#f5f6f8]/75 hover:text-[#f5f6f8]">Reset week</text>
          </row>
        </button>
      </row>
    </column>
  );
});
