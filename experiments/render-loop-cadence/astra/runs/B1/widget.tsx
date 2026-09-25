import { useProvider, useStorage, widget } from "@weaver/sdk";

type Weekday = "Mon" | "Tue" | "Wed" | "Thu" | "Fri" | "Sat" | "Sun";
const days: Weekday[] = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];
const emptyWeek: Record<Weekday, number> = {
  Mon: 0, Tue: 0, Wed: 0, Thu: 0, Fri: 0, Sat: 0, Sun: 0,
};

export default widget({
  name: "Focus Week",
  size: [320, 200],
  anchor: { corner: "top-right", offset: [24, 24] },
  subscribe: ["time"],
}, () => {
  const time = useProvider("time");
  const [counts, setCounts] = useStorage<Record<Weekday, number>>("sessions-by-weekday", emptyWeek);
  const today = time.weekday as Weekday;
  const total = days.reduce((sum, day) => sum + counts[day], 0);
  const progress = Math.min(total / 20, 1);

  return (
    <column class="size-full p-[16px] gap-[10px] bg-[#0b0d12]/90 border border-[#ffffff]/10 rounded-[24px]">
      <row class="w-full h-[20px] shrink-0 items-baseline justify-between">
        <text class="text-[14px] font-semibold text-[#f5f6f8]">Focus week</text>
        <text class="text-[14px] text-[#f5f6f8]/65">{time.weekday}, {time.month} {time.day}</text>
      </row>

      <row class="w-full h-[54px] shrink-0 gap-[4px]">
        {days.map((day) => (
          <column class={day === today
            ? "w-0 grow h-full items-center justify-center gap-[2px] rounded-[10px] bg-[#5eead4]/16"
            : "w-0 grow h-full items-center justify-center gap-[2px] rounded-[10px] bg-[#ffffff]/4"}>
            <text class={day === today ? "w-full text-center text-[12px] font-medium text-[#5eead4]" : "w-full text-center text-[12px] text-[#f5f6f8]/60"}>{day[0]}</text>
            <text class={day === today ? "w-full text-center text-[18px] font-medium tabular-nums text-[#5eead4]" : "w-full text-center text-[18px] font-medium tabular-nums text-[#f5f6f8]"}>{counts[day]}</text>
          </column>
        ))}
      </row>

      <row class="w-full h-[26px] shrink-0 items-center gap-[12px]">
        <canvas class="w-[224px] h-[6px]" onFrame={(ctx) => {
          ctx.clear();
          ctx.fillRoundRect(0, 0, ctx.width, ctx.height, 3, "#ffffff1a");
          if (progress > 0) ctx.fillRoundRect(0, 0, ctx.width * progress, ctx.height, 3, "#5eead4");
        }} />
        <text class="w-[52px] text-right text-[12px] tabular-nums text-[#f5f6f8]/75">{total} / 20</text>
      </row>

      <row class="w-full h-[34px] shrink-0 gap-[8px]">
        <button accessibilityLabel="Log session"
          class="w-0 grow h-full rounded-[11px] bg-[#5eead4] hover:bg-[#87f1df] pressed:bg-[#3ac6b0]"
          onPress={() => setCounts((current) => ({ ...current, [today]: current[today] + 1 }))}>
          <row class="size-full items-center">
            <text class="w-full text-center text-[13px] font-semibold text-[#0b0d12]">Log session</text>
          </row>
        </button>
        <button accessibilityLabel="Reset week"
          class="w-[110px] h-full rounded-[11px] bg-[#ffffff]/8 hover:bg-[#ffffff]/14 pressed:bg-[#ffffff]/20"
          onPress={() => setCounts({ ...emptyWeek })}>
          <row class="size-full items-center">
            <text class="w-full text-center text-[13px] font-medium text-[#f5f6f8]/80">Reset week</text>
          </row>
        </button>
      </row>
    </column>
  );
});
