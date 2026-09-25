import { widget } from "@weaver/sdk";

const draw = (ctx: any) => {
  ctx.clear();
  ctx.fillRoundRect(0, 0, ctx.width, ctx.height, 3, "#5eead4");
};

export default widget({
  name: "Canvas Probe",
  size: [200, 80],
  anchor: { corner: "top-right", offset: [24, 24] },
}, () => (
  <column class="p-3 gap-3 bg-[#11141c]">
    <row class="w-full gap-2 items-center">
      <canvas class="w-0 grow h-[8px]" onFrame={draw} />
      <text class="text-[11px]">grow</text>
    </row>
    <row class="w-full gap-2 items-center">
      <canvas class="w-[180px] h-[8px]" onFrame={draw} />
      <text class="text-[11px]">fixed</text>
    </row>
  </column>
));
