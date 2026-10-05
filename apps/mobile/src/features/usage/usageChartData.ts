/**
 * Shapes merged daily totals into the per-day series stacks both chart
 * implementations (Swift Charts on iOS, plain views elsewhere) render.
 *
 * @module usageChartData
 */
import type { DailyTotals, UsageGroupKey } from "@t3tools/shared/usageMerge";

export type UsageChartMetric = "cost" | "tokens";

export interface UsageChartDay {
  readonly day: string;
  /** In the requested series order, i.e. bottom of the stack first. */
  readonly values: readonly { readonly key: UsageGroupKey; readonly value: number }[];
  readonly total: number;
}

/** One entry per day in the window, zero-filled where nothing happened. */
export function buildChartDays(
  days: readonly string[],
  daily: readonly DailyTotals[],
  metric: UsageChartMetric,
  keys: readonly UsageGroupKey[],
): readonly UsageChartDay[] {
  const byDay = new Map(daily.map((totals) => [totals.day, totals]));
  return days.map((day) => {
    const totals = byDay.get(day);
    const values = keys.map((key) => {
      const entry = totals?.byGroup.get(key);
      const value = entry === undefined ? 0 : metric === "cost" ? entry.costUsd : entry.totalTokens;
      return { key, value };
    });
    return {
      day,
      values,
      total: values.reduce((sum, entry) => sum + entry.value, 0),
    };
  });
}
