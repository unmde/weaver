import { widget } from "@weaver/sdk";

export default widget({
  name: "Styling Fonts",
  size: [420, 250],
  anchor: { corner: "top-right", offset: [24, 24] },
}, () => (
  <stack class="size-full pl-[30px] pt-[10px] pr-[30px] pb-[50px]">
  <column class="w-[360px] h-[190px] p-5 gap-3 bg-zinc-950 rounded-2xl shadow-xl">
    <text class="text-2xl text-emerald-300 font-[GeistPixel-Square] tracking-wide text-shadow-sm">BUNDLED PIXEL FACE</text>
    <text class="text-sm text-slate-200 font-sans">Built-in sans · weight ladder</text>
    <text class="text-sm text-amber-300 font-mono tabular-nums">Built-in mono 02:47:19</text>
    <panel class="w-full h-[1px] bg-slate-700" />
    <text class="text-[13px] text-slate-300 font-[GeistPixel-Square] font-bold leading-relaxed">A single custom face keeps its own outlines for every requested weight; add weight-suffixed files to select real variants.</text>
  </column>
  </stack>
));
