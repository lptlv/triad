import std/[json, options, strutils]

import ../core/msg
import ../types/shell_snapshot
import request_builder, request_executor

type X11WritableIpcRequest* = object
  handled*: bool
  requestName*: string
  windowId*: uint32
  workspaceIndex*: uint32
  followWindow*: bool
  reply*: string
  messages*: seq[Msg]
  requests*: seq[X11Request]

proc okReply(payload: JsonNode): string =
  $(%*{"ok": true, "triad": payload})

proc errReply(message: string): string =
  $(%*{"ok": false, "error": message})

proc uintFromField(node: JsonNode, field: string): Option[uint32] =
  if node.kind != JObject or not node.hasKey(field):
    return none(uint32)
  try:
    if node[field].kind == JInt and node[field].getInt() > 0 and
        node[field].getInt() <= int(high(uint32)):
      return some(uint32(node[field].getInt()))
  except CatchableError:
    discard
  none(uint32)

proc stringFromField(node: JsonNode, field: string): string =
  if node.kind == JObject and node.hasKey(field) and node[field].kind == JString:
    node[field].getStr()
  else:
    ""

proc boolFromField(node: JsonNode, field: string, default = false): bool =
  if node.kind == JObject and node.hasKey(field) and node[field].kind == JBool:
    node[field].getBool()
  else:
    default

proc snapshotHasWindow(snapshot: ShellSnapshot, windowId: uint32): bool =
  for win in snapshot.windows:
    if win.id == windowId:
      return true

proc xlibreCloseWindowReply(windowId: uint32, run: X11RequestRunResult): string =
  if run.code == 0:
    return okReply(
      %*{
        "version": TriadIpcVersion,
        "type": "xlibre-close-window",
        "window": windowId,
        "applied": true,
        "logs": run.logs,
      }
    )
  errReply("xlibre close-window failed: " & run.logs.join("; "))

proc xlibreFocusWindowReply(windowId: uint32, run: X11RequestRunResult): string =
  if run.code == 0:
    return okReply(
      %*{
        "version": TriadIpcVersion,
        "type": "xlibre-focus-window",
        "window": windowId,
        "applied": true,
        "logs": run.logs,
      }
    )
  errReply("xlibre focus-window failed: " & run.logs.join("; "))

proc xlibreFocusWorkspaceReply(
    workspaceIndex: uint32, run: X11RequestRunResult
): string =
  if run.code == 0:
    return okReply(
      %*{
        "version": TriadIpcVersion,
        "type": "xlibre-focus-workspace",
        "workspace": workspaceIndex,
        "applied": true,
        "logs": run.logs,
      }
    )
  errReply("xlibre focus-workspace failed: " & run.logs.join("; "))

proc xlibreMoveWindowToWorkspaceReply(
    windowId, workspaceIndex: uint32, followWindow: bool, run: X11RequestRunResult
): string =
  if run.code == 0:
    return okReply(
      %*{
        "version": TriadIpcVersion,
        "type": "xlibre-move-window-to-workspace",
        "window": windowId,
        "workspace": workspaceIndex,
        "follow": followWindow,
        "applied": true,
        "logs": run.logs,
      }
    )
  errReply("xlibre move-window-to-workspace failed: " & run.logs.join("; "))

proc xlibreWritableRequestFor*(
    line: string, snapshot: ShellSnapshot
): X11WritableIpcRequest =
  let stripped = line.strip()
  if stripped.len == 0 or stripped[0] != '{':
    return

  var root: JsonNode
  try:
    root = parseJson(stripped)
  except CatchableError:
    return

  if root.kind != JObject or not root.hasKey("triad"):
    return

  let payload = root["triad"]
  if payload.kind != JObject:
    return X11WritableIpcRequest(
      handled: true, reply: errReply("triad request must be an object")
    )

  let request = payload.stringFromField("request")
  if request notin [
    "xlibre-close-window", "xlibre-focus-window", "xlibre-focus-workspace",
    "xlibre-move-window-to-workspace",
  ]:
    return

  result.handled = true
  result.requestName = request
  let version = payload.uintFromField("version")
  if version.isNone or version.get() != TriadIpcVersion:
    result.reply = errReply("unsupported triad ipc version")
    return

  if request == "xlibre-focus-workspace":
    let workspaceIndex = payload.uintFromField("workspace")
    if workspaceIndex.isNone:
      result.reply = errReply("xlibre-focus-workspace requires positive workspace")
      return
    result.workspaceIndex = workspaceIndex.get()
    result.messages.add(
      Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: workspaceIndex.get())
    )
    return

  let windowId = payload.uintFromField("id")
  if windowId.isNone:
    result.reply = errReply(request & " requires positive id")
    return
  if not snapshot.snapshotHasWindow(windowId.get()):
    result.reply = errReply("unknown xlibre window id: " & $windowId.get())
    return
  result.windowId = windowId.get()

  if request == "xlibre-move-window-to-workspace":
    let workspaceIndex = payload.uintFromField("workspace")
    if workspaceIndex.isNone:
      result.reply =
        errReply("xlibre-move-window-to-workspace requires positive workspace")
      return
    result.workspaceIndex = workspaceIndex.get()
    result.followWindow = payload.boolFromField("follow", default = true)
    result.messages.add(
      Msg(
        kind: MsgKind.CmdMoveWindowToWorkspaceIndex,
        moveWorkspaceWindowId: windowId.get(),
        moveWorkspaceIndex: workspaceIndex.get(),
        moveWorkspaceFollowWindow: result.followWindow,
      )
    )
    return

  if request == "xlibre-close-window":
    result.requests.add(
      X11Request(kind: X11RequestKind.XrqSendCloseWindow, windowId: windowId.get())
    )
  else:
    result.requests.add(
      X11Request(kind: X11RequestKind.XrqSetInputFocus, windowId: windowId.get())
    )

proc replyForExecutedXlibreWritableRequest*(
    request: X11WritableIpcRequest, run: X11RequestRunResult
): string =
  if not request.handled:
    return ""
  if request.reply.len > 0:
    return request.reply
  if request.requests.len == 1 and
      request.requests[0].kind == X11RequestKind.XrqSendCloseWindow:
    return xlibreCloseWindowReply(request.requests[0].windowId, run)
  if request.requests.len == 1 and
      request.requests[0].kind == X11RequestKind.XrqSetInputFocus:
    return xlibreFocusWindowReply(request.requests[0].windowId, run)
  if request.messages.len == 1 and
      request.messages[0].kind == MsgKind.CmdFocusWorkspaceIndex:
    return xlibreFocusWorkspaceReply(request.workspaceIndex, run)
  if request.messages.len == 1 and
      request.messages[0].kind == MsgKind.CmdMoveWindowToWorkspaceIndex:
    return xlibreMoveWindowToWorkspaceReply(
      request.windowId, request.workspaceIndex, request.followWindow, run
    )
  errReply("unsupported xlibre writable request")
