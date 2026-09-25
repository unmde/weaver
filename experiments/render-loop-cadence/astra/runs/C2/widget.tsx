import { useProvider, useStorage, widget } from "@weaver/sdk";

const days = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];
const letters = ["M", "T", "W", "T", "F", "S", "S"];
const emptyWeek: Record<string, number> = { Mon: 0, Tue: 0, Wed: 0, Thu: 0, Fri: 0, Sat: 0, Sun: 0 };

export default widget({
  name: "Focus Week",
  size: [320, 200],
  anchor: { corner: "top-right", offset: [24, 24] },
  subscribe: ["time"],
}, () => {
  const time = useProvider("time");
  const [counts, setCounts] = useStorage<Record<string, number>>("sessions-by-weekday", emptyWeek);
  const total = days.reduce((sum, day) => sum + counts[day], 0);
  return (
    <column class="size-full p-[16px] gap-[10px] bg-[#0b0d12]/92 border border-[#ffffff]/10 rounded-[24px]">
      <row class="w-full h-[20px] items-baseline justify-between">
        <text class="text-[16px] font-semibold text-[#f5f6f8]">Focus week</text>
        <text class="text-[12px] text-[#f5f6f8]/65">{time.weekday}, {time.month} {time.day}</text>
      </row>
      <row class="w-full h-[52px] gap-[4px]">
        {days.map((day, index) => (
          <column class={day === time.weekday
            ? "w-[0px] grow h-full py-[6px] gap-[2px] rounded-[10px] bg-[#5eead4]/16"
            : "w-[0px] grow h-full py-[6px] gap-[2px] rounded-[10px] bg-[#ffffff]/4"}>
            <text class={day === time.weekday ? "w-full text-center text-[11px] font-medium text-[#5eead4]" : "w-full text-center text-[11px] text-[#f5f6f8]/60"}>{letters[index]}</text>
            <text class="w-full text-center text-[17px] font-semibold tabular-nums text-[#f5f6f8]">{counts[day]}</text>
          </column>
        ))}
      </row>
      <row class="w-full h-[24px] gap-[10px] items-center">
        <canvas class="w-[224px] h-[6px]" onFrame={(ctx) => {
          ctx.clear();
          ctx.fillRoundRect(0, 0, ctx.width, ctx.height, 3, "#ffffff1a");
          if (total > 0) ctx.fillRoundRect(0, 0, ctx.width * Math.min(total / 20, 1), ctx.height, 3, "#5eead4");
        }} />
        <text class="w-[54px] text-right text-[12px] tabular-nums text-[#f5f6f8]/75">{total} / 20</text>
      </row>
      <row class="w-full h-[36px] gap-[8px]">
        <button accessibilityLabel="Log session" class="w-[164px] h-full rounded-[12px] bg-[#5eead4] hover:opacity-90 pressed:opacity-75" onPress={() => setCounts((current) => ({ ...current, [time.weekday]: current[time.weekday] + 1 }))}>
          <row class="size-full items-center">
            <text class="w-full text-center text-[13px] font-semibold text-[#0b0d12]">Log session</text>
          </row>
        </button>
        <button accessibilityLabel="Reset week" class="w-[116px] h-full rounded-[12px] bg-[#ffffff]/8 hover:bg-[#ffffff]/12 pressed:bg-[#ffffff]/16" onPress={() => setCounts({ ...emptyWeek })}>
          <row class="size-full items-center">
            <text class="w-full text-center text-[13px] font-medium text-[#f5f6f8]/85">Reset week</text>
          </row>
        </button>
      </row>
    </column>
  );
});
