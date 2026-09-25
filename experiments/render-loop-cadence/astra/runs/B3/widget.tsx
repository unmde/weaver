import { useProvider, useStorage, widget, type CanvasCtx } from "@weaver/sdk";

const days = [
  { key: "Mon", letter: "M" },
  { key: "Tue", letter: "T" },
  { key: "Wed", letter: "W" },
  { key: "Thu", letter: "T" },
  { key: "Fri", letter: "F" },
  { key: "Sat", letter: "S" },
  { key: "Sun", letter: "S" },
];
const emptyWeek: Record<string, number> = {
  Mon: 0, Tue: 0, Wed: 0, Thu: 0, Fri: 0, Sat: 0, Sun: 0,
};

function drawProgress(ctx: CanvasCtx, total: number): void {
  ctx.clear();
  ctx.fillRoundRect(0, 0, ctx.width, ctx.height, 3, "#ffffff20");
  if (total > 0) {
    ctx.fillRoundRect(0, 0, ctx.width * Math.min(total / 20, 1), ctx.height, 3, "#5eead4");
  }
}

export default widget({
  name: "Focus Week",
  size: [320, 200],
  anchor: { corner: "top-right", offset: [24, 24] },
  subscribe: ["time"],
}, () => {
  const time = useProvider("time");
  const [counts, setCounts] = useStorage<Record<string, number>>("sessions-by-weekday", emptyWeek);
  const total = days.reduce((sum, day) => sum + counts[day.key], 0);

  return (
    <column class="size-full p-[16px] justify-between rounded-[24px] border border-[#ffffff]/10 bg-[#0b0d12]/92">
      <row class="w-full h-[22px] items-baseline justify-between">
        <text class="text-[16px] font-semibold text-[#f5f6f8]">Focus week</text>
        <text class="text-[12px] text-[#f5f6f8]/65">{time.weekday}, {time.month} {time.day}</text>
      </row>

      <row class="w-full h-[52px] gap-[4px]">
        {days.map((day) => (
          <column
            class={day.key === time.weekday
              ? "w-[0px] grow h-full items-center justify-center gap-[3px] rounded-[10px] bg-[#5eead4]/16"
              : "w-[0px] grow h-full items-center justify-center gap-[3px] rounded-[10px] bg-[#ffffff]/4"}
          >
            <text class={day.key === time.weekday
              ? "text-[11px] font-medium text-[#5eead4]"
              : "text-[11px] font-medium text-[#f5f6f8]/60"}>{day.letter}</text>
            <text class={day.key === time.weekday
              ? "text-[18px] font-semibold tabular-nums text-[#5eead4]"
              : "text-[18px] font-medium tabular-nums text-[#f5f6f8]"}>{counts[day.key]}</text>
          </column>
        ))}
      </row>

      <row class="w-full h-[24px] items-center gap-[12px]">
        <canvas class="w-[232px] h-[6px] shrink-0" onFrame={(ctx) => drawProgress(ctx, total)} />
        <text class="w-[0px] grow text-right text-[12px] font-medium tabular-nums text-[#f5f6f8]/75">{total} / 20</text>
      </row>

      <row class="w-full h-[34px] gap-[8px]">
        <button
          accessibilityLabel="Log session"
          class="w-[0px] grow-[3] h-full rounded-[11px] bg-[#5eead4] hover:opacity-90 pressed:opacity-75"
          onPress={() => setCounts((current) => ({ ...current, [time.weekday]: current[time.weekday] + 1 }))}
        >
          <row class="size-full items-center">
            <text class="w-full text-center text-[12px] font-semibold text-[#0b0d12]">Log session</text>
          </row>
        </button>
        <button
          accessibilityLabel="Reset week"
          class="w-[0px] grow-[2] h-full rounded-[11px] bg-[#ffffff]/8 hover:bg-[#ffffff]/12 pressed:bg-[#ffffff]/16"
          onPress={() => setCounts({ ...emptyWeek })}
        >
          <row class="size-full items-center">
            <text class="w-full text-center text-[12px] font-medium text-[#f5f6f8]/80">Reset week</text>
          </row>
        </button>
      </row>
    </column>
  );
});
