import { widget } from "@weaver/sdk";
// Positive control: display-rate grow canvas, nothing ever re-renders the component.
export default widget({ name: "CP display plain", size: [240, 80], anchor: { corner: "top-right", offset: [24, 24] } }, () => (
  <column class="p-3 gap-3 bg-[#11141c]">
    <row class="w-full gap-2 items-center">
      <canvas class="w-0 grow h-[8px]" fps="display" onFrame={(ctx) => { ctx.clear(); ctx.fillRoundRect(0, 0, ctx.width, ctx.height, 3, "#5eead4"); }} />
      <text class="text-[11px] shrink-0">static</text>
    </row>
  </column>
));
