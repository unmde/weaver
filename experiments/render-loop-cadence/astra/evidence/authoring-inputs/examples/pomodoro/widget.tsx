import { useInterval, useStorage, widget, type CanvasCtx } from "@weaver/sdk";

// A tiny app: persisted state, one timer, buttons with native hover and
// pressed states, and a canvas ring that redraws once per second.

type Mode = "focus" | "short" | "long";

const minutes: Record<Mode, number> = { focus: 25, short: 5, long: 15 };
const headings: Record<Mode, string> = { focus: "FOCUS", short: "SHORT BREAK", long: "LONG BREAK" };
const focusColor = "#ff7a59";
const breakColor = "#5eead4";

interface TimerState {
  mode: Mode;
  remaining: number;   // seconds
  running: boolean;
}

function clock(seconds: number): string {
  return `${String(Math.floor(seconds / 60)).padStart(2, "0")}:${String(seconds % 60).padStart(2, "0")}`;
}

// 60 ticks around the dial; the lit arc shrinks clockwise as time runs out.
function drawRing(ctx: CanvasCtx, fraction: number, color: string): void {
  ctx.clear();
  const cx = ctx.width / 2;
  const cy = ctx.height / 2;
  const outer = Math.min(cx, cy) - 2;
  const inner = outer - 11;
  const lit = Math.ceil(Math.max(0, Math.min(1, fraction)) * 60);
  for (let index = 0; index < 60; index += 1) {
    const angle = (index / 60) * Math.PI * 2 - Math.PI / 2;
    const cos = Math.cos(angle);
    const sin = Math.sin(angle);
    ctx.line(cx + cos * inner, cy + sin * inner, cx + cos * outer, cy + sin * outer, 2.5, index < lit ? color : "#ffffff1f");
  }
}

export default widget({
  name: "Pomodoro",
  size: [300, 344],
  anchor: { corner: "top-right", offset: [24, 180] },
}, () => {
  const [timer, setTimer] = useStorage<TimerState>("timer", { mode: "focus", remaining: minutes.focus * 60, running: false });
  const total = minutes[timer.mode] * 60;
  const focus = timer.mode === "focus";
  const color = focus ? focusColor : breakColor;

  // Ticks once per second while running. While paused the interval is
  // stretched to an hour so the widget does not wake up for nothing.
  useInterval(() => {
    setTimer((current) => {
      if (!current.running) return current;
      if (current.remaining <= 1) return { ...current, remaining: 0, running: false };
      return { ...current, remaining: current.remaining - 1 };
    });
  }, timer.running ? 1000 : 3_600_000);

  const select = (mode: Mode) => setTimer({ mode, remaining: minutes[mode] * 60, running: false });
  const chip = (mode: Mode, label: string) => {
    const selected = timer.mode === mode;
    return (
      <button
        accessibilityLabel={label}
        class={selected
          ? "w-[80px] h-[28px] rounded-full items-center justify-center bg-[#ffffff]/14"
          : "w-[80px] h-[28px] rounded-full items-center justify-center bg-transparent hover:bg-[#ffffff]/8 pressed:bg-[#ffffff]/12"}
        onPress={() => select(mode)}
      >
        <row class="size-full items-center">
          <text class={selected ? "w-full text-center text-[11px] font-medium text-[#f5f6f8]" : "w-full text-center text-[11px] font-medium text-[#f5f6f8]/50"}>{label}</text>
        </row>
      </button>
    );
  };

  return (
    <column
      class="size-full p-[20px] gap-[14px] items-center border border-[#ffffff]/10 rounded-[28px]"
      background={[
        { type: "linear", stops: [{ offset: 0, color: "#0b0d12e6" }, { offset: 1, color: "#0b0d12e6" }] },
        { type: "linear", start: [0, 0], end: [0, 1], stops: [{ offset: 0, color: "#ffffff12" }, { offset: 0.6, color: "#ffffff00" }] },
      ]}
    >
      <row class="w-full items-center justify-between">
        <text class={focus ? "text-[11px] tracking-[2px] text-[#ff7a59]" : "text-[11px] tracking-[2px] text-[#5eead4]"}>{headings[timer.mode]}</text>
        <text class="text-[11px] tracking-[1px] tabular-nums text-[#f5f6f8]/40">{minutes[timer.mode]} MIN</text>
      </row>

      <stack class="size-[172px]">
        <canvas class="size-[172px]" onFrame={(ctx) => drawRing(ctx, timer.remaining / total, color)} />
        <column class="size-full items-center justify-center gap-[2px]">
          <text class="text-[42px] leading-none font-light tracking-[-1px] tabular-nums text-[#f5f6f8]">{clock(timer.remaining)}</text>
          <text class="text-[11px] tracking-[1px] text-[#f5f6f8]/40">
            {timer.remaining === 0 ? "DONE" : timer.running ? "RUNNING" : "PAUSED"}
          </text>
        </column>
      </stack>

      <row class="gap-[6px]">
        {chip("focus", "Focus")}
        {chip("short", "Short break")}
        {chip("long", "Long break")}
      </row>

      <row class="w-full gap-[8px]">
        <button
          class={focus
            ? "w-[206px] h-[46px] rounded-[16px] bg-[#ff7a59] hover:opacity-90 pressed:opacity-75"
            : "w-[206px] h-[46px] rounded-[16px] bg-[#5eead4] hover:opacity-90 pressed:opacity-75"}
          onPress={() => setTimer((current) => ({
            ...current,
            remaining: current.remaining === 0 ? total : current.remaining,
            running: !current.running,
          }))}
        >
          <row class="size-full items-center">
            <text class="w-full text-center text-[14px] font-semibold text-[#0b0d12]">{timer.running ? "Pause" : "Start"}</text>
          </row>
        </button>
        <button
          accessibilityLabel="Reset"
          class="size-[46px] rounded-[16px] items-center justify-center bg-[#ffffff]/8 hover:bg-[#ffffff]/12 pressed:bg-[#ffffff]/16"
          onPress={() => select(timer.mode)}
        >
          <icon name="rotate-ccw" class="size-[18px] text-[#f5f6f8]/70" />
        </button>
      </row>
    </column>
  );
});
