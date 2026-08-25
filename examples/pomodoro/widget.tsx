import { useInterval, useStorage, widget } from "@weaver/sdk";

interface PomodoroState {
  minutes: number;
  remaining: number;
  running: boolean;
}

export default widget({
  name: "Pomodoro",
  size: [320, 210],
  anchor: { corner: "top-right", offset: [24, 158] },
}, () => {
  const [timer, setTimer] = useStorage<PomodoroState>("timer", {
    minutes: 25,
    remaining: 25 * 60,
    running: false,
  });

  useInterval(() => {
    if (!timer.running) return;
    setTimer((current) => {
      if (current.remaining <= 1) return { ...current, remaining: 0, running: false };
      return { ...current, remaining: current.remaining - 1 };
    });
  }, 1000);

  const shownMinutes = Math.floor(timer.remaining / 60);
  const shownSeconds = timer.remaining % 60;
  const clock = `${String(shownMinutes).padStart(2, "0")}:${String(shownSeconds).padStart(2, "0")}`;

  return (
    <column class="w-[320px] h-[210px] p-4 gap-3 bg-[#11141c]/92 rounded-2xl">
      <row class="w-[288px] items-center justify-between">
        <column class="gap-1">
          <text class="text-xs text-[#a78bfa] font-semibold">FOCUS TIMER</text>
          <text class="text-4xl text-[#f8fafc] font-light">{clock}</text>
        </column>
        <text class="text-sm text-[#94a3b8]">{timer.running ? "Focusing" : "Ready"}</text>
      </row>
      <column class="gap-2">
        <row class="w-[288px] justify-between">
          <text class="text-xs text-[#94a3b8]">Session length</text>
          <text class="text-xs text-[#e2e8f0]">{timer.minutes} min</text>
        </row>
        <slider
          accessibilityLabel="Session length"
          class="w-[288px] h-[24px]"
          value={timer.minutes}
          max={60}
          onChange={(minutes) => {
            const rounded = Math.max(5, Math.round(minutes));
            setTimer((current) => ({ ...current, minutes: rounded, remaining: current.running ? current.remaining : rounded * 60 }));
          }}
        />
      </column>
      <row class="w-[288px] gap-2">
        <button
          class="grow p-2 bg-[#7c3aed] rounded-lg items-center"
          onPress={() => setTimer((current) => ({ ...current, running: !current.running }))}
        >
          <text class="text-sm text-[#ffffff] font-semibold">{timer.running ? "Pause" : "Start"}</text>
        </button>
        <button
          class="p-2 bg-[#273244] rounded-lg items-center"
          onPress={() => setTimer((current) => ({ ...current, remaining: current.minutes * 60, running: false }))}
        >
          <text class="text-sm text-[#cbd5e1]">Reset</text>
        </button>
      </row>
    </column>
  );
});
