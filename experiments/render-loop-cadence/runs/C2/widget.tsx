import { useProvider, useStorage, widget } from "@weaver/sdk";

// Focus Week — one cell per weekday, a weekly goal bar, and two buttons.
// Counts live in widget storage keyed by the `time` provider's weekday, so
// they survive restarts; nothing here polls or fetches.

const goal = 20;

const days = [
  { key: "Mon", letter: "M" },
  { key: "Tue", letter: "T" },
  { key: "Wed", letter: "W" },
  { key: "Thu", letter: "T" },
  { key: "Fri", letter: "F" },
  { key: "Sat", letter: "S" },
  { key: "Sun", letter: "S" },
];

const emptyWeek: Record<string, number> = { Mon: 0, Tue: 0, Wed: 0, Thu: 0, Fri: 0, Sat: 0, Sun: 0 };

export default widget({
  name: "Focus Week",
  size: [320, 200],
  anchor: { corner: "top-right", offset: [24, 24] },
  subscribe: ["time"],
}, () => {
  const time = useProvider("time");
  const [sessions, setSessions] = useStorage<Record<string, number>>("sessions", emptyWeek);
  const logged = days.reduce((total, day) => total + (sessions[day.key] ?? 0), 0);

  // `weaver check` validates every literal a class can resolve to, so the fill
  // is a table over the 21 reachable counts rather than a computed width.
  const fill =
    logged >= 20 ? "w-full" : logged >= 19 ? "w-19/20" : logged >= 18 ? "w-18/20" : logged >= 17 ? "w-17/20" :
    logged >= 16 ? "w-16/20" : logged >= 15 ? "w-15/20" : logged >= 14 ? "w-14/20" : logged >= 13 ? "w-13/20" :
    logged >= 12 ? "w-12/20" : logged >= 11 ? "w-11/20" : logged >= 10 ? "w-10/20" : logged >= 9 ? "w-9/20" :
    logged >= 8 ? "w-8/20" : logged >= 7 ? "w-7/20" : logged >= 6 ? "w-6/20" : logged >= 5 ? "w-5/20" :
    logged >= 4 ? "w-4/20" : logged >= 3 ? "w-3/20" : logged >= 2 ? "w-2/20" : logged >= 1 ? "w-1/20" :
    "w-0";

  return (
    <column
      class="size-full px-[18px] py-[12px] gap-[12px] border border-[#ffffff]/10 rounded-[24px]"
      background={[
        { type: "linear", stops: [{ offset: 0, color: "#0b0d12e6" }, { offset: 1, color: "#0b0d12e6" }] },
        { type: "linear", start: [0, 0], end: [0, 1], stops: [{ offset: 0, color: "#ffffff12" }, { offset: 0.6, color: "#ffffff00" }] },
      ]}
    >
      <row class="w-full items-baseline justify-between">
        <text class="text-[15px] font-semibold tracking-[-0.2px] text-[#f5f6f8]">Focus week</text>
        <text class="text-[12px] tabular-nums text-[#f5f6f8]/45">{time.weekday}, {time.month} {time.day}</text>
      </row>

      <row class="w-full gap-[3px]">
        {days.map((day) => {
          const today = day.key === time.weekday;
          return (
            <column
              class={today
                ? "grow w-0 py-[6px] gap-[3px] items-center rounded-[10px] bg-[#ff7a59]/18"
                : "grow w-0 py-[6px] gap-[3px] items-center rounded-[10px] bg-[#ffffff]/5"}
            >
              <text class={today
                ? "text-[10px] tracking-[0.5px] text-[#ff7a59]"
                : "text-[10px] tracking-[0.5px] text-[#f5f6f8]/45"}>{day.letter}</text>
              <text class={today
                ? "text-[15px] font-semibold tabular-nums text-[#ff7a59]"
                : "text-[15px] font-medium tabular-nums text-[#f5f6f8]/80"}>{sessions[day.key] ?? 0}</text>
            </column>
          );
        })}
      </row>

      <column class="w-full gap-[6px]">
        <row class="w-full items-baseline justify-between">
          <text class="text-[11px] tracking-[0.4px] text-[#f5f6f8]/50">Weekly goal</text>
          <text class="text-[12px] font-medium tabular-nums text-[#f5f6f8]/75">{logged} / {goal}</text>
        </row>
        <row class="w-full h-[8px] rounded-full overflow-hidden bg-[#ffffff]/8">
          <column class={`h-full rounded-full bg-[#ff7a59] ${fill}`} />
        </row>
      </column>

      <row class="w-full gap-[8px]">
        <button
          accessibilityLabel="Log session"
          class="grow w-0 h-[36px] rounded-[12px] bg-[#ff7a59] hover:opacity-90 pressed:opacity-75"
          onPress={() => setSessions((current) => ({ ...current, [time.weekday]: (current[time.weekday] ?? 0) + 1 }))}
        >
          <row class="size-full items-center">
            <text class="w-full text-center text-[13px] font-semibold text-[#0b0d12]">Log session</text>
          </row>
        </button>
        <button
          accessibilityLabel="Reset week"
          class="w-[104px] h-[36px] rounded-[12px] bg-[#ffffff]/8 hover:bg-[#ffffff]/12 pressed:bg-[#ffffff]/16"
          onPress={() => setSessions(emptyWeek)}
        >
          <row class="size-full items-center">
            <text class="w-full text-center text-[13px] font-medium text-[#f5f6f8]/70">Reset week</text>
          </row>
        </button>
      </row>
    </column>
  );
});
