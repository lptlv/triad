import std/[asyncdispatch, json, options, strutils, times]

import ../config/keysyms
import ../core/msg
import ../config/loading
import ../config/parser
import ../ipc/binding_dispatch
import ../ipc/socket
import ../state/snapshot
import ../systems/[binding_profiles, runtime_facade]
import ../types/[model, runtime_values, shell_snapshot]
import atoms, events, ipc_runtime, pipeline, request_executor, xcb_ffi

const X11IpcListenReadyTimeoutMs = 1000

type
  X11ProbeMode* {.pure.} = enum
    Observe
    Admit
    Manage

  X11ProbeContext = object
    mode: X11ProbeMode
    displayName: string
    model: Model
    stopRequested: bool
    stopPolls: int
    keyGrabSignature: string

  X11ModelLoadResult* = object
    ok*: bool
    path*: string
    error*: string
    model*: Model

proc probeLogCallback(userData: pointer, message: cstring) {.cdecl.} =
  discard userData
  if message != nil:
    stdout.writeLine($message)
    stdout.flushFile()

proc discardIpcMsg(msg: Msg) {.gcsafe.} =
  discard msg

proc configureKeyGrabs(context: ptr X11ProbeContext) {.gcsafe.}

proc probeTickCallback(userData: pointer) {.cdecl.} =
  asyncdispatch.poll(0)
  if userData != nil:
    let context = cast[ptr X11ProbeContext](userData)
    context.configureKeyGrabs()
    if context.stopRequested:
      inc context.stopPolls
      if context.stopPolls >= 2:
        discard triadX11StopActiveProbe()

proc waitForX11IpcReady(listener: Future[bool]): bool =
  let deadline = epochTime() + float(X11IpcListenReadyTimeoutMs) / 1000.0
  while not listener.finished:
    if epochTime() >= deadline:
      return false
    asyncdispatch.poll(10)
  not listener.failed and listener.read

proc modeLabel(mode: X11ProbeMode): string =
  case mode
  of X11ProbeMode.Observe: "observe"
  of X11ProbeMode.Admit: "admit"
  of X11ProbeMode.Manage: "manage"

proc bindingSpec(binding: KeyBindingConfig): string =
  var parts: seq[string]
  if (binding.modifiers and 64'u32) != 0:
    parts.add("Super")
  if (binding.modifiers and 4'u32) != 0:
    parts.add("Ctrl")
  if (binding.modifiers and 1'u32) != 0:
    parts.add("Shift")
  if (binding.modifiers and 8'u32) != 0:
    parts.add("Alt")
  if (binding.modifiers and 32'u32) != 0:
    parts.add("Mod3")
  if (binding.modifiers and 128'u32) != 0:
    parts.add("Mod5")
  parts.add(binding.key)
  parts.join("+")

proc bindingText(value: string): array[128, char] =
  let limit = min(value.len, result.len - 1)
  for i in 0 ..< limit:
    result[i] = value[i]

proc grabBinding(value: X11KeyGrab): string =
  for ch in value.binding:
    if ch == '\0':
      break
    result.add(ch)

proc keyGrabSignature(grabs: openArray[X11KeyGrab]): string =
  for grab in grabs:
    result.add($grab.keysym)
    result.add(":")
    result.add($grab.modifiers)
    result.add(":")
    result.add(grab.grabBinding())
    result.add("\n")

proc xlibreKeyGrabs(model: Model): seq[X11KeyGrab] =
  let snapshot = model.shellSnapshot()
  for binding in model.resolvedKeyBindings():
    let keysym = keySymForBinding(binding.key, binding.modifiers)
    if keysym == 0:
      continue
    let spec = binding.bindingSpec()
    let request = BindingDispatchRequest(
      kind: BindingDispatchKind.BindKey, binding: spec, ticks: 1'i32
    )
    let parsed =
      xlibreWritableRequestFor(bindingDispatchPayload(request), model, snapshot)
    if parsed.handled and parsed.bindingDispatch.ok:
      result.add(
        X11KeyGrab(
          keysym: keysym, modifiers: binding.modifiers, binding: spec.bindingText()
        )
      )

proc configureKeyGrabs(context: ptr X11ProbeContext) {.gcsafe.} =
  if context == nil or context.mode != X11ProbeMode.Manage:
    return
  {.cast(gcsafe).}:
    let grabs = context.model.xlibreKeyGrabs()
    let signature = grabs.keyGrabSignature()
    if context.keyGrabSignature == signature:
      return
    let status =
      if grabs.len == 0:
        triadX11ConfigureActiveKeyGrabs(cast[ptr X11KeyGrab](nil), 0)
      else:
        triadX11ConfigureActiveKeyGrabs(unsafeAddr grabs[0], cuint(grabs.len))
    context.keyGrabSignature = signature
    stdout.writeLine("xlibre_key_grabs requested=" & $grabs.len & " status=" & $status)
    stdout.flushFile()

proc executeXlibreWritableRequest(
  context: ptr X11ProbeContext, request: X11WritableIpcRequest
): string {.gcsafe.}

proc dispatchKeyBinding(context: ptr X11ProbeContext, binding: string) {.gcsafe.} =
  if context == nil or binding.len == 0:
    return
  {.cast(gcsafe).}:
    let dispatch = BindingDispatchRequest(
      kind: BindingDispatchKind.BindKey, binding: binding, ticks: 1'i32
    )
    let request = xlibreWritableRequestFor(
      bindingDispatchPayload(dispatch), context.model, context.model.shellSnapshot()
    )
    if request.handled:
      stdout.writeLine(
        "xlibre_key_binding_reply " & context.executeXlibreWritableRequest(request)
      )
      stdout.flushFile()

proc executeXlibreWritableRequest(
    context: ptr X11ProbeContext, request: X11WritableIpcRequest
): string {.gcsafe.} =
  {.cast(gcsafe).}:
    if request.reply.len > 0:
      return replyForExecutedXlibreWritableRequest(request, X11RequestRunResult())
    if request.requestName == "xlibre-stop":
      context.stopRequested = true
      context.stopPolls = 0
      stdout.writeLine("xlibre_ipc_stop requested=true")
      stdout.flushFile()
      return replyForExecutedXlibreWritableRequest(
        request, X11RequestRunResult(code: 0, dryRun: false, logs: @["stop requested"])
      )
    if request.messages.len > 0:
      var run = X11RequestRunResult(code: 0, dryRun: false)
      for message in request.messages:
        let step = context.model.processCommandWithActiveProbe(message)
        for x11Request in step.layoutRequests:
          stdout.writeLine(
            "xlibre_ipc_layout_request " & x11Request.executeDryRun().description
          )
        for x11Request in step.requests:
          stdout.writeLine(
            "xlibre_ipc_request " & x11Request.executeDryRun().description
          )
        for line in step.xcbRun.logs:
          stdout.writeLine("xlibre_ipc_xcb " & line)
        run = step.xcbRun
        if run.code != 0:
          break
      stdout.flushFile()
      return replyForExecutedXlibreWritableRequest(request, run)
    for x11Request in request.requests:
      stdout.writeLine("xlibre_ipc_request " & x11Request.executeDryRun().description)
    let run = request.requests.executeWithActiveProbe()
    for line in run.logs:
      stdout.writeLine("xlibre_ipc_xcb " & line)
    stdout.flushFile()
    replyForExecutedXlibreWritableRequest(request, run)

proc startReadOnlyIpc(context: ptr X11ProbeContext, socketPath: string): bool =
  if socketPath.len == 0:
    return true

  proc snapshotModel(): ShellSnapshot {.gcsafe.} =
    {.cast(gcsafe).}:
      context.model.shellSnapshot()

  proc runtimeStatus(snapshot: ShellSnapshot): JsonNode {.gcsafe.} =
    {.cast(gcsafe).}:
      %*{
        "backend": "xlibre",
        "mode": context.mode.modeLabel(),
        "display": context.displayName,
        "socket_path": socketPath,
        "read_only": true,
        "writable_ipc": true,
        "binding_dispatch_ipc": true,
        "general_command_ipc": false,
        "window_count": snapshot.windows.len,
        "output_count": snapshot.outputs.len,
      }

  proc writableReply(line: string, snapshot: ShellSnapshot): Option[string] {.gcsafe.} =
    {.cast(gcsafe).}:
      let request = xlibreWritableRequestFor(line, context.model, snapshot)
      if not request.handled:
        return none(string)
      some(context.executeXlibreWritableRequest(request))

  let listenReady = newFuture[bool]("xlibre triad ipc listener ready")
  asyncCheck startIpcServer(
    socketPath,
    discardIpcMsg,
    snapshotModel,
    getReadOnlyRuntimeStatus = runtimeStatus,
    handleReadOnlyWriteRequest = writableReply,
    listenReady = listenReady,
    requestTimeoutMs = IpcRequestTimeoutMs,
    readOnlyTriad = true,
  )
  if not waitForX11IpcReady(listenReady):
    stderr.writeLine("triad_xlibre: read-only ipc failed to listen path=" & socketPath)
    return false
  stdout.writeLine("ipc listening path=\"" & socketPath & "\" mode=read-only")
  stdout.flushFile()
  true

proc dryRunMessageLabel(msg: Msg): string =
  case msg.kind
  of MsgKind.WlWindowCreated:
    "WlWindowCreated id=" & $msg.windowId & " app_id=\"" & msg.appId & "\" title=\"" &
      msg.title & "\""
  of MsgKind.WlWindowDestroyed:
    "WlWindowDestroyed id=" & $msg.destroyedId
  of MsgKind.WlWindowDimensions:
    "WlWindowDimensions id=" & $msg.dimensionsWindowId & " size=" & $msg.actualWidth &
      "x" & $msg.actualHeight
  of MsgKind.WlWindowPid:
    "WlWindowPid id=" & $msg.pidWindowId & " pid=" & $msg.windowPid
  of MsgKind.WlWindowAppId:
    "WlWindowAppId id=" & $msg.appIdWindowId & " app_id=\"" & msg.updatedAppId & "\""
  of MsgKind.WlWindowTitle:
    "WlWindowTitle id=" & $msg.titleWindowId & " title=\"" & msg.updatedTitle & "\""
  of MsgKind.WlWindowStateChanged:
    "WlWindowStateChanged id=" & $msg.stateWindowId & " fullscreen=" &
      $msg.stateFullscreen & " maximized=" & $msg.stateMaximized & " minimized=" &
      $msg.stateMinimized & " urgent=" & $msg.stateUrgent
  of MsgKind.WlOutputDimensions:
    "WlOutputDimensions id=" & $msg.outputId & " size=" & $msg.width & "x" & $msg.height
  of MsgKind.WlOutputName:
    "WlOutputName id=" & $msg.nameOutputId & " name=\"" & msg.outputName & "\""
  of MsgKind.WlOutputPosition:
    "WlOutputPosition id=" & $msg.positionOutputId & " xy=" & $msg.outputX & "," &
      $msg.outputY
  of MsgKind.WlOutputRemoved:
    "WlOutputRemoved id=" & $msg.removedOutputId
  of MsgKind.WlFocusChanged:
    "WlFocusChanged id=" & $msg.newFocusedId
  else:
    $msg.kind

proc eventLabel(event: X11BackendEvent): string =
  case event.kind
  of X11BackendEventKind.WindowDiscovered:
    "WindowDiscovered id=" & $event.window.id & " class=\"" & event.window.wmClass &
      "\" title=\"" & event.window.title & "\""
  of X11BackendEventKind.MapRequested:
    "MapRequested id=" & $event.window.id & " class=\"" & event.window.wmClass &
      "\" title=\"" & event.window.title & "\""
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
    "PropertyChanged id=" & $event.propertyWindowId & " atom=\"" & event.propertyAtom &
      "\""
  of X11BackendEventKind.FocusChanged:
    "FocusChanged id=" & $event.focusWindowId & " focused=" & $event.focused
  of X11BackendEventKind.PointerEntered:
    "PointerEntered id=" & $event.enterWindowId
  of X11BackendEventKind.RandrChanged:
    "RandrChanged root=" & $event.randrRoot & " size=" & $event.randrW & "x" &
      $event.randrH
  of X11BackendEventKind.KeyBinding:
    "KeyBinding binding=\"" & event.keyBinding & "\" keycode=" & $event.keyBindingKeycode &
      " modifiers=0x" & toHex(event.keyBindingModifiers, 4).toLowerAscii()

proc x11ConfigPath*(configPath = ""): string =
  if configPath.len > 0:
    configPath.absoluteConfigPath()
  else:
    defaultConfigPath().absoluteConfigPath()

proc loadX11Model*(configPath = ""): X11ModelLoadResult =
  result.path = x11ConfigPath(configPath)
  let loaded = loadConfigStrict(result.path)
  if not loaded.ok:
    result.ok = false
    result.error = loaded.error
    return
  result.ok = true
  result.model = initRuntimeStateFromConfig(loaded.config).model

proc executorPrefix(mode: X11ProbeMode): string =
  if mode == X11ProbeMode.Manage: "live_xcb " else: "dry_run_xcb "

proc probeEventCallback(userData: pointer, raw: ptr X11ProbeEvent) {.cdecl.} =
  if raw == nil:
    return
  let event = backendEventFromProbe(raw[])
  stdout.writeLine("backend_event " & event.eventLabel())
  if event.kind == X11BackendEventKind.KeyBinding:
    if userData == nil:
      stdout.writeLine("dry_run_msg X11KeyBinding binding=\"" & event.keyBinding & "\"")
    else:
      cast[ptr X11ProbeContext](userData).dispatchKeyBinding(event.keyBinding)
    stdout.flushFile()
    return
  if userData == nil:
    for msg in event.messagesFor():
      stdout.writeLine("dry_run_msg " & msg.dryRunMessageLabel())
  else:
    let context = cast[ptr X11ProbeContext](userData)
    let dryRun = context.mode != X11ProbeMode.Manage
    let step =
      if context.mode == X11ProbeMode.Manage:
        context.model.processEventWithActiveProbe(event)
      else:
        context.model.processEventWithExecutor(
          event, context.displayName, dryRun = dryRun
        )
    for msg in step.admission.messages:
      stdout.writeLine("model_msg " & msg.dryRunMessageLabel())
    for request in step.layoutRequests:
      stdout.writeLine("layout_x11_request " & request.executeDryRun().description)
    for request in step.requests:
      stdout.writeLine("x11_request " & request.executeDryRun().description)
    for line in step.xcbRun.logs:
      stdout.writeLine(context.mode.executorPrefix() & line)
    if step.xcbRun.code != 0:
      stdout.writeLine("x11_executor_error code=" & $step.xcbRun.code)
  stdout.flushFile()

proc runX11Probe*(
    displayName = "",
    once = false,
    mode = X11ProbeMode.Observe,
    configPath = "",
    socketPath = "",
): int =
  let display = if displayName.len == 0: nil else: displayName.cstring
  discard RequiredX11Atoms
  if mode == X11ProbeMode.Observe:
    return int(
      triadX11ProbeRun(
        display,
        cint(ord(once)),
        probeLogCallback,
        probeEventCallback,
        probeTickCallback,
        nil,
      )
    )

  let loaded = loadX11Model(configPath)
  if not loaded.ok:
    stderr.writeLine(
      "triad_xlibre: config invalid: " & loaded.error & " path=" & loaded.path
    )
    return 1
  stdout.writeLine("config loaded path=\"" & loaded.path & "\"")
  stdout.flushFile()

  var context =
    X11ProbeContext(mode: mode, displayName: displayName, model: loaded.model)
  if mode == X11ProbeMode.Manage and not startReadOnlyIpc(addr context, socketPath):
    return 1
  int(
    triadX11ProbeRun(
      display,
      cint(ord(once)),
      probeLogCallback,
      probeEventCallback,
      probeTickCallback,
      addr context,
    )
  )
