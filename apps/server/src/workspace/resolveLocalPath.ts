// @effect-diagnostics nodeBuiltinImport:off
import type * as NodeFS from "node:fs";
import * as NodeFSP from "node:fs/promises";

import { isNetworkPath } from "@t3tools/shared/path";
import type * as Path from "effect/Path";

/** Links followed in one resolution before it fails as a loop, like Linux's MAXSYMLINKS. */
const MAX_LINKS = 40;

type LocalPathResolution =
  | {
      readonly _tag: "Local";
      readonly realPath: string;
      /** `null` when `allowMissing` met a missing entry. */
      readonly stat: NodeFS.Stats | null;
    }
  | { readonly _tag: "Network"; readonly target: string };

/**
 * A `realpath` that reads each link before following it, because touching a network path
 * makes Windows sign in to its host with the user's NTLM credentials. A network target is
 * followed only inside `workspaceRoot`. `from` must be a real directory.
 */
export async function resolveLocalPath(
  path: Path.Path,
  input: {
    readonly from: string;
    readonly segments: ReadonlyArray<string>;
    readonly workspaceRoot: string;
    /** A missing entry the caller named resolves with a null stat; one a link names still throws. */
    readonly allowMissing?: boolean;
  },
): Promise<LocalPathResolution> {
  const queue = input.segments.map((segment) => ({ segment, fromLink: false }));
  let current = input.from;
  let stat: NodeFS.Stats | undefined;
  let links = 0;
  for (let next = queue.shift(); next !== undefined; next = queue.shift()) {
    if (next.segment === "" || next.segment === ".") continue;
    if (next.segment === "..") {
      current = path.dirname(current);
      stat = undefined;
      continue;
    }
    const candidate = path.join(current, next.segment);
    const fromLink = next.fromLink;
    const entry = await NodeFSP.lstat(candidate).catch((error: NodeJS.ErrnoException) => {
      if (error.code === "ENOENT" && input.allowMissing === true && !fromLink) return null;
      throw error;
    });
    if (entry === null) {
      return {
        _tag: "Local",
        realPath: path.join(
          await canonicalSpelling(current),
          next.segment,
          ...queue.map((rest) => rest.segment),
        ),
        stat: null,
      };
    }
    if (!entry.isSymbolicLink()) {
      current = candidate;
      stat = entry;
      continue;
    }
    if (++links > MAX_LINKS) {
      throw Object.assign(new Error(`Too many symbolic links at '${candidate}'.`), {
        code: "ELOOP",
      });
    }
    const target = await NodeFSP.readlink(candidate);
    let rest = target;
    if (isNetworkPath(target)) {
      // Walk the resolved form: Windows reads a `\\?\` path as written, `..` included.
      const resolved = path.resolve(target);
      const relative = path.relative(input.workspaceRoot, resolved);
      if (relative === ".." || relative.startsWith(`..${path.sep}`) || path.isAbsolute(relative)) {
        return { _tag: "Network", target };
      }
      current = path.parse(resolved).root;
      rest = resolved.slice(current.length);
    } else if (path.isAbsolute(target)) {
      current = path.parse(target).root;
      rest = target.slice(current.length);
    }
    stat = undefined;
    queue.unshift(
      ...rest.split(path.sep === "\\" ? /[\\/]/ : "/").map((segment) => ({
        segment,
        fromLink: true,
      })),
    );
  }
  return {
    _tag: "Local",
    realPath: await canonicalSpelling(current),
    stat: stat ?? (await NodeFSP.lstat(current)),
  };
}

/**
 * `current` names no link by now, so native `realpath` follows nothing; it only restores the
 * on-disk spelling, which a case-insensitive volume does not keep. `.git` and loop checks
 * compare that spelling.
 */
const canonicalSpelling = (linkFreePath: string) => NodeFSP.realpath(linkFreePath);
