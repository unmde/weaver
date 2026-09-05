import { useProvider, widget } from "@weaver/sdk";

// A canvas sized by layout, not by an explicit pixel width. The bar must paint
// at the laid-out width on the first capture frame (a fixed-clock capture
// dispatches nothing on its own) and must keep that width after the time
// provider re-renders the component.
export default widget({
  name: "Canvas Grow",
  size: [240, 70],
  anchor: { corner: "top-right", offset: [24, 24] },
  subscribe: ["time"],
}, () => {
  const time = useProvider("time");
  return (
    <column class="p-3 gap-2 bg-[#11141c]">
      <row class="w-full gap-2 items-center">
        <canvas class="w-0 grow h-[8px]" onFrame={(ctx) => {
          ctx.clear();
          ctx.fillRoundRect(0, 0, ctx.width, ctx.height, 3, "#5eead4");
        }} />
        <text class="text-[11px] shrink-0">{time.ss}</text>
      </row>
      <text class="text-[10px] text-[#f5f6f8]/60">grow canvas</text>
    </column>
  );
});
