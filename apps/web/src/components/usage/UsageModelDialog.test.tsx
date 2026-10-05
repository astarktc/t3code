import {
  EnvironmentId,
  UsageDay,
  USAGE_CONTRACT_VERSION,
  type UsageBucket,
  type UsageProviderKind,
  type UsageSummary,
} from "@t3tools/contracts";
import { mergeUsage } from "@t3tools/shared/usageMerge";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vite-plus/test";

import type { EnvironmentUsageStatus } from "../../state/usage";

const chart = vi.hoisted(() => ({ daily: [] as readonly { readonly costUsd: number }[] }));

vi.mock("../ui/dialog", () => ({
  Dialog: "div",
  DialogDescription: "div",
  DialogFooter: "div",
  DialogHeader: "div",
  DialogPanel: "div",
  DialogPopup: "div",
  DialogTitle: "div",
}));
vi.mock("./UsageProviderChart", () => ({
  UsageProviderChart: (props: { readonly daily: readonly { readonly costUsd: number }[] }) => {
    chart.daily = props.daily;
    return null;
  },
}));

import { UsageModelDialog } from "./UsageModelDialog";

function bucket(provider: UsageProviderKind, costUsd: number): UsageBucket {
  return {
    day: UsageDay.make("2026-08-11"),
    provider,
    model: "claude-opus-5-5",
    totals: {
      uncachedInputTokens: 100,
      cachedInputTokens: 0,
      cacheCreationTokens: 0,
      outputTokens: 0,
      reasoningTokens: 0,
    },
    costUsd,
    cacheSavingsUsd: 0,
    costSource: "providerReported",
    records: 1,
    unpricedRecords: 0,
    sessions: 1,
  };
}

const summary: UsageSummary = {
  contractVersion: USAGE_CONTRACT_VERSION,
  readAt: "2026-08-11T12:00:00.000Z",
  sinceDay: UsageDay.make("2026-08-11"),
  untilDay: UsageDay.make("2026-08-11"),
  timeZone: "UTC",
  buckets: [bucket("claude", 2), bucket("pi", 8)],
  sources: (["claude", "pi"] as const).map((provider) => ({
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
    distinctSessions: 1,
    message: null,
  })),
  pricing: { status: "fresh", source: "test", fetchedAt: null, knownModels: 1 },
  scanDurationMs: 1,
};

const environment: EnvironmentUsageStatus = {
  environmentId: EnvironmentId.make("test-environment"),
  label: "Test environment",
  isPending: false,
  canReadDiagnostics: true,
  isConnected: true,
  error: null,
  summary,
  needsCursorKeychainAccess: false,
};

describe("UsageModelDialog", () => {
  let renderer: Root;
  let container: HTMLDivElement;

  async function renderFamilyDialog(hiddenProviders: ReadonlySet<UsageProviderKind>) {
    const visible = {
      ...summary,
      buckets: summary.buckets.filter((entry) => !hiddenProviders.has(entry.provider)),
    };
    const model = mergeUsage(
      [{ environmentId: environment.environmentId, label: environment.label, summary: visible }],
      USAGE_CONTRACT_VERSION,
      "family",
    ).models[0]!;
    await act(() =>
      renderer.render(
        <UsageModelDialog
          model={model}
          groupBy="family"
          environments={[environment]}
          hiddenProviders={hiddenProviders}
          metric="cost"
          chartWindow={{
            days: ["2026-08-11"],
            hours: [],
            resolution: "day",
            timeZone: "UTC",
            referenceTime: undefined,
          }}
          onSetPrice={vi.fn()}
          onClose={vi.fn()}
        />,
      ),
    );
    return chart.daily.reduce((sum, day) => sum + day.costUsd, 0);
  }

  beforeEach(() => {
    vi.stubGlobal("IS_REACT_ACT_ENVIRONMENT", true);
    container = document.createElement("div");
    document.body.append(container);
    renderer = createRoot(container);
  });

  afterEach(async () => {
    await act(() => renderer.unmount());
    container.remove();
    vi.unstubAllGlobals();
  });

  it("charts a family row across every visible harness that ran the model", async () => {
    expect(await renderFamilyDialog(new Set())).toBe(10);
  });

  it("leaves providers filtered out of the page out of a family row's chart", async () => {
    expect(await renderFamilyDialog(new Set(["pi"]))).toBe(2);
  });
});

// @vitest-environment jsdom
