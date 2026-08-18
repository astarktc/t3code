import * as NodeOS from "node:os";

import * as Effect from "effect/Effect";
import * as Path from "effect/Path";

import { expandHomePath } from "../../pathExpansion.ts";

/**
 * Resolves Pi's agent directory (session transcripts live under
 * `<agentDir>/sessions`).
 *
 * Pi has no home setting in `PiSettings`, so this mirrors the CLI's own
 * resolution: the `PI_CODING_AGENT_DIR` environment variable when set,
 * otherwise `~/.pi/agent`.
 */
export const resolvePiAgentDir = Effect.fn("resolvePiAgentDir")(function* (): Effect.fn.Return<
  string,
  never,
  Path.Path
> {
  const path = yield* Path.Path;
  const override = (process.env["PI_CODING_AGENT_DIR"] ?? "").trim();
  return path.resolve(
    override.length > 0 ? expandHomePath(override) : path.join(NodeOS.homedir(), ".pi", "agent"),
  );
});
