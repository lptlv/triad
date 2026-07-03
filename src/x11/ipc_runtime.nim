import std/[json, options, strutils]

import ../types/shell_snapshot
import request_builder, request_executor

type X11WritableIpcRequest* = object
  handled*: bool
  reply*: string
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
  if request != "xlibre-close-window":
    return

  result.handled = true
  let version = payload.uintFromField("version")
  if version.isNone or version.get() != TriadIpcVersion:
    result.reply = errReply("unsupported triad ipc version")
    return

  let windowId = payload.uintFromField("id")
  if windowId.isNone:
    result.reply = errReply("xlibre-close-window requires positive id")
    return
  if not snapshot.snapshotHasWindow(windowId.get()):
    result.reply = errReply("unknown xlibre window id: " & $windowId.get())
    return

  result.requests.add(
    X11Request(kind: X11RequestKind.XrqSendCloseWindow, windowId: windowId.get())
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
  errReply("unsupported xlibre writable request")
