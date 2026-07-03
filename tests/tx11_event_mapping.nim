import unittest

import ../src/core/msg
import ../src/x11/events

suite "X11 event mapping":
  test "raw probe window event maps to typed backend event":
    var raw = X11ProbeEvent(
      kind: X11ProbeEventKind.XpeWindowDiscovered,
      id: 0x2a,
      parentId: 7,
      pid: 1234,
      x: 10,
      y: 20,
      w: 800,
      h: 600,
      mapped: 1,
    )
    for idx, ch in "kitty/kitty":
      raw.name[idx] = ch
    for idx, ch in "Terminal":
      raw.title[idx] = ch

    let event = raw.backendEventFromProbe()
    check event.kind == X11BackendEventKind.WindowDiscovered
    check event.window.id == 0x2a
    check event.window.parentId == 7
    check event.window.pid == 1234
    check event.window.wmClass == "kitty/kitty"
    check event.window.title == "Terminal"
    check event.window.x == 10
    check event.window.y == 20
    check event.window.w == 800
    check event.window.h == 600
    check event.window.mapped

  test "raw probe map request maps to distinct backend event":
    var raw = X11ProbeEvent(
      kind: X11ProbeEventKind.XpeMapRequested,
      id: 0x2b,
      parentId: 7,
      pid: 1235,
      x: 12,
      y: 24,
      w: 640,
      h: 480,
    )
    for idx, ch in "app/app":
      raw.name[idx] = ch
    for idx, ch in "App":
      raw.title[idx] = ch

    let event = raw.backendEventFromProbe()
    check event.kind == X11BackendEventKind.MapRequested
    check event.window.id == 0x2b
    check event.window.parentId == 7
    check event.window.pid == 1235
    check event.window.wmClass == "app/app"
    check event.window.title == "App"
    check event.window.x == 12
    check event.window.y == 24
    check event.window.w == 640
    check event.window.h == 480

  test "raw probe output event maps to typed backend event":
    var raw = X11ProbeEvent(
      kind: X11ProbeEventKind.XpeOutputDiscovered,
      id: 5,
      connected: 1,
      x: 1920,
      y: 0,
      w: 2560,
      h: 1440,
    )
    for idx, ch in "DP-1":
      raw.name[idx] = ch

    let event = raw.backendEventFromProbe()
    check event.kind == X11BackendEventKind.OutputDiscovered
    check event.output.id == 5
    check event.output.name == "DP-1"
    check event.output.connected
    check event.output.x == 1920
    check event.output.y == 0
    check event.output.w == 2560
    check event.output.h == 1440

  test "raw probe configure and property events preserve observed data":
    var propertyRaw = X11ProbeEvent(kind: X11ProbeEventKind.XpePropertyChanged, id: 9)
    for idx, ch in "_NET_WM_STATE":
      propertyRaw.name[idx] = ch
    for idx, ch in "state-value":
      propertyRaw.title[idx] = ch
    propertyRaw.pid = 1234
    let property = propertyRaw.backendEventFromProbe()
    check property.kind == X11BackendEventKind.PropertyChanged
    check property.propertyWindowId == 9
    check property.propertyAtom == "_NET_WM_STATE"
    check property.propertyValue == "state-value"
    check property.propertyPid == 1234

    let configure = X11ProbeEvent(
      kind: X11ProbeEventKind.XpeConfigureRequested,
      id: 10,
      valueMask: 0x0f,
      x: 1,
      y: 2,
      w: 300,
      h: 200,
      sibling: 11,
      stackMode: 1,
    ).backendEventFromProbe()
    check configure.kind == X11BackendEventKind.ConfigureRequested
    check configure.configure.windowId == 10
    check configure.configure.valueMask == 0x0f
    check configure.configure.x == 1
    check configure.configure.y == 2
    check configure.configure.w == 300
    check configure.configure.h == 200
    check configure.configure.sibling == 11
    check configure.configure.stackMode == 1

  test "raw key binding event preserves binding identity without model messages":
    var raw =
      X11ProbeEvent(kind: X11ProbeEventKind.XpeKeyBinding, id: 43, valueMask: 64'u32)
    for idx, ch in "Super+h":
      raw.name[idx] = ch

    let event = raw.backendEventFromProbe()
    check event.kind == X11BackendEventKind.KeyBinding
    check event.keyBinding == "Super+h"
    check event.keyBindingKeycode == 43
    check event.keyBindingModifiers == 64'u32
    check event.messagesFor().len == 0

  test "raw pointer binding event preserves binding identity without model messages":
    var raw = X11ProbeEvent(
      kind: X11ProbeEventKind.XpePointerBinding,
      id: 2,
      parentId: 0x31,
      x: 120,
      y: 140,
      valueMask: 64'u32,
    )
    for idx, ch in "Super+middle":
      raw.name[idx] = ch

    let event = raw.backendEventFromProbe()
    check event.kind == X11BackendEventKind.PointerBinding
    check event.pointerBinding == "Super+middle"
    check event.pointerBindingButton == 2
    check event.pointerBindingModifiers == 64'u32
    check event.pointerBindingTargetWindowId == 0x31
    check event.pointerBindingRootX == 120
    check event.pointerBindingRootY == 140
    check event.messagesFor().len == 0

  test "raw axis binding event preserves binding identity without model messages":
    var raw =
      X11ProbeEvent(kind: X11ProbeEventKind.XpeAxisBinding, id: 4, valueMask: 64'u32)
    for idx, ch in "Super+wheel-up":
      raw.name[idx] = ch

    let event = raw.backendEventFromProbe()
    check event.kind == X11BackendEventKind.AxisBinding
    check event.axisBinding == "Super+wheel-up"
    check event.axisBindingButton == 4
    check event.axisBindingModifiers == 64'u32
    check event.messagesFor().len == 0

  test "raw pointer motion and release events preserve root coordinates":
    let motion = X11ProbeEvent(
      kind: X11ProbeEventKind.XpePointerMotion,
      id: 0x32,
      x: 170,
      y: 155,
      valueMask: 64'u32,
    ).backendEventFromProbe()
    check motion.kind == X11BackendEventKind.PointerMotion
    check motion.pointerMotionTargetWindowId == 0x32
    check motion.pointerMotionRootX == 170
    check motion.pointerMotionRootY == 155
    check motion.pointerMotionModifiers == 64'u32
    check motion.messagesFor().len == 0

    let release = X11ProbeEvent(
      kind: X11ProbeEventKind.XpePointerRelease,
      id: 1,
      parentId: 0x32,
      x: 170,
      y: 155,
      valueMask: 64'u32,
    ).backendEventFromProbe()
    check release.kind == X11BackendEventKind.PointerRelease
    check release.pointerReleaseButton == 1
    check release.pointerReleaseTargetWindowId == 0x32
    check release.pointerReleaseRootX == 170
    check release.pointerReleaseRootY == 155
    check release.pointerReleaseModifiers == 64'u32
    check release.messagesFor().len == 0

  test "window discovery maps to creation, dimensions, and pid messages":
    let messages = X11BackendEvent(
      kind: X11BackendEventKind.WindowDiscovered,
      window: X11WindowSnapshot(
        id: 42,
        parentId: 7,
        pid: 1234,
        wmClass: "kitty/kitty",
        title: "Terminal",
        x: 10,
        y: 20,
        w: 800,
        h: 600,
        mapped: true,
      ),
    ).messagesFor()

    check messages.len == 3
    check messages[0].kind == MsgKind.WlWindowCreated
    check messages[0].windowId == 42
    check messages[0].createdParentWindowId == 7
    check messages[0].createdPid == 1234
    check messages[0].appId == "kitty"
    check messages[0].title == "Terminal"
    check messages[0].createdIdentifier == "x11:0x0000002a"
    check not messages[0].deferAdmission
    check messages[1].kind == MsgKind.WlWindowDimensions
    check messages[1].dimensionsWindowId == 42
    check messages[1].actualWidth == 800
    check messages[1].actualHeight == 600
    check messages[2].kind == MsgKind.WlWindowPid
    check messages[2].pidWindowId == 42
    check messages[2].windowPid == 1234

  test "map request maps to creation, dimensions, and pid messages":
    let messages = X11BackendEvent(
      kind: X11BackendEventKind.MapRequested,
      window: X11WindowSnapshot(
        id: 43, parentId: 7, pid: 1235, wmClass: "app/app", title: "App", w: 640, h: 480
      ),
    ).messagesFor()

    check messages.len == 3
    check messages[0].kind == MsgKind.WlWindowCreated
    check messages[0].windowId == 43
    check messages[0].appId == "app"
    check messages[1].kind == MsgKind.WlWindowDimensions
    check messages[1].dimensionsWindowId == 43
    check messages[2].kind == MsgKind.WlWindowPid
    check messages[2].pidWindowId == 43

  test "override-redirect windows are not admitted":
    let messages = X11BackendEvent(
      kind: X11BackendEventKind.WindowDiscovered,
      window: X11WindowSnapshot(id: 9, wmClass: "menu", overrideRedirect: true),
    ).messagesFor()
    check messages.len == 0

  test "destroyed and unmapped windows map to destroy messages":
    let destroyed = X11BackendEvent(
      kind: X11BackendEventKind.WindowDestroyed, windowId: 11
    ).messagesFor()
    let unmapped = X11BackendEvent(
      kind: X11BackendEventKind.WindowUnmapped, windowId: 12
    ).messagesFor()

    check destroyed.len == 1
    check destroyed[0].kind == MsgKind.WlWindowDestroyed
    check destroyed[0].destroyedId == 11
    check unmapped.len == 1
    check unmapped[0].kind == MsgKind.WlWindowDestroyed
    check unmapped[0].destroyedId == 12

  test "connected output maps to dimensions, name, and position messages":
    let messages = X11BackendEvent(
      kind: X11BackendEventKind.OutputDiscovered,
      output: X11OutputSnapshot(
        id: 3, name: "DP-1", connected: true, x: 1920, y: 0, w: 2560, h: 1440
      ),
    ).messagesFor()

    check messages.len == 3
    check messages[0].kind == MsgKind.WlOutputDimensions
    check messages[0].outputId == 3
    check messages[0].width == 2560
    check messages[0].height == 1440
    check messages[1].kind == MsgKind.WlOutputName
    check messages[1].nameOutputId == 3
    check messages[1].outputName == "DP-1"
    check messages[2].kind == MsgKind.WlOutputPosition
    check messages[2].positionOutputId == 3
    check messages[2].outputX == 1920
    check messages[2].outputY == 0

  test "disconnected output maps to removed output":
    let messages = X11BackendEvent(
      kind: X11BackendEventKind.OutputDiscovered,
      output: X11OutputSnapshot(id: 4, name: "HDMI-A-1", connected: false),
    ).messagesFor()

    check messages.len == 1
    check messages[0].kind == MsgKind.WlOutputRemoved
    check messages[0].removedOutputId == 4

  test "focused event maps to focus changed and unfocused event is ignored":
    let focused = X11BackendEvent(
      kind: X11BackendEventKind.FocusChanged, focusWindowId: 88, focused: true
    ).messagesFor()
    let unfocused = X11BackendEvent(
      kind: X11BackendEventKind.FocusChanged, focusWindowId: 88, focused: false
    ).messagesFor()

    check focused.len == 1
    check focused[0].kind == MsgKind.WlFocusChanged
    check focused[0].newFocusedId == 88
    check unfocused.len == 0

  test "configure request maps explicit size changes to dimensions":
    let messages = X11BackendEvent(
      kind: X11BackendEventKind.ConfigureRequested,
      configure: X11ConfigureRequest(windowId: 1, valueMask: 0x0c, w: 640, h: 480),
    ).messagesFor()

    check messages.len == 1
    check messages[0].kind == MsgKind.WlWindowDimensions
    check messages[0].dimensionsWindowId == 1
    check messages[0].actualWidth == 640
    check messages[0].actualHeight == 480

  test "known property changes map to window metadata updates":
    let title = X11BackendEvent(
      kind: X11BackendEventKind.PropertyChanged,
      propertyWindowId: 1,
      propertyAtom: "_NET_WM_NAME",
      propertyValue: "Updated",
    ).messagesFor()
    let appId = X11BackendEvent(
      kind: X11BackendEventKind.PropertyChanged,
      propertyWindowId: 1,
      propertyAtom: "WM_CLASS",
      propertyValue: "kitty/kitty",
    ).messagesFor()
    let pid = X11BackendEvent(
      kind: X11BackendEventKind.PropertyChanged,
      propertyWindowId: 1,
      propertyAtom: "_NET_WM_PID",
      propertyPid: 4321,
    ).messagesFor()

    check title.len == 1
    check title[0].kind == MsgKind.WlWindowTitle
    check title[0].titleWindowId == 1
    check title[0].updatedTitle == "Updated"
    check appId.len == 1
    check appId[0].kind == MsgKind.WlWindowAppId
    check appId[0].appIdWindowId == 1
    check appId[0].updatedAppId == "kitty"
    check pid.len == 1
    check pid[0].kind == MsgKind.WlWindowPid
    check pid[0].pidWindowId == 1
    check pid[0].windowPid == 4321

  test "net wm state changes map to observed window state":
    let messages = X11BackendEvent(
      kind: X11BackendEventKind.PropertyChanged,
      propertyWindowId: 1,
      propertyAtom: "_NET_WM_STATE",
      propertyValue:
        "_NET_WM_STATE_FULLSCREEN _NET_WM_STATE_MAXIMIZED_HORZ " &
        "_NET_WM_STATE_HIDDEN _NET_WM_STATE_DEMANDS_ATTENTION",
    ).messagesFor()
    let cleared = X11BackendEvent(
      kind: X11BackendEventKind.PropertyChanged,
      propertyWindowId: 1,
      propertyAtom: "_NET_WM_STATE",
      propertyValue: "",
    ).messagesFor()

    check messages.len == 1
    check messages[0].kind == MsgKind.WlWindowStateChanged
    check messages[0].stateWindowId == 1
    check messages[0].stateFullscreen
    check messages[0].stateMaximized
    check messages[0].stateMinimized
    check messages[0].stateUrgent
    check cleared.len == 1
    check cleared[0].kind == MsgKind.WlWindowStateChanged
    check not cleared[0].stateFullscreen
    check not cleared[0].stateMaximized
    check not cleared[0].stateMinimized
    check not cleared[0].stateUrgent

  test "observed-only and incomplete events are explicit no-ops":
    let events = [
      X11BackendEvent(
        kind: X11BackendEventKind.ConfigureRequested,
        configure: X11ConfigureRequest(windowId: 1, valueMask: 0x04, w: 100, h: 0),
      ),
      X11BackendEvent(
        kind: X11BackendEventKind.PropertyChanged,
        propertyWindowId: 1,
        propertyAtom: "_NET_WM_WINDOW_TYPE",
      ),
      X11BackendEvent(kind: X11BackendEventKind.PointerEntered, enterWindowId: 1),
      X11BackendEvent(kind: X11BackendEventKind.RandrChanged, randrRoot: 1),
    ]
    for event in events:
      check event.messagesFor().len == 0
