import { widget, type MeshPatch } from "@weaver/sdk";

const meshPatch: MeshPatch = {
  points: [
    [0, 0], [0.33, 0], [0.67, 0], [1, 0],
    [0, 0.33], [0.28, 0.20], [0.72, 0.42], [1, 0.33],
    [0, 0.67], [0.28, 0.80], [0.72, 0.58], [1, 0.67],
    [0, 1], [0.33, 1], [0.67, 1], [1, 1],
  ],
  colors: ["#FF3D81", "#28C8FF", "#7B45FF", "#FFB52E"],
};

export default widget({
  name: "Gradient Stack",
  size: [760, 460],
  anchor: { corner: "top-right", offset: [24, 24] },
}, () => (
  <column class="size-full p-6 gap-4 bg-zinc-950 rounded-3xl overflow-hidden">
    <column class="gap-1">
      <text class="text-2xl font-semibold text-white">Native gradient stack</text>
      <text class="text-sm text-zinc-400">linear · radial · conic · repeating · layered · bicubic mesh</text>
    </column>

    <row class="w-full grow gap-4">
      <column class="w-[220px] h-full gap-4">
        <panel
          class="w-full grow p-4 rounded-2xl"
          background={{
            type: "linear",
            start: [0, 0],
            end: [1, 1],
            interpolation: "oklab",
            stops: [
              { offset: 0, color: "cyan-400" },
              { offset: 0.48, color: "violet-500" },
              { offset: 1, color: "fuchsia-500" },
            ],
          }}
        >
          <text class="text-lg font-semibold text-white text-shadow-md">Linear / Oklab</text>
        </panel>
        <panel
          class="w-full grow p-4 rounded-2xl"
          background={{
            type: "conic",
            center: [0.5, 0.5],
            from: -35,
            interpolation: "srgb-linear",
            stops: [
              { offset: 0, color: "#FF4D6D" },
              { offset: 0.33, color: "#FFE66D" },
              { offset: 0.66, color: "#4D96FF" },
              { offset: 1, color: "#FF4D6D" },
            ],
          }}
        >
          <text class="text-lg font-semibold text-white text-shadow-md">Conic</text>
        </panel>
      </column>

      <column class="w-[220px] h-full gap-4">
        <panel
          class="w-full grow p-4 rounded-2xl"
          background={{
            type: "radial",
            center: [0.30, 0.25],
            radius: [0.80, 0.65],
            interpolation: "oklab",
            stops: [
              { offset: 0, color: "#FFFFFFE8" },
              { offset: 0.22, color: "sky-400" },
              { offset: 1, color: "indigo-950" },
            ],
          }}
        >
          <text class="text-lg font-semibold text-white text-shadow-md">Radial / ellipse</text>
        </panel>
        <panel class="w-full grow p-4 rounded-2xl bg-repeating-linear-to-r from-amber-400 from-0% via-rose-500 via-25% to-amber-400 to-50%">
          <text class="text-lg font-semibold text-white text-shadow-md">Repeating</text>
        </panel>
      </column>

      <column class="grow h-full gap-4">
        <panel
          class="w-full grow p-4 rounded-2xl"
          background={[
            {
              type: "linear",
              start: [0, 1],
              end: [1, 0],
              interpolation: "oklab",
              stops: [
                { offset: 0, color: "#10163B" },
                { offset: 1, color: "#7028E4" },
              ],
            },
            {
              type: "radial",
              center: [0.22, 0.18],
              radius: [0.62, 0.72],
              stops: [
                { offset: 0, color: "#4DF4FFCC" },
                { offset: 1, color: "#4DF4FF00" },
              ],
            },
          ]}
        >
          <text class="text-lg font-semibold text-white text-shadow-md">Layered painter order</text>
        </panel>
        <panel
          class="w-full grow p-4 rounded-2xl"
          background={{ type: "mesh", interpolation: "oklab", patches: [meshPatch] }}
        >
          <text class="text-lg font-semibold text-white text-shadow-md">Bicubic mesh</text>
        </panel>
      </column>
    </row>
  </column>
));
