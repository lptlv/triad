import std/unittest

import ../src/config/parser
import ../src/core/effects
import ../src/core/msg
import ../src/core/shell_focus
import ../src/state/engine
import ../src/systems/runtime_facade
import ../src/types/model
import ../src/types/runtime_values
import ../src/types/shell_snapshot
import ../src/x11/admission
import ../src/x11/events

proc x11Model(): Model =
  initRuntimeStateFromConfig(
    Config(
      layout: LayoutConfig(
        gaps: 10,
        defaultColumnWidth: 0.7,
        defaultWindowWidth: 0.8,
        defaultWindowHeight: 0.6,
      ),
      workspaces: WorkspaceConfig(defaultCount: 3),
    )
  ).model

proc snapshotWindow(model: Model, id: uint32): ShellWindow =
  for win in model.shellSnapshot().windows:
    if uint32(win.id) == id:
      return win
  ShellWindow()

proc snapshotWorkspace(model: Model, id: uint32): ShellWorkspace =
  for workspace in model.shellSnapshot().workspaces:
    if workspace.tagId == id:
      return workspace
  ShellWorkspace()

proc hasEffect(effects: seq[Effect], kind: EffectKind): bool =
  for effect in effects:
    if effect.kind == kind:
      return true

suite "X11 model admission":
  test "admits output and window discovery into an isolated model":
    var model = x11Model()
    let results =
      model.admitDryRun(
        [
          X11BackendEvent(
            kind: X11BackendEventKind.OutputDiscovered,
            output: X11OutputSnapshot(
              id: 1, name: "Xvfb-0", connected: true, x: 0, y: 0, w: 800, h: 600
            ),
          ),
          X11BackendEvent(
            kind: X11BackendEventKind.WindowDiscovered,
            window: X11WindowSnapshot(
              id: 0x2a,
              pid: 1234,
              wmClass: "triad-smoke/triad-smoke",
              title: "triad smoke",
              x: 32,
              y: 48,
              w: 320,
              h: 200,
              mapped: true,
            ),
          ),
        ]
      )

    check results.len == 2
    check results[0].messages.len == 3
    check results[1].messages.len == 3

    let snapshot = model.shellSnapshot()
    check snapshot.outputs.len == 1
    check snapshot.outputs[0].id == 1
    check snapshot.outputs[0].name == "Xvfb-0"
    check snapshot.outputs[0].w == 800
    check snapshot.outputs[0].h == 600

    check snapshot.windows.len == 1
    let win = model.snapshotWindow(0x2a)
    check win.id == 0x2a
    check win.appId == "triad-smoke"
    check win.title == "triad smoke"
    check win.pid == 1234
    check win.identifier == "x11:0x0000002a"

    var allEffects: seq[Effect]
    for admission in results:
      allEffects.add(admission.effects)
    check allEffects.hasEffect(EffectKind.EffRenderDirty)
    check allEffects.hasEffect(EffectKind.EffFocusWindow)
    check not allEffects.hasEffect(EffectKind.EffSetPosition)
    check not allEffects.hasEffect(EffectKind.EffCloseWindow)

  test "admits focus and destruction into model state":
    var model = x11Model()
    discard
      model.admitDryRun(
        [
          X11BackendEvent(
            kind: X11BackendEventKind.OutputDiscovered,
            output: X11OutputSnapshot(
              id: 1, name: "Xvfb-0", connected: true, w: 800, h: 600
            ),
          ),
          X11BackendEvent(
            kind: X11BackendEventKind.WindowDiscovered,
            window: X11WindowSnapshot(
              id: 10, wmClass: "app", title: "One", w: 300, h: 200, mapped: true
            ),
          ),
          X11BackendEvent(
            kind: X11BackendEventKind.WindowDiscovered,
            window: X11WindowSnapshot(
              id: 11, wmClass: "app", title: "Two", w: 300, h: 200, mapped: true
            ),
          ),
        ]
      )

    let focus = model.admitDryRun(
      X11BackendEvent(
        kind: X11BackendEventKind.FocusChanged, focusWindowId: 11, focused: true
      )
    )
    check focus.messages.len == 1
    check model.shellSnapshot().focusedWindowId().uint32 == 11

    let destroyed = model.admitDryRun(
      X11BackendEvent(kind: X11BackendEventKind.WindowDestroyed, windowId: 11)
    )
    check destroyed.messages.len == 1
    check model.shellSnapshot().windows.len == 1
    check model.snapshotWindow(11).id == 0
    check not destroyed.effects.hasEffect(EffectKind.EffSetPosition)
    check not destroyed.effects.hasEffect(EffectKind.EffCloseWindow)

  test "observed-only backend events are no-op admissions":
    var model = x11Model()
    let before = model.shellSnapshot()
    let result = model.admitDryRun(
      X11BackendEvent(
        kind: X11BackendEventKind.ConfigureRequested,
        configure: X11ConfigureRequest(windowId: 20, valueMask: 0x0f),
      )
    )

    check result.messages.len == 0
    check result.effects.len == 0
    check model.shellSnapshot().windows.len == before.windows.len
    check model.shellSnapshot().outputs.len == before.outputs.len

  test "admits configure and property updates into existing window state":
    var model = x11Model()
    discard model.admitDryRun(
      X11BackendEvent(
        kind: X11BackendEventKind.WindowDiscovered,
        window: X11WindowSnapshot(
          id: 21, wmClass: "app", title: "Old", w: 300, h: 200, mapped: true
        ),
      )
    )

    let configured =
      model.admitDryRun(
        X11BackendEvent(
          kind: X11BackendEventKind.ConfigureRequested,
          configure: X11ConfigureRequest(
            windowId: 21, valueMask: 0x0c, w: 640, h: 480
          ),
        )
      )
    let title =
      model.admitDryRun(
        X11BackendEvent(
          kind: X11BackendEventKind.PropertyChanged,
          propertyWindowId: 21,
          propertyAtom: "_NET_WM_NAME",
          propertyValue: "New",
        )
      )
    let appId =
      model.admitDryRun(
        X11BackendEvent(
          kind: X11BackendEventKind.PropertyChanged,
          propertyWindowId: 21,
          propertyAtom: "WM_CLASS",
          propertyValue: "kitty/kitty",
        )
      )

    check configured.messages.len == 1
    check configured.messages[0].kind == MsgKind.WlWindowDimensions
    check configured.effects.hasEffect(EffectKind.EffRenderDirty)
    check title.messages.len == 1
    check title.messages[0].kind == MsgKind.WlWindowTitle
    check appId.messages.len == 1
    check appId.messages[0].kind == MsgKind.WlWindowAppId

    let win = model.snapshotWindow(21)
    check win.actualW == 640
    check win.actualH == 480
    check win.title == "New"
    check win.appId == "kitty"

  test "admits net wm state updates into existing window state":
    var model = x11Model()
    discard model.admitDryRun(
      X11BackendEvent(
        kind: X11BackendEventKind.OutputDiscovered,
        output: X11OutputSnapshot(
          id: 1, name: "Xvfb-0", connected: true, w: 800, h: 600
        ),
      )
    )
    discard model.admitDryRun(
      X11BackendEvent(
        kind: X11BackendEventKind.WindowDiscovered,
        window: X11WindowSnapshot(
          id: 22, wmClass: "app", title: "App", w: 300, h: 200, mapped: true
        ),
      )
    )

    let state =
      model.admitDryRun(
        X11BackendEvent(
          kind: X11BackendEventKind.PropertyChanged,
          propertyWindowId: 22,
          propertyAtom: "_NET_WM_STATE",
          propertyValue:
            "_NET_WM_STATE_FULLSCREEN _NET_WM_STATE_MAXIMIZED_VERT " &
            "_NET_WM_STATE_HIDDEN _NET_WM_STATE_DEMANDS_ATTENTION",
        )
      )

    check state.messages.len == 1
    check state.messages[0].kind == MsgKind.WlWindowStateChanged
    check state.effects.hasEffect(EffectKind.EffRenderDirty)

    var win = model.snapshotWindow(22)
    check win.isFullscreen
    check win.isMaximized
    check win.isMinimized
    check win.isUrgent
    check model.snapshotWorkspace(1).isUrgent
    check not model.snapshotWorkspace(2).isUrgent
    check not model.snapshotWorkspace(3).isUrgent

    discard model.admitDryRun(
      X11BackendEvent(
        kind: X11BackendEventKind.FocusChanged, focusWindowId: 22, focused: true
      )
    )
    check model.snapshotWindow(22).isUrgent
    check model.snapshotWorkspace(1).isUrgent

    let internalId = model.windowForExternal(ExternalWindowId(22))
    check internalId != NullWindowId
    check model.setWindowSticky(internalId, true)
    check model.snapshotWorkspace(1).isUrgent
    check not model.snapshotWorkspace(2).isUrgent

    discard model.admitDryRun(
      X11BackendEvent(
        kind: X11BackendEventKind.PropertyChanged,
        propertyWindowId: 22,
        propertyAtom: "_NET_WM_STATE",
        propertyValue: "",
      )
    )
    win = model.snapshotWindow(22)
    check not win.isFullscreen
    check not win.isMaximized
    check not win.isMinimized
    check not win.isUrgent
    check not model.snapshotWorkspace(1).isUrgent
