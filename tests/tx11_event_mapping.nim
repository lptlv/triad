import unittest

import ../src/core/msg
import ../src/x11/events

suite "X11 event mapping":
  test "window discovery maps to creation, dimensions, and pid messages":
    let messages =
      X11BackendEvent(
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

  test "override-redirect windows are not admitted":
    let messages =
      X11BackendEvent(
        kind: X11BackendEventKind.WindowDiscovered,
        window: X11WindowSnapshot(id: 9, wmClass: "menu", overrideRedirect: true),
      ).messagesFor()
    check messages.len == 0

  test "destroyed and unmapped windows map to destroy messages":
    let destroyed =
      X11BackendEvent(
        kind: X11BackendEventKind.WindowDestroyed, windowId: 11
      ).messagesFor()
    let unmapped =
      X11BackendEvent(kind: X11BackendEventKind.WindowUnmapped, windowId: 12).messagesFor()

    check destroyed.len == 1
    check destroyed[0].kind == MsgKind.WlWindowDestroyed
    check destroyed[0].destroyedId == 11
    check unmapped.len == 1
    check unmapped[0].kind == MsgKind.WlWindowDestroyed
    check unmapped[0].destroyedId == 12

  test "connected output maps to dimensions, name, and position messages":
    let messages =
      X11BackendEvent(
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
    let messages =
      X11BackendEvent(
        kind: X11BackendEventKind.OutputDiscovered,
        output: X11OutputSnapshot(id: 4, name: "HDMI-A-1", connected: false),
      ).messagesFor()

    check messages.len == 1
    check messages[0].kind == MsgKind.WlOutputRemoved
    check messages[0].removedOutputId == 4

  test "focused event maps to focus changed and unfocused event is ignored":
    let focused =
      X11BackendEvent(
        kind: X11BackendEventKind.FocusChanged, focusWindowId: 88, focused: true
      ).messagesFor()
    let unfocused =
      X11BackendEvent(
        kind: X11BackendEventKind.FocusChanged, focusWindowId: 88, focused: false
      ).messagesFor()

    check focused.len == 1
    check focused[0].kind == MsgKind.WlFocusChanged
    check focused[0].newFocusedId == 88
    check unfocused.len == 0

  test "observed-only events are explicit no-ops":
    let events = [
      X11BackendEvent(
        kind: X11BackendEventKind.ConfigureRequested,
        configure: X11ConfigureRequest(windowId: 1, w: 100, h: 100),
      ),
      X11BackendEvent(
        kind: X11BackendEventKind.PropertyChanged,
        propertyWindowId: 1,
        propertyAtom: "_NET_WM_STATE",
      ),
      X11BackendEvent(kind: X11BackendEventKind.PointerEntered, enterWindowId: 1),
      X11BackendEvent(kind: X11BackendEventKind.RandrChanged, randrRoot: 1),
    ]
    for event in events:
      check event.messagesFor().len == 0
