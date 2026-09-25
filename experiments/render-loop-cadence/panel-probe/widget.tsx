import { widget } from "@weaver/sdk";

export default widget({
  name: "Panel Probe",
  size: [200, 120],
  anchor: { corner: "top-right", offset: [24, 24] },
}, () => (
  <row class="p-2 gap-2 bg-[#11141c]">
    <panel class="w-[60px] h-[80px] items-center justify-center gap-[6px] bg-[#ffffff]/10 rounded-[8px]">
      <text class="text-[11px] leading-none">A</text>
      <text class="text-[17px] leading-none">1</text>
    </panel>
    <column class="w-[60px] h-[80px] items-center justify-center gap-[6px] bg-[#ffffff]/10 rounded-[8px]">
      <text class="text-[11px] leading-none">B</text>
      <text class="text-[17px] leading-none">2</text>
    </column>
    <panel class="w-[60px] h-[80px] items-center justify-center gap-[6px] bg-[#ffffff]/10 rounded-[8px]">
      <text class="text-[11px]">C</text>
      <text class="text-[17px]">3</text>
    </panel>
  </row>
));
