import { describe, expect, it } from "vite-plus/test";

import { buildChartDays } from "./usageChartData";

describe("buildChartDays", () => {
  const daily = [
    {
      day: "2026-08-01",
      costUsd: 30,
      totalTokens: 300,
      byGroup: new Map([
        ["anthropic" as const, { costUsd: 20, totalTokens: 100, estimatedCostUsd: 20 }],
        ["moonshot" as const, { costUsd: 10, totalTokens: 200, estimatedCostUsd: 0 }],
      ]),
    },
  ];

  it("stacks the requested series in order and zero-fills quiet days", () => {
    const days = buildChartDays(["2026-08-01", "2026-08-02"], daily, "cost", [
      "anthropic",
      "openai",
      "moonshot",
    ]);

    expect(days).toEqual([
      {
        day: "2026-08-01",
        values: [
          { key: "anthropic", value: 20 },
          { key: "openai", value: 0 },
          { key: "moonshot", value: 10 },
        ],
        total: 30,
      },
      {
        day: "2026-08-02",
        values: [
          { key: "anthropic", value: 0 },
          { key: "openai", value: 0 },
          { key: "moonshot", value: 0 },
        ],
        total: 0,
      },
    ]);
  });

  it("reads tokens for the tokens metric", () => {
    const [day] = buildChartDays(["2026-08-01"], daily, "tokens", ["moonshot", "anthropic"]);

    expect(day?.values).toEqual([
      { key: "moonshot", value: 200 },
      { key: "anthropic", value: 100 },
    ]);
  });
});
