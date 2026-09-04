import { widget } from "@weaver/sdk";

// Capture regression fixture: the first render throws, so `weaver capture`
// must fail with CaptureWidgetFailed and carry this message in the receipt.
export default widget({ name: "Render Throws", size: [100, 40] }, () => {
  throw new Error("boom: deliberate render failure");
});
