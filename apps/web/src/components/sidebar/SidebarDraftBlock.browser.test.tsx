import { scopeProjectRef, scopeThreadRef } from "@t3tools/client-runtime/environment";
import { EnvironmentId, ProjectId, ThreadId } from "@t3tools/contracts";
import { Profiler } from "react";
import { expect, it, vi } from "vite-plus/test";

import { act, render } from "../../../test/render";
import { DraftId, useComposerDraftStore } from "../../composerDraftStore";
import { SidebarDraftBlock } from "./SidebarDraftBlock";

it("keeps draft previews current through edits, promotion and removal", async () => {
  const initial = useComposerDraftStore.getState();
  using _store = {
    [Symbol.dispose]: () => useComposerDraftStore.setState(initial, true),
  };
  useComposerDraftStore.setState({
    draftsByThreadKey: {},
    draftThreadsByThreadKey: {},
    logicalProjectDraftThreadKeyByLogicalProjectKey: {},
  });
  const environmentId = EnvironmentId.make("draft-preview-environment");
  const projectRef = scopeProjectRef(environmentId, ProjectId.make("draft-preview-project"));
  const draftId = DraftId.make("draft-preview");
  const threadId = ThreadId.make("draft-preview-thread");
  const onRender = vi.fn();
  await using screen = await render(
    <Profiler id="draft-block" onRender={onRender}>
      <ul>
        <SidebarDraftBlock
          projectByKey={new Map()}
          projectDisplayNameByKey={new Map()}
          scopedProjectKeys={null}
          routeDraftId={null}
          expanded
          onToggleExpanded={vi.fn()}
          onNavigateToDraft={vi.fn()}
          onDraftContextMenu={vi.fn()}
        />
      </ul>
    </Profiler>,
  );
  const row = screen.getByTestId("sidebar-draft-row");
  await expect.element(row).not.toBeInTheDocument();

  await act(() => {
    initial.setProjectDraftThreadId(projectRef, draftId, { threadId });
    initial.setPrompt(draftId, "First draft preview");
  });
  await expect.element(row).toHaveAccessibleName("First draft preview, Unsent draft");

  const rendersBeforeOtherComposer = onRender.mock.calls.length;
  await act(() =>
    initial.setPrompt(scopeThreadRef(environmentId, ThreadId.make("other")), "Other composer"),
  );
  expect(onRender).toHaveBeenCalledTimes(rendersBeforeOtherComposer);
  await act(() => initial.setPrompt(draftId, "Updated draft preview"));
  await expect.element(row).toHaveAccessibleName("Updated draft preview, Unsent draft");

  await act(() => initial.markDraftThreadPromoting(draftId));
  await expect.element(row).not.toBeInTheDocument();
  await act(() => initial.clearDraftThread(draftId));

  const nextDraftId = DraftId.make("next-draft-preview");
  await act(() => {
    initial.setProjectDraftThreadId(projectRef, nextDraftId, { threadId: ThreadId.make("next") });
    initial.setPrompt(nextDraftId, "Next draft preview");
  });
  await expect.element(row).toHaveAccessibleName("Next draft preview, Unsent draft");
  await act(() => initial.clearDraftThread(nextDraftId));
  await expect.element(row).not.toBeInTheDocument();
});

it("collapses the drafts to a count and keeps the open draft listed", async () => {
  const initial = useComposerDraftStore.getState();
  using _store = {
    [Symbol.dispose]: () => useComposerDraftStore.setState(initial, true),
  };
  useComposerDraftStore.setState({
    draftsByThreadKey: {},
    draftThreadsByThreadKey: {},
    logicalProjectDraftThreadKeyByLogicalProjectKey: {},
  });
  const environmentId = EnvironmentId.make("draft-shelf-environment");
  const openDraftId = DraftId.make("draft-shelf-open");
  const parkedDraftId = DraftId.make("draft-shelf-parked");
  initial.setProjectDraftThreadId(
    scopeProjectRef(environmentId, ProjectId.make("draft-shelf-open-project")),
    openDraftId,
    { threadId: ThreadId.make("draft-shelf-open-thread") },
  );
  initial.setPrompt(openDraftId, "Open draft");
  initial.setProjectDraftThreadId(
    scopeProjectRef(environmentId, ProjectId.make("draft-shelf-parked-project")),
    parkedDraftId,
    { threadId: ThreadId.make("draft-shelf-parked-thread") },
  );
  initial.setPrompt(parkedDraftId, "Parked draft");
  const onToggleExpanded = vi.fn();
  const shelf = (expanded: boolean) => (
    <ul>
      <SidebarDraftBlock
        projectByKey={new Map()}
        projectDisplayNameByKey={new Map()}
        scopedProjectKeys={null}
        routeDraftId={openDraftId}
        expanded={expanded}
        onToggleExpanded={onToggleExpanded}
        onNavigateToDraft={vi.fn()}
        onDraftContextMenu={vi.fn()}
      />
    </ul>
  );
  await using screen = await render(shelf(false));
  const header = screen.getByTestId("sidebar-drafts-shelf-toggle");
  const rowNames = () =>
    screen
      .getByTestId("sidebar-draft-row")
      .elements()
      .map((row) => row.getAttribute("aria-label"));

  await expect.element(header).toHaveAttribute("aria-expanded", "false");
  await expect.element(header).toHaveTextContent("Drafts2");
  expect(header.element().getAttribute("data-sidebar-row")).toBe("shelf:drafts");
  expect(header.element().hasAttribute("role")).toBe(false);
  expect(rowNames()).toEqual(["Open draft, Unsent draft"]);

  await header.click();
  expect(onToggleExpanded).toHaveBeenCalledTimes(1);

  await screen.rerender(shelf(true));
  await expect.element(header).toHaveAttribute("aria-expanded", "true");
  expect(rowNames()).toHaveLength(2);
  expect(rowNames()).toContain("Parked draft, Unsent draft");
});
