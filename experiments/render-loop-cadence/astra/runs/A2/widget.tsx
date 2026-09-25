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
  const [counts, setCounts] = useStorage<Record<string, number>>("sessions-by-weekday", emptyWeek);
  const total = days.reduce((sum, day) => sum + counts[day.key], 0);
  const fraction = Math.min(1, total / 20);

  return (
    <column class="size-full p-[16px] gap-[10px] rounded-[24px] bg-[#0b0d12]/92">
      <row class="w-full h-[22px] items-baseline justify-between shrink-0">
        <text class="text-[16px] font-semibold text-[#f5f6f8]">Focus week</text>
        <text class="text-[12px] text-[#f5f6f8]/65">{time.weekday}, {time.month} {time.day}</text>
      </row>

      <row class="w-full h-[56px] gap-[4px] shrink-0">
        {days.map((day) => (
          <column
            class={day.key === time.weekday
              ? "w-[0px] grow h-full items-center justify-center gap-[4px] rounded-[10px] bg-[#5eead4]/18"
              : "w-[0px] grow h-full items-center justify-center gap-[4px] rounded-[10px] bg-[#ffffff]/4"}
          >
            <text class={day.key === time.weekday
              ? "w-full text-center text-[11px] font-semibold text-[#5eead4]"
              : "w-full text-center text-[11px] font-medium text-[#f5f6f8]/60"}>{day.letter}</text>
            <text class="w-full text-center text-[18px] font-medium tabular-nums text-[#f5f6f8]">{counts[day.key]}</text>
          </column>
        ))}
      </row>

      <row class="w-full h-[24px] gap-[12px] items-center shrink-0">
        <canvas
          class="w-[216px] h-[6px] shrink-0"
          onFrame={(ctx) => {
            ctx.clear();
            ctx.fillRoundRect(0, 0, ctx.width, ctx.height, 3, "#ffffff1f");
            if (fraction > 0) ctx.fillRoundRect(0, 0, ctx.width * fraction, ctx.height, 3, "#5eead4");
          }}
        />
        <text class="w-[60px] text-right text-[12px] tabular-nums text-[#f5f6f8]/80">{total} / 20</text>
      </row>

      <row class="w-full h-[36px] gap-[8px] shrink-0">
        <button
          accessibilityLabel="Log session"
          class="w-[168px] h-full rounded-[11px] bg-[#5eead4] hover:opacity-90 pressed:opacity-75"
          onPress={() => setCounts((current) => ({ ...current, [time.weekday]: current[time.weekday] + 1 }))}
        >
          <row class="size-full items-center">
            <text class="w-full text-center text-[13px] font-semibold text-[#0b0d12]">Log session</text>
          </row>
        </button>
        <button
          accessibilityLabel="Reset week"
          class="w-[112px] h-full rounded-[11px] bg-[#ffffff]/8 hover:bg-[#ffffff]/12 pressed:bg-[#ffffff]/18"
          onPress={() => setCounts({ ...emptyWeek })}
        >
          <row class="size-full items-center">
            <text class="w-full text-center text-[12px] font-medium text-[#f5f6f8]/85">Reset week</text>
          </row>
        </button>
      </row>
    </column>
  );
});
