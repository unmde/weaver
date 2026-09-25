import { useProvider, useStorage, widget, type CanvasCtx } from "@weaver/sdk";

// A week of focus sessions: one provider for "today", one persisted record
// keyed by weekday, and two buttons. Nothing animates, so the only work is
// the provider's re-render and one bar redraw per render.

const goal = 20;

interface Day {
  key: string;      // matches TimeData.weekday ("Mon" … "Sun")
  letter: string;   // the column head, M T W T F S S
}

const days: readonly Day[] = [
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
  return { Mon: 0, Tue: 0, Wed: 0, Thu: 0, Fri: 0, Sat: 0, Sun: 0 };
}

// The goal bar. Geometry depends on a runtime count, so it is drawn rather
// than sized with classes; a canvas without `fps` draws once per render.
function drawBar(ctx: CanvasCtx, logged: number): void {
  ctx.clear();
  const radius = ctx.height / 2;
  ctx.fillRoundRect(0, 0, ctx.width, ctx.height, radius, "#ffffff14");
  const fraction = Math.max(0, Math.min(1, logged / goal));
  if (fraction > 0) {
    // Never narrower than the cap radius, so a single session still reads.
    ctx.fillRoundRect(0, 0, Math.max(fraction * ctx.width, ctx.height), ctx.height, radius, "#ff7a59");
  }
}

export default widget({
  name: "Focus Week",
  size: [320, 200],
  anchor: { corner: "top-right", offset: [24, 24] },
  subscribe: ["time"],
}, () => {
  const time = useProvider("time");
  const [week, setWeek] = useStorage<Week>("sessions", emptyWeek());

  const logged = days.reduce((total, day) => total + (week[day.key] ?? 0), 0);

  // The row is 288 content px wide: 7 cells of 36 plus 6 gaps of 6, exactly.
  const cell = (day: Day) => {
    const today = day.key === time.weekday;
    return (
      <column
        class={today
          ? "w-[36px] h-full rounded-[12px] items-center justify-center gap-[4px] bg-[#ff7a59]/16 border border-[#ff7a59]/45"
          : "w-[36px] h-full rounded-[12px] items-center justify-center gap-[4px] bg-[#ffffff]/6"}
      >
        <text class={today
          ? "w-full text-center text-[10px] leading-[12px] font-medium text-[#ff7a59]"
          : "w-full text-center text-[10px] leading-[12px] font-medium text-[#f5f6f8]/45"}
        >{day.letter}</text>
        <text class={today
          ? "w-full text-center text-[16px] leading-[20px] font-medium tabular-nums text-[#f5f6f8]"
          : "w-full text-center text-[16px] leading-[20px] tabular-nums text-[#f5f6f8]/75"}
        >{week[day.key] ?? 0}</text>
      </column>
    );
  };

  return (
    <column
      class="size-full px-[16px] py-[14px] gap-[10px] border border-[#ffffff]/10 rounded-[24px]"
      background={[
        { type: "linear", stops: [{ offset: 0, color: "#0b0d12e6" }, { offset: 1, color: "#0b0d12e6" }] },
        { type: "linear", start: [0, 0], end: [0, 1], stops: [{ offset: 0, color: "#ffffff12" }, { offset: 0.6, color: "#ffffff00" }] },
      ]}
    >
      <row class="w-full h-[18px] items-baseline justify-between">
        <text class="text-[13px] leading-[18px] font-medium text-[#f5f6f8]">Focus week</text>
        <text class="text-[13px] leading-[18px] tabular-nums text-[#f5f6f8]/45">{time.weekday}, {time.month} {time.day}</text>
      </row>

      {/* 18 + 58 + 28 + 36 rows and 3 gaps of 10 = 170 of the 172 content px;
          the day row takes the remaining 2 so nothing is left dangling. */}
      <row class="w-full h-[58px] grow gap-[6px]">
        {days.map(cell)}
      </row>

      <column class="w-full gap-[6px]">
        <row class="w-full h-[14px] items-baseline justify-between">
          <text class="text-[11px] leading-[14px] text-[#f5f6f8]/40">Sessions this week</text>
          <text class="text-[11px] leading-[14px] font-medium tabular-nums text-[#f5f6f8]/80">{logged} / {goal}</text>
        </row>
        <canvas class="w-[288px] h-[8px]" onFrame={(ctx) => drawBar(ctx, logged)} />
      </column>

      <row class="w-full h-[36px] gap-[8px]">
        <button
          accessibilityLabel="Log session"
          class="w-[186px] h-[36px] rounded-[12px] bg-[#ff7a59] hover:bg-[#ff8f72] pressed:bg-[#e35f3f]"
          onPress={() => setWeek((current) => ({ ...current, [time.weekday]: (current[time.weekday] ?? 0) + 1 }))}
        >
          <row class="size-full items-center">
            <text class="w-full text-center text-[13px] font-semibold text-[#0b0d12]">Log session</text>
          </row>
        </button>
        <button
          accessibilityLabel="Reset week"
          class="w-[94px] h-[36px] rounded-[12px] bg-[#ffffff]/8 hover:bg-[#ffffff]/14 pressed:bg-[#ffffff]/20"
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
