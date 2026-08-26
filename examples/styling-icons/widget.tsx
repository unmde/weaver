import { widget } from "@weaver/sdk";

export default widget({
  name: "Styling Icons",
  size: [500, 350],
  anchor: { corner: "top-right", offset: [24, 24] },
}, () => (
  <stack class="size-full pl-[30px] pt-[10px] pr-[30px] pb-[50px]">
  <column class="w-[440px] h-[290px] p-5 gap-4 rounded-2xl bg-slate-950 border border-slate-700 shadow-xl">
    <row class="items-center gap-3">
      <icon name="audio-waveform" class="w-10 h-10 text-fuchsia-400" />
      <column>
        <text class="text-xl font-semibold text-white">Bundle-time vector icons</text>
        <text class="text-sm text-slate-400">Full Lucide catalog · tree-shaken M/L/C/Z paths</text>
      </column>
    </row>
    <row class="items-center justify-between p-4 rounded-xl bg-slate-800 border border-slate-700 shadow-sm">
      <icon name="radio-tower" class="w-4 h-4 text-cyan-300" />
      <icon name="badge-question-mark" class="w-6 h-6 text-emerald-300" />
      <icon name="disc-3" class="w-8 h-8 text-amber-300" />
      <icon name="wand-sparkles" class="w-10 h-10 text-violet-300" />
      <icon name="badge-check" class="w-8 h-8 text-rose-300" />
    </row>
    <row class="items-center justify-between p-4 rounded-xl bg-slate-900">
      <column class="items-center gap-2">
        <icon name="skip-back" class="w-6 h-6 text-cyan-400" />
        <text class="text-xs text-slate-400">named</text>
      </column>
      <column class="items-center gap-2">
        <icon d="M 7 7 L 9.333 7 L 9.333 21 L 7 21 Z M 11.083 14 L 21 21 L 21 7 Z" class="w-8 h-8 text-emerald-400" />
        <text class="text-xs text-slate-400">custom fill</text>
      </column>
      <column class="items-center gap-2">
        <icon d="m 4 12 h 16 m -8 -8 v 16" stroke={2} class="w-10 h-10 text-amber-400" />
        <text class="text-xs text-slate-400">custom stroke</text>
      </column>
      <column class="items-center gap-2">
        <icon name="volume-2" class="w-6 h-6 text-slate-200" />
        <text class="text-xs text-slate-400">currentColor</text>
      </column>
    </row>
  </column>
  </stack>
));
