/**
 * Usage history for Pi: the format of its session transcripts
 * (`<agentDir>/sessions/**.jsonl`) and where each instance's agent directory
 * keeps them.
 *
 * @module provider-pi/server/usage
 */

import type { UsageTokenTotals } from "@t3tools/contracts";
import * as Effect from "effect/Effect";
import * as Path from "effect/Path";
import * as Schema from "effect/Schema";

import { expandHomePath } from "@t3tools/provider-core/server/pathExpansion";
import {
  parseTimestampMs,
  tokenCount,
  totalTokens,
  type ProviderUsageReader,
  type TranscriptUsageFormat,
  type UsageRecord,
} from "@t3tools/provider-core/server/usage";

import type { PiSettings } from "../settings.ts";
import * as HostProcess from "@t3tools/shared/HostProcess";

/**
 * Rolling state for a single Pi session file.
 *
 * The session id lives on the leading `{"type":"session"}` line. `model`
 * tracks the session's active model, from `model_change` lines and from each
 * assistant message's own `model`. It attributes an assistant message that
 * carries no `model`, and the compaction and branch-summary entries, which run
 * on the active model and do not name it.
 *
 * Persisted in the scan cache at each resume point. The field order is the
 * stored JSON's, so keep it stable.
 */
export const PiScanState = Schema.Struct({
  model: Schema.mutableKey(Schema.String),
  sessionId: Schema.mutableKey(Schema.String),
});
export type PiScanState = typeof PiScanState.Type;

export function initialPiScanState(): PiScanState {
  return { model: "", sessionId: "" };
}

/**
 * Feeds one line of a Pi session transcript into `state`, returning a record
 * when the line carries usage. That is an assistant message, plus the entries
 * Pi counts in a session's totals without adding them to the conversation:
 * `usage` entries (e.g. `kind: "cache_warm"`; any kind counts, as Pi's session
 * format asks) and the `usage` of compaction and branch-summary entries.
 *
 * Pi writes exactly one complete `usage` object per assistant message (no
 * per-content-block repetition), with token counts that are mutually disjoint
 * (`totalTokens = input + cacheRead + cacheWrite + output`) and a
 * provider-reported USD `cost.total`. Forked/subagent sessions copy parent
 * messages into the child file with their original ids and timestamps, so the
 * dedupe key is the message id plus timestamp.
 */
export function parsePiLine(line: string, state: PiScanState): UsageRecord | null {
  let parsed: unknown;
  try {
    parsed = JSON.parse(line);
  } catch {
    return null;
  }
  return parsePiRecord(parsed, state);
}

function parsePiRecord(parsed: unknown, state: PiScanState): UsageRecord | null {
  if (typeof parsed !== "object" || parsed === null) return null;

  const record = parsed as Record<string, unknown>;
  const type = record["type"];

  if (type === "session") {
    // Only the first session line names this file's own session.
    if (state.sessionId.length === 0 && typeof record["id"] === "string") {
      state.sessionId = record["id"];
    }
    return null;
  }

  if (type === "model_change") {
    if (typeof record["modelId"] === "string") state.model = record["modelId"];
    return null;
  }

  // Usage outside assistant messages. A `usage` entry names its own model;
  // compaction and branch summaries run on the active model.
  if (type === "usage" || type === "compaction" || type === "branch_summary") {
    const ownModel = type === "usage" && typeof record["model"] === "string" ? record["model"] : "";
    return piUsageRecord(record, record["usage"], ownModel, state);
  }

  if (type !== "message") return null;

  const message = record["message"];
  if (typeof message !== "object" || message === null) return null;
  const messageRecord = message as Record<string, unknown>;
  if (messageRecord["role"] !== "assistant") return null;

  const ownModel = typeof messageRecord["model"] === "string" ? messageRecord["model"] : "";
  if (ownModel.length > 0) state.model = ownModel;
  return piUsageRecord(record, messageRecord["usage"], ownModel, state);
}

/** Builds the record for one Pi usage object; `entry` is its transcript line. */
function piUsageRecord(
  entry: Record<string, unknown>,
  usage: unknown,
  ownModel: string,
  state: PiScanState,
): UsageRecord | null {
  if (typeof usage !== "object" || usage === null) return null;
  const usageRecord = usage as Record<string, unknown>;

  const timestampMs = parseTimestampMs(entry["timestamp"]);
  if (timestampMs === null) return null;

  const model = ownModel.length > 0 ? ownModel : state.model;
  if (model.length === 0) return null;

  const outputTokens = tokenCount(usageRecord["output"]);
  const totals: UsageTokenTotals = {
    // Pi reports `input` exclusive of the cached portions.
    uncachedInputTokens: tokenCount(usageRecord["input"]),
    cachedInputTokens: tokenCount(usageRecord["cacheRead"]),
    cacheCreationTokens: tokenCount(usageRecord["cacheWrite"]),
    outputTokens,
    // Pi's optional `reasoning` is a subset of `output`, when the model reports it.
    reasoningTokens: Math.min(outputTokens, tokenCount(usageRecord["reasoning"])),
  };

  if (totalTokens(totals) === 0) return null;

  const cost = usageRecord["cost"];
  const costTotal =
    typeof cost === "object" && cost !== null
      ? (cost as Record<string, unknown>)["total"]
      : undefined;

  const entryId = typeof entry["id"] === "string" ? entry["id"] : null;

  return {
    provider: "pi",
    timestampMs,
    model,
    sessionId: state.sessionId,
    totals,
    // Pi writes 0 for models without rates, so a zero cost is unknown, not free.
    reportedCostUsd:
      typeof costTotal === "number" && Number.isFinite(costTotal) && costTotal > 0
        ? costTotal
        : null,
    // Pi's reported cost already reflects any tier the model ran in.
    speed: "standard",
    // Forked/subagent session files replay parent entries verbatim; id plus
    // timestamp drops those copies while staying unique across sessions.
    dedupeKey: entryId === null ? null : `pi:${entryId}:${timestampMs}`,
  };
}

const orEmpty = (record: UsageRecord | null): readonly UsageRecord[] =>
  record === null ? [] : [record];

export const piUsageFormat: TranscriptUsageFormat<PiScanState> = {
  // `id` names the session on a `session` line and the entry elsewhere;
  // `modelId` is the `model_change` model. Top-level `model` and `usage` belong
  // to `usage` entries (`usage` also to compaction and branch summaries, whose
  // lines carry the whole summary and can be large).
  selectFields: {
    type: true,
    id: true,
    timestamp: true,
    modelId: true,
    model: true,
    usage: true,
    message: { role: true, model: true, usage: true },
  },
  // Pi session and model_change lines carry no usage but feed the reducer
  // (session id, model fallback), so they must reach the parser.
  mightCarryUsage: (line) =>
    line.includes('"usage"') ||
    line.includes('"type":"session"') ||
    line.includes('"model_change"'),
  parseLine: (line, state) => orEmpty(parsePiLine(line, state)),
  parseProjected: (projected, state) => orEmpty(parsePiRecord(projected, state)),
  state: { initial: initialPiScanState, schema: PiScanState },
};

export const piUsageReader: ProviderUsageReader<PiSettings, Path.Path> = {
  kind: "transcripts",
  provider: "pi",
  format: piUsageFormat,
  directories: Effect.fn("piUsageReader.directories")(function* ({ environment }) {
    const path = yield* Path.Path;
    const homeDirectory = yield* HostProcess.HomeDirectory;
    // Pi exposes no home setting; resolution mirrors the CLI's own
    // (PI_CODING_AGENT_DIR, else ~/.pi/agent) off the instance environment.
    const home = expandHomePath(
      environment.PI_CODING_AGENT_DIR?.trim() || path.join(homeDirectory, ".pi", "agent"),
      homeDirectory,
    );
    return [{ dir: path.resolve(home, "sessions") }];
  }),
};
