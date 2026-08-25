import { useStorage, widget } from "@weaver/sdk";

const dailyGoal = 8;

export default widget({
  name: "Tideglass",
  size: [380, 224],
  anchor: { corner: "bottom-right", offset: [24, 24] },
}, () => {
  const [glasses, setGlasses] = useStorage("glasses", 3);
  const remaining = dailyGoal - glasses;
  const percentage = Math.round((glasses / dailyGoal) * 100);

  return (
    <column class="size-full p-4 gap-3 bg-[#071b26]/96 rounded-3xl border border-[#164e63] shadow-[0_16px_36px_-12px_#020617cc]">
      <row class="w-full items-center justify-between">
        <column class="gap-1">
          <text class="text-xs font-semibold tracking-[2px] text-[#67e8f9]">TIDEGLASS</text>
          <text class="text-sm text-[#a5f3fc]">Daily hydration</text>
        </column>
        <column class="items-end">
          <text class="text-3xl font-light tabular-nums text-white">{percentage}%</text>
          <text class="text-xs text-[#6b9bab]">{remaining === 0 ? "goal reached" : `${remaining} to go`}</text>
        </column>
      </row>

      <stack class="w-full h-[74px] rounded-2xl overflow-hidden border border-[#155e75] bg-[#092c3a]">
        <panel class="w-full h-[74px] bg-[#083344]" />
        <column class="w-full h-[74px] px-3 py-3 justify-between">
          <row class="w-full justify-between items-center">
            {Array.from({ length: dailyGoal }, (_, index) =>
              index < glasses
                ? <panel class="size-[22px] rounded-full bg-[#22d3ee] border border-[#a5f3fc] shadow-[0_0_12px_0_#22d3ee88]" />
                : <panel class="size-[22px] rounded-full bg-[#0e3a4a] border border-[#26677a]" />
            )}
          </row>
          <row class="w-full justify-between">
            <text class="text-xs text-[#5eead4]">{glasses} glasses logged</text>
            <text class="text-xs text-[#6b9bab]">goal {dailyGoal}</text>
          </row>
        </column>
      </stack>

      <row class="w-full gap-2">
        <button
          accessibilityLabel="Undo glass"
          class="w-[94px] h-[42px] items-center justify-center rounded-xl border border-[#155e75] bg-[#0e3a4a] hover:bg-[#164e63] pressed:bg-[#071b26]"
          onPress={() => setGlasses((current) => Math.max(0, current - 1))}
        >
          <row class="items-center gap-2">
            <icon name="minus" class="size-[16px] text-[#a5f3fc]" />
            <text class="text-sm font-semibold text-[#a5f3fc]">Undo</text>
          </row>
        </button>
        <button
          accessibilityLabel="Log one glass"
          class="grow h-[42px] items-center justify-center rounded-xl border border-[#67e8f9] bg-[#0891b2] shadow-[0_6px_16px_-6px_#22d3eeaa] hover:bg-[#06b6d4] pressed:bg-[#0e7490]"
          onPress={() => setGlasses((current) => Math.min(dailyGoal, current + 1))}
        >
          <row class="items-center gap-2">
            <icon name="droplets" class="size-[17px] text-white" />
            <text class="text-sm font-semibold text-white">Log a glass</text>
          </row>
        </button>
      </row>
    </column>
  );
});
