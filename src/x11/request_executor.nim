import std/strutils

import request_builder, xcb_ffi

type X11RequestExecution* = object
  request*: X11Request
  applied*: bool
  description*: string

type X11RequestRunResult* = object
  code*: int
  dryRun*: bool
  logs*: seq[string]

proc requestDescription(request: X11Request): string =
  case request.kind
  of X11RequestKind.XrqConfigureWindow:
    "configure window=0x" & request.windowId.toHex(8).toLowerAscii() & " x=" &
      $request.values[0] & " y=" & $request.values[1] & " w=" & $request.values[2] &
      " h=" & $request.values[3]
  of X11RequestKind.XrqSetInputFocus:
    "focus window=0x" & request.windowId.toHex(8).toLowerAscii()
  of X11RequestKind.XrqSendCloseWindow:
    "close window=0x" & request.windowId.toHex(8).toLowerAscii()
  of X11RequestKind.XrqMapWindow:
    "map window=0x" & request.windowId.toHex(8).toLowerAscii()
  of X11RequestKind.XrqSetFullscreenState:
    "set-fullscreen window=0x" & request.windowId.toHex(8).toLowerAscii() & " active=" &
      $(request.values[0] != 0)
  of X11RequestKind.XrqSetMaximizedState:
    "set-maximized window=0x" & request.windowId.toHex(8).toLowerAscii() & " active=" &
      $(request.values[0] != 0)

proc executeDryRun*(request: X11Request): X11RequestExecution =
  X11RequestExecution(
    request: request, applied: false, description: request.requestDescription()
  )

proc executeDryRun*(requests: openArray[X11Request]): seq[X11RequestExecution] =
  for request in requests:
    result.add(request.executeDryRun())

proc requestLogCallback(userData: pointer, message: cstring) {.cdecl.} =
  if userData != nil and message != nil:
    cast[ptr seq[string]](userData)[].add($message)

proc executeWithXcb*(
    requests: openArray[X11Request], displayName = "", dryRun = true
): X11RequestRunResult =
  var logs: seq[string]
  let display = if displayName.len == 0: nil else: displayName.cstring
  let requestPtr =
    if requests.len == 0:
      nil
    else:
      unsafeAddr requests[0]
  result.code = int(
    triadX11ExecuteRequests(
      display,
      requestPtr,
      cuint(requests.len),
      cint(ord(dryRun)),
      requestLogCallback,
      addr logs,
    )
  )
  result.dryRun = dryRun
  result.logs = logs

proc executeWithActiveProbe*(requests: openArray[X11Request]): X11RequestRunResult =
  var logs: seq[string]
  let requestPtr =
    if requests.len == 0:
      nil
    else:
      unsafeAddr requests[0]
  result.code = int(
    triadX11ExecuteRequestsOnActiveProbe(
      requestPtr, cuint(requests.len), requestLogCallback, addr logs
    )
  )
  result.dryRun = false
  result.logs = logs
