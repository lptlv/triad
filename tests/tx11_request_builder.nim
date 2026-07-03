import std/unittest

import ../src/core/effects
import ../src/x11/effect_adapter
import ../src/x11/request_builder

suite "X11 request builder":
  test "builds configure-window request from set-position effect":
    let requests =
      Effect(
        kind: EffectKind.EffSetPosition, windowId: 42, x: 10, y: 20, w: 640, h: 480
      ).x11IntentsFor().x11RequestsFor()

    let expectedMask =
      X11ConfigureMaskX or X11ConfigureMaskY or X11ConfigureMaskWidth or
      X11ConfigureMaskHeight
    check requests.len == 1
    check requests[0].kind == X11RequestKind.XrqConfigureWindow
    check requests[0].windowId == 42
    check requests[0].valueMask == expectedMask
    check requests[0].valueCount == 4
    check requests[0].values == [10'i32, 20, 640, 480]

  test "preserves signed coordinates and positive clamped dimensions":
    let requests =
      Effect(
        kind: EffectKind.EffSetPosition, windowId: 7, x: -30, y: -40, w: 0, h: -5
      ).x11IntentsFor().x11RequestsFor()

    check requests.len == 1
    check requests[0].kind == X11RequestKind.XrqConfigureWindow
    check requests[0].values == [-30'i32, -40, 1, 1]

  test "builds focus and close request records":
    let requests =
      @[
        Effect(kind: EffectKind.EffFocusWindow, focusId: 10),
        Effect(kind: EffectKind.EffCloseWindow, closeId: 11),
      ].x11IntentsFor().x11RequestsFor()

    check requests.len == 2
    check requests[0].kind == X11RequestKind.XrqSetInputFocus
    check requests[0].windowId == 10
    check requests[0].valueMask == 0
    check requests[0].valueCount == 0
    check requests[1].kind == X11RequestKind.XrqSendCloseWindow
    check requests[1].windowId == 11
    check requests[1].valueMask == 0
    check requests[1].valueCount == 0

  test "builds map-window request record":
    let request = x11MapWindowRequest(12)

    check request.kind == X11RequestKind.XrqMapWindow
    check request.windowId == 12
    check request.valueMask == 0
    check request.valueCount == 0

  test "request ABI enum keeps stable wire values":
    check ord(X11RequestKind.XrqConfigureWindow) == 0
    check ord(X11RequestKind.XrqSetInputFocus) == 1
    check ord(X11RequestKind.XrqSendCloseWindow) == 2
    check ord(X11RequestKind.XrqMapWindow) == 3
