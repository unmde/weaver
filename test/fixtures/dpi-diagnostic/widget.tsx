import { useState, widget } from "@weaver/sdk";

// This fixture is deliberately edge-to-edge. Its four corner colors and the
// cyan retained/immediate seam make a one-pixel crop, strip, offset, or double
// scale visible to both a person and scripts/verify-dpi.ps1.
export default widget({
  name: "DPI Diagnostic",
  size: [480, 320],
  anchor: { corner: "top-left", offset: [48, 48] },
  layer: "normal",
}, () => {
  const [rightPressed, setRightPressed] = useState(false);
  const [bottomPressed, setBottomPressed] = useState(false);
  return (
    <column class="w-[480px] h-[320px] bg-[#182033]">
      <row class="w-[480px] h-[260px]">
        <canvas
          class="w-[420px] h-[260px]"
          fps={0}
          onFrame={(ctx) => {
            ctx.clear();
            ctx.fillRect(0, 0, ctx.width, 1, "#FF0055");
            ctx.fillRect(0, 0, 1, ctx.height, "#00FF66");
            ctx.fillRect(0, 0, 18, 18, "#FF0055");
            ctx.fillRoundRect(38, 34, 344, 162, 18, "#25314DCC");
            ctx.fillRect(70, 74, 280, 18, "#7C6DF4");
            ctx.fillRect(70, 108, 214, 18, "#4F7CFF");
            ctx.line(300, 174, ctx.width, 234, 6, "#00D9FF");
            ctx.fillRect(ctx.width - 1, 218, 1, 28, "#00D9FF");
          }}
        />
        <column class="w-[60px] h-[260px] bg-[#00A0FF]">
          {rightPressed ? (
            <button class="w-[60px] h-[260px] rounded-[1px] bg-[#FFFFFF] text-[#111827]" onPress={() => setRightPressed(true)}>
              <text class="text-xs font-bold">HIT</text>
            </button>
          ) : (
            <button class="w-[60px] h-[260px] rounded-[1px] bg-[#00A0FF] text-[#FFFFFF]" onPress={() => setRightPressed(true)}>
              <text class="text-xs font-bold">R</text>
            </button>
          )}
        </column>
      </row>
      <row class="w-[480px] h-[60px]">
        <column class="w-[420px] h-[60px] bg-[#FFD400]">
          {bottomPressed ? (
            <button class="w-[420px] h-[60px] rounded-[1px] bg-[#00FF66] text-[#111827]" onPress={() => setBottomPressed(true)}>
              <text class="text-xs font-bold">BOTTOM HIT</text>
            </button>
          ) : (
            <button class="w-[420px] h-[60px] rounded-[1px] bg-[#FFD400] text-[#111827]" onPress={() => setBottomPressed(true)}>
              <text class="text-xs font-bold">BOTTOM EDGE</text>
            </button>
          )}
        </column>
        <column class="w-[60px] h-[60px] bg-[#A855F7]">
          <button class="w-[60px] h-[60px] rounded-[1px] bg-[#A855F7] text-[#FFFFFF]" onPress={() => {}}>
            <text class="text-xs font-bold">C</text>
          </button>
        </column>
      </row>
    </column>
  );
});
