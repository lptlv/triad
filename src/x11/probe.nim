import std/strutils

import ../core/msg
import atoms, events, xcb_ffi

proc probeLogCallback(userData: pointer, message: cstring) {.cdecl.} =
  discard userData
  if message != nil:
    stdout.writeLine($message)
    stdout.flushFile()

proc dryRunMessageLabel(msg: Msg): string =
  case msg.kind
  of MsgKind.WlWindowCreated:
    "WlWindowCreated id=" & $msg.windowId & " app_id=\"" & msg.appId &
      "\" title=\"" & msg.title & "\""
  of MsgKind.WlWindowDestroyed:
    "WlWindowDestroyed id=" & $msg.destroyedId
  of MsgKind.WlWindowDimensions:
    "WlWindowDimensions id=" & $msg.dimensionsWindowId & " size=" &
      $msg.actualWidth & "x" & $msg.actualHeight
  of MsgKind.WlWindowPid:
    "WlWindowPid id=" & $msg.pidWindowId & " pid=" & $msg.windowPid
  of MsgKind.WlWindowAppId:
    "WlWindowAppId id=" & $msg.appIdWindowId & " app_id=\"" & msg.updatedAppId & "\""
  of MsgKind.WlWindowTitle:
    "WlWindowTitle id=" & $msg.titleWindowId & " title=\"" & msg.updatedTitle & "\""
  of MsgKind.WlWindowStateChanged:
    "WlWindowStateChanged id=" & $msg.stateWindowId & " fullscreen=" &
      $msg.stateFullscreen & " maximized=" & $msg.stateMaximized & " minimized=" &
      $msg.stateMinimized
  of MsgKind.WlOutputDimensions:
    "WlOutputDimensions id=" & $msg.outputId & " size=" & $msg.width & "x" &
      $msg.height
  of MsgKind.WlOutputName:
    "WlOutputName id=" & $msg.nameOutputId & " name=\"" & msg.outputName & "\""
  of MsgKind.WlOutputPosition:
    "WlOutputPosition id=" & $msg.positionOutputId & " xy=" & $msg.outputX &
      "," & $msg.outputY
  of MsgKind.WlOutputRemoved:
    "WlOutputRemoved id=" & $msg.removedOutputId
  of MsgKind.WlFocusChanged:
    "WlFocusChanged id=" & $msg.newFocusedId
  else:
    $msg.kind

proc eventLabel(event: X11BackendEvent): string =
  case event.kind
  of X11BackendEventKind.WindowDiscovered:
    "WindowDiscovered id=" & $event.window.id & " class=\"" &
      event.window.wmClass & "\" title=\"" & event.window.title & "\""
  of X11BackendEventKind.WindowDestroyed:
    "WindowDestroyed id=" & $event.windowId
  of X11BackendEventKind.WindowUnmapped:
    "WindowUnmapped id=" & $event.windowId
  of X11BackendEventKind.OutputDiscovered:
    "OutputDiscovered id=" & $event.output.id & " name=\"" & event.output.name &
      "\" connected=" & $event.output.connected
  of X11BackendEventKind.ConfigureRequested:
    "ConfigureRequested id=" & $event.configure.windowId & " mask=0x" &
      toHex(event.configure.valueMask, 4).toLowerAscii()
  of X11BackendEventKind.PropertyChanged:
    "PropertyChanged id=" & $event.propertyWindowId & " atom=\"" &
      event.propertyAtom & "\""
  of X11BackendEventKind.FocusChanged:
    "FocusChanged id=" & $event.focusWindowId & " focused=" & $event.focused
  of X11BackendEventKind.PointerEntered:
    "PointerEntered id=" & $event.enterWindowId
  of X11BackendEventKind.RandrChanged:
    "RandrChanged root=" & $event.randrRoot & " size=" & $event.randrW & "x" &
      $event.randrH

proc probeEventCallback(userData: pointer, raw: ptr X11ProbeEvent) {.cdecl.} =
  discard userData
  if raw == nil:
    return
  let event = backendEventFromProbe(raw[])
  stdout.writeLine("backend_event " & event.eventLabel())
  for msg in event.messagesFor():
    stdout.writeLine("dry_run_msg " & msg.dryRunMessageLabel())
  stdout.flushFile()

proc runX11Probe*(displayName = "", once = false): int =
  let display =
    if displayName.len == 0:
      nil
    else:
      displayName.cstring
  discard RequiredX11Atoms
  int(
    triadX11ProbeRun(
      display, cint(ord(once)), probeLogCallback, probeEventCallback, nil
    )
  )
