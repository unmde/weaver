import { useMediaTransport, useProvider, widget } from "@weaver/sdk";

// Pixel-faithful live port of noro-player (SunkenInTime/noro-player).
// Every dimension and color comes from the skin's Variables.inc.
const progressSegments = 24;

function elapsed(ms: number): string {
  const totalSeconds = Math.max(0, Math.floor(ms / 1000));
  return `${String(Math.floor(totalSeconds / 60)).padStart(2, "0")}:${String(totalSeconds % 60).padStart(2, "0")}`;
}

function clock(hourText: string, minuteText: string): string {
  const hour = Number(hourText);
  return `${String(hour % 12 || 12).padStart(2, "0")}:${minuteText} ${hour >= 12 ? "PM" : "AM"}`;
}

export default widget({
  name: "Noro Shell",
  size: [340, 356],
  anchor: { corner: "top-right", offset: [420, 32] },
  subscribe: ["time", "media"],
  capabilities: ["media-transport"],
}, () => {
  const time = useProvider("time");
  const media = useProvider("media");
  const transport = useMediaTransport();
  const playing = media.status === "playing";
  const progress = media.durationMs > 0 ? Math.max(0, Math.min(1, media.positionMs / media.durationMs)) : 0;
  const filledSegments = Math.round(progress * progressSegments);
  return (
    <stack class="size-full rounded-[51px] overflow-hidden">
      <column class="size-full bg-[#1a1a1a] rounded-[51px] border border-[#000000] shadow-[0_1px_2px_0_#ffffff1a] shadow-inner p-[14px]">
        <stack class="w-full h-[188px] rounded-t-[36px] rounded-b-[4px] overflow-hidden bg-[#000000] border border-[#000000]">
          {media.artPath
            ? <image src={media.artPath} fit="cover" class="size-full" />
            : <image src="./assets/cover.jpg" fit="cover" class="size-full" />}
          <image src="./assets/GridTile.png" tile class="size-full" />
          <image src="./assets/GrainTile.png" tile class="size-full opacity-20" />
          <column class="size-full justify-end">
            {/* The text row below sits on the bottom edge of the cover art, and
                the art can be any color — a white cover leaves white text on
                white. This is a baked ramp: 36px of flat 78% scrim under the row
                so it always reads, easing to nothing over the 56px above so the
                shadow rises into the art with no visible edge. Baked, not drawn,
                because this static ramp needs no frame clock and a stack of
                translucent panels would waste the retained-tree node budget. */}
            <image src="./assets/ArtShadow.png" fit="stretch" class="w-full h-[92px]" />
          </column>
          <column class="size-full pt-[22px] pr-[24px] items-end">
            {playing
              ? <panel class="w-[10px] h-[10px] rounded-full bg-[#ff3b30]/78" />
              : <panel class="w-[10px] h-[10px] bg-transparent" />}
          </column>
          <column class="size-full justify-end">
            <row class="w-full pl-[12px] pr-[2px] items-center gap-[4px]">
              <text class="w-[72px] text-[13px] text-[#ffffff] font-[Cozette-Subset]">{elapsed(media.positionMs)}</text>
              <text class="grow text-center truncate text-[13px] tracking-wide text-[#ffffff] font-[Cozette-Subset]">{media.title ? media.title.toUpperCase() : "OPEN PLAYER"}</text>
              <text class="w-[88px] text-right text-[13px] text-[#ffffff] font-[Cozette-Subset]">{clock(time.hh, time.mm)}</text>
            </row>
            <row class="w-full h-[3px] bg-[#ffffff]/5">
              {Array.from({ length: progressSegments }, (_, index) => (
                index < filledSegments
                  ? <panel class="w-[13px] h-full bg-[#ffffff]" />
                  : <panel class="w-[13px] h-full" />
              ))}
            </row>
          </column>
          <column class="size-full justify-end">
            <button
              accessibilityLabel="Seek"
              class="w-full h-[12px] bg-transparent"
              onPress={(event) => {
                if (media.durationMs <= 0) return;
                const normalized = Math.max(0, Math.min(1, event?.u ?? 0));
                void transport.seek(Math.round(normalized * media.durationMs));
              }}
            />
          </column>
        </stack>

        <stack class="w-full h-[24px] mt-[10px] rounded-[3px] overflow-hidden bg-[#1a1a1a] border border-[#000000]">
          <image src="./assets/GrilleTile.png" tile class="size-full opacity-5" />
        </stack>

        <row class="w-full mt-[4px] gap-[6px]">
          <button
            accessibilityLabel="Previous track"
            onPress={() => { void transport.previous(); }}
            class="w-[100px] h-[100px] items-center justify-center rounded-[8.33px] rounded-bl-[37.5px] bg-[#1a1a1a] border border-[#0a0a0a] shadow-[0_1px_2px_0_#ffffff0d] shadow-inner pressed:bg-[#141414] pressed:shadow-[0_2px_4px_0_#0000004d] pressed:shadow-inner"
          >
            <icon d="M 7 7 L 9.333 7 L 9.333 21 L 7 21 Z M 11.083 14 L 21 21 L 21 7 Z" viewBox="0 0 28 28" class="w-[28px] h-[28px] text-[#d0d0d0] pressed:text-[#b6b6b6]" />
          </button>
          <button
            accessibilityLabel={playing ? "Pause" : "Play"}
            onPress={() => { void (playing ? transport.pause() : transport.play()); }}
            class="w-[100px] h-[100px] items-center justify-center rounded-[8.33px] bg-[#1a1a1a] border border-[#0a0a0a] shadow-[0_1px_2px_0_#ffffff0d] shadow-inner pressed:bg-[#141414] pressed:shadow-[0_2px_4px_0_#0000004d] pressed:shadow-inner"
          >
            {playing
              ? <icon d="M 7 5.833 L 11.667 5.833 L 11.667 22.166 L 7 22.166 Z M 16.333 5.833 L 21 5.833 L 21 22.166 L 16.333 22.166 Z" viewBox="0 0 28 28" class="w-[28px] h-[28px] text-[#d0d0d0] pressed:text-[#b6b6b6]" />
              : <icon d="M 9.333 5.833 L 9.333 22.167 L 22.167 14 Z" viewBox="0 0 28 28" class="w-[28px] h-[28px] text-[#d0d0d0] pressed:text-[#b6b6b6]" />}
          </button>
          <button
            accessibilityLabel="Next track"
            onPress={() => { void transport.next(); }}
            class="w-[100px] h-[100px] items-center justify-center rounded-[8.33px] rounded-br-[37.5px] bg-[#1a1a1a] border border-[#0a0a0a] shadow-[0_1px_2px_0_#ffffff0d] shadow-inner pressed:bg-[#141414] pressed:shadow-[0_2px_4px_0_#0000004d] pressed:shadow-inner"
          >
            <icon d="M 7 21 L 16.917 14 L 7 7 Z M 18.667 7 L 21 7 L 21 21 L 18.667 21 Z" viewBox="0 0 28 28" class="w-[28px] h-[28px] text-[#d0d0d0] pressed:text-[#b6b6b6]" />
          </button>
        </row>
      </column>
      <image src="./assets/GrainTile.png" tile class="size-full opacity-5" />
    </stack>
  );
});
