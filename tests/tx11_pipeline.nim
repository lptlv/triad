import std/[sequtils, strutils, unittest]

import ../src/config/parser
import ../src/core/[effects, layout_selection_codec]
import ../src/core/msg
import ../src/state/engine
import ../src/systems/runtime_facade
import ../src/types/model
import ../src/types/runtime_values
import ../src/x11/events
import ../src/x11/pipeline
import ../src/x11/request_builder

proc x11Model(): Model =
  initRuntimeStateFromConfig(
    Config(layout: LayoutConfig(gaps: 10), workspaces: WorkspaceConfig(defaultCount: 3))
  ).model

proc x11ModelWithMappedWindows(windowIds: openArray[uint32]): Model =
  result = x11Model()
  discard result.processEventDryRun(
    X11BackendEvent(
      kind: X11BackendEventKind.OutputDiscovered,
      output: X11OutputSnapshot(
        id: 1, name: "Xvfb-0", connected: true, x: 0, y: 0, w: 800, h: 600
      ),
    )
  )
  for windowId in windowIds:
    discard result.processEventDryRun(
      X11BackendEvent(
        kind: X11BackendEventKind.MapRequested,
        window:
          X11WindowSnapshot(id: windowId, wmClass: "app", title: "App", w: 300, h: 200),
      )
    )

proc x11ModelWithTwoOutputs(): Model =
  result = x11Model()
  discard result.processEventDryRun(
    X11BackendEvent(
      kind: X11BackendEventKind.OutputDiscovered,
      output: X11OutputSnapshot(
        id: 1, name: "DP-1", connected: true, x: 0, y: 0, w: 800, h: 600
      ),
    )
  )
  discard result.processEventDryRun(
    X11BackendEvent(
      kind: X11BackendEventKind.OutputDiscovered,
      output: X11OutputSnapshot(
        id: 2, name: "DP-2", connected: true, x: 800, y: 0, w: 800, h: 600
      ),
    )
  )

suite "X11 admission pipeline":
  test "dry-run pipeline routes supported admission effects to request records":
    var model = x11Model()
    discard model.processEventDryRun(
      X11BackendEvent(
        kind: X11BackendEventKind.OutputDiscovered,
        output: X11OutputSnapshot(
          id: 1, name: "Xvfb-0", connected: true, x: 0, y: 0, w: 800, h: 600
        ),
      )
    )

    let step = model.processEventDryRun(
      X11BackendEvent(
        kind: X11BackendEventKind.WindowDiscovered,
        window: X11WindowSnapshot(
          id: 0x2a,
          wmClass: "triad-smoke/triad-smoke",
          title: "triad smoke",
          x: 32,
          y: 48,
          w: 320,
          h: 200,
          mapped: true,
        ),
      )
    )

    check step.admission.messages.len == 2
    check step.intents.len == 1
    check step.layoutRequests.len == 1
    check step.requests.len == 2
    check step.requests[0].kind == X11RequestKind.XrqConfigureWindow
    check step.requests[0].windowId == 0x2a
    check step.requests[1].kind == X11RequestKind.XrqSetInputFocus
    check step.requests[1].windowId == 0x2a
    check step.dryRunExecutions.len == 2
    check not step.dryRunExecutions[0].applied
    check step.xcbRun.code == 0
    check step.xcbRun.dryRun
    check step.xcbRun.logs.len == 0

  test "executor pipeline can run selected admission effects through C dry-run":
    var model = x11Model()
    let step = model.processEventWithExecutor(
      X11BackendEvent(
        kind: X11BackendEventKind.WindowDiscovered,
        window: X11WindowSnapshot(
          id: 0x2b, wmClass: "app", title: "App", w: 300, h: 200, mapped: true
        ),
      ),
      dryRun = true,
    )

    check step.requests.len == 1
    check step.requests[0].kind == X11RequestKind.XrqSetInputFocus
    check step.xcbRun.code == 0
    check step.xcbRun.dryRun
    check step.xcbRun.logs ==
      @[
        "dry_run focus window=0x0000002b",
        "request execution complete dry_run=1 count=1",
      ]

  test "observed focus events do not reissue XCB focus requests":
    var model = x11ModelWithMappedWindows([0x2c'u32, 0x2d'u32])

    let step = model.processEventDryRun(
      X11BackendEvent(
        kind: X11BackendEventKind.FocusChanged, focusWindowId: 0x2c, focused: true
      )
    )

    check step.admission.messages.len == 1
    check step.admission.messages[0].kind == MsgKind.FocusChanged
    check step.admission.effects.anyIt(it.kind == EffectKind.EffFocusWindow)
    check step.intents.len == 0
    check step.requests.len == 0
    check step.dryRunExecutions.len == 0

  test "map requests add map before focus execution":
    var model = x11Model()
    discard model.processEventDryRun(
      X11BackendEvent(
        kind: X11BackendEventKind.OutputDiscovered,
        output: X11OutputSnapshot(
          id: 1, name: "Xvfb-0", connected: true, x: 0, y: 0, w: 800, h: 600
        ),
      )
    )
    let step = model.processEventWithExecutor(
      X11BackendEvent(
        kind: X11BackendEventKind.MapRequested,
        window:
          X11WindowSnapshot(id: 0x2c, wmClass: "app", title: "App", w: 300, h: 200),
      ),
      dryRun = true,
    )

    check step.admission.messages.len == 2
    check step.layoutRequests.len == 1
    check step.requests.len == 3
    check step.requests[0].kind == X11RequestKind.XrqConfigureWindow
    check step.requests[0].windowId == 0x2c
    check step.requests[0].values[2] > 0
    check step.requests[0].values[3] > 0
    check step.requests[1].kind == X11RequestKind.XrqMapWindow
    check step.requests[1].windowId == 0x2c
    check step.requests[2].kind == X11RequestKind.XrqSetInputFocus
    check step.requests[2].windowId == 0x2c
    check step.xcbRun.code == 0
    check step.xcbRun.dryRun
    check step.xcbRun.logs.len == 4
    check step.xcbRun.logs[0].startsWith("dry_run configure window=0x0000002c")
    check step.xcbRun.logs[1] == "dry_run map window=0x0000002c"
    check step.xcbRun.logs[2] == "dry_run focus window=0x0000002c"
    check step.xcbRun.logs[3] == "request execution complete dry_run=1 count=3"

  test "second managed window reprojects both windows":
    var model = x11Model()
    discard model.processEventDryRun(
      X11BackendEvent(
        kind: X11BackendEventKind.OutputDiscovered,
        output: X11OutputSnapshot(
          id: 1, name: "Xvfb-0", connected: true, x: 0, y: 0, w: 800, h: 600
        ),
      )
    )
    discard model.processEventDryRun(
      X11BackendEvent(
        kind: X11BackendEventKind.MapRequested,
        window:
          X11WindowSnapshot(id: 0x30, wmClass: "app", title: "One", w: 300, h: 200),
      )
    )

    let step = model.processEventWithExecutor(
      X11BackendEvent(
        kind: X11BackendEventKind.MapRequested,
        window:
          X11WindowSnapshot(id: 0x31, wmClass: "app", title: "Two", w: 300, h: 200),
      ),
      dryRun = true,
    )

    check step.layoutRequests.len == 2
    check step.layoutRequests.anyIt(it.windowId == 0x30)
    check step.layoutRequests.anyIt(it.windowId == 0x31)
    check step.requests[0].kind == X11RequestKind.XrqConfigureWindow
    check step.requests[0].windowId == 0x31
    check step.requests[1].kind == X11RequestKind.XrqMapWindow
    check step.requests[1].windowId == 0x31
    check step.requests.anyIt(
      it.kind == X11RequestKind.XrqConfigureWindow and it.windowId == 0x30
    )

  test "destroyed windows reproject remaining windows without map requests":
    var model = x11Model()
    discard model.processEventDryRun(
      X11BackendEvent(
        kind: X11BackendEventKind.OutputDiscovered,
        output: X11OutputSnapshot(
          id: 1, name: "Xvfb-0", connected: true, x: 0, y: 0, w: 800, h: 600
        ),
      )
    )
    discard model.processEventDryRun(
      X11BackendEvent(
        kind: X11BackendEventKind.MapRequested,
        window:
          X11WindowSnapshot(id: 0x40, wmClass: "app", title: "One", w: 300, h: 200),
      )
    )
    discard model.processEventDryRun(
      X11BackendEvent(
        kind: X11BackendEventKind.MapRequested,
        window:
          X11WindowSnapshot(id: 0x41, wmClass: "app", title: "Two", w: 300, h: 200),
      )
    )

    let step = model.processEventWithExecutor(
      X11BackendEvent(kind: X11BackendEventKind.WindowDestroyed, windowId: 0x41),
      dryRun = true,
    )

    check step.layoutRequests.len == 1
    check step.layoutRequests[0].windowId == 0x40
    check step.requests.anyIt(
      it.kind == X11RequestKind.XrqConfigureWindow and it.windowId == 0x40
    )
    check not step.requests.anyIt(it.kind == X11RequestKind.XrqMapWindow)

  test "observed-only events do not invoke the executor boundary":
    var model = x11Model()
    let step = model.processEventWithExecutor(
      X11BackendEvent(
        kind: X11BackendEventKind.ConfigureRequested,
        configure: X11ConfigureRequest(windowId: 20, valueMask: 0x0f),
      ),
      dryRun = true,
    )

    check step.admission.messages.len == 0
    check step.intents.len == 0
    check step.requests.len == 0
    check step.xcbRun.code == 0
    check step.xcbRun.dryRun
    check step.xcbRun.logs.len == 0

  test "configure updates produce model effects but no executor requests":
    var model = x11Model()
    discard model.processEventDryRun(
      X11BackendEvent(
        kind: X11BackendEventKind.WindowDiscovered,
        window: X11WindowSnapshot(
          id: 33, wmClass: "app", title: "App", w: 300, h: 200, mapped: true
        ),
      )
    )

    let step = model.processEventDryRun(
      X11BackendEvent(
        kind: X11BackendEventKind.ConfigureRequested,
        configure: X11ConfigureRequest(windowId: 33, valueMask: 0x0c, w: 640, h: 480),
      )
    )

    check step.admission.messages.len == 1
    check step.admission.messages[0].kind == MsgKind.WindowDimensions
    check step.admission.effects.len > 0
    check step.admission.effects.anyIt(it.kind == EffectKind.EffRenderDirty)
    check step.intents.len == 0
    check step.requests.len == 0
    check step.dryRunExecutions.len == 0

  test "net wm state updates trigger layout projection requests":
    var model = x11Model()
    discard model.processEventDryRun(
      X11BackendEvent(
        kind: X11BackendEventKind.OutputDiscovered,
        output: X11OutputSnapshot(
          id: 1, name: "Xvfb-0", connected: true, x: 0, y: 0, w: 800, h: 600
        ),
      )
    )
    discard model.processEventDryRun(
      X11BackendEvent(
        kind: X11BackendEventKind.WindowDiscovered,
        window: X11WindowSnapshot(
          id: 44, wmClass: "app", title: "App", w: 300, h: 200, mapped: true
        ),
      )
    )

    let step = model.processEventDryRun(
      X11BackendEvent(
        kind: X11BackendEventKind.PropertyChanged,
        propertyWindowId: 44,
        propertyAtom: "_NET_WM_STATE",
        propertyValue:
          "_NET_WM_STATE_FULLSCREEN _NET_WM_STATE_MAXIMIZED_HORZ " &
          "_NET_WM_STATE_DEMANDS_ATTENTION",
      )
    )

    check step.admission.messages.len == 1
    check step.admission.messages[0].kind == MsgKind.WindowStateChanged
    check step.admission.effects.len > 0
    check step.admission.effects.anyIt(it.kind == EffectKind.EffRenderDirty)
    check step.intents.len == 0
    check step.layoutRequests.len == 1
    check step.requests.len == 1
    check step.requests[0].kind == X11RequestKind.XrqConfigureWindow
    check step.dryRunExecutions.len == 1

  test "transient parent updates trigger layout projection requests":
    var model = x11ModelWithMappedWindows([0x50'u32, 0x51'u32])

    let step = model.processEventDryRun(
      X11BackendEvent(
        kind: X11BackendEventKind.PropertyChanged,
        propertyWindowId: 0x51,
        propertyParentWindowId: 0x50,
        propertyAtom: "WM_TRANSIENT_FOR",
      )
    )

    check step.admission.messages.len == 1
    check step.admission.messages[0].kind == MsgKind.WindowParent
    check step.layoutRequests.len > 0
    check step.requests.anyIt(
      it.kind == X11RequestKind.XrqConfigureWindow and it.windowId == 0x51
    )
    check step.dryRunExecutions.len == step.requests.len

  test "normal size hint updates trigger layout projection requests":
    var model = x11ModelWithMappedWindows([0x52'u32])

    let step = model.processEventDryRun(
      X11BackendEvent(
        kind: X11BackendEventKind.PropertyChanged,
        propertyWindowId: 0x52,
        propertyAtom: "WM_NORMAL_HINTS",
        propertyMinWidth: 320,
        propertyMinHeight: 200,
        propertyMaxWidth: 1280,
        propertyMaxHeight: 900,
      )
    )

    check step.admission.messages.len == 1
    check step.admission.messages[0].kind == MsgKind.WindowDimensionsHint
    check step.layoutRequests.len > 0
    check step.requests.anyIt(
      it.kind == X11RequestKind.XrqConfigureWindow and it.windowId == 0x52
    )
    check step.dryRunExecutions.len == step.requests.len

  test "wm hints urgency updates trigger layout projection requests":
    var model = x11ModelWithMappedWindows([0x53'u32])

    let step = model.processEventDryRun(
      X11BackendEvent(
        kind: X11BackendEventKind.PropertyChanged,
        propertyWindowId: 0x53,
        propertyAtom: "WM_HINTS",
        propertyValue: "_NET_WM_STATE_FULLSCREEN",
        propertyUrgent: true,
      )
    )

    check step.admission.messages.len == 1
    check step.admission.messages[0].kind == MsgKind.WindowStateChanged
    check step.admission.messages[0].stateFullscreen
    check step.admission.messages[0].stateUrgent
    check step.layoutRequests.len > 0
    check step.requests.anyIt(
      it.kind == X11RequestKind.XrqConfigureWindow and it.windowId == 0x53
    )
    check step.dryRunExecutions.len == step.requests.len

  test "client messages produce EWMH command requests":
    var model = x11ModelWithMappedWindows([0x90'u32, 0x91'u32])

    let active = model.processEventDryRun(
      X11BackendEvent(
        kind: X11BackendEventKind.ClientMessage,
        clientWindowId: 0x90,
        clientMessageType: "_NET_ACTIVE_WINDOW",
        clientMessageFormat: 32,
      )
    )

    check active.admission.messages.len == 1
    check active.admission.messages[0].kind == MsgKind.CmdFocusWindowById
    check active.requests.anyIt(
      it.kind == X11RequestKind.XrqSetInputFocus and it.windowId == 0x90
    )

    let state = model.processEventDryRun(
      X11BackendEvent(
        kind: X11BackendEventKind.ClientMessage,
        clientWindowId: 0x90,
        clientMessageType: "_NET_WM_STATE",
        clientMessageFormat: 32,
        clientData: [1'u32, 0'u32, 0'u32, 0'u32, 0'u32],
        clientAtomValues: "_NET_WM_STATE_FULLSCREEN",
      )
    )

    check state.admission.messages.len == 1
    check state.admission.messages[0].kind == MsgKind.CmdSetWindowFullscreenById
    check state.layoutRequests.anyIt(
      it.kind == X11RequestKind.XrqConfigureWindow and it.windowId == 0x90
    )
    check state.requests.anyIt(
      it.kind == X11RequestKind.XrqSetFullscreenState and it.windowId == 0x90 and
        it.values[0] == 1
    )

    let close = model.processEventDryRun(
      X11BackendEvent(
        kind: X11BackendEventKind.ClientMessage,
        clientWindowId: 0x90,
        clientMessageType: "_NET_CLOSE_WINDOW",
        clientMessageFormat: 32,
      )
    )

    check close.admission.messages.len == 1
    check close.admission.messages[0].kind == MsgKind.CmdCloseWindowById
    check close.requests.anyIt(
      it.kind == X11RequestKind.XrqSendCloseWindow and it.windowId == 0x90
    )

  test "workspace command pipeline reprojects and reasserts focus":
    var model = x11Model()
    discard model.processEventDryRun(
      X11BackendEvent(
        kind: X11BackendEventKind.OutputDiscovered,
        output: X11OutputSnapshot(
          id: 1, name: "Xvfb-0", connected: true, x: 0, y: 0, w: 800, h: 600
        ),
      )
    )
    discard model.processEventDryRun(
      X11BackendEvent(
        kind: X11BackendEventKind.MapRequested,
        window:
          X11WindowSnapshot(id: 0x60, wmClass: "app", title: "One", w: 300, h: 200),
      )
    )

    let step = model.processCommandDryRun(
      Msg(
        kind: MsgKind.CmdMoveWindowToWorkspaceIndex,
        moveWorkspaceWindowId: 0x60,
        moveWorkspaceIndex: 2,
        moveWorkspaceFollowWindow: true,
      )
    )

    check step.layoutRequests.len == 1
    check step.layoutRequests[0].kind == X11RequestKind.XrqConfigureWindow
    check step.layoutRequests[0].windowId == 0x60
    check step.requests.anyIt(
      it.kind == X11RequestKind.XrqSetInputFocus and it.windowId == 0x60
    )
    check step.xcbRun.code == 0
    check step.xcbRun.dryRun

  test "focus-tag command pipeline reprojects and reasserts focus":
    var model = x11ModelWithMappedWindows([0x72'u32, 0x73'u32])
    discard model.processCommandDryRun(
      Msg(
        kind: MsgKind.CmdMoveWindowToWorkspaceIndex,
        moveWorkspaceWindowId: 0x73,
        moveWorkspaceIndex: 2,
        moveWorkspaceFollowWindow: false,
      )
    )

    let step = model.processCommandDryRun(Msg(kind: MsgKind.CmdFocusTag, focusTag: 2))

    check step.message.kind == MsgKind.CmdFocusTag
    check step.message.focusTag == 2
    check step.layoutRequests.len == 1
    check step.layoutRequests[0].kind == X11RequestKind.XrqConfigureWindow
    check step.layoutRequests[0].windowId == 0x73
    check step.requests.anyIt(
      it.kind == X11RequestKind.XrqConfigureWindow and it.windowId == 0x73
    )
    check step.requests.anyIt(
      it.kind == X11RequestKind.XrqSetInputFocus and it.windowId == 0x73
    )
    check step.xcbRun.code == 0
    check step.xcbRun.dryRun

  test "workspace focus pipeline maps target workspace and unmaps previous workspace":
    var model = x11ModelWithMappedWindows([0x74'u32])
    discard model.processCommandDryRun(
      Msg(
        kind: MsgKind.CmdMoveWindowToWorkspaceIndex,
        moveWorkspaceWindowId: 0x74,
        moveWorkspaceIndex: 2,
        moveWorkspaceFollowWindow: false,
      )
    )
    discard model.processEventDryRun(
      X11BackendEvent(
        kind: X11BackendEventKind.MapRequested,
        window:
          X11WindowSnapshot(id: 0x75, wmClass: "app", title: "Two", w: 300, h: 200),
      )
    )

    let step = model.processCommandDryRun(
      Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 2)
    )

    check step.message.kind == MsgKind.CmdFocusWorkspaceIndex
    check step.requests.anyIt(
      it.kind == X11RequestKind.XrqMapWindow and it.windowId == 0x74
    )
    check step.requests.anyIt(
      it.kind == X11RequestKind.XrqUnmapWindow and it.windowId == 0x75
    )
    check step.requests.anyIt(
      it.kind == X11RequestKind.XrqSetInputFocus and it.windowId == 0x74
    )

  test "output command pipeline reprojects and reasserts focus":
    var model = x11ModelWithTwoOutputs()
    discard model.processEventDryRun(
      X11BackendEvent(
        kind: X11BackendEventKind.MapRequested,
        window:
          X11WindowSnapshot(id: 0x88, wmClass: "app", title: "One", w: 300, h: 200),
      )
    )
    discard model.processCommandDryRun(
      Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 2)
    )
    discard model.processEventDryRun(
      X11BackendEvent(
        kind: X11BackendEventKind.MapRequested,
        window:
          X11WindowSnapshot(id: 0x89, wmClass: "app", title: "Two", w: 300, h: 200),
      )
    )

    let focusedOutput = model.processCommandDryRun(
      Msg(kind: MsgKind.CmdFocusOutput, outputTarget: "DP-1")
    )

    check focusedOutput.message.kind == MsgKind.CmdFocusOutput
    check focusedOutput.layoutRequests.anyIt(
      it.kind == X11RequestKind.XrqConfigureWindow and it.windowId == 0x88
    )
    check focusedOutput.requests.anyIt(
      it.kind == X11RequestKind.XrqSetInputFocus and it.windowId == 0x88
    )

    let movedWorkspace = model.processCommandDryRun(
      Msg(kind: MsgKind.CmdMoveWorkspaceToOutput, outputTarget: "DP-2")
    )

    check movedWorkspace.message.kind == MsgKind.CmdMoveWorkspaceToOutput
    check movedWorkspace.layoutRequests.anyIt(
      it.kind == X11RequestKind.XrqConfigureWindow and it.windowId == 0x88
    )
    check movedWorkspace.requests.anyIt(
      it.kind == X11RequestKind.XrqSetInputFocus and it.windowId == 0x88
    )

    let movedWindow = model.processCommandDryRun(
      Msg(kind: MsgKind.CmdMoveToOutput, outputTarget: "DP-1")
    )

    check movedWindow.message.kind == MsgKind.CmdMoveToOutput
    check movedWindow.layoutRequests.anyIt(
      it.kind == X11RequestKind.XrqConfigureWindow and it.windowId == 0x88
    )
    check movedWindow.requests.anyIt(
      it.kind == X11RequestKind.XrqSetInputFocus and it.windowId == 0x88
    )
    check movedWindow.xcbRun.code == 0
    check movedWindow.xcbRun.dryRun

  test "move-to-tag command pipeline reprojects moved focused window":
    var model = x11ModelWithMappedWindows([0x74'u32])

    let step = model.processCommandDryRun(Msg(kind: MsgKind.CmdMoveToTag, targetTag: 2))

    check step.message.kind == MsgKind.CmdMoveToTag
    check step.message.targetTag == 2
    check step.layoutRequests.len == 1
    check step.layoutRequests[0].kind == X11RequestKind.XrqConfigureWindow
    check step.layoutRequests[0].windowId == 0x74
    check step.requests.anyIt(
      it.kind == X11RequestKind.XrqConfigureWindow and it.windowId == 0x74
    )
    check step.requests.anyIt(
      it.kind == X11RequestKind.XrqSetInputFocus and it.windowId == 0x74
    )
    check step.xcbRun.code == 0
    check step.xcbRun.dryRun

  test "switch-layout command pipeline reprojects managed windows":
    var model = x11Model()
    discard model.processEventDryRun(
      X11BackendEvent(
        kind: X11BackendEventKind.OutputDiscovered,
        output: X11OutputSnapshot(
          id: 1, name: "Xvfb-0", connected: true, x: 0, y: 0, w: 800, h: 600
        ),
      )
    )
    discard model.processEventDryRun(
      X11BackendEvent(
        kind: X11BackendEventKind.MapRequested,
        window:
          X11WindowSnapshot(id: 0x61, wmClass: "app", title: "One", w: 300, h: 200),
      )
    )

    let step = model.processCommandDryRun(Msg(kind: MsgKind.CmdSwitchLayout))

    check step.message.kind == MsgKind.CmdSwitchLayout
    check step.layoutRequests.len == 1
    check step.layoutRequests[0].kind == X11RequestKind.XrqConfigureWindow
    check step.layoutRequests[0].windowId == 0x61
    check step.requests.anyIt(
      it.kind == X11RequestKind.XrqConfigureWindow and it.windowId == 0x61
    )
    check step.xcbRun.code == 0
    check step.xcbRun.dryRun

  test "maximize-column command pipeline reprojects managed windows":
    var model = x11Model()
    discard model.processEventDryRun(
      X11BackendEvent(
        kind: X11BackendEventKind.OutputDiscovered,
        output: X11OutputSnapshot(
          id: 1, name: "Xvfb-0", connected: true, x: 0, y: 0, w: 800, h: 600
        ),
      )
    )
    discard model.processEventDryRun(
      X11BackendEvent(
        kind: X11BackendEventKind.MapRequested,
        window:
          X11WindowSnapshot(id: 0x62, wmClass: "app", title: "One", w: 300, h: 200),
      )
    )

    let step = model.processCommandDryRun(Msg(kind: MsgKind.CmdMaximizeColumn))

    check step.message.kind == MsgKind.CmdMaximizeColumn
    check step.layoutRequests.len == 1
    check step.layoutRequests[0].kind == X11RequestKind.XrqConfigureWindow
    check step.layoutRequests[0].windowId == 0x62
    check step.requests.anyIt(
      it.kind == X11RequestKind.XrqConfigureWindow and it.windowId == 0x62
    )
    check step.xcbRun.code == 0
    check step.xcbRun.dryRun

  test "move-window command pipeline reprojects managed windows":
    var model = x11ModelWithMappedWindows([0x68'u32, 0x69'u32])

    let step = model.processCommandDryRun(Msg(kind: MsgKind.CmdMoveWindowLeft))

    check step.message.kind == MsgKind.CmdMoveWindowLeft
    check step.layoutRequests.len == 2
    check step.layoutRequests.anyIt(
      it.kind == X11RequestKind.XrqConfigureWindow and it.windowId == 0x68
    )
    check step.layoutRequests.anyIt(
      it.kind == X11RequestKind.XrqConfigureWindow and it.windowId == 0x69
    )
    check step.requests.anyIt(
      it.kind == X11RequestKind.XrqConfigureWindow and it.windowId == 0x68
    )
    check step.requests.anyIt(
      it.kind == X11RequestKind.XrqConfigureWindow and it.windowId == 0x69
    )
    check step.xcbRun.code == 0
    check step.xcbRun.dryRun

  test "resize-width command pipeline reprojects managed windows":
    var model = x11ModelWithMappedWindows([0x6a'u32, 0x6b'u32])

    let step =
      model.processCommandDryRun(Msg(kind: MsgKind.CmdResizeWidth, deltaW: 0.1'f32))

    check step.message.kind == MsgKind.CmdResizeWidth
    check step.message.deltaW == 0.1'f32
    check step.layoutRequests.len == 2
    check step.layoutRequests.anyIt(
      it.kind == X11RequestKind.XrqConfigureWindow and it.windowId == 0x6a
    )
    check step.layoutRequests.anyIt(
      it.kind == X11RequestKind.XrqConfigureWindow and it.windowId == 0x6b
    )
    check step.requests.anyIt(
      it.kind == X11RequestKind.XrqConfigureWindow and it.windowId == 0x6a
    )
    check step.requests.anyIt(
      it.kind == X11RequestKind.XrqConfigureWindow and it.windowId == 0x6b
    )
    check step.xcbRun.code == 0
    check step.xcbRun.dryRun

  test "master-ratio command pipeline reprojects managed windows":
    var model = x11ModelWithMappedWindows([0x6c'u32, 0x6d'u32])

    let step = model.processCommandDryRun(
      Msg(kind: MsgKind.CmdAdjustMasterRatio, deltaMR: 0.05'f32)
    )

    check step.message.kind == MsgKind.CmdAdjustMasterRatio
    check step.message.deltaMR == 0.05'f32
    check step.layoutRequests.len == 2
    check step.layoutRequests.anyIt(
      it.kind == X11RequestKind.XrqConfigureWindow and it.windowId == 0x6c
    )
    check step.layoutRequests.anyIt(
      it.kind == X11RequestKind.XrqConfigureWindow and it.windowId == 0x6d
    )
    check step.requests.anyIt(
      it.kind == X11RequestKind.XrqConfigureWindow and it.windowId == 0x6c
    )
    check step.requests.anyIt(
      it.kind == X11RequestKind.XrqConfigureWindow and it.windowId == 0x6d
    )
    check step.xcbRun.code == 0
    check step.xcbRun.dryRun

  test "adjust-gaps command pipeline reprojects managed windows":
    var model = x11ModelWithMappedWindows([0x6e'u32, 0x6f'u32])

    let step = model.processCommandDryRun(Msg(kind: MsgKind.CmdAdjustGaps, deltaG: 2))

    check step.message.kind == MsgKind.CmdAdjustGaps
    check step.message.deltaG == 2
    check step.layoutRequests.len == 2
    check step.layoutRequests.anyIt(
      it.kind == X11RequestKind.XrqConfigureWindow and it.windowId == 0x6e
    )
    check step.layoutRequests.anyIt(
      it.kind == X11RequestKind.XrqConfigureWindow and it.windowId == 0x6f
    )
    check step.requests.anyIt(
      it.kind == X11RequestKind.XrqConfigureWindow and it.windowId == 0x6e
    )
    check step.requests.anyIt(
      it.kind == X11RequestKind.XrqConfigureWindow and it.windowId == 0x6f
    )
    check step.xcbRun.code == 0
    check step.xcbRun.dryRun

  test "set core scroller layout command pipeline reprojects managed windows":
    var model = x11Model()
    discard model.processEventDryRun(
      X11BackendEvent(
        kind: X11BackendEventKind.OutputDiscovered,
        output: X11OutputSnapshot(
          id: 1, name: "Xvfb-0", connected: true, x: 0, y: 0, w: 800, h: 600
        ),
      )
    )
    discard model.processEventDryRun(
      X11BackendEvent(
        kind: X11BackendEventKind.MapRequested,
        window:
          X11WindowSnapshot(id: 0x63, wmClass: "app", title: "One", w: 300, h: 200),
      )
    )

    let step = model.processCommandDryRun(
      Msg(kind: MsgKind.CmdSetLayout, newLayout: LayoutMode.VerticalScroller)
    )

    check step.message.kind == MsgKind.CmdSetLayout
    check step.message.newLayout == LayoutMode.VerticalScroller
    check step.layoutRequests.len == 1
    check step.layoutRequests[0].kind == X11RequestKind.XrqConfigureWindow
    check step.layoutRequests[0].windowId == 0x63
    check step.requests.anyIt(
      it.kind == X11RequestKind.XrqConfigureWindow and it.windowId == 0x63
    )
    check step.xcbRun.code == 0
    check step.xcbRun.dryRun

  test "set bundled algorithmic layout command pipeline reprojects managed windows":
    var model = x11ModelWithMappedWindows([0x80'u32, 0x81'u32])

    let step = model.processCommandDryRun(
      Msg(kind: MsgKind.CmdSetCustomLayout, customLayout: janetLayoutId("grid"))
    )

    check step.message.kind == MsgKind.CmdSetCustomLayout
    check step.message.customLayout.layoutIdString() == "grid"
    check step.layoutRequests.len == 2
    check step.requests.anyIt(
      it.kind == X11RequestKind.XrqConfigureWindow and it.windowId == 0x80
    )
    check step.requests.anyIt(
      it.kind == X11RequestKind.XrqConfigureWindow and it.windowId == 0x81
    )
    check step.xcbRun.code == 0
    check step.xcbRun.dryRun

  test "fullscreen command pipeline sets EWMH state and reprojects managed windows":
    var model = x11Model()
    discard model.processEventDryRun(
      X11BackendEvent(
        kind: X11BackendEventKind.OutputDiscovered,
        output: X11OutputSnapshot(
          id: 1, name: "Xvfb-0", connected: true, x: 0, y: 0, w: 800, h: 600
        ),
      )
    )
    discard model.processEventDryRun(
      X11BackendEvent(
        kind: X11BackendEventKind.MapRequested,
        window:
          X11WindowSnapshot(id: 0x64, wmClass: "app", title: "One", w: 300, h: 200),
      )
    )

    let step = model.processCommandDryRun(Msg(kind: MsgKind.CmdToggleFullscreen))

    check step.message.kind == MsgKind.CmdToggleFullscreen
    check step.requests.anyIt(
      it.kind == X11RequestKind.XrqConfigureWindow and it.windowId == 0x64
    )
    check step.requests.anyIt(
      it.kind == X11RequestKind.XrqSetFullscreenState and it.windowId == 0x64 and
        it.values[0] == 1
    )
    check step.xcbRun.code == 0
    check step.xcbRun.dryRun

  test "maximize command pipeline sets EWMH state and reprojects managed windows":
    var model = x11Model()
    discard model.processEventDryRun(
      X11BackendEvent(
        kind: X11BackendEventKind.OutputDiscovered,
        output: X11OutputSnapshot(
          id: 1, name: "Xvfb-0", connected: true, x: 0, y: 0, w: 800, h: 600
        ),
      )
    )
    discard model.processEventDryRun(
      X11BackendEvent(
        kind: X11BackendEventKind.MapRequested,
        window:
          X11WindowSnapshot(id: 0x65, wmClass: "app", title: "One", w: 300, h: 200),
      )
    )

    let step = model.processCommandDryRun(Msg(kind: MsgKind.CmdToggleMaximized))

    check step.message.kind == MsgKind.CmdToggleMaximized
    check step.requests.anyIt(
      it.kind == X11RequestKind.XrqConfigureWindow and it.windowId == 0x65
    )
    check step.requests.anyIt(
      it.kind == X11RequestKind.XrqSetMaximizedState and it.windowId == 0x65 and
        it.values[0] == 1
    )
    check step.xcbRun.code == 0
    check step.xcbRun.dryRun

  test "toggle-floating command pipeline reprojects managed window":
    var model = x11ModelWithMappedWindows([0x75'u32])

    let step = model.processCommandDryRun(Msg(kind: MsgKind.CmdToggleFloating))

    check step.message.kind == MsgKind.CmdToggleFloating
    check step.layoutRequests.len == 1
    check step.layoutRequests[0].kind == X11RequestKind.XrqConfigureWindow
    check step.layoutRequests[0].windowId == 0x75
    check step.requests.anyIt(
      it.kind == X11RequestKind.XrqConfigureWindow and it.windowId == 0x75
    )
    check step.xcbRun.code == 0
    check step.xcbRun.dryRun

  test "zoom command pipeline reprojects managed windows":
    var model = x11ModelWithMappedWindows([0x76'u32, 0x77'u32])

    let step = model.processCommandDryRun(Msg(kind: MsgKind.CmdZoom))

    check step.message.kind == MsgKind.CmdZoom
    check step.layoutRequests.len == 2
    check step.requests.anyIt(
      it.kind == X11RequestKind.XrqConfigureWindow and it.windowId == 0x76
    )
    check step.requests.anyIt(
      it.kind == X11RequestKind.XrqConfigureWindow and it.windowId == 0x77
    )
    check step.requests.anyIt(
      it.kind == X11RequestKind.XrqSetInputFocus and it.windowId == 0x77
    )
    check step.xcbRun.code == 0
    check step.xcbRun.dryRun

  test "consume and expel command pipeline reprojects managed windows":
    var model = x11ModelWithMappedWindows([0x78'u32, 0x79'u32])
    discard model.processCommandDryRun(
      Msg(kind: MsgKind.CmdFocusWindowById, focusWindowId: 0x78)
    )

    let consume = model.processCommandDryRun(Msg(kind: MsgKind.CmdConsumeWindow))

    check consume.message.kind == MsgKind.CmdConsumeWindow
    check consume.layoutRequests.len == 2
    check consume.requests.anyIt(
      it.kind == X11RequestKind.XrqConfigureWindow and it.windowId == 0x78
    )
    check consume.requests.anyIt(
      it.kind == X11RequestKind.XrqConfigureWindow and it.windowId == 0x79
    )
    check consume.requests.anyIt(
      it.kind == X11RequestKind.XrqSetInputFocus and it.windowId == 0x78
    )

    let expel = model.processCommandDryRun(Msg(kind: MsgKind.CmdExpelWindow))

    check expel.message.kind == MsgKind.CmdExpelWindow
    check expel.layoutRequests.len == 2
    check expel.requests.anyIt(
      it.kind == X11RequestKind.XrqConfigureWindow and it.windowId == 0x78
    )
    check expel.requests.anyIt(
      it.kind == X11RequestKind.XrqConfigureWindow and it.windowId == 0x79
    )
    check expel.requests.anyIt(
      it.kind == X11RequestKind.XrqSetInputFocus and it.windowId == 0x78
    )
    check expel.xcbRun.code == 0
    check expel.xcbRun.dryRun

  test "group command pipeline maps visible group member":
    var model = x11ModelWithMappedWindows([0x7a'u32, 0x7b'u32])

    let grouped = model.processCommandDryRun(Msg(kind: MsgKind.CmdGroupWindows))

    check grouped.message.kind == MsgKind.CmdGroupWindows
    check grouped.layoutRequests.len == 1
    check grouped.requests.anyIt(
      it.kind == X11RequestKind.XrqConfigureWindow and it.windowId == 0x7b
    )
    check grouped.requests.anyIt(
      it.kind == X11RequestKind.XrqUnmapWindow and it.windowId == 0x7a
    )

    let focused = model.processCommandDryRun(Msg(kind: MsgKind.CmdFocusNextInGroup))
    var mapIdx = -1
    var focusIdx = -1
    var unmapIdx = -1
    for idx, request in focused.requests:
      if request.kind == X11RequestKind.XrqMapWindow and request.windowId == 0x7a:
        mapIdx = idx
      if request.kind == X11RequestKind.XrqSetInputFocus and request.windowId == 0x7a:
        focusIdx = idx
      if request.kind == X11RequestKind.XrqUnmapWindow and request.windowId == 0x7b:
        unmapIdx = idx

    check focused.message.kind == MsgKind.CmdFocusNextInGroup
    check mapIdx >= 0
    check focusIdx >= 0
    check unmapIdx >= 0
    check mapIdx < focusIdx

    let ungrouped = model.processCommandDryRun(Msg(kind: MsgKind.CmdUngroupWindow))

    check ungrouped.message.kind == MsgKind.CmdUngroupWindow
    check ungrouped.layoutRequests.len == 2
    check ungrouped.requests.anyIt(
      it.kind == X11RequestKind.XrqMapWindow and it.windowId == 0x7b
    )
    check ungrouped.requests.anyIt(
      it.kind == X11RequestKind.XrqConfigureWindow and it.windowId == 0x7a
    )
    check ungrouped.requests.anyIt(
      it.kind == X11RequestKind.XrqConfigureWindow and it.windowId == 0x7b
    )
    check ungrouped.xcbRun.code == 0
    check ungrouped.xcbRun.dryRun

  test "scratchpad command pipeline maps and unmaps active scratchpad":
    var model = x11ModelWithMappedWindows([0x82'u32, 0x83'u32])

    let moved = model.processCommandDryRun(Msg(kind: MsgKind.CmdMoveToScratchpad))

    check moved.message.kind == MsgKind.CmdMoveToScratchpad
    check moved.requests.anyIt(
      it.kind == X11RequestKind.XrqUnmapWindow and it.windowId == 0x83
    )
    check not moved.requests.anyIt(
      it.kind == X11RequestKind.XrqConfigureWindow and it.windowId == 0x83
    )
    check moved.requests.anyIt(
      it.kind == X11RequestKind.XrqSetInputFocus and it.windowId == 0x82
    )

    let shown = model.processCommandDryRun(Msg(kind: MsgKind.CmdToggleScratchpad))
    var mapIdx = -1
    var focusIdx = -1
    for idx, request in shown.requests:
      if request.kind == X11RequestKind.XrqMapWindow and request.windowId == 0x83:
        mapIdx = idx
      if request.kind == X11RequestKind.XrqSetInputFocus and request.windowId == 0x83:
        focusIdx = idx

    check shown.message.kind == MsgKind.CmdToggleScratchpad
    check shown.requests.anyIt(
      it.kind == X11RequestKind.XrqConfigureWindow and it.windowId == 0x83
    )
    check mapIdx >= 0
    check focusIdx >= 0
    check mapIdx < focusIdx

    let hidden = model.processCommandDryRun(Msg(kind: MsgKind.CmdToggleScratchpad))

    check hidden.message.kind == MsgKind.CmdToggleScratchpad
    check hidden.requests.anyIt(
      it.kind == X11RequestKind.XrqUnmapWindow and it.windowId == 0x83
    )

  test "restore-scratchpad command pipeline remaps restored window":
    var model = x11ModelWithMappedWindows([0x84'u32, 0x85'u32])
    discard model.processCommandDryRun(Msg(kind: MsgKind.CmdMoveToScratchpad))

    let restored = model.processCommandDryRun(Msg(kind: MsgKind.CmdRestoreScratchpad))
    var mapIdx = -1
    var focusIdx = -1
    for idx, request in restored.requests:
      if request.kind == X11RequestKind.XrqMapWindow and request.windowId == 0x85:
        mapIdx = idx
      if request.kind == X11RequestKind.XrqSetInputFocus and request.windowId == 0x85:
        focusIdx = idx

    check restored.message.kind == MsgKind.CmdRestoreScratchpad
    check restored.requests.anyIt(
      it.kind == X11RequestKind.XrqConfigureWindow and it.windowId == 0x85
    )
    check mapIdx >= 0
    check focusIdx >= 0
    check mapIdx < focusIdx
    check restored.xcbRun.code == 0
    check restored.xcbRun.dryRun

  test "named scratchpad command pipeline maps named scratchpad on toggle":
    var model = x11ModelWithMappedWindows([0x86'u32, 0x87'u32])

    let moved = model.processCommandDryRun(
      Msg(kind: MsgKind.CmdMoveToNamedScratchpad, scratchpadName: "terminal")
    )

    check moved.message.kind == MsgKind.CmdMoveToNamedScratchpad
    check moved.message.scratchpadName == "terminal"
    check moved.requests.anyIt(
      it.kind == X11RequestKind.XrqUnmapWindow and it.windowId == 0x87
    )

    let shown = model.processCommandDryRun(
      Msg(kind: MsgKind.CmdToggleNamedScratchpad, scratchpadName: "terminal")
    )

    check shown.message.kind == MsgKind.CmdToggleNamedScratchpad
    check shown.message.scratchpadName == "terminal"
    check shown.requests.anyIt(
      it.kind == X11RequestKind.XrqMapWindow and it.windowId == 0x87
    )
    check shown.requests.anyIt(
      it.kind == X11RequestKind.XrqConfigureWindow and it.windowId == 0x87
    )

  test "minimize command pipeline hides and unmaps focused window":
    var model = x11Model()
    discard model.processEventDryRun(
      X11BackendEvent(
        kind: X11BackendEventKind.OutputDiscovered,
        output: X11OutputSnapshot(
          id: 1, name: "Xvfb-0", connected: true, x: 0, y: 0, w: 800, h: 600
        ),
      )
    )
    discard model.processEventDryRun(
      X11BackendEvent(
        kind: X11BackendEventKind.MapRequested,
        window:
          X11WindowSnapshot(id: 0x66, wmClass: "app", title: "One", w: 300, h: 200),
      )
    )

    let step = model.processCommandDryRun(Msg(kind: MsgKind.CmdMinimize))

    check step.message.kind == MsgKind.CmdMinimize
    check step.requests.anyIt(
      it.kind == X11RequestKind.XrqSetHiddenState and it.windowId == 0x66 and
        it.values[0] == 1
    )
    check step.requests.anyIt(
      it.kind == X11RequestKind.XrqUnmapWindow and it.windowId == 0x66
    )
    check not step.requests.anyIt(
      it.kind == X11RequestKind.XrqConfigureWindow and it.windowId == 0x66
    )
    check step.xcbRun.code == 0
    check step.xcbRun.dryRun

  test "focus command pipeline maps restored minimized window before focus":
    var model = x11Model()
    discard model.processEventDryRun(
      X11BackendEvent(
        kind: X11BackendEventKind.OutputDiscovered,
        output: X11OutputSnapshot(
          id: 1, name: "Xvfb-0", connected: true, x: 0, y: 0, w: 800, h: 600
        ),
      )
    )
    discard model.processEventDryRun(
      X11BackendEvent(
        kind: X11BackendEventKind.MapRequested,
        window:
          X11WindowSnapshot(id: 0x67, wmClass: "app", title: "One", w: 300, h: 200),
      )
    )
    discard model.processCommandDryRun(Msg(kind: MsgKind.CmdMinimize))

    let step = model.processCommandDryRun(
      Msg(kind: MsgKind.CmdFocusWindowById, focusWindowId: 0x67)
    )
    var mapIdx = -1
    var focusIdx = -1
    for idx, request in step.requests:
      if request.kind == X11RequestKind.XrqMapWindow and request.windowId == 0x67:
        mapIdx = idx
      if request.kind == X11RequestKind.XrqSetInputFocus and request.windowId == 0x67:
        focusIdx = idx

    check step.requests.anyIt(
      it.kind == X11RequestKind.XrqSetHiddenState and it.windowId == 0x67 and
        it.values[0] == 0
    )
    check mapIdx >= 0
    check focusIdx >= 0
    check mapIdx < focusIdx
    check step.xcbRun.code == 0
    check step.xcbRun.dryRun
