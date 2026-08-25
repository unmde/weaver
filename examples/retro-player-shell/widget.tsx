import { widget } from "@weaver/sdk";

const noop = () => {};

export default widget({
  name: "Retro Player Shell",
  size: [760, 520],
  anchor: { corner: "top-right", offset: [32, 32] },
}, () => (
  <column class="size-full p-5 gap-4 bg-stone-900 rounded-tl-3xl rounded-tr-lg rounded-br-3xl rounded-bl-xl border-2 border-stone-600 shadow-xl">
    <row class="justify-between items-center">
      <column class="gap-1">
        <text class="text-xs tracking-widest text-amber-300 font-[GeistPixel-Square] text-shadow-sm">WEAVER HI-FI SYSTEM</text>
        <text class="text-sm text-stone-400 font-mono">MODEL WR-04 / STATIC SIGNAL</text>
      </column>
      <panel class="p-2 rounded-lg border border-amber-500 bg-black shadow-inner">
        <text class="text-sm tabular-nums tracking-wide text-amber-300 font-[GeistPixel-Square] text-shadow">10:24 PM</text>
      </panel>
    </row>

    <stack class="w-full grow overflow-hidden rounded-tl-3xl rounded-tr-md rounded-br-2xl rounded-bl-lg">
      <image src="./assets/night-bloom.jpg" fit="cover" class="size-full rounded-tl-3xl rounded-tr-md rounded-br-2xl rounded-bl-lg border-2 border-stone-500 shadow-lg" />
      <panel class="size-full bg-black/25" />
      <column class="size-full p-5 justify-between">
        <row class="justify-between items-start">
          <panel class="p-2 rounded-lg bg-black/65 border border-white/20 shadow-inner">
            <text class="text-xs tracking-widest text-stone-200 font-[GeistPixel-Square]">NIGHT BLOOM</text>
          </panel>
          <text class="text-sm tabular-nums text-white font-[GeistPixel-Square] text-shadow-md">03:18 / 05:42</text>
        </row>
        <column class="gap-2">
          <text class="text-3xl tracking-wide text-white font-[GeistPixel-Square] font-bold text-shadow-lg">SECOND NATURE</text>
          <text class="text-sm tracking-wider text-amber-200 font-[GeistPixel-Square] text-shadow-md">CHANNEL SURFING / SIDE A</text>
          <panel class="w-full h-2 rounded-full bg-black/70 border border-white/20 overflow-hidden">
            <panel class="w-1/2 h-full rounded-full bg-amber-400" />
          </panel>
        </column>
      </column>
    </stack>

    <image src="./assets/grille.png" tile class="w-full h-14 rounded-lg border border-stone-700 opacity-70" />

    <row class="gap-3 justify-center items-center">
      <button
        accessibilityLabel="Previous track"
        onPress={noop}
        class="size-14 p-3 items-center justify-center rounded-xl border-2 border-stone-600 bg-stone-800 text-stone-200 shadow-inner hover:bg-stone-700 hover:border-amber-500 pressed:bg-black pressed:text-amber-300 pressed:border-amber-200 pressed:opacity-70"
      >
        <icon name="skip-back" class="size-full" />
      </button>
      <button
        accessibilityLabel="Play"
        onPress={noop}
        class="size-16 p-4 items-center justify-center rounded-full border-2 border-amber-500 bg-amber-400 text-stone-950 shadow-inner hover:bg-amber-300 hover:border-amber-200 pressed:bg-amber-700 pressed:text-white pressed:border-white pressed:opacity-70"
      >
        <icon name="play" class="size-full" />
      </button>
      <button
        accessibilityLabel="Next track"
        onPress={noop}
        class="size-14 p-3 items-center justify-center rounded-xl border-2 border-stone-600 bg-stone-800 text-stone-200 shadow-inner hover:bg-stone-700 hover:border-amber-500 pressed:bg-black pressed:text-amber-300 pressed:border-amber-200 pressed:opacity-70"
      >
        <icon name="skip-forward" class="size-full" />
      </button>
    </row>
  </column>
));
