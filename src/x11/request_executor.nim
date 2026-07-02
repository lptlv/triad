import std/strutils

import request_builder

type X11RequestExecution* = object
  request*: X11Request
  applied*: bool
  description*: string

proc requestDescription(request: X11Request): string =
  case request.kind
  of XrqConfigureWindow:
    "configure window=0x" & request.windowId.toHex(8).toLowerAscii() & " x=" &
      $request.values[0] & " y=" & $request.values[1] & " w=" & $request.values[2] &
      " h=" & $request.values[3]
  of XrqSetInputFocus:
    "focus window=0x" & request.windowId.toHex(8).toLowerAscii()
  of XrqSendCloseWindow:
    "close window=0x" & request.windowId.toHex(8).toLowerAscii()

proc executeDryRun*(request: X11Request): X11RequestExecution =
  X11RequestExecution(
    request: request, applied: false, description: request.requestDescription()
  )

proc executeDryRun*(requests: openArray[X11Request]): seq[X11RequestExecution] =
  for request in requests:
    result.add(request.executeDryRun())
