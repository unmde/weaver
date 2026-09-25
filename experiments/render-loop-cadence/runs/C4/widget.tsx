import { useProvider, useStorage, widget } from "@weaver/sdk";

// Focus Week — seven day cells, a weekly session goal, and two buttons.
// Counts live in widget storage keyed by the short weekday name, so a
// restart reopens the same week.

const goal = 20;

const days: { key: string; letter: string }[] = [
  { key: "Mon", letter: "M" },
  { key: "Tue", letter: "T" },
  { key: "Wed", letter: "W" },
  { key: "Thu", letter: "T" },
  { key: "Fri", letter: "F" },
  { key: "Sat", letter: "S" },
  { key: "Sun", letter: "S" },
];

type Counts = Record<string, number>;

const empty: Counts = { Mon: 0, Tue: 0, Wed: 0, Thu: 0, Fri: 0, Sat: 0, Sun: 0 };

export default widget({
  name: "Focus Week",
  size: [320, 200],
  anchor: { corner: "top-right", offset: [24, 24] },
  subscribe: ["time"],
}, () => {
  const time = useProvider("time");
  const [counts, setCounts] = useStorage<Counts>("counts", empty);
  const sessions = days.reduce((sum, day) => sum + (counts[day.key] ?? 0), 0);
  const total = Math.min(sessions, goal);

  return (
    <column
      class="size-full px-[18px] py-[15px] gap-[14px] border border-[#ffffff]/10 rounded-[24px]"
      background={[
        { type: "linear", stops: [{ offset: 0, color: "#0b0d12e6" }, { offset: 1, color: "#0b0d12e6" }] },
        { type: "linear", start: [0, 0], end: [0, 1], stops: [{ offset: 0, color: "#ffffff12" }, { offset: 0.6, color: "#ffffff00" }] },
      ]}
    >
      <row class="w-full items-baseline justify-between">
        <text class="text-[14px] font-semibold tracking-[0.2px] text-[#f5f6f8]">Focus week</text>
        <text class="text-[12px] tabular-nums text-[#f5f6f8]/45">{time.weekday}, {time.month} {time.day}</text>
      </row>

      <row class="w-full h-[48px] gap-[4px]">
        {days.map((day) => {
          const today = day.key === time.weekday;
          return (
            <column
              class={today
                ? "grow h-full min-w-0 items-center justify-center gap-[2px] rounded-[10px] bg-[#f59e0b]/14 border border-[#f59e0b]/40"
                : "grow h-full min-w-0 items-center justify-center gap-[2px] rounded-[10px] bg-[#ffffff]/5 border border-[#ffffff]/0"}
            >
              <text class={today ? "text-[10px] leading-none tracking-[0.5px] font-medium text-[#f59e0b]" : "text-[10px] leading-none tracking-[0.5px] font-medium text-[#f5f6f8]/45"}>{day.letter}</text>
              <text class={today ? "text-[15px] leading-none font-semibold tabular-nums text-[#f5f6f8]" : "text-[15px] leading-none font-normal tabular-nums text-[#f5f6f8]/70"}>{counts[day.key] ?? 0}</text>
            </column>
          );
        })}
      </row>

      <column class="w-full gap-[6px]">
        <row class="w-full items-baseline justify-between">
          <text class="text-[11px] leading-none tracking-[0.4px] text-[#f5f6f8]/50">Sessions this week</text>
          <text class="text-[11px] leading-none font-medium tabular-nums text-[#f5f6f8]/75">{sessions} / {goal}</text>
        </row>
        {/* The fill width is one of 21 literal classes: weaver check validates
            every class it can see, so the width cannot be computed inline. */}
        <row class="w-full h-[6px] rounded-full bg-[#ffffff]/8 overflow-hidden">
          <column
            class={
                total === 0 ? "h-full rounded-full bg-[#f59e0b] w-[0px]" :
                total === 1 ? "h-full rounded-full bg-[#f59e0b] w-[14px]" :
                total === 2 ? "h-full rounded-full bg-[#f59e0b] w-[28px]" :
                total === 3 ? "h-full rounded-full bg-[#f59e0b] w-[43px]" :
                total === 4 ? "h-full rounded-full bg-[#f59e0b] w-[57px]" :
                total === 5 ? "h-full rounded-full bg-[#f59e0b] w-[71px]" :
                total === 6 ? "h-full rounded-full bg-[#f59e0b] w-[85px]" :
                total === 7 ? "h-full rounded-full bg-[#f59e0b] w-[99px]" :
                total === 8 ? "h-full rounded-full bg-[#f59e0b] w-[114px]" :
                total === 9 ? "h-full rounded-full bg-[#f59e0b] w-[128px]" :
                total === 10 ? "h-full rounded-full bg-[#f59e0b] w-[142px]" :
                total === 11 ? "h-full rounded-full bg-[#f59e0b] w-[156px]" :
                total === 12 ? "h-full rounded-full bg-[#f59e0b] w-[170px]" :
                total === 13 ? "h-full rounded-full bg-[#f59e0b] w-[185px]" :
                total === 14 ? "h-full rounded-full bg-[#f59e0b] w-[199px]" :
                total === 15 ? "h-full rounded-full bg-[#f59e0b] w-[213px]" :
                total === 16 ? "h-full rounded-full bg-[#f59e0b] w-[227px]" :
                total === 17 ? "h-full rounded-full bg-[#f59e0b] w-[241px]" :
                total === 18 ? "h-full rounded-full bg-[#f59e0b] w-[256px]" :
                total === 19 ? "h-full rounded-full bg-[#f59e0b] w-[270px]" :
                "h-full rounded-full bg-[#f59e0b] w-[284px]"
            }
          />
        </row>
      </column>

      <row class="w-full h-[38px] gap-[8px]">
        <button
          accessibilityLabel="Log session"
          class="grow h-full rounded-[12px] bg-[#f59e0b] hover:bg-[#fbbf24] pressed:bg-[#d97706]"
          onPress={() => setCounts((current) => ({ ...current, [time.weekday]: (current[time.weekday] ?? 0) + 1 }))}
        >
          <row class="size-full items-center">
            <text class="w-full text-center text-[13px] font-semibold text-[#0b0d12]">Log session</text>
          </row>
        </button>
        <button
          accessibilityLabel="Reset week"
          class="w-[108px] h-full rounded-[12px] bg-[#ffffff]/8 hover:bg-[#ffffff]/14 pressed:bg-[#ffffff]/20"
          onPress={() => setCounts(empty)}
        >
          <row class="size-full items-center">
            <text class="w-full text-center text-[13px] font-medium text-[#f5f6f8]/75">Reset week</text>
          </row>
        </button>
      </row>
    </column>
  );
});
