import std/strutils

import ../core/msg

const
  X11ConfigureMaskWidth = 1'u32 shl 2
  X11ConfigureMaskHeight = 1'u32 shl 3
  X11StateFullscreen = "_NET_WM_STATE_FULLSCREEN"
  X11StateMaximizedHorz = "_NET_WM_STATE_MAXIMIZED_HORZ"
  X11StateMaximizedVert = "_NET_WM_STATE_MAXIMIZED_VERT"
  X11StateHidden = "_NET_WM_STATE_HIDDEN"
  X11StateDemandsAttention = "_NET_WM_STATE_DEMANDS_ATTENTION"

type
  X11ProbeEventKind* {.pure, size: sizeof(cuint).} = enum
    XpeWindowDiscovered = 0
    XpeWindowDestroyed = 1
    XpeWindowUnmapped = 2
    XpeOutputDiscovered = 3
    XpeConfigureRequested = 4
    XpePropertyChanged = 5
    XpeFocusChanged = 6
    XpePointerEntered = 7
    XpeRandrChanged = 8
    XpeMapRequested = 9

  X11ProbeEvent* {.bycopy.} = object
    kind*: X11ProbeEventKind
    id*: uint32
    parentId*: uint32
    pid*: int32
    x*, y*, w*, h*: int32
    valueMask*: uint32
    sibling*: uint32
    stackMode*: uint32
    root*: uint32
    overrideRedirect*: uint8
    mapped*: uint8
    connected*: uint8
    focused*: uint8
    name*: array[256, char]
    title*: array[512, char]

  X11BackendEventKind* {.pure.} = enum
    WindowDiscovered
    MapRequested
    WindowDestroyed
    WindowUnmapped
    OutputDiscovered
    ConfigureRequested
    PropertyChanged
    FocusChanged
    PointerEntered
    RandrChanged

  X11WindowSnapshot* = object
    id*: uint32
    parentId*: uint32
    pid*: int32
    wmClass*: string
    title*: string
    x*, y*, w*, h*: int32
    overrideRedirect*: bool
    mapped*: bool

  X11OutputSnapshot* = object
    id*: uint32
    name*: string
    connected*: bool
    x*, y*, w*, h*: int32

  X11ConfigureRequest* = object
    windowId*: uint32
    valueMask*: uint32
    x*, y*, w*, h*: int32
    sibling*: uint32
    stackMode*: uint32

  X11BackendEvent* = object
    case kind*: X11BackendEventKind
    of X11BackendEventKind.WindowDiscovered, X11BackendEventKind.MapRequested:
      window*: X11WindowSnapshot
    of X11BackendEventKind.WindowDestroyed, X11BackendEventKind.WindowUnmapped:
      windowId*: uint32
    of X11BackendEventKind.OutputDiscovered:
      output*: X11OutputSnapshot
    of X11BackendEventKind.ConfigureRequested:
      configure*: X11ConfigureRequest
    of X11BackendEventKind.PropertyChanged:
      propertyWindowId*: uint32
      propertyAtom*: string
      propertyValue*: string
      propertyPid*: int32
    of X11BackendEventKind.FocusChanged:
      focusWindowId*: uint32
      focused*: bool
    of X11BackendEventKind.PointerEntered:
      enterWindowId*: uint32
    of X11BackendEventKind.RandrChanged:
      randrRoot*: uint32
      randrW*, randrH*: int32

proc x11WindowIdentifier*(id: uint32): string =
  "x11:0x" & toHex(id, 8).toLowerAscii()

proc appIdFromWmClass*(wmClass: string): string =
  let cleaned = wmClass.strip()
  if cleaned.len == 0:
    return ""
  let slash = cleaned.rfind("/")
  if slash >= 0 and slash + 1 < cleaned.len:
    return cleaned[slash + 1 .. ^1]
  cleaned

proc stateTokenSet(value: string): seq[string] =
  for token in value.splitWhitespace():
    result.add(token)

proc hasState(tokens: openArray[string], state: string): bool =
  for token in tokens:
    if token == state:
      return true

proc cArrayString[N: static[int]](value: array[N, char]): string =
  for ch in value:
    if ch == '\0':
      break
    result.add(ch)

proc backendEventFromProbe*(event: X11ProbeEvent): X11BackendEvent =
  case event.kind
  of X11ProbeEventKind.XpeWindowDiscovered:
    X11BackendEvent(
      kind: X11BackendEventKind.WindowDiscovered,
      window: X11WindowSnapshot(
        id: event.id,
        parentId: event.parentId,
        pid: event.pid,
        wmClass: event.name.cArrayString(),
        title: event.title.cArrayString(),
        x: event.x,
        y: event.y,
        w: event.w,
        h: event.h,
        overrideRedirect: event.overrideRedirect != 0,
        mapped: event.mapped != 0,
      ),
    )
  of X11ProbeEventKind.XpeMapRequested:
    X11BackendEvent(
      kind: X11BackendEventKind.MapRequested,
      window: X11WindowSnapshot(
        id: event.id,
        parentId: event.parentId,
        pid: event.pid,
        wmClass: event.name.cArrayString(),
        title: event.title.cArrayString(),
        x: event.x,
        y: event.y,
        w: event.w,
        h: event.h,
        overrideRedirect: event.overrideRedirect != 0,
        mapped: event.mapped != 0,
      ),
    )
  of X11ProbeEventKind.XpeWindowDestroyed:
    X11BackendEvent(kind: X11BackendEventKind.WindowDestroyed, windowId: event.id)
  of X11ProbeEventKind.XpeWindowUnmapped:
    X11BackendEvent(kind: X11BackendEventKind.WindowUnmapped, windowId: event.id)
  of X11ProbeEventKind.XpeOutputDiscovered:
    X11BackendEvent(
      kind: X11BackendEventKind.OutputDiscovered,
      output: X11OutputSnapshot(
        id: event.id,
        name: event.name.cArrayString(),
        connected: event.connected != 0,
        x: event.x,
        y: event.y,
        w: event.w,
        h: event.h,
      ),
    )
  of X11ProbeEventKind.XpeConfigureRequested:
    X11BackendEvent(
      kind: X11BackendEventKind.ConfigureRequested,
      configure: X11ConfigureRequest(
        windowId: event.id,
        valueMask: event.valueMask,
        x: event.x,
        y: event.y,
        w: event.w,
        h: event.h,
        sibling: event.sibling,
        stackMode: event.stackMode,
      ),
    )
  of X11ProbeEventKind.XpePropertyChanged:
    X11BackendEvent(
      kind: X11BackendEventKind.PropertyChanged,
      propertyWindowId: event.id,
      propertyAtom: event.name.cArrayString(),
      propertyValue: event.title.cArrayString(),
      propertyPid: event.pid,
    )
  of X11ProbeEventKind.XpeFocusChanged:
    X11BackendEvent(
      kind: X11BackendEventKind.FocusChanged,
      focusWindowId: event.id,
      focused: event.focused != 0,
    )
  of X11ProbeEventKind.XpePointerEntered:
    X11BackendEvent(kind: X11BackendEventKind.PointerEntered, enterWindowId: event.id)
  of X11ProbeEventKind.XpeRandrChanged:
    X11BackendEvent(
      kind: X11BackendEventKind.RandrChanged,
      randrRoot: event.root,
      randrW: event.w,
      randrH: event.h,
    )

proc messagesFor*(event: X11BackendEvent): seq[Msg] =
  case event.kind
  of X11BackendEventKind.WindowDiscovered, X11BackendEventKind.MapRequested:
    if event.window.overrideRedirect:
      return
    result.add(
      Msg(
        kind: MsgKind.WlWindowCreated,
        windowId: event.window.id,
        createdParentWindowId: event.window.parentId,
        createdPid: event.window.pid,
        appId: event.window.wmClass.appIdFromWmClass(),
        title: event.window.title,
        createdIdentifier: event.window.id.x11WindowIdentifier(),
        deferAdmission: false,
      )
    )
    if event.window.w > 0 or event.window.h > 0:
      result.add(
        Msg(
          kind: MsgKind.WlWindowDimensions,
          dimensionsWindowId: event.window.id,
          actualWidth: event.window.w,
          actualHeight: event.window.h,
        )
      )
    if event.window.pid > 0:
      result.add(
        Msg(
          kind: MsgKind.WlWindowPid,
          pidWindowId: event.window.id,
          windowPid: event.window.pid,
        )
      )
  of X11BackendEventKind.WindowDestroyed, X11BackendEventKind.WindowUnmapped:
    result.add(Msg(kind: MsgKind.WlWindowDestroyed, destroyedId: event.windowId))
  of X11BackendEventKind.OutputDiscovered:
    if not event.output.connected:
      result.add(Msg(kind: MsgKind.WlOutputRemoved, removedOutputId: event.output.id))
      return
    if event.output.w > 0 or event.output.h > 0:
      result.add(
        Msg(
          kind: MsgKind.WlOutputDimensions,
          outputId: event.output.id,
          width: event.output.w,
          height: event.output.h,
        )
      )
    if event.output.name.len > 0:
      result.add(
        Msg(
          kind: MsgKind.WlOutputName,
          nameOutputId: event.output.id,
          outputName: event.output.name,
        )
      )
    result.add(
      Msg(
        kind: MsgKind.WlOutputPosition,
        positionOutputId: event.output.id,
        outputX: event.output.x,
        outputY: event.output.y,
      )
    )
  of X11BackendEventKind.FocusChanged:
    if event.focused:
      result.add(Msg(kind: MsgKind.WlFocusChanged, newFocusedId: event.focusWindowId))
  of X11BackendEventKind.ConfigureRequested:
    let requiredMask = X11ConfigureMaskWidth or X11ConfigureMaskHeight
    if (event.configure.valueMask and requiredMask) == requiredMask and
        event.configure.w > 0 and event.configure.h > 0:
      result.add(
        Msg(
          kind: MsgKind.WlWindowDimensions,
          dimensionsWindowId: event.configure.windowId,
          actualWidth: event.configure.w,
          actualHeight: event.configure.h,
        )
      )
  of X11BackendEventKind.PropertyChanged:
    case event.propertyAtom
    of "WM_CLASS":
      if event.propertyValue.len > 0:
        result.add(
          Msg(
            kind: MsgKind.WlWindowAppId,
            appIdWindowId: event.propertyWindowId,
            updatedAppId: event.propertyValue.appIdFromWmClass(),
          )
        )
    of "WM_NAME", "_NET_WM_NAME":
      result.add(
        Msg(
          kind: MsgKind.WlWindowTitle,
          titleWindowId: event.propertyWindowId,
          updatedTitle: event.propertyValue,
        )
      )
    of "_NET_WM_PID":
      if event.propertyPid > 0:
        result.add(
          Msg(
            kind: MsgKind.WlWindowPid,
            pidWindowId: event.propertyWindowId,
            windowPid: event.propertyPid,
          )
        )
    of "_NET_WM_STATE":
      let tokens = event.propertyValue.stateTokenSet()
      result.add(
        Msg(
          kind: MsgKind.WlWindowStateChanged,
          stateWindowId: event.propertyWindowId,
          stateFullscreen: tokens.hasState(X11StateFullscreen),
          stateMaximized:
            tokens.hasState(X11StateMaximizedHorz) or
            tokens.hasState(X11StateMaximizedVert),
          stateMinimized: tokens.hasState(X11StateHidden),
          stateUrgent: tokens.hasState(X11StateDemandsAttention),
        )
      )
    else:
      discard
  of X11BackendEventKind.PointerEntered, X11BackendEventKind.RandrChanged:
    discard
