import { widget } from "@weaver/sdk";

export default widget({
  name: "Styling Shadows",
  size: [380, 250],
  anchor: { corner: "top-right", offset: [24, 24] },
}, () => (
  <stack class="size-full pl-[30px] pt-[10px] pr-[30px] pb-[50px]">
  <column class="w-[320px] h-[190px] p-5 gap-4 bg-zinc-900 rounded-2xl shadow-xl shadow-black/70">
    <text class="text-xl font-semibold text-white text-shadow-lg">Shadow breadth</text>
    <row class="w-full grow gap-4 items-center justify-around">
      <panel class="size-[72px] bg-sky-500 rounded-xl shadow-lg shadow-sky-950/70" />
      <panel class="size-[72px] bg-violet-500 rounded-xl shadow-inner shadow-violet-950/80" />
      <panel class="size-[72px] bg-amber-400 rounded-full shadow-[4px_6px_10px_-2px_#00000080]" />
    </row>
    <text class="w-full text-center text-sm text-slate-200 text-shadow-sm">outset · inset · arbitrary</text>
  </column>
  </stack>
));
