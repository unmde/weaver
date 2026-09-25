import { useProvider, useStorage, widget, type CanvasCtx } from "@weaver/sdk";

// Focus Week: seven day cells fed by one persisted counter map, keyed by the
// short weekday name the `time` provider already speaks. One provider, no
// timers of our own, no network.

const order = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"] as const;
const letters = ["M", "T", "W", "T", "F", "S", "S"] as const;

type Counts = Record<string, number>;

const empty: Counts = { Mon: 0, Tue: 0, Wed: 0, Thu: 0, Fri: 0, Sat: 0, Sun: 0 };

const goal = 20;
const accent = "#ff7a59";

// The bar is drawn rather than laid out: `weaver check` resolves `class` to at
// most 32 literal strings, so a fill width of "sessions / 20" cannot be a
// utility. One rounded rect per render, no `fps`, so it costs nothing between
// provider ticks.
function drawProgress(ctx: CanvasCtx, fraction: number): void {
  ctx.clear();
  const radius = ctx.height / 2;
  ctx.fillRoundRect(0, 0, ctx.width, ctx.height, radius, "#ffffff1f");
  const filled = Math.max(0, Math.min(1, fraction)) * ctx.width;
  if (filled > 0) ctx.fillRoundRect(0, 0, Math.max(filled, ctx.height), ctx.height, radius, accent);
}

export default widget({
  name: "Focus Week",
  size: [320, 200],
  anchor: { corner: "top-right", offset: [24, 24] },
  subscribe: ["time"],
}, () => {
  const time = useProvider("time");
  const [counts, setCounts] = useStorage<Counts>("sessions", empty);

  const today = time.weekday;
  const total = order.reduce((sum, day) => sum + (counts[day] ?? 0), 0);

  const cell = (day: string, letter: string) => {
    const current = day === today;
    return (
      <column
        class={current
          ? "w-[36px] h-full items-center justify-center gap-[5px] rounded-[12px] border border-[#ff7a59]/45 bg-[#ff7a59]/16"
          : "w-[36px] h-full items-center justify-center gap-[5px] rounded-[12px] border border-[#ffffff]/8 bg-[#ffffff]/4"}
      >
        <text class={current
          ? "text-[10px] leading-none tracking-[1px] font-medium text-[#ff7a59]"
          : "text-[10px] leading-none tracking-[1px] font-medium text-[#f5f6f8]/50"}>{letter}</text>
        <text class={current
          ? "text-[17px] leading-none font-semibold tabular-nums text-[#f5f6f8]"
          : "text-[17px] leading-none font-normal tabular-nums text-[#f5f6f8]/65"}>{counts[day] ?? 0}</text>
      </column>
    );
  };

  return (
    <column
      class="size-full px-[16px] py-[14px] gap-[12px] border border-[#ffffff]/10 rounded-[24px]"
      background={[
        { type: "linear", stops: [{ offset: 0, color: "#0b0d12e6" }, { offset: 1, color: "#0b0d12e6" }] },
        { type: "linear", start: [0, 0], end: [0, 1], stops: [{ offset: 0, color: "#ffffff12" }, { offset: 0.6, color: "#ffffff00" }] },
      ]}
    >
      <row class="w-full items-baseline justify-between">
        <text class="text-[13px] leading-none font-medium tracking-[0.5px] text-[#f5f6f8]">Focus week</text>
        <text class="text-[12px] leading-none tabular-nums text-[#f5f6f8]/45">{time.weekday}, {time.month} {time.day}</text>
      </row>

      <row class="w-full grow justify-between">
        {order.map((day, index) => cell(day, letters[index]))}
      </row>

      <column class="w-full gap-[8px]">
        <row class="w-full items-baseline justify-between">
          <text class="text-[10px] leading-none tracking-[1px] text-[#f5f6f8]/45">WEEKLY GOAL</text>
          <text class="text-[11px] leading-none tabular-nums text-[#f5f6f8]/70">{total} / {goal}</text>
        </row>
        <canvas class="w-[288px] h-[7px]" onFrame={(ctx) => drawProgress(ctx, total / goal)} />
      </column>

      <row class="w-full gap-[8px]">
        <button
          accessibilityLabel="Log session"
          class="w-[140px] h-[40px] rounded-[14px] bg-[#ff7a59] hover:opacity-90 pressed:opacity-75"
          onPress={() => setCounts((current) => ({ ...current, [today]: (current[today] ?? 0) + 1 }))}
        >
          <row class="size-full items-center">
            <text class="w-full text-center text-[13px] font-semibold text-[#0b0d12]">Log session</text>
          </row>
        </button>
        <button
          accessibilityLabel="Reset week"
          class="w-[140px] h-[40px] rounded-[14px] border border-[#ffffff]/10 bg-[#ffffff]/8 hover:bg-[#ffffff]/12 pressed:bg-[#ffffff]/16"
          onPress={() => setCounts({ ...empty })}
        >
          <row class="size-full items-center">
            <text class="w-full text-center text-[13px] font-medium text-[#f5f6f8]/80">Reset week</text>
          </row>
        </button>
      </row>
    </column>
  );
});
