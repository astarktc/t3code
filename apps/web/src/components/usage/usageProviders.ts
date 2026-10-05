import type { UsageProviderKind } from "@t3tools/contracts";
import type { UsageGroupBy, UsageGroupKey } from "@t3tools/shared/usageMerge";
import {
  MODEL_FAMILY_LABEL,
  MODEL_FAMILY_ORDER,
  type ModelFamily,
} from "@t3tools/shared/usageModelFamily";

import { ProviderDriverKind } from "@t3tools/contracts";

type UsageProviderPresentation = {
  readonly label: string;
  readonly color: string;
  readonly driverKind: ProviderDriverKind;
};

/**
 * Exhaustive presentation for providers supported by the usage contract.
 * Declaration order is reused by every chart and table, so adding a provider
 * only requires its contract support and one entry here.
 */
export const PROVIDER_PRESENTATION = {
  codex: {
    label: "Codex",
    color: "var(--contrast-foreground)",
    driverKind: ProviderDriverKind.make("codex"),
  },
  claude: {
    label: "Claude Code",
    color: "#d97757",
    driverKind: ProviderDriverKind.make("claudeAgent"),
  },
  grok: {
    label: "Grok Build",
    // Contrast-aware neutral between the Codex series and muted chart chrome.
    color: "color-mix(in oklab, var(--contrast-foreground) 72%, var(--background))",
    driverKind: ProviderDriverKind.make("grok"),
  },
  cursor: { label: "Cursor", color: "#8b8b8b", driverKind: ProviderDriverKind.make("cursor") },
  opencode: {
    label: "OpenCode",
    color: "#5b9bbd",
    driverKind: ProviderDriverKind.make("opencode"),
  },
  antigravity: {
    label: "Antigravity",
    color: "#8c7bd1",
    driverKind: ProviderDriverKind.make("antigravity"),
  },
  pi: {
    label: "Pi",
    // Emerald: distinct from Antigravity's lavender and the neutrals.
    color: "#10b981",
    driverKind: ProviderDriverKind.make("pi"),
  },
} satisfies Record<UsageProviderKind, UsageProviderPresentation>;

/** Stable provider reading order across charts, summaries, tables, and hover rows. */
export const PROVIDER_ORDER = Object.keys(PROVIDER_PRESENTATION) as UsageProviderKind[];

/**
 * Model families. Vendors behind a built-in harness reuse its mark and color;
 * the rest are a color dot only. Hues sit between the harness colors and
 * read in both themes.
 */
export const FAMILY_PRESENTATION = {
  anthropic: {
    color: PROVIDER_PRESENTATION.claude.color,
    driverKind: ProviderDriverKind.make("claudeAgent"),
  },
  openai: {
    color: PROVIDER_PRESENTATION.codex.color,
    driverKind: ProviderDriverKind.make("codex"),
  },
  google: { color: "#3b82f6", driverKind: ProviderDriverKind.make("antigravity") },
  xai: { color: PROVIDER_PRESENTATION.grok.color, driverKind: ProviderDriverKind.make("grok") },
  cursor: {
    color: PROVIDER_PRESENTATION.cursor.color,
    driverKind: ProviderDriverKind.make("cursor"),
  },
  meta: { color: "#0ea5e9" },
  moonshot: { color: "#ec4899" },
  zai: { color: "#a855f7" },
  deepseek: { color: "#6366f1" },
  xiaomi: { color: "#65a30d" },
  alibaba: { color: "#14b8a6" },
  mistral: { color: "#f59e0b" },
  unknown: { color: "color-mix(in oklab, var(--foreground) 35%, var(--background))" },
} satisfies Record<
  ModelFamily,
  { readonly color: string; readonly driverKind?: ProviderDriverKind }
>;

/** One row, chart series and table column of the current grouping. */
export interface UsageSeries {
  readonly key: UsageGroupKey;
  readonly label: string;
  readonly color: string;
  /** Brand mark. Families without a harness of their own have none. */
  readonly driverKind?: ProviderDriverKind;
}

const HARNESS_SERIES: readonly UsageSeries[] = PROVIDER_ORDER.map((provider) => ({
  key: provider,
  ...PROVIDER_PRESENTATION[provider],
}));

const FAMILY_SERIES: readonly UsageSeries[] = MODEL_FAMILY_ORDER.map((family) => ({
  key: family,
  label: MODEL_FAMILY_LABEL[family],
  ...FAMILY_PRESENTATION[family],
}));

/** Every series of a grouping, in its stable reading order. */
export function seriesFor(groupBy: UsageGroupBy): readonly UsageSeries[] {
  return groupBy === "family" ? FAMILY_SERIES : HARNESS_SERIES;
}

/** Series with real activity, independent of the metric currently displayed. */
export function seriesWithUsage(
  groups: readonly {
    readonly key: UsageGroupKey;
    readonly costUsd: number;
    readonly totalTokens: number;
  }[],
  groupBy: UsageGroupBy,
): readonly UsageSeries[] {
  const active = new Set(
    groups.filter((entry) => entry.totalTokens > 0 || entry.costUsd > 0).map((entry) => entry.key),
  );
  return seriesFor(groupBy).filter((series) => active.has(series.key));
}
