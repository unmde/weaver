import { widget } from "@weaver/sdk";

const barCount = 28;

const colors = Array.from({ length: barCount }, (_, index) => {
  const hue = index / (barCount - 1);
  const red = Math.round(90 + 55 * (1 - hue)).toString(16).padStart(2, "0");
  const blue = Math.round(190 + 55 * hue).toString(16).padStart(2, "0");
  return `#${red}78${blue}`;
});

export default widget({
  name: "M4b Mixed Synthetic",
  size: [480, 320],
  anchor: { corner: "top-left", offset: [24, 24] },
  layer: "desktop",
}, () => (
  <column class="w-[480px] h-[320px] p-4 gap-3 bg-[#10131c]/85 rounded-2xl">
    <row class="w-[448px] justify-between items-center">
      <text class="text-xs text-[#94a3b8] font-semibold">SPECTRUM · SYNTHETIC 60</text>
      <text class="text-xs text-[#64748b]">HYBRID</text>
    </row>
    <canvas
      class="w-[448px] h-[265px]"
      fps={60}
      onFrame={(ctx, frame) => {
        ctx.clear();
        const gap = 3;
        const width = (ctx.width - gap * (barCount - 1)) / barCount;
        const step = Math.floor(frame.t * 60);
        for (let index = 0; index < barCount; index += 1) {
          const phase = ((step * 7 + index * 37) % 97) / 96;
          const height = 8 + phase * (ctx.height - 8);
          ctx.fillRoundRect(index * (width + gap), ctx.height - height, width, height, width / 2, colors[index]);
        }
      }}
    />
  </column>
));
