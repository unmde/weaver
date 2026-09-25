import { useProvider, useStorage, widget, type CanvasCtx } from "@weaver/sdk";

// Focus week: seven persisted session counters, one per weekday, plus a
// weekly goal. The `time` provider names today; nothing else ticks.

const goal = 20;
const days = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"] as const;
const letters = ["M", "T", "W", "T", "F", "S", "S"] as const;

type Week = Record<string, number>;

const emptyWeek: Week = { Mon: 0, Tue: 0, Wed: 0, Thu: 0, Fri: 0, Sat: 0, Sun: 0 };

const accent = "#5eead4";

// The goal bar. Drawn rather than sized with utilities so the fill lands on an
// exact pixel instead of a rounded percentage class.
function drawGoalBar(ctx: CanvasCtx, fraction: number): void {
  ctx.clear();
  const radius = ctx.height / 2;
  ctx.fillRoundRect(0, 0, ctx.width, ctx.height, radius, "#ffffff14");
  const clamped = Math.max(0, Math.min(1, fraction));
  if (clamped === 0) return;
  ctx.fillRoundRect(0, 0, Math.max(clamped * ctx.width, ctx.height), ctx.height, radius, accent);
}

export default widget({
  name: "Focus Week",
  size: [320, 200],
  anchor: { corner: "top-right", offset: [24, 24] },
  subscribe: ["time"],
}, () => {
  const time = useProvider("time");
  const [week, setWeek] = useStorage<Week>("week", emptyWeek);

  const today = days.includes(time.weekday as typeof days[number]) ? time.weekday : days[0];
  const logged = days.reduce((sum, day) => sum + (week[day] ?? 0), 0);

  return (
    <column
      class="size-full px-[15px] py-[14px] gap-[10px] justify-between border border-[#ffffff]/10 rounded-[24px]"
      background={[
        { type: "linear", stops: [{ offset: 0, color: "#0b0d12e6" }, { offset: 1, color: "#0b0d12e6" }] },
        { type: "linear", start: [0, 0], end: [0, 1], stops: [{ offset: 0, color: "#ffffff12" }, { offset: 0.6, color: "#ffffff00" }] },
      ]}
    >
      <row class="w-full items-baseline justify-between">
        <text class="text-[15px] font-medium text-[#f5f6f8]">Focus week</text>
        <text class="text-[12px] text-[#f5f6f8]/50">{time.weekday}, {time.month} {time.day}</text>
      </row>

      <row class="w-full gap-[6px]">
        {days.map((day, index) => (
          <column
            class={day === today
              ? "w-[36px] grow h-[48px] gap-[3px] items-center justify-center rounded-[10px] border border-[#5eead4]/55 bg-[#5eead4]/18"
              : "w-[36px] grow h-[48px] gap-[3px] items-center justify-center rounded-[10px] border border-[#ffffff]/8 bg-[#ffffff]/4"}
          >
            <text class={day === today
              ? "text-[11px] tracking-[1px] text-[#5eead4]"
              : "text-[11px] tracking-[1px] text-[#f5f6f8]/40"}>{letters[index]}</text>
            <text class={day === today
              ? "text-[15px] leading-none tabular-nums text-[#f5f6f8]"
              : "text-[15px] leading-none tabular-nums text-[#f5f6f8]/65"}>{week[day] ?? 0}</text>
          </column>
        ))}
      </row>

      <column class="w-full gap-[6px]">
        <row class="w-full items-baseline justify-between">
          <text class="text-[11px] tracking-[1px] text-[#f5f6f8]/40">WEEKLY GOAL</text>
          <text class="text-[12px] tabular-nums text-[#f5f6f8]/80">{logged} / {goal}</text>
        </row>
        <row class="w-full">
          <canvas class="w-[288px] grow h-[8px]" onFrame={(ctx) => drawGoalBar(ctx, logged / goal)} />
        </row>
      </column>

      <row class="w-full gap-[8px]">
        <button
          accessibilityLabel="Log session"
          class="grow h-[36px] rounded-[12px] bg-[#5eead4] hover:bg-[#7ff3e2] pressed:bg-[#43c6b1]"
          onPress={() => setWeek((current) => ({ ...current, [today]: (current[today] ?? 0) + 1 }))}
        >
          <row class="size-full items-center">
            <text class="w-full text-center text-[13px] font-semibold text-[#0b0d12]">Log session</text>
          </row>
        </button>
        <button
          accessibilityLabel="Reset week"
          class="w-[104px] h-[36px] rounded-[12px] bg-[#ffffff]/8 hover:bg-[#ffffff]/14 pressed:bg-[#ffffff]/20"
          onPress={() => setWeek({ ...emptyWeek })}
        >
          <row class="size-full items-center">
            <text class="w-full text-center text-[13px] font-medium text-[#f5f6f8]/75">Reset week</text>
          </row>
        </button>
      </row>
    </column>
  );
});
