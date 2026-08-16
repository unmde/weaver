import { useProviderSignal, widget, type TimeData } from "@weaver/sdk";

function hourMinute(value: TimeData): string {
  return `${value.hh}:${value.mm}`;
}

function seconds(value: TimeData): string {
  return value.ss;
}

function date(value: TimeData): string {
  return `${value.weekday}, ${value.month} ${value.day}`;
}

export default widget({
  name: "Myclock",
  size: [240, 110],
  anchor: { corner: "top-right", offset: [24, 24] },
  subscribe: ["time"],
}, () => {
  const time = useProviderSignal("time");
  const hourMinuteSignal = time.map(hourMinute);
  const secondsSignal = time.map(seconds);
  const dateSignal = time.map(date);
  return (
    <column class="p-4 gap-1 bg-[#11141c]/86 rounded-2xl">
      <row class="items-baseline gap-2">
        <text class="text-3xl font-light">{hourMinuteSignal}</text>
        <text class="text-sm opacity-70">{secondsSignal}</text>
      </row>
      <text class="text-xs opacity-60">{dateSignal}</text>
    </column>
  );
});
