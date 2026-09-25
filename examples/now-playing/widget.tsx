import { useMediaTransport, useProvider, widget, type CanvasCtx } from "@weaver/sdk";

// System media: artwork, metadata, and transport. `media` is change-pushed
// (1 Hz position while playing), so the progress canvas redraws only when a
// frame arrives. Seeking uses the press event's normalized `u` coordinate.

function timestamp(ms: number): string {
  const seconds = Math.max(0, Math.floor(ms / 1000));
  return `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, "0")}`;
}

function drawProgress(ctx: CanvasCtx, fraction: number): void {
  ctx.clear();
  const radius = ctx.height / 2;
  ctx.fillRoundRect(0, 0, ctx.width, ctx.height, radius, "#ffffff1f");
  const width = Math.max(0, Math.min(1, fraction)) * ctx.width;
  if (width > 0) ctx.fillRoundRect(0, 0, Math.max(ctx.height, width), ctx.height, radius, "#f5f6f8");
}

export default widget({
  name: "Now Playing",
  size: [400, 132],
  anchor: { corner: "bottom-left", offset: [24, 24] },
  subscribe: ["media"],
  capabilities: ["media-transport"],
}, () => {
  const media = useProvider("media");
  const transport = useMediaTransport();
  const playing = media.status === "playing";
  const hasTrack = media.title.length > 0;
  const progress = media.durationMs > 0 ? media.positionMs / media.durationMs : 0;

  return (
    <row
      class="size-full p-[14px] gap-[14px] items-center border border-[#ffffff]/10 rounded-[28px]"
      background={[
        { type: "linear", stops: [{ offset: 0, color: "#0b0d12e6" }, { offset: 1, color: "#0b0d12e6" }] },
        { type: "linear", start: [0, 0], end: [0, 1], stops: [{ offset: 0, color: "#ffffff12" }, { offset: 0.6, color: "#ffffff00" }] },
      ]}
    >
      <stack class="size-[104px] shrink-0 rounded-[18px] overflow-hidden bg-[#ffffff]/6">
        {media.artPath
          ? <image src={media.artPath} fit="cover" class="size-full" />
          : (
            <column class="size-full items-center justify-center">
              <icon name="music" class="size-[30px] text-[#f5f6f8]/30" />
            </column>
          )}
      </stack>

      <column class="grow min-w-0 h-full justify-between py-[2px]">
        <column class="w-full gap-[2px]">
          <text class="w-full truncate text-[17px] leading-tight font-semibold text-[#f5f6f8]">{hasTrack ? media.title : "Nothing playing"}</text>
          <text class="w-full truncate text-[13px] text-[#f5f6f8]/55">{hasTrack ? (media.artist || media.album || "Unknown artist") : "Play something in any app"}</text>
        </column>

        <column class="w-full gap-[6px]">
          <stack class="w-full h-[14px]">
            <column class="size-full justify-center">
              <canvas class="w-[254px] h-[4px]" onFrame={(ctx) => drawProgress(ctx, progress)} />
            </column>
            <button
              accessibilityLabel="Seek"
              class="size-full bg-transparent"
              onPress={(event) => {
                if (media.durationMs <= 0) return;
                void transport.seek(Math.max(0, Math.min(1, event?.u ?? 0)) * media.durationMs);
              }}
            />
          </stack>
          <row class="w-full items-center justify-between">
            <row class="items-center gap-[2px]">
              <button
                accessibilityLabel="Previous"
                class="size-[30px] rounded-full items-center justify-center bg-transparent hover:bg-[#ffffff]/10 pressed:bg-[#ffffff]/16"
                onPress={() => { void transport.previous(); }}
              >
                <icon name="skip-back" class="size-[16px] text-[#f5f6f8]/80 pressed:text-[#f5f6f8]" />
              </button>
              <button
                accessibilityLabel={playing ? "Pause" : "Play"}
                class="size-[34px] rounded-full items-center justify-center bg-[#f5f6f8] hover:bg-[#ffffff] pressed:bg-[#d4d6db]"
                onPress={() => { void (playing ? transport.pause() : transport.play()); }}
              >
                {playing
                  ? <icon name="pause" class="size-[16px] text-[#0b0d12]" />
                  : <icon name="play" class="size-[16px] ml-[2px] text-[#0b0d12]" />}
              </button>
              <button
                accessibilityLabel="Next"
                class="size-[30px] rounded-full items-center justify-center bg-transparent hover:bg-[#ffffff]/10 pressed:bg-[#ffffff]/16"
                onPress={() => { void transport.next(); }}
              >
                <icon name="skip-forward" class="size-[16px] text-[#f5f6f8]/80 pressed:text-[#f5f6f8]" />
              </button>
            </row>
            <text class="text-[11px] tabular-nums text-[#f5f6f8]/45">
              {media.durationMs > 0 ? `${timestamp(media.positionMs)} / ${timestamp(media.durationMs)}` : media.sourceApp}
            </text>
          </row>
        </column>
      </column>
    </row>
  );
});
