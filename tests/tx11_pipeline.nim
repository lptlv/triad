import std/[sequtils, unittest]

import ../src/config/parser
import ../src/core/effects
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
    Config(
      layout: LayoutConfig(gaps: 10),
      workspaces: WorkspaceConfig(defaultCount: 3),
    )
  ).model

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

    let step =
      model.processEventDryRun(
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
    check step.requests.len == 1
    check step.requests[0].kind == X11RequestKind.XrqSetInputFocus
    check step.requests[0].windowId == 0x2a
    check step.dryRunExecutions.len == 1
    check not step.dryRunExecutions[0].applied
    check step.xcbRun.code == 0
    check step.xcbRun.dryRun
    check step.xcbRun.logs.len == 0

  test "executor pipeline can run selected admission effects through C dry-run":
    var model = x11Model()
    let step =
      model.processEventWithExecutor(
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
    check step.xcbRun.logs == @[
      "dry_run focus window=0x0000002b",
      "request execution complete dry_run=1 count=1",
    ]

  test "map requests add map before focus execution":
    var model = x11Model()
    let step =
      model.processEventWithExecutor(
        X11BackendEvent(
          kind: X11BackendEventKind.MapRequested,
          window: X11WindowSnapshot(
            id: 0x2c, wmClass: "app", title: "App", w: 300, h: 200
          ),
        ),
        dryRun = true,
      )

    check step.admission.messages.len == 2
    check step.requests.len == 2
    check step.requests[0].kind == X11RequestKind.XrqMapWindow
    check step.requests[0].windowId == 0x2c
    check step.requests[1].kind == X11RequestKind.XrqSetInputFocus
    check step.requests[1].windowId == 0x2c
    check step.xcbRun.code == 0
    check step.xcbRun.dryRun
    check step.xcbRun.logs == @[
      "dry_run map window=0x0000002c",
      "dry_run focus window=0x0000002c",
      "request execution complete dry_run=1 count=2",
    ]

  test "observed-only events do not invoke the executor boundary":
    var model = x11Model()
    let step =
      model.processEventWithExecutor(
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

    let step =
      model.processEventDryRun(
        X11BackendEvent(
          kind: X11BackendEventKind.ConfigureRequested,
          configure: X11ConfigureRequest(
            windowId: 33, valueMask: 0x0c, w: 640, h: 480
          ),
        )
      )

    check step.admission.messages.len == 1
    check step.admission.messages[0].kind == MsgKind.WlWindowDimensions
    check step.admission.effects.len > 0
    check step.admission.effects.anyIt(it.kind == EffectKind.EffRenderDirty)
    check step.intents.len == 0
    check step.requests.len == 0
    check step.dryRunExecutions.len == 0

  test "net wm state updates remain model-only in the pipeline":
    var model = x11Model()
    discard model.processEventDryRun(
      X11BackendEvent(
        kind: X11BackendEventKind.WindowDiscovered,
        window: X11WindowSnapshot(
          id: 44, wmClass: "app", title: "App", w: 300, h: 200, mapped: true
        ),
      )
    )

    let step =
      model.processEventDryRun(
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
    check step.admission.messages[0].kind == MsgKind.WlWindowStateChanged
    check step.admission.effects.len > 0
    check step.admission.effects.anyIt(it.kind == EffectKind.EffRenderDirty)
    check step.intents.len == 0
    check step.requests.len == 0
    check step.dryRunExecutions.len == 0
