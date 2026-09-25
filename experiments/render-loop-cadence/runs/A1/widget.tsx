import { useProvider, useStorage, widget } from "@weaver/sdk";

// Focus Week: seven persisted per-day session counts, one weekly goal.
// The only moving part is the `time` provider (for today's date and which
// cell is highlighted); every count change comes from a button press.

interface Week {
  Mon: number; Tue: number; Wed: number; Thu: number;
  Fri: number; Sat: number; Sun: number;
}

type DayKey = keyof Week;

const dayKeys: DayKey[] = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];
const dayLetters: Record<DayKey, string> = {
  Mon: "M", Tue: "T", Wed: "W", Thu: "T", Fri: "F", Sat: "S", Sun: "S",
};

const goal = 20;
const accent = "#f59e0b";

const emptyWeek = (): Week => ({ Mon: 0, Tue: 0, Wed: 0, Thu: 0, Fri: 0, Sat: 0, Sun: 0 });

// The bar is one node: a two-colour linear gradient with both stops repeated at
// `fraction`, which is the contract's deterministic hard stop. No per-frame work
// and no dynamic class string, so `weaver check` still validates every utility.
const barFill = (fraction: number) => ({
  type: "linear" as const,
  stops: [
    { offset: 0, color: accent },
    { offset: fraction, color: accent },
    { offset: fraction, color: "#ffffff1f" },
    { offset: 1, color: "#ffffff1f" },
  ],
});

export default widget({
  name: "Focus Week",
  size: [320, 200],
  anchor: { corner: "top-right", offset: [24, 24] },
  subscribe: ["time"],
}, () => {
  const time = useProvider("time");
  const [week, setWeek] = useStorage<Week>("week", emptyWeek());

  // `time.weekday` is always one of the seven short names; the fallback only
  // keeps the type honest.
  const today = dayKeys.find((day) => day === time.weekday) ?? "Mon";
  const total = dayKeys.reduce((sum, day) => sum + week[day], 0);
  const fraction = Math.max(0, Math.min(1, total / goal));

  const logSession = () => setWeek((current) => {
    const next: Week = { ...current };
    next[today] = next[today] + 1;
    return next;
  });

  return (
    <column
      class="size-full px-[18px] py-[14px] gap-[12px] border border-[#ffffff]/10 rounded-[24px]"
      background={[
        { type: "linear", stops: [{ offset: 0, color: "#0b0d12e6" }, { offset: 1, color: "#0b0d12e6" }] },
        { type: "linear", start: [0, 0], end: [0, 1], stops: [{ offset: 0, color: "#ffffff12" }, { offset: 0.6, color: "#ffffff00" }] },
      ]}
    >
      <row class="w-full items-baseline justify-between">
        <text class="text-[15px] leading-none font-medium text-[#f5f6f8]">Focus week</text>
        <text class="text-[12px] leading-none text-[#f5f6f8]/45">{time.weekday}, {time.month} {time.day}</text>
      </row>

      <row class="w-full grow items-stretch">
        {dayKeys.map((day) => (
          <column class="w-1/7 px-[2px]">
            <panel
              class={day === today
                ? "w-full grow items-center justify-center gap-[6px] rounded-[12px] bg-[#f59e0b]/18"
                : "w-full grow items-center justify-center gap-[6px] rounded-[12px] bg-[#ffffff]/5"}
            >
              <text class={day === today
                ? "text-[11px] leading-none font-medium text-[#f59e0b]"
                : "text-[11px] leading-none font-medium text-[#f5f6f8]/40"}>{dayLetters[day]}</text>
              <text class={day === today
                ? "text-[17px] leading-none font-medium tabular-nums text-[#f5f6f8]"
                : "text-[17px] leading-none tabular-nums text-[#f5f6f8]/75"}>{week[day]}</text>
            </panel>
          </column>
        ))}
      </row>

      <column class="w-full gap-[8px]">
        <row class="w-full items-baseline justify-between">
          <text class="text-[11px] leading-none tracking-[1px] text-[#f5f6f8]/35">THIS WEEK</text>
          <text class="text-[12px] leading-none tabular-nums text-[#f5f6f8]/70">{total} / {goal}</text>
        </row>
        <panel class="w-full h-[8px] rounded-full" background={barFill(fraction)} />
      </column>

      <row class="w-full gap-[10px]">
        <button
          accessibilityLabel="Log session"
          class="w-[162px] h-[38px] rounded-[14px] bg-[#f59e0b] hover:bg-[#fbbf24] pressed:bg-[#d97706]"
          onPress={logSession}
        >
          <row class="size-full items-center">
            <text class="w-full text-center text-[13px] font-semibold text-[#17130a]">Log session</text>
          </row>
        </button>
        <button
          accessibilityLabel="Reset week"
          class="w-[112px] shrink-0 h-[38px] rounded-[14px] bg-[#ffffff]/8 hover:bg-[#ffffff]/12 pressed:bg-[#ffffff]/16"
          onPress={() => setWeek(emptyWeek())}
        >
          <row class="size-full items-center">
            <text class="w-full text-center text-[13px] font-medium text-[#f5f6f8]/70">Reset week</text>
          </row>
        </button>
      </row>
    </column>
  );
});
