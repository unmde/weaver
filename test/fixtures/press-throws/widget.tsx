import { widget } from "@weaver/sdk";

// Capture regression fixture: the widget renders, but the Detonate button's
// handler throws, so a capture that clicks it must fail with
// CaptureWidgetFailed and carry this message in the receipt.
export default widget({ name: "Press Throws", size: [160, 60] }, () => (
  <column class="w-[160px] h-[60px] p-3 bg-[#11141c] rounded-xl">
    <button
      class="p-2 bg-[#7c3aed] rounded-lg items-center"
      onPress={() => {
        throw new Error("boom: deliberate press failure");
      }}
    >
      <text class="text-sm text-[#f8fafc]">Detonate</text>
    </button>
  </column>
));
