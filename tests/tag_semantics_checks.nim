import std/options
import ../src/state/snapshot
import ../src/types/[model, shell_snapshot]

proc fail(context, message: string) =
  raise newException(AssertionDefect, context & ": " & message)

proc require(context: string, condition: bool, message: string) =
  if not condition:
    fail(context, message)

proc activeWorkspace(
    snapshot: ShellSnapshot
): tuple[found: bool, workspace: ShellWorkspace] =
  for workspace in snapshot.workspaces:
    if workspace.isActive:
      if result.found:
        return (false, ShellWorkspace())
      result = (true, workspace)

proc shellWindow(
    snapshot: ShellSnapshot, winId: uint32
): tuple[found: bool, win: ShellWindow] =
  for win in snapshot.windows:
    if win.id == winId:
      return (true, win)

proc focusedShellWindow(snapshot: ShellSnapshot): tuple[count: int, win: ShellWindow] =
  for win in snapshot.windows:
    if win.isFocused:
      inc result.count
      result.win = win

proc workspaceByTag(
    snapshot: ShellSnapshot, tagId: uint32
): tuple[found: bool, workspace: ShellWorkspace] =
  for workspace in snapshot.workspaces:
    if workspace.tagId == tagId:
      return (true, workspace)

proc workspaceByIndex(
    snapshot: ShellSnapshot, idx: uint32
): tuple[found: bool, workspace: ShellWorkspace] =
  for workspace in snapshot.workspaces:
    if workspace.workspaceIdx == idx:
      return (true, workspace)

proc requireTagShellSemantics*(model: Model, context = "tag semantics") =
  let snapshot = model.shellSnapshot()
  let active = snapshot.activeWorkspace()
  let focused = snapshot.focusedShellWindow()

  require(
    context,
    focused.count <= 1,
    "snapshot must expose at most one globally focused window",
  )

  if snapshot.workspaces.len > 0:
    require(
      context, active.found, "snapshot with workspaces must expose an active workspace"
    )
    require(
      context,
      active.workspace.workspaceIdx == snapshot.activeWorkspaceIdx,
      "active workspace index mismatch",
    )
    require(
      context,
      active.workspace.tagId == snapshot.activeTag,
      "active workspace tag mismatch",
    )

  if active.found and active.workspace.focusedWindow != 0'u32 and
      snapshot.activeScratchpadWindow == 0'u32:
    let activeWin = snapshot.shellWindow(active.workspace.focusedWindow)
    if activeWin.found and not activeWin.win.isMinimized:
      require(
        context,
        focused.count == 1,
        "active workspace focus must export one global focused window",
      )
      require(
        context,
        focused.win.id == active.workspace.focusedWindow,
        "global focused window must match active workspace focus",
      )

  if focused.count == 1:
    if focused.win.id == snapshot.activeScratchpadWindow:
      require(
        context,
        focused.win.workspaceIdx == 0,
        "focused scratchpad window must not claim a workspace index",
      )
      require(
        context, focused.win.tagId.isNone,
        "focused scratchpad window must not claim a tag",
      )
    else:
      require(
        context, active.found, "focused shell window requires an active workspace"
      )
      require(
        context,
        focused.win.workspaceIdx == active.workspace.workspaceIdx,
        "focused shell window must be on active workspace index",
      )
      require(context, focused.win.tagId.isSome, "focused shell window must have a tag")
      require(
        context,
        focused.win.tagId.get() == active.workspace.tagId,
        "focused shell window must be on active workspace tag",
      )

  for win in snapshot.windows:
    if win.tagId.isSome:
      let workspace = snapshot.workspaceByTag(win.tagId.get())
      require(context, workspace.found, "tagged shell window has no visible workspace")
      require(
        context,
        workspace.workspace.workspaceIdx == win.workspaceIdx,
        "shell window workspace index does not match workspace tag",
      )
    if win.workspaceIdx != 0:
      let workspace = snapshot.workspaceByIndex(win.workspaceIdx)
      require(
        context, workspace.found,
        "shell window workspace index has no visible workspace",
      )
      if win.tagId.isSome:
        require(
          context,
          workspace.workspace.tagId == win.tagId.get(),
          "shell window tag does not match indexed workspace",
        )
    if win.isFocused:
      if win.id == snapshot.activeScratchpadWindow:
        require(context, win.workspaceIdx == 0, "scratchpad focus must be untagged")
      else:
        require(context, active.found, "focused window requires active workspace")
        require(
          context,
          win.workspaceIdx == active.workspace.workspaceIdx,
          "inactive workspace focus exported as global focus",
        )
