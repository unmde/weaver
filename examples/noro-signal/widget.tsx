import { useMediaTransport, useProvider, widget } from "@weaver/sdk";

const progressSegments = 18;

function timestamp(ms: number): string {
  const seconds = Math.max(0, Math.floor(ms / 1000));
  return `${String(Math.floor(seconds / 60)).padStart(2, "0")}:${String(seconds % 60).padStart(2, "0")}`;
}

export default widget({
  name: "Noro Signal",
  size: [430, 248],
  anchor: { corner: "top-right", offset: [24, 32] },
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
    <stack class="size-full rounded-[28px] overflow-hidden">
      <column class="size-full p-[16px] gap-[12px] rounded-[28px] bg-[#080c12]/96 border border-[#223044] shadow-[0_16px_40px_0_#00000080]">
        <row class="w-full grow gap-[16px]">
          <stack class="w-[150px] h-[150px] shrink-0 rounded-[18px] overflow-hidden bg-[#101923] border border-[#2a3c52] shadow-inner">
            {media.artPath
              ? <image src={media.artPath} fit="cover" class="size-full" />
              : (
                <column class="size-full p-[14px] justify-between bg-[#0b131c]">
                  <row class="w-full h-[70px] items-end gap-[5px]">
                    <panel class="w-[10px] h-[24px] rounded-full bg-[#38bdf8]" />
                    <panel class="w-[10px] h-[44px] rounded-full bg-[#22d3ee]" />
                    <panel class="w-[10px] h-[62px] rounded-full bg-[#a3e635]" />
                    <panel class="w-[10px] h-[36px] rounded-full bg-[#22d3ee]" />
                    <panel class="w-[10px] h-[52px] rounded-full bg-[#38bdf8]" />
                    <panel class="grow h-[1px] bg-[#2a3c52]" />
                  </row>
                  <column class="gap-[2px]">
                    <text class="text-[11px] tracking-widest text-[#67e8f9]">NORO SIGNAL</text>
                    <text class="text-[11px] text-[#64748b]">ARTWORK OFFLINE</text>
                  </column>
                </column>
              )}
            <column class="size-full p-[10px] items-end">
              {playing
                ? <panel class="w-[9px] h-[9px] rounded-full bg-[#a3e635] shadow-[0_0_10px_0_#a3e635]" />
                : <panel class="w-[9px] h-[9px] rounded-full bg-[#334155]" />}
            </column>
          </stack>

          <column class="grow min-w-0 h-[150px] justify-between">
            <row class="w-full items-center justify-between">
              <text class="text-[11px] tracking-widest text-[#38bdf8]">NOW / SIGNAL</text>
              <text class="text-[11px] tabular-nums text-[#64748b]">{time.hh}:{time.mm}</text>
            </row>

            <column class="w-full min-w-0 gap-[3px]">
              <text class="w-full truncate text-[26px] leading-tight font-semibold text-[#f8fafc]">{media.title || "Nothing playing"}</text>
              <text class="w-full truncate text-[13px] tracking-wide text-[#94a3b8]">{media.artist || "Unknown artist"}</text>
              <text class="w-full truncate text-[11px] text-[#526176]">{media.album || media.sourceApp || "Open a media app"}</text>
            </column>

            <stack class="w-full h-[20px]">
              <row class="size-full items-center gap-[4px]">
                {Array.from({ length: progressSegments }, (_, index) => (
                  index < filledSegments
                    ? <panel class="w-[8px] h-[5px] rounded-full bg-[#22d3ee]" />
                    : <panel class="w-[8px] h-[5px] rounded-full bg-[#1d2938]" />
                ))}
              </row>
              <button
                class="size-full bg-transparent"
                onPress={(event) => {
                  if (media.durationMs <= 0) return;
                  const normalized = Math.max(0, Math.min(1, event?.u ?? 0));
                  void transport.seek(Math.round(normalized * media.durationMs));
                }}
              />
            </stack>

            <row class="w-full items-center justify-between">
              <text class="text-[11px] tabular-nums text-[#cbd5e1]">{timestamp(media.positionMs)}</text>
              <text class="text-[11px] tracking-wide text-[#526176]">{media.sourceApp || "LOCAL"}</text>
              <text class="text-[11px] tabular-nums text-[#64748b]">-{timestamp(Math.max(0, media.durationMs - media.positionMs))}</text>
            </row>
          </column>
        </row>

        <row class="w-full h-[54px] items-center justify-between">
          <column class="gap-[2px]">
            <text class="text-[11px] tracking-widest text-[#a3e635]">{playing ? "TRANSMITTING" : "STANDBY"}</text>
            <text class="text-[10px] text-[#526176]">MEDIA TRANSPORT / READY</text>
          </column>

          <row class="h-full items-center gap-[8px]">
            <button
              class="w-[54px] h-[42px] items-center justify-center rounded-[12px] bg-[#101923] border border-[#2a3c52] pressed:bg-[#0b1119] pressed:border-[#38bdf8]"
              onPress={() => { void transport.previous(); }}
            >
              <text class="text-[10px] tracking-wide text-[#94a3b8] pressed:text-[#67e8f9]">PREV</text>
            </button>
            <button
              class="w-[70px] h-[48px] items-center justify-center rounded-[16px] bg-[#22d3ee] border border-[#67e8f9] shadow-[0_8px_20px_0_#0891b24d] pressed:bg-[#0e7490] pressed:border-[#a3e635]"
              onPress={() => { void (playing ? transport.pause() : transport.play()); }}
            >
              <text class="text-[11px] tracking-widest font-semibold text-[#071015] pressed:text-[#f8fafc]">{playing ? "PAUSE" : "PLAY"}</text>
            </button>
            <button
              class="w-[54px] h-[42px] items-center justify-center rounded-[12px] bg-[#101923] border border-[#2a3c52] pressed:bg-[#0b1119] pressed:border-[#38bdf8]"
              onPress={() => { void transport.next(); }}
            >
              <text class="text-[10px] tracking-wide text-[#94a3b8] pressed:text-[#67e8f9]">NEXT</text>
            </button>
          </row>
        </row>
      </column>
    </stack>
  );
});
