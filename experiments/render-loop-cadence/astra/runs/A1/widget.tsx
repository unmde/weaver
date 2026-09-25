import { useProvider, useStorage, widget } from "@weaver/sdk";

type Weekday = "Mon" | "Tue" | "Wed" | "Thu" | "Fri" | "Sat" | "Sun";
type Counts = Record<Weekday, number>;
const days: Weekday[] = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];
const emptyWeek: Counts = { Mon: 0, Tue: 0, Wed: 0, Thu: 0, Fri: 0, Sat: 0, Sun: 0 };
const goal = 20;

export default widget({
  name: "Focus Week",
  size: [320, 200],
  anchor: { corner: "top-right", offset: [24, 24] },
  subscribe: ["time"],
}, () => {
  const time = useProvider("time");
  const [counts, setCounts] = useStorage<Counts>("sessions-by-weekday", emptyWeek);
  const today = time.weekday as Weekday;
  const total = days.reduce((sum, day) => sum + counts[day], 0);

  return (
    <column class="size-full p-[16px] justify-between bg-[#0b0d12]/90 border border-[#ffffff]/10 rounded-[24px]">
      <row class="w-full h-[20px] items-baseline justify-between">
        <text class="text-[16px] font-semibold text-[#f5f6f8]">Focus week</text>
        <text class="text-[12px] text-[#f5f6f8]/60">{time.weekday}, {time.month} {time.day}</text>
      </row>

      <row class="w-full h-[52px] gap-[4px]">
        {days.map((day) => (
          <column class={day === today
            ? "w-[0px] grow h-full items-center justify-center gap-[3px] rounded-[10px] bg-[#5eead4]/16"
            : "w-[0px] grow h-full items-center justify-center gap-[3px] rounded-[10px] bg-[#ffffff]/4"}>
            <text class={day === today
              ? "w-full text-center text-[11px] font-medium text-[#5eead4]"
              : "w-full text-center text-[11px] font-medium text-[#f5f6f8]/55"}>{day[0]}</text>
            <text class={day === today
              ? "w-full text-center text-[18px] leading-none font-semibold tabular-nums text-[#5eead4]"
              : "w-full text-center text-[18px] leading-none font-medium tabular-nums text-[#f5f6f8]"}>{counts[day]}</text>
          </column>
        ))}
      </row>

      <column class="w-full h-[26px] justify-between">
        <row class="w-full h-[14px] items-baseline justify-between">
          <text class="text-[11px] text-[#f5f6f8]/55">WEEKLY SESSIONS</text>
          <text class="text-[12px] leading-none tabular-nums text-[#f5f6f8]/80">{total} / {goal}</text>
        </row>
        <canvas class="w-[286px] h-[6px]" onFrame={(ctx) => {
          ctx.clear();
          ctx.fillRoundRect(0, 0, ctx.width, ctx.height, 3, "#ffffff14");
          if (total > 0) {
            ctx.fillRoundRect(0, 0, ctx.width * Math.min(total / goal, 1), ctx.height, 3, "#5eead4");
          }
        }} />
      </column>

      <row class="w-full h-[36px] gap-[8px]">
        <button accessibilityLabel="Log session"
          class="w-[0px] grow h-full rounded-[11px] bg-[#5eead4] hover:opacity-90 pressed:opacity-75"
          onPress={() => setCounts((current) => ({ ...current, [today]: current[today] + 1 }))}>
          <row class="size-full items-center">
            <text class="w-full text-center text-[13px] font-semibold text-[#0b0d12]">Log session</text>
          </row>
        </button>
        <button accessibilityLabel="Reset week"
          class="w-[110px] h-full rounded-[11px] bg-[#ffffff]/8 hover:bg-[#ffffff]/12 pressed:bg-[#ffffff]/16"
          onPress={() => setCounts({ ...emptyWeek })}>
          <row class="size-full items-center">
            <text class="w-full text-center text-[12px] font-medium text-[#f5f6f8]/80">Reset week</text>
          </row>
        </button>
      </row>
    </column>
  );
});
