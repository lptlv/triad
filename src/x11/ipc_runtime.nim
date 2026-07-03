import std/[json, options, strutils]

import ../config/[keysyms, parser]
import ../core/msg
import ../ipc/[binding_dispatch, commands]
import ../systems/[binding_profiles, runtime]
import ../types/[model, runtime_values]
import ../types/shell_snapshot
import request_builder, request_executor

type X11WritableIpcRequest* = object
  handled*: bool
  requestName*: string
  bindingDispatch*: BindingDispatchResult
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

proc xlibreStopReply(run: X11RequestRunResult): string =
  if run.code == 0:
    return okReply(
      %*{
        "version": TriadIpcVersion,
        "type": "xlibre-stop",
        "applied": true,
        "logs": run.logs,
      }
    )
  errReply("xlibre stop failed: " & run.logs.join("; "))

proc xlibreBindingDispatchReply(
    dispatch: BindingDispatchResult, run: X11RequestRunResult
): string =
  if not dispatch.ok:
    return bindingDispatchReply(dispatch)
  if run.code == 0:
    return okReply(
      %*{
        "version": TriadIpcVersion,
        "type": "xlibre-binding-dispatch",
        "kind": dispatch.request.kind.bindingDispatchKindId(),
        "binding": dispatch.request.binding,
        "command": dispatch.command,
        "dispatched": dispatch.dispatched,
        "applied": true,
        "logs": run.logs,
      }
    )
  errReply("xlibre binding dispatch failed: " & run.logs.join("; "))

proc bindingDispatchFailure(
    request: BindingDispatchRequest, message: string
): BindingDispatchResult =
  BindingDispatchResult(ok: false, error: message, request: request)

proc bindingDispatchSuccess(
    request: BindingDispatchRequest, command: string, dispatched: int32
): BindingDispatchResult =
  BindingDispatchResult(
    ok: true, request: request, command: command, dispatched: dispatched
  )

proc bindingModeActive(model: Model, mode: BindingMode): bool =
  case mode
  of BindingMode.BindAlways:
    true
  of BindingMode.BindNormal:
    not model.overviewActive and not model.recentWindowsActive
  of BindingMode.BindOverview:
    model.overviewActive
  of BindingMode.BindRecent:
    model.recentWindowsActive

proc keyBindingActive(model: Model, binding: KeyBindingConfig): bool =
  if model.exitSessionConfirmOpen:
    return false
  if model.sessionLocked and not binding.whileLocked:
    return false
  if not model.bindingModeActive(binding.mode):
    return false
  if model.keyboardShortcutsInhibited() and not binding.bypassShortcutsInhibit:
    return false
  true

proc pointerBindingActive(model: Model, binding: PointerBindingConfig): bool =
  if model.exitSessionConfirmOpen or model.sessionLocked:
    return false
  if not model.bindingModeActive(binding.mode):
    return false
  if model.keyboardShortcutsInhibited() and not binding.bypassShortcutsInhibit:
    return false
  true

proc axisBindingActive(model: Model, binding: AxisBindingConfig): bool =
  if model.exitSessionConfirmOpen or model.sessionLocked:
    return false
  if not model.bindingModeActive(binding.mode):
    return false
  if model.keyboardShortcutsInhibited() and not binding.bypassShortcutsInhibit:
    return false
  true

proc gestureBindingActive(model: Model, binding: GestureBindingConfig): bool =
  if model.exitSessionConfirmOpen or model.sessionLocked:
    return false
  if not model.bindingModeActive(binding.mode):
    return false
  if model.keyboardShortcutsInhibited() and not binding.bypassShortcutsInhibit:
    return false
  true

proc xlibreCommandSupported(msg: Msg): bool =
  case msg.kind
  of MsgKind.CmdCloseWindow, MsgKind.CmdCloseWindowById, MsgKind.CmdFocusNext,
      MsgKind.CmdFocusPrev, MsgKind.CmdFocusDirection, MsgKind.CmdFocusLast,
      MsgKind.CmdFocusColumnFirst, MsgKind.CmdFocusColumnLast,
      MsgKind.CmdFocusWorkspaceIndex, MsgKind.CmdFocusWindowById,
      MsgKind.CmdMoveToWorkspaceIndex, MsgKind.CmdMoveWindowToWorkspaceIndex,
      MsgKind.CmdSwitchLayout, MsgKind.CmdSpawn, MsgKind.CmdSpawnTerminal:
    true
  else:
    false

proc resolvedBindingCommand(
    model: Model, request: BindingDispatchRequest
): BindingDispatchResult =
  case request.kind
  of BindingDispatchKind.BindKey:
    let spec = parseKeySpec(request.binding)
    if spec.key.len == 0 or keySymForBinding(spec.key, spec.modifiers) == 0:
      return request.bindingDispatchFailure("invalid key binding: " & request.binding)
    let candidate = KeyBindingConfig(key: spec.key, modifiers: spec.modifiers)
    for binding in model.resolvedKeyBindings():
      if not binding.samePhysicalKeySlot(candidate):
        continue
      if not model.keyBindingActive(binding):
        return request.bindingDispatchFailure(
          "key binding is not active: " & request.binding
        )
      let msg = parseTextCommand(binding.command)
      if msg.isNone:
        return request.bindingDispatchFailure(
          "invalid configured command for key binding: " & request.binding
        )
      if not msg.get().xlibreCommandSupported():
        return request.bindingDispatchFailure(
          "configured key binding command is not supported by XLibre: " & binding.command
        )
      return request.bindingDispatchSuccess(binding.command, 1)
    request.bindingDispatchFailure("key binding not found: " & request.binding)
  of BindingDispatchKind.BindPointer:
    let spec = parseKeySpec(request.binding)
    let button = buttonValue(spec.key)
    if button == 0:
      return
        request.bindingDispatchFailure("invalid pointer binding: " & request.binding)
    for binding in model.pointerBindings:
      if binding.button != button or binding.modifiers != spec.modifiers:
        continue
      if not model.pointerBindingActive(binding):
        return request.bindingDispatchFailure(
          "pointer binding is not active: " & request.binding
        )
      if binding.op != PointerOpKind.OpNone:
        return request.bindingDispatchFailure(
          "interactive pointer bindings cannot be dispatched over XLibre IPC"
        )
      let msg = parseTextCommand(binding.command)
      if msg.isNone:
        return request.bindingDispatchFailure(
          "invalid configured command for pointer binding: " & request.binding
        )
      if not msg.get().xlibreCommandSupported():
        return request.bindingDispatchFailure(
          "configured pointer binding command is not supported by XLibre: " &
            binding.command
        )
      return request.bindingDispatchSuccess(binding.command, 1)
    request.bindingDispatchFailure("pointer binding not found: " & request.binding)
  of BindingDispatchKind.BindAxis:
    if request.ticks <= 0 or request.ticks > 100:
      return request.bindingDispatchFailure("axis ticks must be in 1..100")
    let spec = parseKeySpec(request.binding)
    let direction = axisDirectionValue(spec.key)
    if direction == AxisBindingDirection.AxisNone:
      return request.bindingDispatchFailure("invalid axis binding: " & request.binding)
    for binding in model.axisBindings:
      if binding.direction != direction or binding.modifiers != spec.modifiers:
        continue
      if not model.axisBindingActive(binding):
        return request.bindingDispatchFailure(
          "axis binding is not active: " & request.binding
        )
      let msg = parseTextCommand(binding.command)
      if msg.isNone:
        return request.bindingDispatchFailure(
          "invalid configured command for axis binding: " & request.binding
        )
      if not msg.get().xlibreCommandSupported():
        return request.bindingDispatchFailure(
          "configured axis binding command is not supported by XLibre: " &
            binding.command
        )
      return request.bindingDispatchSuccess(binding.command, request.ticks)
    request.bindingDispatchFailure("axis binding not found: " & request.binding)
  of BindingDispatchKind.BindGesture:
    if request.fingers == 0:
      return request.bindingDispatchFailure("gesture fingers must be greater than zero")
    let spec = parseKeySpec(request.binding)
    let direction = gestureDirectionValue(spec.key)
    if direction == GestureBindingDirection.GestureNone:
      return
        request.bindingDispatchFailure("invalid gesture binding: " & request.binding)
    for binding in model.gestureBindings:
      if binding.direction != direction or binding.fingers != request.fingers or
          binding.modifiers != spec.modifiers:
        continue
      if not model.gestureBindingActive(binding):
        return request.bindingDispatchFailure(
          "gesture binding is not active: " & request.binding
        )
      let msg = parseTextCommand(binding.command)
      if msg.isNone:
        return request.bindingDispatchFailure(
          "invalid configured command for gesture binding: " & request.binding
        )
      if not msg.get().xlibreCommandSupported():
        return request.bindingDispatchFailure(
          "configured gesture binding command is not supported by XLibre: " &
            binding.command
        )
      return request.bindingDispatchSuccess(binding.command, 1)
    request.bindingDispatchFailure("gesture binding not found: " & request.binding)

proc xlibreBindingDispatchRequestFor(
    line: string, model: Model
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
    return
  if payload.stringFromField("request") != "dispatch-binding":
    return

  result.handled = true
  result.requestName = "dispatch-binding"
  let version = payload.uintFromField("version")
  if version.isNone or version.get() != TriadIpcVersion:
    result.reply = errReply("unsupported triad ipc version")
    return

  let request = bindingDispatchRequestFromPayload(payload)
  if request.isNone:
    result.reply = bindingDispatchError("invalid dispatch-binding request")
    return

  result.bindingDispatch = model.resolvedBindingCommand(request.get())
  if not result.bindingDispatch.ok:
    result.reply = bindingDispatchReply(result.bindingDispatch)
    return

  let msg = parseTextCommand(result.bindingDispatch.command)
  if msg.isNone:
    result.reply =
      bindingDispatchError("invalid configured command for binding dispatch")
    return
  for _ in 0 ..< result.bindingDispatch.dispatched:
    result.messages.add(msg.get())

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
    "xlibre-move-window-to-workspace", "xlibre-stop",
  ]:
    return

  result.handled = true
  result.requestName = request
  let version = payload.uintFromField("version")
  if version.isNone or version.get() != TriadIpcVersion:
    result.reply = errReply("unsupported triad ipc version")
    return

  if request == "xlibre-stop":
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

proc xlibreWritableRequestFor*(
    line: string, model: Model, snapshot: ShellSnapshot
): X11WritableIpcRequest =
  result = xlibreWritableRequestFor(line, snapshot)
  if result.handled:
    return
  result = xlibreBindingDispatchRequestFor(line, model)

proc replyForExecutedXlibreWritableRequest*(
    request: X11WritableIpcRequest, run: X11RequestRunResult
): string =
  if not request.handled:
    return ""
  if request.reply.len > 0:
    return request.reply
  if request.requestName == "dispatch-binding":
    return xlibreBindingDispatchReply(request.bindingDispatch, run)
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
  if request.requestName == "xlibre-stop":
    return xlibreStopReply(run)
  errReply("unsupported xlibre writable request")
