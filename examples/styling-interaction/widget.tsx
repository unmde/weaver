import { useState, widget, type PressEvent } from "@weaver/sdk";

function describe(kind: string, event: PressEvent | undefined): string {
  if (!event) return kind;
  return `${kind}: ${event.x.toFixed(0)}px, ${event.y.toFixed(0)}px · ${(event.u * 100).toFixed(0)}%, ${(event.v * 100).toFixed(0)}%`;
}

export default widget({
  name: "Styling Interaction",
  size: [560, 300],
  anchor: { corner: "top-right", offset: [24, 24] },
}, () => {
  const [last, setLast] = useState("Hover, press, double-click, or right-click the button");
  const [level, setLevel] = useState(38);
  return (
    <column class="size-full p-5 gap-4 bg-slate-950 rounded-2xl border border-slate-700 shadow-xl">
      <column class="gap-1">
        <text class="text-xl font-semibold text-white">Native interaction states</text>
        <text class="text-sm text-slate-400">Visual swaps stay native; events report local and normalized coordinates</text>
      </column>
      <button
        class="w-full p-4 rounded-xl border border-indigo-500 bg-indigo-700 text-white shadow-sm hover:bg-indigo-600 hover:border-indigo-300 hover:opacity-90 hover:shadow-md pressed:bg-indigo-950 pressed:border-white pressed:opacity-70 pressed:shadow-[0_2px_4px_0_#00000066] pressed:shadow-inner"
        onPress={(event) => setLast(describe("press", event))}
        onDoublePress={(event) => setLast(describe("double", event))}
        onRightPress={(event) => setLast(describe("right", event))}
      >
        <text class="text-base font-semibold text-center pressed:text-indigo-200">Interactive surface</text>
      </button>
      <text class="text-sm font-mono text-slate-300">{last}</text>
      <column class="gap-2">
        <row class="justify-between">
          <text class="text-sm text-slate-400">Slider pressed state</text>
          <text class="text-sm tabular-nums text-white">{level}%</text>
        </row>
        <slider
          accessibilityLabel="Level"
          value={level}
          max={100}
          onChange={setLevel}
          class="w-full h-4 rounded-full bg-slate-800 pressed:bg-indigo-900 pressed:border-indigo-300 pressed:opacity-70 border border-slate-600"
        />
      </column>
    </column>
  );
});
