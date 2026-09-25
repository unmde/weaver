import { useProvider, useState, widget } from "@weaver/sdk";

export default widget({
  name: "Canvas Probe",
  size: [240, 80],
  anchor: { corner: "top-right", offset: [24, 24] },
  subscribe: ["time"],
}, () => {
  const time = useProvider("time");
  const [seen, setSeen] = useState("none");
  return (
    <column class="p-3 gap-3 bg-[#11141c]">
      <row class="w-full gap-2 items-center">
        <canvas class="w-[300px] shrink h-[8px]" onFrame={(ctx) => {
          ctx.clear();
          ctx.fillRoundRect(0, 0, ctx.width, ctx.height, 3, "#5eead4");
          const label = `w=${Math.round(ctx.width)}`;
          if (label !== seen) setSeen(label);
        }} />
        <text class="text-[11px] shrink-0">{seen} s={time.ss}</text>
      </row>
    </column>
  );
});
