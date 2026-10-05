import type { UsageProviderKind } from "@t3tools/contracts";
import type { UsageGroupBy, UsageGroupKey } from "@t3tools/shared/usageMerge";
import {
  MODEL_FAMILY_LABEL,
  MODEL_FAMILY_ORDER,
  type ModelFamily,
} from "@t3tools/shared/usageModelFamily";

import { useAppearancePreferences } from "../settings/appearance/AppearancePreferencesProvider";

/**
 * Series and table order. The chart stacks providers from the bottom in this
 * order, so it also fixes which band sits on top of the bars.
 */
export const PROVIDER_ORDER: readonly UsageProviderKind[] = [
  "codex",
  "claude",
  "grok",
  "cursor",
  "opencode",
  "antigravity",
  "pi",
];

export const PROVIDER_LABEL: Record<UsageProviderKind, string> = {
  claude: "Claude Code",
  codex: "Codex",
  grok: "Grok Build",
  cursor: "Cursor",
  opencode: "OpenCode",
  antigravity: "Antigravity",
  pi: "Pi",
};

/**
 * Claude's brand orange holds in both themes; Codex and Grok are neutrals and
 * must flip with the theme or their bars vanish against the matching background.
 */
export function useProviderColors(): Record<UsageProviderKind, string> {
  const { themeAppearance: scheme } = useAppearancePreferences();
  return {
    claude: "#d97757",
    codex: scheme === "dark" ? "#e6e6e6" : "#3c3c43",
    grok: scheme === "dark" ? "#a1a1aa" : "#52525b",
    cursor: "#8b8b8b",
    opencode: "#5b9bbd",
    antigravity: "#8c7bd1",
    // Emerald holds in both themes and stays distinct from Antigravity's lavender.
    pi: "#10b981",
  };
}

/** Driver kind `ProviderIcon` draws for each harness. */
export const PROVIDER_ICON: Record<UsageProviderKind, string> = {
  claude: "claudeAgent",
  codex: "codex",
  grok: "grok",
  cursor: "cursor",
  opencode: "opencode",
  antigravity: "antigravity",
  pi: "pi",
};

/**
 * Family colors. Vendors behind a built-in harness keep its color, so
 * OpenAI and xAI flip with the theme like Codex and Grok; the other hues read
 * in both themes. Matches the web palette.
 */
function useFamilyColors(): Record<ModelFamily, string> {
  const providerColors = useProviderColors();
  const { themeAppearance: scheme } = useAppearancePreferences();
  return {
    anthropic: providerColors.claude,
    openai: providerColors.codex,
    google: "#3b82f6",
    xai: providerColors.grok,
    cursor: providerColors.cursor,
    meta: "#0ea5e9",
    moonshot: "#ec4899",
    zai: "#a855f7",
    deepseek: "#6366f1",
    xiaomi: "#65a30d",
    alibaba: "#14b8a6",
    mistral: "#f59e0b",
    unknown: scheme === "dark" ? "#5c5c5c" : "#b0b0b0",
  };
}

/** One row, chart band and legend entry of the current grouping. */
export interface UsageSeries {
  readonly key: UsageGroupKey;
  readonly label: string;
  readonly color: string;
}

/** Every series of a grouping, in stack and reading order. */
export function useUsageSeries(groupBy: UsageGroupBy): readonly UsageSeries[] {
  const providerColors = useProviderColors();
  const familyColors = useFamilyColors();
  return groupBy === "family"
    ? MODEL_FAMILY_ORDER.map((family) => ({
        key: family,
        label: MODEL_FAMILY_LABEL[family],
        color: familyColors[family],
      }))
    : PROVIDER_ORDER.map((provider) => ({
        key: provider,
        label: PROVIDER_LABEL[provider],
        color: providerColors[provider],
      }));
}

/**
 * Neutral steps for cost and token mixes, so they never borrow a provider's
 * color. Matches the web steps: oklab mixes of the codex ink into the
 * background, above the 15 ΔE separation floor for adjacent segments.
 */
export function useUsageMixColors() {
  const { themeAppearance: scheme } = useAppearancePreferences();
  const dark = scheme === "dark";
  return {
    input: dark ? "#737373" : "#848484",
    cacheRead: dark ? "#282828" : "#c0c0c0",
    cacheWrite: dark ? "#949494" : "#6d6d6d",
    output: dark ? "#e6e6e6" : "#3c3c43",
    other: dark ? "#494949" : "#a3a3a3",
    standard: dark ? "#313131" : "#b8b8b8",
    fast: dark ? "#838383" : "#797979",
    ultrafast: dark ? "#e6e6e6" : "#3c3c43",
  };
}
