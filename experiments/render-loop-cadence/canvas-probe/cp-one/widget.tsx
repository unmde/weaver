import { useProvider, widget } from "@weaver/sdk";
let drawLog: string[] = [];
export default widget({ name: "CP one", size: [240, 70], anchor: { corner: "top-right", offset: [24, 24] }, subscribe: ["time"] }, () => {
  const time = useProvider("time");
  const history = drawLog.join(",");
  return (
    <column class="p-3 gap-2 bg-[#11141c]">
      <row class="w-full gap-2 items-center">
        <canvas class="w-0 grow h-[8px]" onFrame={(ctx) => { drawLog.push(String(Math.round(ctx.width))); ctx.clear(); ctx.fillRoundRect(0, 0, ctx.width, ctx.height, 3, "#5eead4"); }} />
        <text class="text-[11px] shrink-0">s={time.ss}</text>
      </row>
      <text class="text-[10px]">draws:{history}</text>
    </column>
  );
});
