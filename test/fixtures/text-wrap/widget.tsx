import { widget } from "@weaver/sdk";

// Regression fixture: labels sized exactly to their measured text, placed
// at fractional x positions by centering. Each <text> must lay out on one
// line. Render-time pixel snapping rounds each frame edge on its own and
// can shave up to a whole device pixel off such a frame; the wrap budget
// used to hand back only half of that, so "Start" painted as "Star" / "t".
// The chip row is sized with room to spare so no flex shrink applies:
// a row that overflows its container shrinks its children and wraps them
// legitimately.
export default widget({
  name: "Text Wrap",
  size: [300, 140],
}, () => (
  <column class="size-full p-[12px] gap-[8px] items-center bg-[#101010]">
    <row class="gap-[6px]">
      <row class="h-[28px] px-[12px] items-center bg-[#333333]"><text class="text-[11px] text-[#ffffff]">Focus</text></row>
      <row class="h-[28px] px-[12px] items-center bg-[#333333]"><text class="text-[11px] text-[#ffffff]">Short break</text></row>
      <row class="h-[28px] px-[12px] items-center bg-[#333333]"><text class="text-[11px] text-[#ffffff]">Long break</text></row>
    </row>
    <row class="w-[197px] h-[46px] bg-[#333333]">
      <row class="size-full items-center justify-center"><text class="text-[14px] font-semibold text-[#ffffff]">Start</text></row>
    </row>
    <row class="w-[183px] h-[30px] bg-[#333333]">
      <row class="size-full items-center justify-center"><text class="text-[11px] text-[#ffffff]">fixture</text></row>
    </row>
  </column>
));
