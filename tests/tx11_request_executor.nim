import std/unittest

import ../src/core/effects
import ../src/x11/effect_adapter
import ../src/x11/request_builder
import ../src/x11/request_executor

suite "X11 request executor":
  test "dry-run execution records configure request without applying it":
    let executions =
      Effect(
        kind: EffectKind.EffSetPosition, windowId: 42, x: 10, y: 20, w: 640, h: 480
      ).x11IntentsFor().x11RequestsFor().executeDryRun()

    check executions.len == 1
    check not executions[0].applied
    check executions[0].request.kind == XrqConfigureWindow
    check executions[0].description ==
      "configure window=0x0000002a x=10 y=20 w=640 h=480"

  test "dry-run execution describes focus and close requests":
    let executions =
      @[
        Effect(kind: EffectKind.EffFocusWindow, focusId: 10),
        Effect(kind: EffectKind.EffCloseWindow, closeId: 11),
      ].x11IntentsFor().x11RequestsFor().executeDryRun()

    check executions.len == 2
    check not executions[0].applied
    check executions[0].description == "focus window=0x0000000a"
    check not executions[1].applied
    check executions[1].description == "close window=0x0000000b"
