import { widget } from "@weaver/sdk";

export default widget({
  name: "Styling Stack",
  size: [420, 280],
  anchor: { corner: "top-right", offset: [24, 24] },
}, () => (
  <stack class="size-full pl-[30px] pt-[10px] pr-[30px] pb-[50px]">
  <column class="w-[360px] h-[220px] p-5 gap-3 bg-slate-950 rounded-2xl border border-slate-700 shadow-xl">
    <text class="text-xl font-semibold text-white">Overlay stack</text>
    <stack class="w-full grow overflow-hidden rounded-tl-3xl rounded-tr-lg rounded-br-2xl rounded-bl-md">
      <panel class="size-full bg-indigo-700 border border-indigo-400" />
      <panel class="w-[112px] h-full bg-fuchsia-500/70 self-end" />
      <column class="size-full p-4 justify-between">
        <text class="text-sm font-semibold text-white text-shadow-md">Children paint in order</text>
        <row class="w-full justify-between items-end">
          <text class="text-xs text-indigo-100">rounded clip</text>
          <icon name="layers" class="text-2xl text-white" />
        </row>
      </column>
    </stack>
  </column>
  </stack>
));
