import { useProvider, widget } from "@weaver/sdk";
// Module-level probes: onFrame records the width it saw; the labels re-render only on time ticks.
let oneShotWidth = -1;
let displayWidth = -1;
export default widget({ name: "CP pair", size: [240, 90], anchor: { corner: "top-right", offset: [24, 24] }, subscribe: ["time"] }, () => {
  const time = useProvider("time");
  return (
    <column class="p-3 gap-3 bg-[#11141c]">
      <row class="w-full gap-2 items-center">
        <canvas class="w-0 grow h-[8px]" onFrame={(ctx) => { oneShotWidth = Math.round(ctx.width); ctx.clear(); ctx.fillRoundRect(0, 0, ctx.width, ctx.height, 3, "#5eead4"); }} />
        <text class="text-[11px] shrink-0">one w={oneShotWidth}</text>
      </row>
      <row class="w-full gap-2 items-center">
        <canvas class="w-0 grow h-[8px]" fps="display" onFrame={(ctx) => { displayWidth = Math.round(ctx.width); ctx.clear(); ctx.fillRoundRect(0, 0, ctx.width, ctx.height, 3, "#fb7185"); }} />
        <text class="text-[11px] shrink-0">disp w={displayWidth} s={time.ss}</text>
      </row>
    </column>
  );
});
