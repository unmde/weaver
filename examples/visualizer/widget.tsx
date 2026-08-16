import { useEffect, useProviderSignal, useState, widget, type AudioData } from "@weaver/sdk";

// A canvas gets no host GPU surface if any ancestor clips, or if a layer with
// opacity paints behind it. So: no overflow-hidden anywhere (each overlay image
// carries its own radius instead), and the well behind the meter is plain black.
// Same chassis as the noro-shell player: #1a1a1a body, black recessed well,
// Cozette pixel type, grain over everything, and one red accent. The meter is
// a segmented ladder built from the player's 13px progress-bar cell, so both
// widgets read as modules of one device.
const barCount = 24;
const cellCount = 14;
const cellHeight = 3;
const cellGap = 2;
const barGap = 2;
const barWidth = 11;
const segments = 24;

const levels = Array.from({ length: barCount }, () => 0);
const peaks = Array.from({ length: barCount }, () => 0);

function readout(rms: number): string {
  if (rms <= 0.0005) return "--";
  const db = Math.round(20 * Math.log10(rms));
  return `${db > 0 ? "+" : ""}${db} DB`;
}

function readoutValue(audio: AudioData): string {
  return readout(audio.rms);
}

function hasSignal(audio: AudioData): boolean {
  return audio.bands.some((value) => value > 0.002);
}

export default widget({
  name: "Visualizer",
  size: [340, 158],
  anchor: { corner: "top-right", offset: [420, 400] },
  layer: "desktop",
  subscribe: ["audio"],
}, () => {
  const [active, setActive] = useState(false);
  const audio = useProviderSignal("audio");
  useEffect(() => audio.subscribe((next) => {
    if (hasSignal(next)) setActive(true);
  }), [audio]);
  const readoutSignal = audio.map(readoutValue);
  return (
    <stack class="size-full rounded-[20px]">
      <column class="size-full bg-[#1a1a1a] rounded-[20px] border border-[#000000] shadow-[0_1px_2px_0_#ffffff1a] shadow-inner p-[14px]">
        <stack class="w-full h-[96px] rounded-t-[16px] rounded-b-[4px] bg-[#000000] border border-[#000000]">
          <column class="size-full">
            <canvas
              class="w-[312px] h-[75px]"
              fps={active ? 30 : 0}
              onFrame={(ctx, frame) => {
                const sample = audio.value;
                ctx.clear();
                // Integer point geometry remains pixel-aligned at every
                // integral backing scale, so solid cells stay direct Metal
                // quads instead of taking the antialiased raster fallback.
                const meterWidth = barCount * barWidth + (barCount - 1) * barGap;
                const meterX = Math.floor((ctx.width - meterWidth) / 2);
                const pitch = cellHeight + cellGap;
                const ladder = cellCount * pitch - cellGap;
                const base = ctx.height - (ctx.height - ladder) / 2;
                const dt = Math.min(frame.dt || 1 / 30, 0.08);
                // One solid bar each, then full-width separators carve the cells.
                // Drawing every cell individually would need barCount * cellCount
                // rects, over the 256-command frame budget.
                for (let index = 0; index < barCount; index += 1) {
                  const source = index * (sample.bands.length - 1) / (barCount - 1);
                  const lower = Math.floor(source);
                  const blend = source - lower;
                  const target = (sample.bands[lower] ?? 0) * (1 - blend) +
                    (sample.bands[Math.min(lower + 1, sample.bands.length - 1)] ?? 0) * blend;
                  const response = target > levels[index] ? 18 : 7;
                  levels[index] += (target - levels[index]) * (1 - Math.exp(-response * dt));
                  // Peak-hold falls far slower than the bar, the way a hardware
                  // meter parks its cap after a transient.
                  peaks[index] = Math.max(levels[index], peaks[index] - 0.22 * dt);
                  const x = meterX + index * (barWidth + barGap);
                  ctx.fillRect(x, base - ladder, barWidth, ladder, "#ffffff17");
                  const lit = Math.round(levels[index] * cellCount);
                  if (lit > 0) {
                    const height = (lit - 1) * pitch + cellHeight;
                    ctx.fillRect(x, base - height, barWidth, height, "#ffffffff");
                  }
                  const peakCell = Math.min(cellCount, Math.round(peaks[index] * cellCount)) - 1;
                  if (peakCell >= 0) {
                    ctx.fillRect(x, base - peakCell * pitch - cellHeight, barWidth, cellHeight, "#ff3b30c7");
                  }
                }
                for (let cell = 1; cell < cellCount; cell += 1) {
                  ctx.fillRect(0, base - cell * pitch, ctx.width, cellGap, "#000000ff");
                }
                // The RMS strip is drawn, not built from 24 panel nodes: the
                // widget profile caps one GPU frame packet at 64 KiB and node
                // count is what blows it.
                // dB, not linear: rms * 6 pegged the strip on anything loud.
                const level = sample.rms > 0.0005
                  ? Math.max(0, Math.min(1, (20 * Math.log10(sample.rms) + 48) / 48))
                  : 0;
                const lit = Math.round(level * segments);
                const stripWidth = segments * 13 - 1;
                const stripX = Math.floor((ctx.width - stripWidth) / 2);
                for (let index = 0; index < segments; index += 1) {
                  ctx.fillRect(stripX + index * 13, ctx.height - 3, 12, 3, index < lit ? "#ffffffff" : "#ffffff17");
                }
                if (!hasSignal(sample) && levels.every((value) => value < 0.008) && peaks.every((value) => value < 0.02)) {
                  setActive(false);
                }
              }}
            />
            <row class="w-full pl-[12px] pr-[2px] items-center gap-[4px] h-[22px]">
              <text class="grow text-[13px] tracking-wide text-[#ffffff] font-[Cozette-Subset]">SPECTRUM</text>
              <text class="w-[72px] text-right text-[13px] text-[#ffffff] font-[Cozette-Subset]">{readoutSignal}</text>
            </row>
          </column>
          <image src="./assets/GrainTile.png" tile class="size-full opacity-20 rounded-t-[16px] rounded-b-[4px]" />
        </stack>

        <stack class="w-full h-[24px] mt-[10px] rounded-[3px] bg-[#1a1a1a] border border-[#000000]">
          <image src="./assets/GrilleTile.png" tile class="size-full opacity-5 rounded-[3px]" />
        </stack>
      </column>
      <image src="./assets/GrainTile.png" tile class="size-full opacity-5 rounded-[20px]" />
    </stack>
  );
});
