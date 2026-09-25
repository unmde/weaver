import { useProvider, useStorage, widget } from "@weaver/sdk";

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

export default widget({
  name: "Focus Week",
  size: [320, 200],
  anchor: { corner: "top-right", offset: [24, 24] },
  subscribe: ["time"],
}, () => {
  const time = useProvider("time");
  const [sessions, setSessions] = useStorage<Record<string, number>>("sessions-by-weekday", emptyWeek);
  const total = days.reduce((sum, day) => sum + sessions[day.key], 0);
  const fraction = Math.min(1, total / 20);

  return (
    <column class="size-full p-[16px] gap-[10px] rounded-[24px] border border-[#ffffff]/10 bg-[#0b0d12]/92">
      <row class="w-full h-[20px] items-baseline justify-between">
        <text class="text-[15px] font-semibold text-[#f5f6f8]">Focus week</text>
        <text class="text-[12px] text-[#f5f6f8]/65">{time.weekday}, {time.month} {time.day}</text>
      </row>

      <row class="w-full h-[54px] gap-[4px]">
        {days.map((day) => (
          <column class={day.key === time.weekday
            ? "w-[0px] grow h-full items-center justify-center gap-[3px] rounded-[10px] bg-[#5eead4]/16"
            : "w-[0px] grow h-full items-center justify-center gap-[3px] rounded-[10px] bg-[#ffffff]/4"}>
            <text class={day.key === time.weekday
              ? "w-full text-center text-[11px] font-medium text-[#5eead4]"
              : "w-full text-center text-[11px] font-medium text-[#f5f6f8]/55"}>{day.letter}</text>
            <text class={day.key === time.weekday
              ? "w-full text-center text-[18px] font-semibold tabular-nums text-[#5eead4]"
              : "w-full text-center text-[18px] font-medium tabular-nums text-[#f5f6f8]"}>{sessions[day.key]}</text>
          </column>
        ))}
      </row>

      <column class="w-full h-[28px] gap-[6px]">
        <row class="w-full h-[16px] items-baseline justify-between">
          <text class="text-[11px] text-[#f5f6f8]/55">WEEKLY SESSIONS</text>
          <text class="text-[12px] font-medium tabular-nums text-[#f5f6f8]/80">{total} / 20</text>
        </row>
        <stack class="w-full h-[6px] rounded-full bg-[#ffffff]/10 overflow-hidden">
          <canvas class="w-[288px] h-[6px]" onFrame={(ctx) => {
            ctx.clear();
            if (fraction > 0) ctx.fillRoundRect(0, 0, ctx.width * fraction, ctx.height, 3, "#5eead4");
          }} />
        </stack>
      </column>

      <row class="w-full h-[34px] gap-[8px]">
        <button accessibilityLabel="Log session"
          class="w-[0px] grow h-full rounded-[10px] bg-[#5eead4] hover:opacity-90 pressed:opacity-75"
          onPress={() => setSessions((current) => ({ ...current, [time.weekday]: current[time.weekday] + 1 }))}>
          <row class="size-full items-center">
            <text class="w-full text-center text-[12px] font-semibold text-[#0b0d12]">Log session</text>
          </row>
        </button>
        <button accessibilityLabel="Reset week"
          class="w-[0px] grow h-full rounded-[10px] bg-[#ffffff]/8 hover:bg-[#ffffff]/12 pressed:bg-[#ffffff]/16"
          onPress={() => setSessions({ ...emptyWeek })}>
          <row class="size-full items-center">
            <text class="w-full text-center text-[12px] font-medium text-[#f5f6f8]/85">Reset week</text>
          </row>
        </button>
      </row>
    </column>
  );
});
