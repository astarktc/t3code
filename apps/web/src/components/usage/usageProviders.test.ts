import { describe, expect, it } from "vite-plus/test";

import { rankProvidersByMetric, rankSeriesByMetric, seriesFor } from "./usageProviders";

describe("rankProvidersByMetric", () => {
  it("ranks by the selected metric, highest first", () => {
    const totals = [
      { provider: "codex" as const, totalTokens: 100, costUsd: 20 },
      { provider: "claude" as const, totalTokens: 200, costUsd: 10 },
    ];
    const providers = ["codex", "claude"] as const;

    expect(rankProvidersByMetric(providers, totals, "tokens")).toEqual(["claude", "codex"]);
    expect(rankProvidersByMetric(providers, totals, "cost")).toEqual(["codex", "claude"]);
  });

  it("keeps ties in input order without reordering the shared provider list", () => {
    const totals = [
      { provider: "codex" as const, totalTokens: 10, costUsd: 1 },
      { provider: "claude" as const, totalTokens: 10, costUsd: 1 },
      { provider: "grok" as const, totalTokens: 20, costUsd: 2 },
    ];
    const providers = ["claude", "codex", "grok"] as const;

    expect(rankProvidersByMetric(providers, totals, "tokens")).toEqual(["grok", "claude", "codex"]);
    expect(providers).toEqual(["claude", "codex", "grok"]);
  });
});

describe("rankSeriesByMetric", () => {
  it("ranks model families by the selected metric, ties in reading order", () => {
    const totals = new Map([
      ["anthropic", { totalTokens: 100, costUsd: 30 }],
      ["openai", { totalTokens: 300, costUsd: 10 }],
      ["google", { totalTokens: 100, costUsd: 30 }],
    ]);
    const families = seriesFor("family").filter(({ key }) => totals.has(key));
    const ranked = (metric: "cost" | "tokens") =>
      rankSeriesByMetric(families, (key) => totals.get(key), metric).map(({ key }) => key);

    expect(ranked("tokens")).toEqual(["openai", "anthropic", "google"]);
    expect(ranked("cost")).toEqual(["anthropic", "google", "openai"]);
    expect(families.map(({ key }) => key)).toEqual(["anthropic", "openai", "google"]);
  });
});
