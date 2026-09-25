import { useProvider, useStorage, widget } from "@weaver/sdk";

// Focus Week: seven day cells fed by per-weekday session counts.
// Only the `time` provider is subscribed; it names today and dates the header.

interface Day {
  key: string;    // matches TimeData.weekday
  letter: string; // column heading
}

const week: Day[] = [
  { key: "Mon", letter: "M" },
  { key: "Tue", letter: "T" },
  { key: "Wed", letter: "W" },
  { key: "Thu", letter: "T" },
  { key: "Fri", letter: "F" },
  { key: "Sat", letter: "S" },
  { key: "Sun", letter: "S" },
];

type Counts = Record<string, number>;

function emptyWeek(): Counts {
  return { Mon: 0, Tue: 0, Wed: 0, Thu: 0, Fri: 0, Sat: 0, Sun: 0 };
}

const goal = 20;

// One tick per goal session. Equal ticks make the meter land exactly on the
// session count, and the gaps keep every tick readable at 1x.
const ticks: number[] = Array.from({ length: goal }, (_, index) => index);

export default widget({
  name: "Focus Week",
  size: [320, 200],
  anchor: { corner: "top-right", offset: [24, 24] },
  subscribe: ["time"],
}, () => {
  const time = useProvider("time");
  const [counts, setCounts] = useStorage<Counts>("counts", emptyWeek());
  const total = week.reduce((sum, day) => sum + (counts[day.key] ?? 0), 0);
  const filled = Math.max(0, Math.min(goal, total));

  // One seventh of the row each, so the cells always fill the width exactly.
  // The outer cell carries the spacing; the inner box carries the highlight, and
  // every cell keeps a border so today's ring never shifts the text inside.
  const cell = (day: Day) => {
    const today = day.key === time.weekday;
    return (
      <column class="w-1/7 px-[2px]">
        <column
          class={today
            ? "w-full items-center gap-[3px] py-[7px] rounded-[10px] border border-[#ff7a59]/45 bg-[#ff7a59]/16"
            : "w-full items-center gap-[3px] py-[7px] rounded-[10px] border border-[#ffffff]/8 bg-[#ffffff]/5"}
        >
          <text class={today
            ? "text-[10px] leading-none tracking-[0.5px] text-[#ff7a59]"
            : "text-[10px] leading-none tracking-[0.5px] text-[#f5f6f8]/40"}
          >{day.letter}</text>
          <text class={today
            ? "text-[15px] leading-none font-semibold tabular-nums text-[#f5f6f8]"
            : "text-[15px] leading-none tabular-nums text-[#f5f6f8]/70"}
          >{counts[day.key] ?? 0}</text>
        </column>
      </column>
    );
  };

  return (
    <column
      class="size-full px-[18px] py-[16px] gap-[14px] border border-[#ffffff]/10 rounded-[24px]"
      background={[
        { type: "linear", stops: [{ offset: 0, color: "#0b0d12e6" }, { offset: 1, color: "#0b0d12e6" }] },
        { type: "linear", start: [0, 0], end: [0, 1], stops: [{ offset: 0, color: "#ffffff12" }, { offset: 0.6, color: "#ffffff00" }] },
      ]}
    >
      <row class="w-full items-baseline justify-between">
        <text class="text-[15px] leading-none font-semibold tracking-[0.2px] text-[#f5f6f8]">Focus week</text>
        <text class="text-[12px] leading-none text-[#f5f6f8]/45">{time.weekday}, {time.month} {time.day}</text>
      </row>

      <row class="w-full">
        {week.map(cell)}
      </row>

      <column class="w-full gap-[7px]">
        <row class="w-full items-baseline justify-between">
          <text class="text-[11px] leading-none tracking-[0.4px] text-[#f5f6f8]/40">Sessions this week</text>
          <text class="text-[12px] leading-none font-medium tabular-nums text-[#f5f6f8]/75">{total} / {goal}</text>
        </row>
        <row class="w-full h-[8px] gap-[3px]">
          {ticks.map((index) => (
            <row class={index < filled
              ? "grow h-full rounded-[2px] bg-[#ff7a59]"
              : "grow h-full rounded-[2px] bg-[#ffffff]/12"}
            />
          ))}
        </row>
      </column>

      <row class="w-full h-[42px] gap-[8px]">
        <button
          accessibilityLabel="Log session"
          class="grow h-full rounded-[14px] bg-[#ff7a59] hover:opacity-90 pressed:opacity-75"
          onPress={() => setCounts((current) => ({ ...current, [time.weekday]: (current[time.weekday] ?? 0) + 1 }))}
        >
          <row class="size-full items-center">
            <text class="w-full text-center text-[13px] font-semibold text-[#0b0d12]">Log session</text>
          </row>
        </button>
        <button
          accessibilityLabel="Reset week"
          class="w-[104px] h-full rounded-[14px] bg-[#ffffff]/8 hover:bg-[#ffffff]/12 pressed:bg-[#ffffff]/16"
          onPress={() => setCounts(emptyWeek())}
        >
          <row class="size-full items-center">
            <text class="w-full text-center text-[13px] font-medium text-[#f5f6f8]/70">Reset week</text>
          </row>
        </button>
      </row>
    </column>
  );
});
