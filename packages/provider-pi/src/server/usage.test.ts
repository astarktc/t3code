import { describe, expect, it } from "@effect/vitest";

import { initialPiScanState, parsePiLine } from "./usage.ts";

/** Shaped after a real Pi session transcript. */
function piMessageLine(overrides: {
  messageId: string;
  model?: string | undefined;
  costTotal?: number | null;
  timestamp?: string;
}): string {
  const usage: Record<string, unknown> = {
    input: 2,
    output: 116,
    cacheRead: 42158,
    cacheWrite: 3757,
    totalTokens: 46033,
  };
  if (overrides.costTotal !== null) {
    usage["cost"] = {
      input: 0.00003,
      output: 0.00174,
      cacheRead: 0.0632,
      cacheWrite: 0.0704,
      total: overrides.costTotal ?? 0.123118,
    };
  }
  return JSON.stringify({
    type: "message",
    id: overrides.messageId,
    timestamp: overrides.timestamp ?? "2026-08-18T15:53:20.123Z",
    message: {
      role: "assistant",
      provider: "anthropic",
      model: overrides.model,
      usage,
    },
  });
}

describe("parsePiLine", () => {
  it("extracts token totals, reported cost, and the session id", () => {
    const state = initialPiScanState();
    expect(
      parsePiLine(
        JSON.stringify({
          type: "session",
          version: 3,
          id: "01a01593-a588-77be-8477-3642b7ce261e",
          timestamp: "2026-08-18T15:53:12.840Z",
          cwd: "/home/theo/project",
        }),
        state,
      ),
    ).toBeNull();

    const record = parsePiLine(
      piMessageLine({ messageId: "7b9d01d3", model: "claude-fable-5" }),
      state,
    );

    expect(record).not.toBeNull();
    expect(record?.provider).toBe("pi");
    expect(record?.model).toBe("claude-fable-5");
    expect(record?.sessionId).toBe("01a01593-a588-77be-8477-3642b7ce261e");
    // Pi reports `input` exclusive of the cached portions, so the fields map
    // across directly (totalTokens = input + cacheRead + cacheWrite + output).
    expect(record?.totals).toEqual({
      uncachedInputTokens: 2,
      cachedInputTokens: 42158,
      cacheCreationTokens: 3757,
      outputTokens: 116,
      reasoningTokens: 0,
    });
    expect(record?.reportedCostUsd).toBe(0.123118);
    expect(record?.dedupeKey).toBe("pi:7b9d01d3:1787068400123");
  });

  it("falls back to the model carried forward from model_change", () => {
    const state = initialPiScanState();
    expect(
      parsePiLine(
        JSON.stringify({
          type: "model_change",
          provider: "anthropic",
          modelId: "claude-fable-5",
        }),
        state,
      ),
    ).toBeNull();

    const record = parsePiLine(piMessageLine({ messageId: "aa11bb22", model: undefined }), state);

    expect(record?.model).toBe("claude-fable-5");
  });

  it("drops usage when no model is known at all", () => {
    const state = initialPiScanState();
    expect(
      parsePiLine(piMessageLine({ messageId: "aa11bb22", model: undefined }), state),
    ).toBeNull();
  });

  it("survives a missing cost object", () => {
    const state = initialPiScanState();
    const record = parsePiLine(
      piMessageLine({ messageId: "cc33dd44", model: "gpt-5.2-codex", costTotal: null }),
      state,
    );

    expect(record).not.toBeNull();
    expect(record?.reportedCostUsd).toBeNull();
  });

  it("gives a replayed fork copy the same dedupe key as the original", () => {
    // A forked/subagent session file replays parent messages verbatim (same
    // id, same timestamp), so the copies collapse in the aggregator's dedup.
    const parent = parsePiLine(
      piMessageLine({ messageId: "ee55ff66", model: "claude-fable-5" }),
      initialPiScanState(),
    );
    const forkCopy = parsePiLine(
      piMessageLine({ messageId: "ee55ff66", model: "claude-fable-5" }),
      initialPiScanState(),
    );

    expect(parent?.dedupeKey).not.toBeNull();
    expect(parent?.dedupeKey).toBe(forkCopy?.dedupeKey);
  });

  it("counts usage entries such as cache warming under their own model", () => {
    const state = initialPiScanState();
    parsePiLine(piMessageLine({ messageId: "aa11bb22", model: "claude-fable-5" }), state);

    const record = parsePiLine(
      JSON.stringify({
        type: "usage",
        id: "dfc910fe",
        parentId: "aa11bb22",
        timestamp: "2026-09-29T10:31:22.212Z",
        kind: "cache_warm",
        provider: "anthropic",
        model: "claude-opus-5-5",
        usage: {
          input: 2,
          output: 1,
          cacheRead: 359943,
          cacheWrite: 0,
          totalTokens: 359946,
          cost: {
            input: 0.000008,
            output: 0.00002,
            cacheRead: 0.0719886,
            cacheWrite: 0,
            total: 0.0720166,
          },
        },
      }),
      state,
    );

    expect(record?.model).toBe("claude-opus-5-5");
    expect(record?.totals.cachedInputTokens).toBe(359943);
    expect(record?.reportedCostUsd).toBe(0.0720166);
    expect(record?.dedupeKey).toBe("pi:dfc910fe:1790677882212");
  });

  it("attributes compaction and branch-summary usage to the active model", () => {
    const state = initialPiScanState();
    parsePiLine(
      JSON.stringify({ type: "model_change", provider: "anthropic", modelId: "claude-fable-5" }),
      state,
    );
    // The latest assistant message names the model that is actually running.
    parsePiLine(piMessageLine({ messageId: "aa11bb22", model: "claude-opus-5-5" }), state);

    const usage = {
      input: 51000,
      output: 2400,
      cacheRead: 0,
      cacheWrite: 0,
      cost: { total: 0.31 },
    };
    const compaction = parsePiLine(
      JSON.stringify({
        type: "compaction",
        id: "c0c0c0c0",
        timestamp: "2026-09-29T11:00:00.000Z",
        summary: "User discussed X, Y, Z...",
        firstKeptEntryId: "aa11bb22",
        tokensBefore: 180000,
        usage,
      }),
      state,
    );
    const branchSummary = parsePiLine(
      JSON.stringify({
        type: "branch_summary",
        id: "b5b5b5b5",
        timestamp: "2026-09-29T11:05:00.000Z",
        fromId: "aa11bb22",
        summary: "Branch explored approach A...",
        usage,
      }),
      state,
    );

    expect(compaction?.model).toBe("claude-opus-5-5");
    expect(compaction?.totals.uncachedInputTokens).toBe(51000);
    expect(compaction?.reportedCostUsd).toBe(0.31);
    expect(branchSummary?.model).toBe("claude-opus-5-5");
    expect(branchSummary?.dedupeKey).toBe("pi:b5b5b5b5:1790679900000");
  });

  it("ignores compaction entries without usage", () => {
    const state = initialPiScanState();
    parsePiLine(piMessageLine({ messageId: "aa11bb22", model: "claude-fable-5" }), state);
    expect(
      parsePiLine(
        JSON.stringify({
          type: "compaction",
          id: "c0c0c0c0",
          timestamp: "2026-09-29T11:00:00.000Z",
          summary: "Extension-provided summary",
          firstKeptEntryId: "aa11bb22",
          tokensBefore: 180000,
          fromHook: true,
        }),
        state,
      ),
    ).toBeNull();
  });

  it("ignores user messages and lines without usage", () => {
    const state = initialPiScanState();
    expect(
      parsePiLine(
        JSON.stringify({
          type: "message",
          id: "9988aabb",
          timestamp: "2026-08-18T15:53:20.123Z",
          message: { role: "user", content: "hello" },
        }),
        state,
      ),
    ).toBeNull();
  });
});
