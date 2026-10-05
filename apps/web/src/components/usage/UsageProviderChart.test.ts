import { describe, expect, it } from "vite-plus/test";

import { buildPeriodColumns, chartScale, niceScale } from "./UsageProviderChart";
import { PROVIDER_ORDER, seriesWithUsage } from "./usageProviders";

describe("chartScale", () => {
  const column = (codex: number) => ({
    total: codex,
    bands: [{ key: "codex" as const, value: codex, costUsd: 0, estimatedCostUsd: 0 }],
  });

  it("holds unlabeled placeholder gridlines while loading providers have nothing to show", () => {
    const scale = chartScale([column(0)], new Set(["codex" as const]));

    expect(scale.labeled).toBe(false);
    expect(scale.ticks.length).toBeGreaterThan(1);
  });

  it("scales to what is on screen, loading or not", () => {
    expect(chartScale([column(40)], new Set(["codex" as const]))).toMatchObject({
      max: 40,
      labeled: true,
    });
  });
});

describe("niceScale", () => {
  it("never puts the peak above the top of the scale", () => {
    // Regression: an earlier version stopped at the last step below the peak,
    // so the tallest day was drawn past the plot and clipped.
    for (const peak of [1122.71, 999, 1, 0.04, 1_400_000_000, 37.5, 5000, 100.001]) {
      const { max } = niceScale(peak, 4);
      expect(max, `peak ${peak}`).toBeGreaterThanOrEqual(peak);
    }
  });

  it("starts at zero and ends at the maximum", () => {
    const { max, ticks } = niceScale(1122.71, 4);

    expect(ticks[0]).toBe(0);
    expect(ticks[ticks.length - 1]).toBeCloseTo(max, 6);
  });

  it("uses evenly spaced 1/2/5 steps", () => {
    const { ticks } = niceScale(1122.71, 4);
    const steps = ticks.slice(1).map((tick, index) => tick - (ticks[index] ?? 0));

    for (const step of steps) expect(step).toBeCloseTo(steps[0] ?? 0, 6);
    const [first = 0] = steps;
    const normalized = first / 10 ** Math.floor(Math.log10(first));
    expect([1, 2, 5, 10]).toContain(Math.round(normalized));
  });

  it("keeps the tick count near the requested resolution", () => {
    const { ticks } = niceScale(1122.71, 4);
    expect(ticks.length).toBeGreaterThanOrEqual(3);
    expect(ticks.length).toBeLessThanOrEqual(7);
  });

  it("degrades to a single zero tick with no data", () => {
    expect(niceScale(0, 4)).toEqual({ max: 0, ticks: [0] });
  });
});

describe("buildPeriodColumns", () => {
  const days = ["2026-08-01", "2026-08-02", "2026-08-03"];
  const byDay = new Map([
    [
      "2026-08-01",
      {
        day: "2026-08-01",
        costUsd: 30,
        totalTokens: 300,
        byGroup: new Map([
          ["codex" as const, { costUsd: 10, totalTokens: 100, estimatedCostUsd: 10 }],
          ["claude" as const, { costUsd: 20, totalTokens: 200, estimatedCostUsd: 0 }],
        ]),
      },
    ],
    // 2026-08-02 is deliberately absent: a day with no activity.
    [
      "2026-08-03",
      {
        day: "2026-08-03",
        costUsd: 5,
        totalTokens: 50,
        byGroup: new Map([
          ["claude" as const, { costUsd: 5, totalTokens: 50, estimatedCostUsd: 0 }],
        ]),
      },
    ],
  ]);

  it("plots each day on its own", () => {
    expect(
      buildPeriodColumns(days, byDay, "cost", PROVIDER_ORDER).map((column) => column.total),
    ).toEqual([30, 0, 5]);
  });

  it("reads the requested metric", () => {
    expect(
      buildPeriodColumns(days, byDay, "tokens", PROVIDER_ORDER).map((column) => column.total),
    ).toEqual([300, 0, 50]);
  });

  it("keeps band values absolute rather than cumulative", () => {
    // Regression: the bands were once stack offsets, which drew Claude Code
    // permanently above Codex regardless of which provider spent more.
    const [first] = buildPeriodColumns(days, byDay, "cost", PROVIDER_ORDER);

    expect(first?.bands).toEqual([
      { key: "codex", value: 10, costUsd: 10, estimatedCostUsd: 10 },
      { key: "claude", value: 20, costUsd: 20, estimatedCostUsd: 0 },
      { key: "grok", value: 0, costUsd: 0, estimatedCostUsd: 0 },
      { key: "cursor", value: 0, costUsd: 0, estimatedCostUsd: 0 },
      { key: "opencode", value: 0, costUsd: 0, estimatedCostUsd: 0 },
      { key: "antigravity", value: 0, costUsd: 0, estimatedCostUsd: 0 },
      { key: "pi", value: 0, costUsd: 0, estimatedCostUsd: 0 },
    ]);
  });

  it("plots only the requested series, in their order", () => {
    const [first] = buildPeriodColumns(days, byDay, "cost", ["claude", "codex"]);

    expect(first?.bands.map((band) => band.key)).toEqual(["claude", "codex"]);
  });

  it("marks estimated cost only on the cost metric", () => {
    const [first] = buildPeriodColumns(days, byDay, "tokens", ["codex"]);

    expect(first?.bands).toEqual([{ key: "codex", value: 100, costUsd: 10, estimatedCostUsd: 0 }]);
  });

  it("reports the total as the sum of its bands", () => {
    for (const column of buildPeriodColumns(days, byDay, "cost", PROVIDER_ORDER)) {
      const sum = column.bands.reduce((running, band) => running + band.value, 0);
      expect(column.total).toBeCloseTo(sum, 9);
    }
  });
});

describe("seriesWithUsage", () => {
  it("omits providers with no cost or tokens", () => {
    expect(
      seriesWithUsage(
        [
          { key: "codex", costUsd: 0, totalTokens: 0 },
          { key: "claude", costUsd: 0, totalTokens: 200 },
        ],
        "harness",
      ).map((series) => series.key),
    ).toEqual(["claude"]);
  });

  it("orders families with unknown last and reuses harness marks where they exist", () => {
    const series = seriesWithUsage(
      [
        { key: "unknown", costUsd: 1, totalTokens: 10 },
        { key: "moonshot", costUsd: 2, totalTokens: 10 },
        { key: "anthropic", costUsd: 3, totalTokens: 10 },
        { key: "google", costUsd: 0, totalTokens: 0 },
      ],
      "family",
    );

    expect(series.map(({ key, label }) => [key, label])).toEqual([
      ["anthropic", "Anthropic"],
      ["moonshot", "Moonshot (Kimi)"],
      ["unknown", "Other / unknown"],
    ]);
    expect(series[0]?.driverKind).toBe("claudeAgent");
    expect(series[1]?.driverKind).toBeUndefined();
  });

  it("presents harness series exactly as the provider presentation", () => {
    const [codex] = seriesWithUsage([{ key: "codex", costUsd: 1, totalTokens: 1 }], "harness");

    expect(codex).toEqual({
      key: "codex",
      label: "Codex",
      color: "var(--contrast-foreground)",
      driverKind: "codex",
    });
  });
});

describe("hourly chart columns", () => {
  it("zero-fills inactive hours and preserves hourly provider values", () => {
    const byHour = new Map([
      [
        "2026-08-11T09:37:00.000Z",
        {
          day: "2026-08-11",
          hourStart: "2026-08-11T09:37:00.000Z",
          costUsd: 4,
          totalTokens: 40,
          byGroup: new Map([
            ["codex" as const, { costUsd: 4, totalTokens: 40, estimatedCostUsd: 0 }],
          ]),
        },
      ],
    ]);

    expect(
      buildPeriodColumns(
        ["2026-08-11T08:37:00.000Z", "2026-08-11T09:37:00.000Z", "2026-08-11T10:37:00.000Z"],
        byHour,
        "cost",
        PROVIDER_ORDER,
      ).map((column) => column.total),
    ).toEqual([0, 4, 0]);
  });
});
