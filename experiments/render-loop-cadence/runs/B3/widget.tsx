import { useProvider, useStorage, widget, type CanvasCtx, type TimeData } from "@weaver/sdk";

// Focus Week: seven persisted day counters, a weekly goal, and two buttons.
// The only live input is the `time` provider, which names today's cell and
// prints the header date.

const goal = 20;
const accent = "#ff7a59";

// Monday-first week. `key` matches TimeData.weekday, so today's cell and the
// stored counter share one name.
const week = [
  { key: "Mon", letter: "M" },
  { key: "Tue", letter: "T" },
  { key: "Wed", letter: "W" },
  { key: "Thu", letter: "T" },
  { key: "Fri", letter: "F" },
  { key: "Sat", letter: "S" },
  { key: "Sun", letter: "S" },
];

type Week = Record<string, number>;

function emptyWeek(): Week {
  const counts: Week = {};
  for (const day of week) counts[day.key] = 0;
  return counts;
}

function headerDate(time: TimeData): string {
  return `${time.weekday}, ${time.month} ${time.day}`;
}

// Track plus fill, both fully rounded. The fill keeps one bar-height stub so a
// single logged session is still visible.
function drawProgress(ctx: CanvasCtx, fraction: number): void {
  ctx.clear();
  const radius = ctx.height / 2;
  ctx.fillRoundRect(0, 0, ctx.width, ctx.height, radius, "#ffffff14");
  if (fraction <= 0) return;
  const filled = Math.max(ctx.height, Math.min(1, fraction) * ctx.width);
  ctx.fillRoundRect(0, 0, filled, ctx.height, radius, accent);
}

export default widget({
  name: "Focus Week",
  size: [320, 200],
  anchor: { corner: "top-right", offset: [24, 24] },
  subscribe: ["time"],
}, () => {
  const time = useProvider("time");
  const [sessions, setSessions] = useStorage<Week>("sessions", emptyWeek());
  const total = week.reduce((sum, day) => sum + (sessions[day.key] ?? 0), 0);

  const cell = (key: string, letter: string) => {
    const today = key === time.weekday;
    return (
      <column class={today
        ? "w-[36px] h-[48px] rounded-[12px] items-center justify-center gap-[4px] bg-[#ff7a59]/22"
        : "w-[36px] h-[48px] rounded-[12px] items-center justify-center gap-[4px] bg-[#ffffff]/5"}>
        <text class={today
          ? "text-[10px] leading-[12px] font-semibold tracking-[1px] text-[#ff7a59]"
          : "text-[10px] leading-[12px] font-medium tracking-[1px] text-[#f5f6f8]/50"}>{letter}</text>
        <text class={today
          ? "text-[16px] leading-[20px] font-semibold tabular-nums text-[#f5f6f8]"
          : "text-[16px] leading-[20px] font-medium tabular-nums text-[#f5f6f8]/70"}>{sessions[key] ?? 0}</text>
      </column>
    );
  };

  return (
    <column
      class="size-full px-[15px] py-[14px] justify-between border border-[#ffffff]/10 rounded-[24px]"
      background={[
        { type: "linear", stops: [{ offset: 0, color: "#0b0d12e6" }, { offset: 1, color: "#0b0d12e6" }] },
        { type: "linear", start: [0, 0], end: [0, 1], stops: [{ offset: 0, color: "#ffffff12" }, { offset: 0.6, color: "#ffffff00" }] },
      ]}
    >
      <row class="w-full items-baseline justify-between">
        <text class="text-[13px] leading-[18px] font-semibold tracking-[0.2px] text-[#f5f6f8]">Focus week</text>
        <text class="text-[11px] leading-[18px] tabular-nums text-[#f5f6f8]/50">{headerDate(time)}</text>
      </row>

      <row class="w-full justify-between">
        {week.map((day) => cell(day.key, day.letter))}
      </row>

      <column class="w-full gap-[6px]">
        <row class="w-full items-baseline justify-between">
          <text class="text-[11px] leading-[14px] text-[#f5f6f8]/50">Sessions</text>
          <text class="text-[11px] leading-[14px] font-semibold tabular-nums text-[#f5f6f8]/75">{`${total} / ${goal}`}</text>
        </row>
        <canvas class="w-[290px] h-[8px]" onFrame={(ctx) => drawProgress(ctx, total / goal)} />
      </column>

      <row class="w-full gap-[8px]">
        <button
          accessibilityLabel="Log session"
          class="w-[164px] h-[40px] rounded-[14px] bg-[#ff7a59] hover:bg-[#ff8b6b] pressed:bg-[#ef6a48]"
          onPress={() => setSessions((current) => ({ ...current, [time.weekday]: (current[time.weekday] ?? 0) + 1 }))}
        >
          <row class="size-full items-center">
            <text class="w-full text-center text-[13px] font-semibold text-[#0b0d12]">Log session</text>
          </row>
        </button>
        <button
          accessibilityLabel="Reset week"
          class="w-[118px] h-[40px] rounded-[14px] bg-[#ffffff]/8 hover:bg-[#ffffff]/12 pressed:bg-[#ffffff]/16"
          onPress={() => setSessions(emptyWeek())}
        >
          <row class="size-full items-center">
            <text class="w-full text-center text-[13px] font-medium text-[#f5f6f8]/80">Reset week</text>
          </row>
        </button>
      </row>
    </column>
  );
});
