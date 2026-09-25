import { useProvider, useStorage, widget } from "@weaver/sdk";

const weekdays = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];
const emptyWeek = { Mon: 0, Tue: 0, Wed: 0, Thu: 0, Fri: 0, Sat: 0, Sun: 0 };
const letters = ["M", "T", "W", "T", "F", "S", "S"];

export default widget({
  name: "Focus Week",
  size: [320, 200],
  anchor: { corner: "top-right", offset: [24, 24] },
  subscribe: ["time"],
}, () => {
  const time = useProvider("time");
  const [counts, setCounts] = useStorage<Record<string, number>>("sessions-by-weekday", emptyWeek);
  const total = weekdays.reduce((sum, day) => sum + counts[day], 0);
  return (
    <column class="size-full p-[16px] gap-[12px] bg-[#11141c]/94 border border-[#ffffff]/10 rounded-[24px]">
      <row class="w-full h-[22px] items-baseline justify-between">
        <text class="text-[14px] font-semibold text-[#f5f6f8]">Focus week</text>
        <text class="text-[14px] text-[#f5f6f8]/65">{time.weekday}, {time.month} {time.day}</text>
      </row>
      <row class="w-full h-[52px] gap-[4px]">
        {weekdays.map((day, index) => (
          <column class={day === time.weekday
            ? "w-0 grow h-full items-center justify-center gap-[2px] rounded-[10px] bg-[#5eead4]/15"
            : "w-0 grow h-full items-center justify-center gap-[2px] rounded-[10px] bg-[#ffffff]/4"}>
            <text class={day === time.weekday ? "text-[12px] text-[#5eead4]" : "text-[12px] text-[#f5f6f8]/60"}>{letters[index]}</text>
            <text class="text-[18px] font-medium tabular-nums text-[#f5f6f8]">{counts[day]}</text>
          </column>
        ))}
      </row>
      <column class="w-full gap-[5px]">
        <row class="w-full items-baseline justify-between">
          <text class="text-[12px] text-[#f5f6f8]/60">Weekly goal</text>
          <text class="text-[12px] tabular-nums text-[#f5f6f8]/85">{total} / 20</text>
        </row>
        <canvas class="w-[288px] h-[6px]" onFrame={(ctx) => {
          ctx.clear();
          ctx.fillRoundRect(0, 0, ctx.width, ctx.height, 3, "#ffffff1a");
          if (total > 0) ctx.fillRoundRect(0, 0, ctx.width * Math.min(total / 20, 1), ctx.height, 3, "#5eead4");
        }} />
      </column>
      <row class="w-full gap-[8px] h-[28px]">
        <button accessibilityLabel="Log session" class="w-[172px] h-full rounded-[9px] bg-[#5eead4] hover:bg-[#99f6e4] pressed:bg-[#2dd4bf]"
          onPress={() => setCounts((current) => ({ ...current, [time.weekday]: current[time.weekday] + 1 }))}>
          <row class="size-full items-center">
            <text class="w-full text-center text-[12px] font-semibold text-[#0b0d12]">Log session</text>
          </row>
        </button>
        <button accessibilityLabel="Reset week" class="w-[108px] h-full rounded-[9px] bg-[#ffffff]/8 hover:bg-[#ffffff]/14 pressed:bg-[#ffffff]/20"
          onPress={() => setCounts({ ...emptyWeek })}>
          <row class="size-full items-center">
            <text class="w-full text-center text-[12px] font-medium text-[#f5f6f8]/85">Reset week</text>
          </row>
        </button>
      </row>
    </column>
  );
});
