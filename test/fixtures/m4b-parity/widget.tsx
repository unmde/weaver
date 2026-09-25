import { widget } from "@weaver/sdk";

const heights = [0.32, 0.58, 0.42, 0.76, 0.61, 0.88, 0.47, 0.69, 0.36, 0.82, 0.54, 0.73, 0.45, 0.91];

export default widget({
  name: "M4b Hybrid Parity",
  size: [480, 320],
  anchor: { corner: "top-left", offset: [24, 24] },
  layer: "desktop",
}, () => (
  <column class="w-[480px] h-[320px] p-4 gap-3 bg-[#10131c]/85 rounded-2xl">
    <row class="w-[448px] justify-between items-center">
      <text class="text-xs text-[#94a3b8] font-semibold">SPECTRUM {"\u00b7"} PARITY</text>
      <text class="text-xs text-[#64748b]">RETAINED + CANVAS</text>
    </row>
    <canvas
      class="w-[448px] h-[265px]"
      fps={0}
      onFrame={(ctx) => {
        ctx.clear();
        const gap = 8;
        const width = (ctx.width - gap * (heights.length - 1)) / heights.length;
        for (let index = 0; index < heights.length; index += 1) {
          const height = heights[index] * (ctx.height - 10);
          ctx.fillRoundRect(index * (width + gap), ctx.height - height, width, height, width / 2, index < 7 ? "#a78bfa" : "#4f7cff");
        }
      }}
    />
  </column>
));
