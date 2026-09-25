import { useEffect, useInterval, useState, useStorage, wfetch, widget } from "@weaver/sdk";

// Declared-origin networking: the widget may only reach hosts listed in
// `origins`. Open-Meteo needs no API key. Change `place` to your city and
// `units` to "fahrenheit" if you prefer.

const place = { name: "San Francisco", latitude: 37.77, longitude: -122.42 };
const units: "celsius" | "fahrenheit" = "celsius";
const refreshMs = 15 * 60 * 1000;

interface Day { date: string; code: number; high: number; low: number }
interface Forecast {
  temperature: number;
  code: number;
  isDay: boolean;
  wind: number;
  humidity: number;
  days: Day[];
  fetchedAt: number;
}

const weekdays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];

// WMO weather interpretation codes, as returned by Open-Meteo.
function describe(code: number): string {
  if (code === 0) return "Clear";
  if (code <= 2) return "Partly cloudy";
  if (code === 3) return "Overcast";
  if (code <= 48) return "Fog";
  if (code <= 57) return "Drizzle";
  if (code <= 67) return "Rain";
  if (code <= 77) return "Snow";
  if (code <= 82) return "Showers";
  if (code <= 86) return "Snow showers";
  return "Thunderstorm";
}

type Sky = "sun" | "moon" | "cloud-sun" | "cloud-moon" | "cloud" | "cloud-fog" | "cloud-drizzle" | "cloud-rain" | "cloud-snow" | "cloud-lightning";

function skyFor(code: number, isDay: boolean): Sky {
  if (code === 0) return isDay ? "sun" : "moon";
  if (code <= 2) return isDay ? "cloud-sun" : "cloud-moon";
  if (code === 3) return "cloud";
  if (code <= 48) return "cloud-fog";
  if (code <= 57) return "cloud-drizzle";
  if (code <= 67 || (code >= 80 && code <= 82)) return "cloud-rain";
  if (code <= 86) return "cloud-snow";
  return "cloud-lightning";
}

// Icon names must be literals so `weaver check` can validate and embed only
// the referenced geometry, hence one branch per sky.
function skyIcon(sky: Sky, size: "large" | "small"): JSX.Element {
  const cls = size === "large" ? "size-[36px] text-[#ffffff]" : "size-[16px] text-[#ffffff]/85";
  switch (sky) {
    case "sun": return <icon name="sun" class={cls} />;
    case "moon": return <icon name="moon" class={cls} />;
    case "cloud-sun": return <icon name="cloud-sun" class={cls} />;
    case "cloud-moon": return <icon name="cloud-moon" class={cls} />;
    case "cloud": return <icon name="cloud" class={cls} />;
    case "cloud-fog": return <icon name="cloud-fog" class={cls} />;
    case "cloud-drizzle": return <icon name="cloud-drizzle" class={cls} />;
    case "cloud-rain": return <icon name="cloud-rain" class={cls} />;
    case "cloud-snow": return <icon name="cloud-snow" class={cls} />;
    case "cloud-lightning": return <icon name="cloud-lightning" class={cls} />;
  }
}

function weekday(date: string): string {
  return weekdays[new Date(`${date}T12:00:00`).getDay()] ?? date;
}

function number(value: unknown): number | null {
  return typeof value === "number" && Number.isFinite(value) ? value : null;
}

function parseForecast(payload: unknown): Forecast | null {
  if (typeof payload !== "object" || payload === null) return null;
  const current = (payload as { current?: Record<string, unknown> }).current;
  const daily = (payload as { daily?: Record<string, unknown[]> }).daily;
  if (!current || !daily) return null;
  const temperature = number(current.temperature_2m);
  const code = number(current.weather_code);
  if (temperature === null || code === null) return null;
  const dates = Array.isArray(daily.time) ? daily.time : [];
  const days: Day[] = [];
  for (let index = 0; index < dates.length; index += 1) {
    const dayCode = number(daily.weather_code?.[index]);
    const high = number(daily.temperature_2m_max?.[index]);
    const low = number(daily.temperature_2m_min?.[index]);
    if (typeof dates[index] !== "string" || dayCode === null || high === null || low === null) continue;
    days.push({ date: dates[index] as string, code: dayCode, high, low });
  }
  return {
    temperature,
    code,
    isDay: current.is_day !== 0,
    wind: number(current.wind_speed_10m) ?? 0,
    humidity: number(current.relative_humidity_2m) ?? 0,
    days,
    fetchedAt: Date.now(),
  };
}

function updatedAt(epochMs: number): string {
  const date = new Date(epochMs);
  return `${String(date.getHours()).padStart(2, "0")}:${String(date.getMinutes()).padStart(2, "0")}`;
}

export default widget({
  name: "Weather",
  size: [320, 212],
  anchor: { corner: "top-left", offset: [24, 244] },
  origins: ["api.open-meteo.com"],
}, () => {
  const [forecast, setForecast] = useStorage<Forecast | null>("forecast", null);
  const [status, setStatus] = useState<"loading" | "ok" | "error">("loading");

  const refresh = async () => {
    setStatus("loading");
    try {
      const response = await wfetch(
        `https://api.open-meteo.com/v1/forecast?latitude=${place.latitude}&longitude=${place.longitude}` +
        "&current=temperature_2m,relative_humidity_2m,weather_code,wind_speed_10m,is_day" +
        "&daily=weather_code,temperature_2m_max,temperature_2m_min" +
        `&timezone=auto&forecast_days=5&temperature_unit=${units}`,
      );
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      const parsed = parseForecast(await response.json());
      if (!parsed) throw new Error("unexpected payload");
      setForecast(parsed);
      setStatus("ok");
    } catch {
      setStatus("error");
    }
  };
  useEffect(() => { void refresh(); }, []);
  useInterval(() => { void refresh(); }, refreshMs);

  const today = forecast?.days[0];
  const footer = status === "error"
    ? "Couldn't reach api.open-meteo.com · retrying in 15 min"
    : forecast
      ? `Updated ${updatedAt(forecast.fetchedAt)}`
      : "Fetching forecast…";

  return (
    <column
      class="size-full px-[22px] py-[18px] justify-between border border-[#ffffff]/15 rounded-[28px]"
      background={[
        {
          type: "linear",
          start: [0, 0],
          end: [0.2, 1],
          interpolation: "oklab",
          stops: [{ offset: 0, color: "#4d7fe6" }, { offset: 1, color: "#172a5f" }],
        },
        {
          type: "radial",
          center: [0.1, 0],
          radius: [0.45, 0.6],
          stops: [{ offset: 0, color: "#ffb95c59" }, { offset: 1, color: "#ffb95c00" }],
        },
      ]}
    >
      <row class="w-full items-start justify-between">
        <column class="gap-[2px]">
          <text class="text-[13px] font-medium text-[#ffffff]/90">{place.name}</text>
          <text class="text-[12px] text-[#ffffff]/60">{forecast ? describe(forecast.code) : "—"}</text>
        </column>
        {forecast
          ? skyIcon(skyFor(forecast.code, forecast.isDay), "large")
          : <icon name="cloud-sun" class="size-[36px] text-[#ffffff]/40" />}
      </row>

      <row class="w-full items-end justify-between">
        <row class="items-start gap-[2px]">
          {forecast
            ? <text class="text-[54px] leading-none font-light tracking-[-2px] tabular-nums text-[#ffffff]">{Math.round(forecast.temperature)}</text>
            : <text class="text-[54px] leading-none font-light tracking-[-2px] text-[#ffffff]/35">--</text>}
          <text class="text-[26px] leading-none text-[#ffffff]/70">°</text>
        </row>
        <column class="items-end gap-[3px]">
          <text class="text-[12px] tabular-nums text-[#ffffff]/75">
            {today ? `H ${Math.round(today.high)}°  L ${Math.round(today.low)}°` : ""}
          </text>
          <text class="text-[11px] tabular-nums text-[#ffffff]/50">
            {forecast ? `${Math.round(forecast.wind)} km/h · ${Math.round(forecast.humidity)}% humidity` : ""}
          </text>
        </column>
      </row>

      <row class="w-full justify-between">
        {(forecast?.days ?? [null, null, null, null, null]).slice(0, 5).map((day, index) => (
          <column class="w-[44px] items-center gap-[4px]">
            <text class="w-full text-center text-[10px] tracking-[1px] text-[#ffffff]/55">{day ? weekday(day.date).toUpperCase() : "—"}</text>
            {day
              ? skyIcon(skyFor(day.code, true), "small")
              : <icon name="cloud" class="size-[16px] text-[#ffffff]/25" />}
            <text class="w-full text-center text-[12px] tabular-nums text-[#ffffff]/85">{day ? `${Math.round(day.high)}°` : ""}</text>
          </column>
        ))}
      </row>

      <text class="text-[10px] text-[#ffffff]/45">{footer}</text>
    </column>
  );
});
