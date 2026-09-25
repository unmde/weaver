import { useInterval, useState, widget } from "@weaver/sdk";

function verificationClock(tick: number): string {
  const minutes = Math.floor(tick / 60) % 60;
  const seconds = tick % 60;
  return `${String(minutes).padStart(2, "0")}:${String(seconds).padStart(2, "0")}`;
}

export default widget({
  name: "Styling Text",
  size: [500, 280],
  anchor: { corner: "top-right", offset: [24, 24] },
}, () => {
  const [tick, setTick] = useState(0);
  useInterval(() => setTick((value) => value + 1), 1000);

  return (
    <stack class="size-full pl-[30px] pt-[10px] pr-[30px] pb-[50px]">
    <column class="w-[440px] h-[220px] p-5 gap-4 bg-zinc-950 rounded-2xl border border-zinc-700 shadow-xl">
      <column class="gap-1">
        <text class="text-lg font-semibold tracking-wide text-white">CoreText verification</text>
        <text class="text-xs text-zinc-400">The live row changes once per second; every digit column must stay fixed.</text>
      </column>

      <row class="gap-4 items-start">
        <column class="w-[150px] gap-1">
          <text class="text-xs tracking-widest text-sky-300">TABULAR DIGITS</text>
          <column class="w-full p-2 gap-1 bg-black rounded-lg border border-sky-900">
            <text class="w-full text-xl font-mono tabular-nums tracking-wide text-right text-zinc-600">88:88</text>
            <text class="w-full text-xl font-mono tabular-nums tracking-wide text-right text-sky-200">{verificationClock(tick)}</text>
          </column>
        </column>

        <column class="grow min-w-0 gap-1">
          <text class="text-xs tracking-widest text-amber-300">TWO-LINE CLAMP</text>
          <text class="w-full text-sm leading-tight tracking-wide text-zinc-200 line-clamp-2">
            Fractions, bounds, aspect ratio, and clamped text must reserve two distinct lines and end with an ellipsis.
          </text>
        </column>
      </row>
    </column>
    </stack>
  );
});
