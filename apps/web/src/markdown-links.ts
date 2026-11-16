import { isLocalEditorFileUrl } from "@t3tools/contracts";
import { fileBasename, isAbsolutePath, workspaceRelativeFilePath } from "@t3tools/shared/path";
import {
  inlineCodeFilePathCandidate,
  inlineCodeSpacedFilePathCandidate,
  isRelativeFilePath,
  normalizeMarkdownLinkDestination,
  parseMarkdownFileLink,
  resolveMarkdownFileLinkTarget,
} from "@t3tools/shared/markdownLinks";
import {
  formatFilePathPosition,
  parseFileUrlHref,
  resolvePathLinkTarget,
  splitFilePathPosition,
} from "@t3tools/shared/fileLinks";

import { formatWorkspaceRelativePath } from "./filePathDisplay";
import { isTerminalLinkActivation } from "./terminal-links";

export interface MarkdownFileLinkMeta {
  filePath: string;
  workspaceLookupPath: string | null;
  targetPath: string;
  displayPath: string;
  workspaceRelativePath: string | null;
  basename: string;
  line?: number;
  column?: number;
  endLine?: number;
}

export function shouldOpenMarkdownFileLinkInEditor(
  event: Pick<MouseEvent, "metaKey" | "ctrlKey">,
  platform?: string,
): boolean {
  return isTerminalLinkActivation(event, platform);
}

export function rewriteMarkdownFileUriHref(href: string | undefined): string | null {
  if (!href) return null;
  const target = parseFileUrlHref(normalizeMarkdownLinkDestination(href));
  return target ? `${target.path}${target.hash}` : null;
}

export function isLocalEditorFileHref(href: string): boolean {
  try {
    return isLocalEditorFileUrl(new URL(href));
  } catch {
    return false;
  }
}

export function resolveInlineCodeFileLinkMeta(
  codeText: string,
  cwd?: string,
  baseDir: string | undefined = cwd,
): MarkdownFileLinkMeta | null {
  const candidate = inlineCodeFilePathCandidate(codeText);
  if (candidate === null) return null;

  return resolveMarkdownFileLinkMeta(
    candidate,
    cwd,
    inlineCodePathNamesFromWorkspaceRoot(candidate, cwd, baseDir) ? cwd : baseDir,
  );
}

/**
 * Link it only once the host confirms `filePath` is a file; see inlineCodeSpacedFilePathCandidate.
 * Inline code holds a literal path, so `#`, `?` and `%` stay part of the name, unlike in a link
 * destination: `/bin/ls # notes.md` must be checked whole, never as `/bin/ls`.
 */
export function resolveSpacedInlineCodeFileLinkMeta(
  codeText: string,
  cwd?: string,
  baseDir: string | undefined = cwd,
): MarkdownFileLinkMeta | null {
  const candidate = inlineCodeSpacedFilePathCandidate(codeText);
  if (candidate === null) return null;
  if (isRelativeFilePath(candidate) && !baseDir) return null;
  const position = splitFilePathPosition(candidate);
  const targetPath = isRelativeFilePath(candidate)
    ? resolvePathLinkTarget(candidate, baseDir!)
    : formatFilePathPosition(position);
  return {
    ...buildFileLinkMetaFromTarget(targetPath, cwd),
    // The target keeps only the first line, so a `:12-18` range is carried here.
    ...(position.endLine !== undefined ? { endLine: position.endLine } : {}),
    workspaceLookupPath: null,
  };
}

function inlineCodePathNamesFromWorkspaceRoot(
  candidate: string,
  cwd: string | undefined,
  baseDir: string | undefined,
): boolean {
  if (!cwd || !baseDir || !isRelativeFilePath(candidate)) return false;
  if (/^(?:~|\.{1,2})\//.test(candidate)) return false;
  if (!splitFilePathPosition(candidate).path.includes("/")) return false;
  return workspaceRelativeFilePath(baseDir, cwd) !== null;
}

export function resolveMarkdownFileLinkMeta(
  href: string | undefined,
  cwd?: string,
  baseDir: string | undefined = cwd,
): MarkdownFileLinkMeta | null {
  const targetPath = resolveMarkdownFileLinkTarget(href, cwd, baseDir);
  if (!targetPath) return null;
  const source = href ? parseMarkdownFileLink(href) : null;
  return {
    ...buildFileLinkMetaFromTarget(targetPath, cwd),
    ...(source?.endLine !== undefined ? { endLine: source.endLine } : {}),
    workspaceLookupPath:
      source !== null &&
      !isAbsolutePath(source.path) &&
      baseDir !== undefined &&
      workspaceRelativeFilePath(baseDir, cwd) === "."
        ? source.path
        : null,
  };
}

function buildFileLinkMetaFromTarget(targetPath: string, cwd?: string) {
  const { path, line, column } = splitFilePathPosition(targetPath);
  return {
    filePath: path,
    targetPath,
    displayPath: formatWorkspaceRelativePath(targetPath, cwd),
    workspaceRelativePath: workspaceRelativeFilePath(path, cwd),
    basename: fileBasename(path),
    ...(line !== undefined ? { line } : {}),
    ...(column !== undefined ? { column } : {}),
  };
}
