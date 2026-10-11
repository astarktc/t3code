import {
  EnvironmentId,
  UsageDay,
  USAGE_CONTRACT_VERSION,
  type UsageBucket,
  type UsageSummary,
} from "@t3tools/contracts";
import { mergeUsage } from "@t3tools/shared/usageMerge";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vite-plus/test";

const testState = vi.hoisted(() => ({
  useUsage: vi.fn(),
  groupBy: "harness" as "harness" | "family",
  metric: "cost" as "cost" | "limits",
}));

vi.mock(import("@tanstack/react-router"), async (original) => ({
  ...(await original()),
  useNavigate: (() => vi.fn()) as never,
  useCanGoBack: () => true,
}));
vi.mock(import("../../state/usage"), async (original) => ({
  ...(await original()),
  useUsage: testState.useUsage,
}));
vi.mock(import("./usagePagePreferences"), async (original) => {
  const actual = await original();
  return {
    ...actual,
    readUsagePagePreferences: () => ({
      ...actual.readUsagePagePreferences(),
      metric: testState.metric,
      windowDays: 30,
      groupBy: testState.groupBy,
    }),
    saveUsagePagePreferences: vi.fn(),
  };
});

import { UsagePage } from "./UsagePage";
import type { UsageGroupBy } from "./usageProviders";

function bucket(overrides: Partial<UsageBucket>): UsageBucket {
  return {
    day: UsageDay.make("2026-08-11"),
    provider: "claude",
    model: "claude-opus-5-5",
    totals: {
      uncachedInputTokens: 100,
      cachedInputTokens: 0,
      cacheCreationTokens: 0,
      outputTokens: 0,
      reasoningTokens: 0,
    },
    costUsd: 10,
    cacheSavingsUsd: 0,
    costSource: "modelPriced",
    records: 2,
    unpricedRecords: 0,
    sessions: 1,
    ...overrides,
  };
}

const summary: UsageSummary = {
  contractVersion: USAGE_CONTRACT_VERSION,
  readAt: "2026-08-11T12:37:00.000Z",
  sinceDay: UsageDay.make("2026-08-10"),
  untilDay: UsageDay.make("2026-08-11"),
  timeZone: "UTC",
  buckets: [
    bucket({}),
    bucket({ provider: "codex", model: "claude-opus-5-5" }),
    bucket({ provider: "codex", model: "gpt-6-1-sol", records: 1 }),
  ],
  sources: (["claude", "codex"] as const).map((provider) => ({
    fingerprint: {
      hostId: "host",
      provider,
      resolvedHomePath: `/home/${provider}`,
      volumeId: "1:1",
    },
    status: "ok" as const,
    scannedFiles: 1,
    skippedFiles: 0,
    malformedRecords: 0,
    distinctSessions: 3,
    message: null,
  })),
  pricing: { status: "fresh", source: "test", fetchedAt: null, knownModels: 1 },
  scanDurationMs: 1,
};
const environments = [
  {
    environmentId: EnvironmentId.make("test-environment"),
    label: "Test environment",
    isPending: false,
    canReadDiagnostics: true,
    error: null,
    summary,
  },
];

describe("UsagePage grouping", () => {
  let renderer: Root;
  let container: HTMLDivElement;

  async function render(groupBy: UsageGroupBy, metric: "cost" | "limits" = "cost") {
    testState.groupBy = groupBy;
    testState.metric = metric;
    testState.useUsage.mockImplementation((window) => {
      const merged = mergeUsage(
        environments.map(({ environmentId, label }) => ({ environmentId, label, summary })),
        USAGE_CONTRACT_VERSION,
      );
      return {
        merged,
        environments,
        selectedEnvironments: environments,
        isPending: false,
        shown: { window, merged },
        isPartial: false,
        refresh: vi.fn(),
      };
    });
    await act(() => renderer.render(<UsagePage />));
    // Let the scroll area settle its measured layout inside act.
    await act(() => new Promise((resolve) => requestAnimationFrame(() => resolve(undefined))));
  }

  beforeEach(() => {
    vi.stubGlobal("IS_REACT_ACT_ENVIRONMENT", true);
    testState.useUsage.mockReset();
    container = document.createElement("div");
    document.body.append(container);
    renderer = createRoot(container);
  });

  // The page renders inside AppRouteModal, which portals to document.body.
  function pageText(): string {
    return document.querySelector("[data-app-modal]")?.textContent ?? "";
  }

  afterEach(async () => {
    await act(() => renderer.unmount());
    container.remove();
    vi.unstubAllGlobals();
  });

  it("keeps harness rows with their session counts by default", async () => {
    await render("harness");

    const text = pageText();
    expect(text).toContain("Claude Code");
    expect(text).toContain("3 sessions");
    expect(text).not.toContain("requests");
  });

  it("re-keys rows by model family with request counts", async () => {
    await render("family");

    const text = pageText();
    // Opus run by both harnesses lands in one Anthropic row.
    expect(text).toContain("Anthropic");
    expect(text).toContain("4 requests");
    expect(text).toContain("OpenAI");
    expect(text).toContain("1 request");
    expect(text).not.toContain("3 sessions");
  });

  // Header controls in document order: the wide toolbar, then the narrow one.
  function headerControls(): string[] {
    const labels = ["Group usage by", "Usage period", "Usage metric"];
    return [
      ...(document.querySelector("[data-app-modal]")?.querySelectorAll("[aria-label]") ?? []),
    ]
      .map((element) => element.getAttribute("aria-label") ?? "")
      .filter((label) => labels.includes(label));
  }

  it("puts Group by leftmost, before the period and the metric tabs", async () => {
    await render("family");

    expect(headerControls()).toEqual([
      "Group usage by",
      "Usage period",
      "Usage metric",
      "Group usage by",
      "Usage period",
      "Usage metric",
    ]);
  });

  it("drops Group by and the period on Limits, leaving the metric tabs in place", async () => {
    await render("family", "limits");

    expect(headerControls()).toEqual(["Usage metric", "Usage metric"]);
  });
});
