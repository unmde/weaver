import { useProvider, useStorage, widget, type CanvasCtx } from "@weaver/sdk";

// Focus Week: seven day cells, a weekly goal, and two buttons. One provider
// (time) tells us which cell is today; the counts live in widget storage,
// keyed by weekday, so they survive restarts.

const days = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"] as const;
const letters = ["M", "T", "W", "T", "F", "S", "S"] as const;
const goal = 20;

const empty: Record<string, number> = { Mon: 0, Tue: 0, Wed: 0, Thu: 0, Fri: 0, Sat: 0, Sun: 0 };

const accent = "#ff7a59";

// The bar is a canvas so the fill can land on an exact pixel instead of one of
// a handful of static width utilities. No fps: it redraws only on render.
function drawBar(ctx: CanvasCtx, fraction: number): void {
  ctx.clear();
  const radius = ctx.height / 2;
  ctx.fillRoundRect(0, 0, ctx.width, ctx.height, radius, "#ffffff1f");
  const filled = Math.round(ctx.width * Math.max(0, Math.min(1, fraction)));
  if (filled > 0) ctx.fillRoundRect(0, 0, Math.max(filled, ctx.height), ctx.height, radius, accent);
}

export default widget({
  name: "Focus Week",
  size: [320, 200],
  anchor: { corner: "top-right", offset: [24, 24] },
  subscribe: ["time"],
}, () => {
  const time = useProvider("time");
  const [sessions, setSessions] = useStorage<Record<string, number>>("sessions", empty);

  const today = time.weekday;
  const total = days.reduce((sum, day) => sum + (sessions[day] ?? 0), 0);

  const cell = (day: string, letter: string) => {
    const isToday = day === today;
    return (
      <column
        class={isToday
          ? "w-[36px] h-[44px] items-center justify-center gap-[3px] rounded-[10px] border border-[#ff7a59]/45 bg-[#ff7a59]/16"
          : "w-[36px] h-[44px] items-center justify-center gap-[3px] rounded-[10px] border border-[#ffffff]/0 bg-[#ffffff]/4"}
      >
        <text class={isToday
          ? "text-[10px] leading-none tracking-[1px] text-[#ff7a59]"
          : "text-[10px] leading-none tracking-[1px] text-[#f5f6f8]/50"}
        >{letter}</text>
        <text class={isToday
          ? "text-[15px] leading-none font-medium tabular-nums text-[#ff7a59]"
          : "text-[15px] leading-none font-medium tabular-nums text-[#f5f6f8]/85"}
        >{sessions[day] ?? 0}</text>
      </column>
    );
  };

  return (
    <column
      class="size-full p-[16px] gap-[12px] border border-[#ffffff]/10 rounded-[24px]"
      background={[
        { type: "linear", stops: [{ offset: 0, color: "#0b0d12e6" }, { offset: 1, color: "#0b0d12e6" }] },
        { type: "linear", start: [0, 0], end: [0, 1], stops: [{ offset: 0, color: "#ffffff12" }, { offset: 0.6, color: "#ffffff00" }] },
      ]}
    >
      <row class="w-full items-baseline justify-between">
        <text class="text-[13px] font-medium tracking-[0.2px] text-[#f5f6f8]">Focus week</text>
        <text class="text-[12px] text-[#f5f6f8]/45">{time.weekday}, {time.month} {time.day}</text>
      </row>

      <row class="w-full gap-[6px]">
        {cell(days[0], letters[0])}
        {cell(days[1], letters[1])}
        {cell(days[2], letters[2])}
        {cell(days[3], letters[3])}
        {cell(days[4], letters[4])}
        {cell(days[5], letters[5])}
        {cell(days[6], letters[6])}
      </row>

      <column class="w-full gap-[6px]">
        <row class="w-full items-baseline justify-between">
          <text class="text-[11px] tracking-[1px] text-[#f5f6f8]/45">THIS WEEK</text>
          <text class="text-[12px] font-medium tabular-nums text-[#f5f6f8]/70">{total} / {goal}</text>
        </row>
        <canvas class="w-[288px] h-[8px]" onFrame={(ctx) => drawBar(ctx, total / goal)} />
      </column>

      <row class="w-full gap-[8px]">
        <button
          accessibilityLabel="Log session"
          class="w-[168px] h-[36px] rounded-[12px] bg-[#ff7a59] hover:opacity-90 pressed:opacity-75"
          onPress={() => setSessions((current) => ({ ...current, [today]: (current[today] ?? 0) + 1 }))}
        >
          <row class="size-full items-center">
            <text class="w-full text-center text-[13px] font-semibold text-[#0b0d12]">Log session</text>
          </row>
        </button>
        <button
          accessibilityLabel="Reset week"
          class="w-[112px] h-[36px] rounded-[12px] bg-[#ffffff]/8 hover:bg-[#ffffff]/12 pressed:bg-[#ffffff]/16"
          onPress={() => setSessions({ ...empty })}
        >
          <row class="size-full items-center">
            <text class="w-full text-center text-[13px] font-medium text-[#f5f6f8]/75">Reset week</text>
          </row>
        </button>
      </row>
    </column>
  );
});
