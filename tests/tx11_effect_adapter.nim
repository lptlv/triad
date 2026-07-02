import std/unittest

import ../src/core/effects
import ../src/x11/effect_adapter

suite "X11 effect adapter":
  test "translates set position to configure-window intent":
    let intents =
      Effect(
        kind: EffectKind.EffSetPosition, windowId: 42, x: 10, y: 20, w: 640, h: 480
      ).x11IntentsFor()

    check intents.len == 1
    check intents[0].kind == X11EffectIntentKind.ConfigureWindow
    check intents[0].configureWindowId == 42
    let expectedMask =
      X11ConfigureMaskX or X11ConfigureMaskY or X11ConfigureMaskWidth or
      X11ConfigureMaskHeight
    check intents[0].configureMask == expectedMask
    check intents[0].configureX == 10
    check intents[0].configureY == 20
    check intents[0].configureW == 640
    check intents[0].configureH == 480

  test "clamps configure dimensions to X11-positive sizes":
    let intents =
      Effect(
        kind: EffectKind.EffSetPosition, windowId: 7, x: -5, y: -6, w: 0, h: -10
      ).x11IntentsFor()

    check intents.len == 1
    check intents[0].configureWindowId == 7
    check intents[0].configureX == -5
    check intents[0].configureY == -6
    check intents[0].configureW == 1
    check intents[0].configureH == 1

  test "translates focus and close effects":
    let intents =
      @[
        Effect(kind: EffectKind.EffFocusWindow, focusId: 10),
        Effect(kind: EffectKind.EffCloseWindow, closeId: 11),
      ].x11IntentsFor()

    check intents.len == 2
    check intents[0].kind == X11EffectIntentKind.FocusWindow
    check intents[0].focusWindowId == 10
    check intents[1].kind == X11EffectIntentKind.CloseWindow
    check intents[1].closeWindowId == 11

  test "ignores unsupported and zero-id effects":
    let intents =
      @[
        Effect(kind: EffectKind.EffRenderDirty, renderDirtyReason: "test"),
        Effect(kind: EffectKind.EffFocusWindow, focusId: 0),
        Effect(kind: EffectKind.EffCloseWindow, closeId: 0),
      ].x11IntentsFor()

    check intents.len == 0
