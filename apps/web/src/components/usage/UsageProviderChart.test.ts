import { describe, expect, it } from "vite-plus/test";

import { buildPeriodColumns } from "./UsageProviderChart";

describe("buildPeriodColumns", () => {
  const days = ["2026-08-01", "2026-08-02", "2026-08-03"];
  const byDay = new Map([
    [
      "2026-08-01",
      {
        day: "2026-08-01",
        costUsd: 35,
        totalTokens: 350,
        byProvider: new Map([
          ["codex" as const, { costUsd: 10, totalTokens: 100 }],
          ["claude" as const, { costUsd: 20, totalTokens: 200 }],
          ["pi" as const, { costUsd: 5, totalTokens: 50 }],
        ]),
        byFamily: new Map([
          ["anthropic" as const, { costUsd: 25, totalTokens: 250 }],
          ["openai" as const, { costUsd: 10, totalTokens: 100 }],
        ]),
      },
    ],
    [
      "2026-08-03",
      {
        day: "2026-08-03",
        costUsd: 5,
        totalTokens: 50,
        byProvider: new Map([["claude" as const, { costUsd: 5, totalTokens: 50 }]]),
        byFamily: new Map([["anthropic" as const, { costUsd: 5, totalTokens: 50 }]]),
      },
    ],
  ]);

  it("keeps band values absolute rather than cumulative", () => {
    const [first] = buildPeriodColumns(days, byDay, "cost");

    expect(first?.bands).toEqual([
      { key: "codex", value: 10 },
      { key: "claude", value: 20 },
      { key: "grok", value: 0 },
      { key: "cursor", value: 0 },
      { key: "opencode", value: 0 },
      { key: "antigravity", value: 0 },
      { key: "pi", value: 5 },
    ]);
  });

  it("plots model families from the same days when grouped by model", () => {
    const columns = buildPeriodColumns(days, byDay, "cost", "family");

    expect(columns.map((column) => column.total)).toEqual([35, 0, 5]);
    expect(columns[0]?.bands.filter((band) => band.value > 0)).toEqual([
      { key: "anthropic", value: 25 },
      { key: "openai", value: 10 },
    ]);
  });
});
