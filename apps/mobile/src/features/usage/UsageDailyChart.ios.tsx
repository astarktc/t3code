import { Chart, Host, type ChartDataPoint } from "@expo/ui/swift-ui";
import { frame } from "@expo/ui/swift-ui/modifiers";
import { useMemo } from "react";

import type { DailyTotals } from "@t3tools/shared/usageMerge";

import { buildChartDays, type UsageChartMetric } from "./usageChartData";
import type { UsageSeries } from "./usageProviders";

export interface UsageDailyChartProps {
  readonly days: readonly string[];
  readonly daily: readonly DailyTotals[];
  /** Stacked bottom first: harnesses or model families. */
  readonly series: readonly UsageSeries[];
  readonly metric: UsageChartMetric;
  readonly height: number;
}

/**
 * Native Swift Charts daily bars. Points sharing an x value stack, so emitting
 * one point per series per day yields per-series bands whose stack height
 * is the day's total; changes animate natively.
 *
 * Axes are hidden: 30-90 categorical day labels cannot fit on a phone, so the
 * screen renders its own edge labels under the chart instead.
 */
export function UsageDailyChart({ days, daily, series, metric, height }: UsageDailyChartProps) {
  const data = useMemo((): ChartDataPoint[] => {
    return buildChartDays(
      days,
      daily,
      metric,
      series.map((entry) => entry.key),
    ).flatMap((day) =>
      series.map((entry, index) => ({
        x: day.day,
        y: day.values[index]?.value ?? 0,
        color: entry.color,
      })),
    );
  }, [days, daily, metric, series]);

  return (
    <Host style={{ height, width: "100%" }}>
      <Chart
        type="bar"
        data={data}
        animate
        showGrid={false}
        barStyle={{ cornerRadius: 2 }}
        modifiers={[frame({ height })]}
      />
    </Host>
  );
}
