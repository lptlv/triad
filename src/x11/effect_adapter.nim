import ../core/effects

const
  X11ConfigureMaskX* = 1'u32 shl 0
  X11ConfigureMaskY* = 1'u32 shl 1
  X11ConfigureMaskWidth* = 1'u32 shl 2
  X11ConfigureMaskHeight* = 1'u32 shl 3

type
  X11EffectIntentKind* {.pure.} = enum
    ConfigureWindow
    FocusWindow
    CloseWindow
    SetFullscreenState
    SetMaximizedState

  X11EffectIntent* = object
    case kind*: X11EffectIntentKind
    of X11EffectIntentKind.ConfigureWindow:
      configureWindowId*: uint32
      configureMask*: uint32
      configureX*, configureY*, configureW*, configureH*: int32
    of X11EffectIntentKind.FocusWindow:
      focusWindowId*: uint32
    of X11EffectIntentKind.CloseWindow:
      closeWindowId*: uint32
    of X11EffectIntentKind.SetFullscreenState:
      fullscreenWindowId*: uint32
      fullscreenActive*: bool
    of X11EffectIntentKind.SetMaximizedState:
      maximizedWindowId*: uint32
      maximizedActive*: bool

proc positiveDimension(value: int32): int32 =
  max(1'i32, value)

proc x11IntentsFor*(effect: Effect): seq[X11EffectIntent] =
  case effect.kind
  of EffectKind.EffSetPosition:
    result.add(
      X11EffectIntent(
        kind: X11EffectIntentKind.ConfigureWindow,
        configureWindowId: effect.windowId,
        configureMask:
          X11ConfigureMaskX or X11ConfigureMaskY or X11ConfigureMaskWidth or
          X11ConfigureMaskHeight,
        configureX: effect.x,
        configureY: effect.y,
        configureW: effect.w.positiveDimension(),
        configureH: effect.h.positiveDimension(),
      )
    )
  of EffectKind.EffFocusWindow:
    if effect.focusId != 0:
      result.add(
        X11EffectIntent(
          kind: X11EffectIntentKind.FocusWindow, focusWindowId: effect.focusId
        )
      )
  of EffectKind.EffCloseWindow:
    if effect.closeId != 0:
      result.add(
        X11EffectIntent(
          kind: X11EffectIntentKind.CloseWindow, closeWindowId: effect.closeId
        )
      )
  of EffectKind.EffSetFullscreen:
    if effect.fsWinId != 0:
      result.add(
        X11EffectIntent(
          kind: X11EffectIntentKind.SetFullscreenState,
          fullscreenWindowId: effect.fsWinId,
          fullscreenActive: effect.isFullscreen,
        )
      )
  of EffectKind.EffSetMaximized:
    if effect.maxWinId != 0:
      result.add(
        X11EffectIntent(
          kind: X11EffectIntentKind.SetMaximizedState,
          maximizedWindowId: effect.maxWinId,
          maximizedActive: effect.isMaximized,
        )
      )
  else:
    discard

proc x11IntentsFor*(effects: openArray[Effect]): seq[X11EffectIntent] =
  for effect in effects:
    result.add(effect.x11IntentsFor())
