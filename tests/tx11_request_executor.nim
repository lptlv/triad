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
    check executions[0].request.kind == X11RequestKind.XrqConfigureWindow
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

  test "xcb dry-run boundary logs request records without a display":
    let run =
      @[
        Effect(kind: EffectKind.EffFocusWindow, focusId: 10),
        Effect(kind: EffectKind.EffCloseWindow, closeId: 11),
      ].x11IntentsFor().x11RequestsFor().executeWithXcb(dryRun = true)

    check run.code == 0
    check run.dryRun
    check run.logs.len == 3
    check run.logs[0] == "dry_run focus window=0x0000000a"
    check run.logs[1] == "dry_run close window=0x0000000b"
    check run.logs[2] == "request execution complete dry_run=1 count=2"

  test "xcb dry-run boundary rejects malformed configure records":
    let run =
      @[
        X11Request(
          kind: X11RequestKind.XrqConfigureWindow, windowId: 42, valueCount: 2
        )
      ].executeWithXcb(dryRun = true)

    check run.code != 0
    check run.dryRun
    check run.logs.len == 1
    check run.logs[0] == "error configure window=0x0000002a value_count=2"

  test "xcb live boundary reports connection failure for missing display":
    let run =
      @[
        Effect(kind: EffectKind.EffFocusWindow, focusId: 10)
      ].x11IntentsFor().x11RequestsFor().executeWithXcb(
        displayName = ":triad-missing-display", dryRun = false
      )

    check run.code != 0
    check not run.dryRun
    check run.logs.len == 1
    check run.logs[0] == "error failed to connect to X display"
