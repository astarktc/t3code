#!/usr/bin/env node
// Writes this host's canonical Pi model preferences into ~/.t3/userdata/settings.json
// (watched; no restart): favourites, visible rows, hidden ids, defaults. One set for all
// four hosts, Cortex included (QM-305). Idempotent; keeps other keys. Run: node model-prefs.mjs
// The set and its reasons: fork-infra/README.md "Host model preferences".

import * as NodeFS from "node:fs";
import * as NodeOS from "node:os";
import * as NodePath from "node:path";

const file = NodePath.join(NodeOS.homedir(), ".t3", "userdata", "settings.json");

const favorites = [
  "auto/opus-5-5",
  "auto/sonnet-5-5",
  "auto/haiku-5-5",
  "auto/gpt-6-astra",
  "auto/gpt-6.1-sol",
  "auto/gpt-6.1-terra",
  "auto/gpt-6-luna",
  "anthropic/claude-fable-5-1",
  "anthropic/claude-opus-5-5",
  "openai/gpt-6-astra",
  "openai/gpt-6.1-sol",
  "openai/gpt-6.1-terra",
  "openai/gpt-6-luna",
  "cortex/claude-opus-5-5",
  "cortex-responses/openai-gpt-6-astra",
  "cortex-responses/openai-gpt-6.1-sol",
  "cortex-responses/openai-gpt-6.1-terra",
  "cortex-responses/openai-gpt-6-luna",
];
const visibleOnly = [
  "anthropic/claude-sonnet-5-5",
  "anthropic/claude-haiku-5-5",
  "cortex/claude-sonnet-5-5",
  "cortex/claude-haiku-5-5",
];
const visible = [...favorites, ...visibleOnly];

// Ids known to appear in Pi's registered catalog on some host; hidden unless visible.
const knownIds = [
  "default",
  ...[
    "claude-fable-5",
    "claude-haiku-4-5",
    "claude-haiku-4-5-20251001",
    "claude-opus-4-5",
    "claude-opus-4-5-20251101",
    "claude-opus-4-6",
    "claude-opus-4-7",
    "claude-opus-4-8",
    "claude-sonnet-4-5",
    "claude-sonnet-4-5-20250929",
    "claude-sonnet-4-6",
    "claude-sonnet-5",
    "claude-opus-5",
  ].map((m) => `anthropic/${m}`),
  ...[
    "gpt-4",
    "gpt-4-turbo",
    "gpt-4.1",
    "gpt-4.1-mini",
    "gpt-4.1-nano",
    "gpt-4o",
    "gpt-4o-2024-05-13",
    "gpt-4o-2024-08-06",
    "gpt-4o-2024-11-20",
    "gpt-4o-mini",
    "gpt-5",
    "gpt-5-chat-latest",
    "gpt-5-mini",
    "gpt-5-nano",
    "gpt-5-pro",
    "gpt-5.1",
    "gpt-5.2",
    "gpt-5.2-chat-latest",
    "gpt-5.2-pro",
    "gpt-5.3-chat-latest",
    "gpt-5.3-codex",
    "gpt-5.3-codex-spark",
    "gpt-5.4",
    "gpt-5.4-mini",
    "gpt-5.4-nano",
    "gpt-5.4-pro",
    "gpt-5.5",
    "gpt-5.5-pro",
    "gpt-5.6-luna",
    "gpt-5.6-sol",
    "gpt-5.6-terra",
    "gpt-6-sol",
    "gpt-daybreak-blue-latest",
    "gpt-daybreak-red-latest",
    "gpt-realtime-2.1",
    "o1",
    "o1-pro",
    "o3",
    "o3-mini",
    "o3-pro",
    "o4-mini",
  ].map((m) => `openai/${m}`),
  ...[
    "gpt-5.3-codex-spark",
    "gpt-5.4",
    "gpt-5.4-mini",
    "gpt-5.5",
    "gpt-5.6-luna",
    "gpt-5.6-sol",
    "gpt-5.6-terra",
    "gpt-6-astra",
    "gpt-6-luna",
    "gpt-6-sol",
    "gpt-6.1-sol",
    "gpt-6.1-terra",
  ].map((m) => `openai-codex/${m}`),
  ...[
    "claude-opus-5-5",
    "claude-sonnet-5-5",
    "claude-haiku-5-5",
    "claude-sonnet-5",
    "claude-opus-5",
    "claude-fable-5",
    "claude-opus-4-8",
    "claude-opus-4-7",
    "claude-opus-4-6",
    "claude-sonnet-4-6",
    "claude-haiku-4-5",
  ].flatMap((m) => [`cortex/${m}`, `cortex-staging/${m}`]),
  ...[
    "openai-gpt-6-astra",
    "openai-gpt-6-sol",
    "openai-gpt-6-luna",
    "openai-gpt-6.1-sol",
    "openai-gpt-6.1-terra",
    "openai-gpt-5.6-sol",
    "openai-gpt-5.6-terra",
    "openai-gpt-5.6-luna",
    "openai-gpt-5.5",
    "openai-gpt-5.4",
    "openai-gpt-5.2",
  ].flatMap((m) => [`cortex-responses/${m}`, `cortex-responses-staging/${m}`]),
  ...["claude-opus-4-6", "claude-sonnet-4-6", "claude-haiku-4-5", "openai-gpt-5.2"].flatMap((m) => [
    `cortex-openai/${m}`,
    `cortex-openai-staging/${m}`,
  ]),
];

const settings = JSON.parse(NodeFS.readFileSync(file, "utf8"));
const prefs = settings.providerModelPreferences ?? {};
const pi = prefs.pi ?? { hiddenModels: [], modelOrder: [] };
const previouslyKnown = [...(pi.hiddenModels ?? []), ...(pi.modelOrder ?? [])];
const visibleSet = new Set(visible);
const hidden = [...new Set([...knownIds, ...previouslyKnown])]
  .filter((id) => !visibleSet.has(id))
  .sort();

settings.favorites = favorites.map((model) => ({ provider: "pi", model }));
settings.providerModelPreferences = {
  ...prefs,
  pi: { hiddenModels: hidden, modelOrder: [...visible, ...hidden] },
};
settings.textGenerationModelSelection = {
  instanceId: "pi",
  model: "openai/gpt-6-luna",
  options: [{ id: "thinking", value: "high" }],
};
// New threads start on Opus 5.5 (operator, 2026-10-30); the thinking level the host
// already had is kept, else high.
settings.defaultModelSelection = {
  instanceId: "pi",
  model: "anthropic/claude-opus-5-5",
  options: settings.defaultModelSelection?.options ?? [{ id: "thinking", value: "high" }],
};

NodeFS.writeFileSync(file, `${JSON.stringify(settings, null, 2)}\n`);
console.log(
  `${NodeOS.hostname()}: favorites=${favorites.length} visible=${visible.length} hidden=${hidden.length} textgen=openai/gpt-6-luna default=anthropic/claude-opus-5-5`,
);
