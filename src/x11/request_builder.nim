import effect_adapter

type
  X11RequestKind* {.pure, size: sizeof(cuint).} = enum
    XrqConfigureWindow = 0
    XrqSetInputFocus = 1
    XrqSendCloseWindow = 2

  X11Request* {.bycopy.} = object
    kind*: X11RequestKind
    windowId*: uint32
    valueMask*: uint32
    valueCount*: uint32
    values*: array[4, int32]

proc configureValues(intent: X11EffectIntent): array[4, int32] =
  [
    intent.configureX,
    intent.configureY,
    intent.configureW,
    intent.configureH,
  ]

proc x11RequestFor*(intent: X11EffectIntent): X11Request =
  case intent.kind
  of X11EffectIntentKind.ConfigureWindow:
    X11Request(
      kind: X11RequestKind.XrqConfigureWindow,
      windowId: intent.configureWindowId,
      valueMask: intent.configureMask,
      valueCount: 4,
      values: intent.configureValues(),
    )
  of X11EffectIntentKind.FocusWindow:
    X11Request(kind: X11RequestKind.XrqSetInputFocus, windowId: intent.focusWindowId)
  of X11EffectIntentKind.CloseWindow:
    X11Request(
      kind: X11RequestKind.XrqSendCloseWindow, windowId: intent.closeWindowId
    )

proc x11RequestsFor*(intents: openArray[X11EffectIntent]): seq[X11Request] =
  for intent in intents:
    result.add(intent.x11RequestFor())
