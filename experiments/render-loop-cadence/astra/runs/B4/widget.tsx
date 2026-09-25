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
  const [sessions, setSessions] = useStorage<Record<string, number>>("sessions", emptyWeek);
  const total = days.reduce((sum, day) => sum + sessions[day], 0);
  const progress = Math.min(total, 20);
  const progressClass =
    progress === 1 ? "w-1/20 h-full bg-[#5eead4] rounded-full" :
    progress === 2 ? "w-2/20 h-full bg-[#5eead4] rounded-full" :
    progress === 3 ? "w-3/20 h-full bg-[#5eead4] rounded-full" :
    progress === 4 ? "w-4/20 h-full bg-[#5eead4] rounded-full" :
    progress === 5 ? "w-5/20 h-full bg-[#5eead4] rounded-full" :
    progress === 6 ? "w-6/20 h-full bg-[#5eead4] rounded-full" :
    progress === 7 ? "w-7/20 h-full bg-[#5eead4] rounded-full" :
    progress === 8 ? "w-8/20 h-full bg-[#5eead4] rounded-full" :
    progress === 9 ? "w-9/20 h-full bg-[#5eead4] rounded-full" :
    progress === 10 ? "w-10/20 h-full bg-[#5eead4] rounded-full" :
    progress === 11 ? "w-11/20 h-full bg-[#5eead4] rounded-full" :
    progress === 12 ? "w-12/20 h-full bg-[#5eead4] rounded-full" :
    progress === 13 ? "w-13/20 h-full bg-[#5eead4] rounded-full" :
    progress === 14 ? "w-14/20 h-full bg-[#5eead4] rounded-full" :
    progress === 15 ? "w-15/20 h-full bg-[#5eead4] rounded-full" :
    progress === 16 ? "w-16/20 h-full bg-[#5eead4] rounded-full" :
    progress === 17 ? "w-17/20 h-full bg-[#5eead4] rounded-full" :
    progress === 18 ? "w-18/20 h-full bg-[#5eead4] rounded-full" :
    progress === 19 ? "w-19/20 h-full bg-[#5eead4] rounded-full" :
    "w-full h-full bg-[#5eead4] rounded-full";

  return (
    <column class="size-full p-[18px] gap-[12px] bg-[#0b0d12]/92 rounded-[24px]">
      <row class="w-full h-[20px] shrink-0 items-baseline justify-between">
        <text class="text-[14px] leading-[20px] font-semibold text-[#f5f6f8]">Focus week</text>
        <text class="text-[14px] leading-[20px] text-[#f5f6f8]/65">{time.weekday}, {time.month} {time.day}</text>
      </row>

      <row class="w-full h-[54px] shrink-0 gap-[4px]">
        {days.map((day, index) => (
          <column class={day === time.weekday
            ? "w-[0px] grow h-full items-center justify-center gap-[4px] rounded-[10px] bg-[#5eead4]/18"
            : "w-[0px] grow h-full items-center justify-center gap-[4px] rounded-[10px] bg-[#ffffff]/4"}>
            <text class={day === time.weekday ? "text-[11px] text-[#5eead4] font-medium" : "text-[11px] text-[#f5f6f8]/60"}>{letters[index]}</text>
            <text class={day === time.weekday ? "text-[18px] leading-[22px] font-semibold tabular-nums text-[#5eead4]" : "text-[18px] leading-[22px] font-medium tabular-nums text-[#f5f6f8]"}>{sessions[day]}</text>
          </column>
        ))}
      </row>

      <row class="w-full h-[20px] shrink-0 items-center gap-[12px]">
        <row class="w-[0px] grow h-[6px] bg-[#ffffff]/12 rounded-full overflow-hidden">
          {progress > 0 ? <panel class={progressClass} /> : null}
        </row>
        <text class="w-[60px] shrink-0 text-right text-[12px] tabular-nums text-[#f5f6f8]/75">{total} / 20</text>
      </row>

      <row class="w-full h-[34px] shrink-0 gap-[8px]">
        <button accessibilityLabel="Log session" class="w-[0px] grow h-full rounded-[10px] bg-[#5eead4] hover:bg-[#99f6e4] pressed:bg-[#2dd4bf]" onPress={() => setSessions((current) => ({ ...current, [time.weekday]: current[time.weekday] + 1 }))}>
          <row class="size-full items-center">
            <text class="w-full text-center text-[12px] font-semibold text-[#0b0d12]">Log session</text>
          </row>
        </button>
        <button accessibilityLabel="Reset week" class="w-[104px] h-full rounded-[10px] bg-[#ffffff]/8 hover:bg-[#ffffff]/14 pressed:bg-[#ffffff]/20" onPress={() => setSessions({ ...emptyWeek })}>
          <row class="size-full items-center">
            <text class="w-full text-center text-[12px] font-medium text-[#f5f6f8]/80">Reset week</text>
          </row>
        </button>
      </row>
    </column>
  );
});
