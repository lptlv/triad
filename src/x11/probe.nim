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
import atoms, events, ipc_runtime, pipeline, request_executor, spawn_runner, xcb_ffi

const X11IpcListenReadyTimeoutMs = 1000
const
  X11ProbeTraceXinputMotion* = X11ProbeOptionTraceXinputMotion
  X11ResizeEdgeTop = 1'u32
  X11ResizeEdgeBottom = 2'u32
  X11ResizeEdgeLeft = 4'u32
  X11ResizeEdgeRight = 8'u32

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
    buttonGrabSignature: string
    axisGrabSignature: string
    pointerGrabStartX: int32
    pointerGrabStartY: int32
    pointerGrabActive: bool

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

proc configureInputGrabs(context: ptr X11ProbeContext) {.gcsafe.}

proc probeTickCallback(userData: pointer) {.cdecl.} =
  asyncdispatch.poll(0)
  if userData != nil:
    let context = cast[ptr X11ProbeContext](userData)
    context.configureInputGrabs()
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
  bindingSpec(binding.modifiers, binding.key)

proc buttonName(button: uint32): string =
  case button
  of 0x110'u32:
    "left"
  of 0x111'u32:
    "right"
  of 0x112'u32:
    "middle"
  of 0x113'u32:
    "side"
  of 0x114'u32:
    "extra"
  of 0x115'u32:
    "forward"
  of 0x116'u32:
    "back"
  of 0x117'u32:
    "task"
  else:
    if button > 0 and button <= 255'u32:
      "button" & $button
    else:
      ""

proc x11ButtonDetail(button: uint32): uint32 =
  case button
  of 0x110'u32:
    1'u32
  of 0x111'u32:
    3'u32
  of 0x112'u32:
    2'u32
  of 0x113'u32:
    8'u32
  of 0x114'u32:
    9'u32
  of 0x115'u32:
    9'u32
  of 0x116'u32:
    8'u32
  of 0x117'u32:
    10'u32
  else:
    if button > 0 and button <= 255'u32: button else: 0'u32

proc bindingSpec(binding: PointerBindingConfig): string =
  let name = binding.button.buttonName()
  if name.len == 0:
    return ""
  bindingSpec(binding.modifiers, name)

proc axisName(direction: AxisBindingDirection): string =
  case direction
  of AxisBindingDirection.AxisUp: "wheel-up"
  of AxisBindingDirection.AxisDown: "wheel-down"
  of AxisBindingDirection.AxisLeft: "wheel-left"
  of AxisBindingDirection.AxisRight: "wheel-right"
  of AxisBindingDirection.AxisNone: ""

proc x11ButtonDetail(direction: AxisBindingDirection): uint32 =
  case direction
  of AxisBindingDirection.AxisUp: 4'u32
  of AxisBindingDirection.AxisDown: 5'u32
  of AxisBindingDirection.AxisLeft: 6'u32
  of AxisBindingDirection.AxisRight: 7'u32
  of AxisBindingDirection.AxisNone: 0'u32

proc bindingSpec(binding: AxisBindingConfig): string =
  let name = binding.direction.axisName()
  if name.len == 0:
    return ""
  bindingSpec(binding.modifiers, name)

proc bindingText(value: string): array[128, char] =
  let limit = min(value.len, result.len - 1)
  for i in 0 ..< limit:
    result[i] = value[i]

proc grabBinding(value: X11KeyGrab): string =
  for ch in value.binding:
    if ch == '\0':
      break
    result.add(ch)

proc grabBinding(value: X11ButtonGrab): string =
  for ch in value.binding:
    if ch == '\0':
      break
    result.add(ch)

proc grabBinding(value: X11AxisGrab): string =
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

proc buttonGrabSignature(grabs: openArray[X11ButtonGrab]): string =
  for grab in grabs:
    result.add($grab.button)
    result.add(":")
    result.add($grab.modifiers)
    result.add(":")
    result.add(grab.grabBinding())
    result.add("\n")

proc axisGrabSignature(grabs: openArray[X11AxisGrab]): string =
  for grab in grabs:
    result.add($grab.button)
    result.add(":")
    result.add($grab.modifiers)
    result.add(":")
    result.add(grab.grabBinding())
    result.add("\n")

proc x11InputClassConfig(config: InputPointerConfig): X11InputClassConfig =
  result.naturalScrollSet = if config.naturalScrollSet: 1'u32 else: 0'u32
  result.naturalScroll = if config.naturalScroll: 1'u32 else: 0'u32
  let factor =
    if config.scrollFactorSet:
      max(0.0'f32, min(config.scrollFactor, 100.0'f32))
    else:
      1.0'f32
  result.scrollFactorMilli = uint32(factor * 1000.0'f32)

proc x11InputConfig(model: Model): X11InputConfig =
  X11InputConfig(
    mouse: model.input.mouse.x11InputClassConfig(),
    touchpad: model.input.touchpad.pointer.x11InputClassConfig(),
    trackpoint: model.input.trackpoint.x11InputClassConfig(),
    trackball: model.input.trackball.x11InputClassConfig(),
  )

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

proc xlibreButtonGrabs(model: Model): seq[X11ButtonGrab] =
  let snapshot = model.shellSnapshot()
  for binding in model.pointerBindings:
    let button = binding.button.x11ButtonDetail()
    if button == 0:
      continue
    let spec = binding.bindingSpec()
    if spec.len == 0:
      continue
    if binding.op != PointerOpKind.OpNone:
      result.add(
        X11ButtonGrab(
          button: button, modifiers: binding.modifiers, binding: spec.bindingText()
        )
      )
      continue
    let request = BindingDispatchRequest(
      kind: BindingDispatchKind.BindPointer, binding: spec, ticks: 1'i32
    )
    let parsed =
      xlibreWritableRequestFor(bindingDispatchPayload(request), model, snapshot)
    if parsed.handled and parsed.bindingDispatch.ok:
      result.add(
        X11ButtonGrab(
          button: button, modifiers: binding.modifiers, binding: spec.bindingText()
        )
      )

proc xlibreAxisGrabs(model: Model): seq[X11AxisGrab] =
  let snapshot = model.shellSnapshot()
  for binding in model.axisBindings:
    let button = binding.direction.x11ButtonDetail()
    if button == 0:
      continue
    let spec = binding.bindingSpec()
    if spec.len == 0:
      continue
    let request = BindingDispatchRequest(
      kind: BindingDispatchKind.BindAxis, binding: spec, ticks: 1'i32
    )
    let parsed =
      xlibreWritableRequestFor(bindingDispatchPayload(request), model, snapshot)
    if parsed.handled and parsed.bindingDispatch.ok:
      result.add(
        X11AxisGrab(
          button: button, modifiers: binding.modifiers, binding: spec.bindingText()
        )
      )

proc configureInputGrabs(context: ptr X11ProbeContext) {.gcsafe.} =
  if context == nil or context.mode != X11ProbeMode.Manage:
    return
  {.cast(gcsafe).}:
    let grabs = context.model.xlibreKeyGrabs()
    let signature = grabs.keyGrabSignature()
    if context.keyGrabSignature != signature:
      let status =
        if grabs.len == 0:
          triadX11ConfigureActiveKeyGrabs(cast[ptr X11KeyGrab](nil), 0)
        else:
          triadX11ConfigureActiveKeyGrabs(unsafeAddr grabs[0], cuint(grabs.len))
      context.keyGrabSignature = signature
      stdout.writeLine(
        "xlibre_key_grabs requested=" & $grabs.len & " status=" & $status
      )
      stdout.flushFile()

    let buttonGrabs = context.model.xlibreButtonGrabs()
    let buttonSignature = buttonGrabs.buttonGrabSignature()
    if context.buttonGrabSignature != buttonSignature:
      let status =
        if buttonGrabs.len == 0:
          triadX11ConfigureActiveButtonGrabs(cast[ptr X11ButtonGrab](nil), 0)
        else:
          triadX11ConfigureActiveButtonGrabs(
            unsafeAddr buttonGrabs[0], cuint(buttonGrabs.len)
          )
      context.buttonGrabSignature = buttonSignature
      stdout.writeLine(
        "xlibre_button_grabs requested=" & $buttonGrabs.len & " status=" & $status
      )
      stdout.flushFile()

    let axisGrabs = context.model.xlibreAxisGrabs()
    let axisSignature = axisGrabs.axisGrabSignature()
    if context.axisGrabSignature != axisSignature:
      let status =
        if axisGrabs.len == 0:
          triadX11ConfigureActiveAxisGrabs(cast[ptr X11AxisGrab](nil), 0)
        else:
          triadX11ConfigureActiveAxisGrabs(
            unsafeAddr axisGrabs[0], cuint(axisGrabs.len)
          )
      context.axisGrabSignature = axisSignature
      stdout.writeLine(
        "xlibre_axis_grabs requested=" & $axisGrabs.len & " status=" & $status
      )
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

proc dispatchPointerBinding(context: ptr X11ProbeContext, binding: string) {.gcsafe.} =
  if context == nil or binding.len == 0:
    return
  {.cast(gcsafe).}:
    let dispatch = BindingDispatchRequest(
      kind: BindingDispatchKind.BindPointer, binding: binding, ticks: 1'i32
    )
    let request = xlibreWritableRequestFor(
      bindingDispatchPayload(dispatch), context.model, context.model.shellSnapshot()
    )
    if request.handled:
      stdout.writeLine(
        "xlibre_pointer_binding_reply " & context.executeXlibreWritableRequest(request)
      )
      stdout.flushFile()

proc pointerBindingOp(model: Model, bindingText: string): PointerBindingConfig =
  let spec = parseKeySpec(bindingText)
  let button = buttonValue(spec.key)
  if button == 0:
    return
  for binding in model.pointerBindings:
    if binding.button == button and binding.modifiers == spec.modifiers:
      return binding

proc runXlibreCommandStep(context: ptr X11ProbeContext, message: Msg) {.gcsafe.} =
  if context == nil:
    return
  {.cast(gcsafe).}:
    let step = context.model.processCommandWithActiveProbe(message)
    for x11Request in step.layoutRequests:
      stdout.writeLine(
        "xlibre_pointer_layout_request " & x11Request.executeDryRun().description
      )
    for x11Request in step.requests:
      stdout.writeLine(
        "xlibre_pointer_request " & x11Request.executeDryRun().description
      )
    for line in step.xcbRun.logs:
      stdout.writeLine("xlibre_pointer_xcb " & line)
    stdout.flushFile()

proc resizeEdgesForPointer(
    model: Model, targetWindowId: uint32, rootX, rootY: int32
): uint32 =
  for win in model.shellSnapshot().windows:
    if win.id != targetWindowId or not win.isFloating:
      continue
    let geom = win.floatingGeom
    if geom.w <= 0 or geom.h <= 0:
      break
    let horizontal =
      if rootX < geom.x + geom.w div 2: X11ResizeEdgeLeft else: X11ResizeEdgeRight
    let vertical =
      if rootY < geom.y + geom.h div 2: X11ResizeEdgeTop else: X11ResizeEdgeBottom
    return horizontal or vertical
  X11ResizeEdgeBottom or X11ResizeEdgeRight

proc startInteractivePointerBinding(
    context: ptr X11ProbeContext,
    bindingText: string,
    targetWindowId: uint32,
    rootX, rootY: int32,
) {.gcsafe.} =
  if context == nil or bindingText.len == 0:
    return
  {.cast(gcsafe).}:
    let binding = context.model.pointerBindingOp(bindingText)
    if binding.op == PointerOpKind.OpNone:
      context.dispatchPointerBinding(bindingText)
      return
    if targetWindowId == 0:
      return
    case binding.op
    of PointerOpKind.OpMove:
      context.runXlibreCommandStep(
        Msg(kind: MsgKind.PointerMoveRequested, moveWinId: targetWindowId)
      )
    of PointerOpKind.OpResize:
      context.runXlibreCommandStep(
        Msg(
          kind: MsgKind.PointerResizeRequested,
          resizeWinId: targetWindowId,
          resizeEdges: context.model.resizeEdgesForPointer(targetWindowId, rootX, rootY),
        )
      )
    of PointerOpKind.OpNone, PointerOpKind.OpOverviewDrag,
        PointerOpKind.OpOverviewScroll:
      discard
    context.pointerGrabActive = context.model.pointerOp.kind != PointerOpKind.OpNone
    if context.pointerGrabActive:
      context.pointerGrabStartX = rootX
      context.pointerGrabStartY = rootY

proc dispatchPointerMotion(
    context: ptr X11ProbeContext, rootX, rootY: int32
) {.gcsafe.} =
  if context == nil or not context.pointerGrabActive:
    return
  let dx = rootX - context.pointerGrabStartX
  let dy = rootY - context.pointerGrabStartY
  context.runXlibreCommandStep(Msg(kind: MsgKind.PointerDelta, dx: dx, dy: dy))

proc dispatchPointerRelease(context: ptr X11ProbeContext) {.gcsafe.} =
  if context == nil or not context.pointerGrabActive:
    return
  context.pointerGrabActive = false
  context.runXlibreCommandStep(Msg(kind: MsgKind.PointerRelease))

proc dispatchAxisBinding(
    context: ptr X11ProbeContext, binding: string, ticks: int32
) {.gcsafe.} =
  if context == nil or binding.len == 0:
    return
  {.cast(gcsafe).}:
    let dispatch = BindingDispatchRequest(
      kind: BindingDispatchKind.BindAxis,
      binding: binding,
      ticks: max(1'i32, min(ticks, 100'i32)),
    )
    let request = xlibreWritableRequestFor(
      bindingDispatchPayload(dispatch), context.model, context.model.shellSnapshot()
    )
    if request.handled:
      stdout.writeLine(
        "xlibre_axis_binding_reply " & context.executeXlibreWritableRequest(request)
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
        if message.kind == MsgKind.CmdSpawnTerminal:
          let terminalRun = context.model.executeXlibreTerminalSpawn()
          for line in terminalRun.logs:
            stdout.writeLine("xlibre_ipc_spawn " & line)
          run = X11RequestRunResult(
            code: terminalRun.code, dryRun: false, logs: terminalRun.logs
          )
          if run.code != 0:
            break
          continue
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
        let spawnRun = context.model.executeXlibreSpawnEffects(step.effects)
        for line in spawnRun.logs:
          stdout.writeLine("xlibre_ipc_spawn " & line)
        run.logs.add(spawnRun.logs)
        if spawnRun.code != 0:
          run.code = spawnRun.code
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
  of MsgKind.WindowCreated:
    "WindowCreated id=" & $msg.windowId & " app_id=\"" & msg.appId & "\" title=\"" &
      msg.title & "\""
  of MsgKind.WindowDestroyed:
    "WindowDestroyed id=" & $msg.destroyedId
  of MsgKind.WindowDimensions:
    "WindowDimensions id=" & $msg.dimensionsWindowId & " size=" & $msg.actualWidth & "x" &
      $msg.actualHeight
  of MsgKind.WindowPid:
    "WindowPid id=" & $msg.pidWindowId & " pid=" & $msg.windowPid
  of MsgKind.WindowAppId:
    "WindowAppId id=" & $msg.appIdWindowId & " app_id=\"" & msg.updatedAppId & "\""
  of MsgKind.WindowTitle:
    "WindowTitle id=" & $msg.titleWindowId & " title=\"" & msg.updatedTitle & "\""
  of MsgKind.WindowStateChanged:
    "WindowStateChanged id=" & $msg.stateWindowId & " fullscreen=" & $msg.stateFullscreen &
      " maximized=" & $msg.stateMaximized & " minimized=" & $msg.stateMinimized &
      " urgent=" & $msg.stateUrgent
  of MsgKind.WindowParentedRoleHint:
    "WindowParentedRoleHint id=" & $msg.parentedRoleWindowId & " role=" &
      $msg.parentedRoleHint
  of MsgKind.OutputDimensions:
    "OutputDimensions id=" & $msg.outputId & " size=" & $msg.width & "x" & $msg.height
  of MsgKind.OutputName:
    "OutputName id=" & $msg.nameOutputId & " name=\"" & msg.outputName & "\""
  of MsgKind.OutputPosition:
    "OutputPosition id=" & $msg.positionOutputId & " xy=" & $msg.outputX & "," &
      $msg.outputY
  of MsgKind.OutputRemoved:
    "OutputRemoved id=" & $msg.removedOutputId
  of MsgKind.FocusChanged:
    "FocusChanged id=" & $msg.newFocusedId
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
  of X11BackendEventKind.PointerBinding:
    "PointerBinding binding=\"" & event.pointerBinding & "\" button=" &
      $event.pointerBindingButton & " modifiers=0x" &
      toHex(event.pointerBindingModifiers, 4).toLowerAscii()
  of X11BackendEventKind.AxisBinding:
    "AxisBinding binding=\"" & event.axisBinding & "\" button=" &
      $event.axisBindingButton & " modifiers=0x" &
      toHex(event.axisBindingModifiers, 4).toLowerAscii() & " ticks=" &
      $event.axisBindingTicks
  of X11BackendEventKind.PointerMotion:
    "PointerMotion target=" & $event.pointerMotionTargetWindowId & " root_xy=" &
      $event.pointerMotionRootX & "," & $event.pointerMotionRootY & " modifiers=0x" &
      toHex(event.pointerMotionModifiers, 4).toLowerAscii()
  of X11BackendEventKind.PointerRelease:
    "PointerRelease button=" & $event.pointerReleaseButton & " target=" &
      $event.pointerReleaseTargetWindowId & " root_xy=" & $event.pointerReleaseRootX &
      "," & $event.pointerReleaseRootY & " modifiers=0x" &
      toHex(event.pointerReleaseModifiers, 4).toLowerAscii()
  of X11BackendEventKind.MappingChanged:
    "MappingChanged request=" & $event.mappingRequest & " first_keycode=" &
      $event.mappingFirstKeycode & " count=" & $event.mappingCount
  of X11BackendEventKind.XkbChanged:
    "XkbChanged type=" & $event.xkbEventType & " changed=0x" &
      toHex(event.xkbChanged, 4).toLowerAscii() & " group=" & $event.xkbGroup &
      " locked_group=" & $event.xkbLockedGroup & " keycode=" & $event.xkbKeycode
  of X11BackendEventKind.ClientMessage:
    "ClientMessage id=" & $event.clientWindowId & " type=\"" & event.clientMessageType &
      "\" format=" & $event.clientMessageFormat

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
  if event.kind in {X11BackendEventKind.MappingChanged, X11BackendEventKind.XkbChanged}:
    if userData != nil:
      let context = cast[ptr X11ProbeContext](userData)
      context.keyGrabSignature = ""
      context.buttonGrabSignature = ""
      context.axisGrabSignature = ""
      let reason =
        if event.kind == X11BackendEventKind.MappingChanged:
          "mapping-changed"
        else:
          "xkb-changed"
      stdout.writeLine("xlibre_input_grabs invalidated reason=" & reason)
    stdout.flushFile()
    return
  if event.kind == X11BackendEventKind.KeyBinding:
    if userData == nil:
      stdout.writeLine("dry_run_msg X11KeyBinding binding=\"" & event.keyBinding & "\"")
    else:
      cast[ptr X11ProbeContext](userData).dispatchKeyBinding(event.keyBinding)
    stdout.flushFile()
    return
  if event.kind == X11BackendEventKind.PointerBinding:
    if userData == nil:
      stdout.writeLine(
        "dry_run_msg X11PointerBinding binding=\"" & event.pointerBinding & "\""
      )
    else:
      cast[ptr X11ProbeContext](userData).startInteractivePointerBinding(
        event.pointerBinding, event.pointerBindingTargetWindowId,
        event.pointerBindingRootX, event.pointerBindingRootY,
      )
    stdout.flushFile()
    return
  if event.kind == X11BackendEventKind.AxisBinding:
    if userData == nil:
      stdout.writeLine(
        "dry_run_msg X11AxisBinding binding=\"" & event.axisBinding & "\" ticks=" &
          $event.axisBindingTicks
      )
    else:
      cast[ptr X11ProbeContext](userData).dispatchAxisBinding(
        event.axisBinding, event.axisBindingTicks
      )
    stdout.flushFile()
    return
  if event.kind == X11BackendEventKind.PointerMotion:
    if userData == nil:
      stdout.writeLine(
        "dry_run_msg X11PointerMotion root_xy=" & $event.pointerMotionRootX & "," &
          $event.pointerMotionRootY
      )
    else:
      cast[ptr X11ProbeContext](userData).dispatchPointerMotion(
        event.pointerMotionRootX, event.pointerMotionRootY
      )
    stdout.flushFile()
    return
  if event.kind == X11BackendEventKind.PointerRelease:
    if userData == nil:
      stdout.writeLine("dry_run_msg X11PointerRelease")
    else:
      cast[ptr X11ProbeContext](userData).dispatchPointerRelease()
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
    probeOptions = 0'u32,
): int =
  let display = if displayName.len == 0: nil else: displayName.cstring
  discard RequiredX11Atoms
  if mode == X11ProbeMode.Observe:
    return int(
      triadX11ProbeRun(
        display,
        cint(ord(once)),
        cuint(probeOptions),
        nil,
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
  var inputConfig = loaded.model.x11InputConfig()

  var context =
    X11ProbeContext(mode: mode, displayName: displayName, model: loaded.model)
  if mode == X11ProbeMode.Manage and not startReadOnlyIpc(addr context, socketPath):
    return 1
  int(
    triadX11ProbeRun(
      display,
      cint(ord(once)),
      cuint(probeOptions),
      addr inputConfig,
      probeLogCallback,
      probeEventCallback,
      probeTickCallback,
      addr context,
    )
  )
