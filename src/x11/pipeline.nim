import std/options

import ../core/effects
import ../core/msg
import ../core/shell_focus
import ../state/queries
import ../state/snapshot
import ../systems/layout_projection
import ../systems/update
import ../types/model
import ../types/projection_values
import ../types/shell_snapshot
import admission, effect_adapter, events, request_builder, request_executor

type X11PipelineStep* = object
  admission*: X11AdmissionResult
  intents*: seq[X11EffectIntent]
  layoutRequests*: seq[X11Request]
  requests*: seq[X11Request]
  dryRunExecutions*: seq[X11RequestExecution]
  xcbRun*: X11RequestRunResult

type X11CommandStep* = object
  message*: Msg
  effects*: seq[Effect]
  layoutRequests*: seq[X11Request]
  requests*: seq[X11Request]
  xcbRun*: X11RequestRunResult

proc requestsForAdmission*(admission: X11AdmissionResult): seq[X11Request] =
  admission.effects.x11IntentsFor().x11RequestsFor()

proc requestsForEventEffects*(
    event: X11BackendEvent, effects: openArray[Effect]
): seq[X11Request] =
  let effectRequests = effects.x11IntentsFor().x11RequestsFor()
  if event.kind != X11BackendEventKind.MapRequested:
    return effectRequests

  for request in effectRequests:
    if request.kind == X11RequestKind.XrqConfigureWindow:
      result.add(request)
  result.add(x11MapWindowRequest(event.window.id))
  for request in effectRequests:
    if request.kind != X11RequestKind.XrqConfigureWindow:
      result.add(request)

proc shouldProjectLayout*(event: X11BackendEvent): bool =
  case event.kind
  of X11BackendEventKind.WindowDiscovered, X11BackendEventKind.MapRequested,
      X11BackendEventKind.WindowDestroyed, X11BackendEventKind.WindowUnmapped,
      X11BackendEventKind.OutputDiscovered, X11BackendEventKind.RandrChanged:
    true
  of X11BackendEventKind.PropertyChanged:
    event.propertyAtom in
      ["_NET_WM_STATE", "WM_TRANSIENT_FOR", "WM_NORMAL_HINTS", "WM_HINTS"]
  of X11BackendEventKind.ClientMessage:
    event.clientMessageType == "_NET_WM_STATE"
  else:
    false

proc x11ConfigureRequestFor*(instruction: RenderInstruction): X11Request =
  X11Request(
    kind: X11RequestKind.XrqConfigureWindow,
    windowId: instruction.windowId,
    valueMask:
      X11ConfigureMaskX or X11ConfigureMaskY or X11ConfigureMaskWidth or
      X11ConfigureMaskHeight,
    valueCount: 4,
    values: [
      instruction.geom.x,
      instruction.geom.y,
      max(1'i32, instruction.geom.w),
      max(1'i32, instruction.geom.h),
    ],
  )

proc layoutRequestsFor*(model: var Model, event: X11BackendEvent): seq[X11Request] =
  if not event.shouldProjectLayout():
    return
  if model.outputCount() == 0:
    return
  for instruction in model.layoutInstructions():
    if instruction.windowId != 0:
      result.add(instruction.x11ConfigureRequestFor())

proc layoutRequestsForProjection*(model: var Model): seq[X11Request] =
  if model.outputCount() == 0:
    return
  for instruction in model.layoutInstructions():
    if instruction.windowId != 0:
      result.add(instruction.x11ConfigureRequestFor())

proc projectionVisibleWindowIds(model: var Model): seq[uint32] =
  if model.outputCount() == 0:
    return
  for instruction in model.layoutInstructions():
    if instruction.windowId == 0:
      continue
    var found = false
    for existing in result:
      if existing == instruction.windowId:
        found = true
        break
    if not found:
      result.add(instruction.windowId)

proc containsWindowId(ids: openArray[uint32], windowId: uint32): bool =
  for id in ids:
    if id == windowId:
      return true
  false

proc snapshotMinimized(snapshot: ShellSnapshot, windowId: uint32): bool =
  for win in snapshot.windows:
    if win.id == windowId:
      return win.isMinimized
  false

proc minimizedStateChanged(before, after: ShellSnapshot, windowId: uint32): bool =
  before.snapshotMinimized(windowId) != after.snapshotMinimized(windowId)

proc projectionVisibilityRequestsFor(
    before, after: ShellSnapshot, beforeVisible, afterVisible: openArray[uint32]
): seq[X11Request] =
  for windowId in afterVisible:
    if not beforeVisible.containsWindowId(windowId) and
        not minimizedStateChanged(before, after, windowId):
      result.add(x11MapWindowRequest(windowId))
  for windowId in beforeVisible:
    if not afterVisible.containsWindowId(windowId) and
        not minimizedStateChanged(before, after, windowId):
      result.add(x11UnmapWindowRequest(windowId))

proc shouldSyncProjectionVisibility(kind: MsgKind): bool =
  kind in {
    MsgKind.CmdGroupWindows, MsgKind.CmdUngroupWindow, MsgKind.CmdFocusNextInGroup,
    MsgKind.CmdMoveToScratchpad, MsgKind.CmdMoveToNamedScratchpad,
    MsgKind.CmdToggleScratchpad, MsgKind.CmdToggleNamedScratchpad,
    MsgKind.CmdRestoreScratchpad,
  }

proc hasFocusRequest(requests: openArray[X11Request], windowId: uint32): bool =
  for request in requests:
    if request.kind == X11RequestKind.XrqSetInputFocus and request.windowId == windowId:
      return true

proc addCommandFocusRequest(model: Model, message: Msg, requests: var seq[X11Request]) =
  if message.kind notin {
    MsgKind.CmdFocusWorkspaceIndex, MsgKind.CmdMoveToWorkspaceIndex,
    MsgKind.CmdMoveWindowToWorkspaceIndex, MsgKind.CmdFocusOutput,
    MsgKind.CmdMoveWorkspaceToOutput, MsgKind.CmdMoveToOutput,
  }:
    return
  let focused = model.shellSnapshot().focusedWindowId()
  if focused != 0'u32 and not requests.hasFocusRequest(focused):
    requests.add(X11Request(kind: X11RequestKind.XrqSetInputFocus, windowId: focused))

proc snapshotWindow(snapshot: ShellSnapshot, windowId: uint32): Option[ShellWindow] =
  for win in snapshot.windows:
    if win.id == windowId:
      return some(win)
  none(ShellWindow)

proc minimizedStateRequestsFor(before, after: ShellSnapshot): seq[X11Request] =
  for win in after.windows:
    let previous = before.snapshotWindow(win.id)
    if previous.isNone or previous.get().isMinimized == win.isMinimized:
      continue
    result.add(x11SetHiddenStateRequest(win.id, win.isMinimized))
    if win.isMinimized:
      result.add(x11UnmapWindowRequest(win.id))
    else:
      result.add(x11MapWindowRequest(win.id))

proc combineEventRequests*(
    event: X11BackendEvent, layoutRequests, effectRequests: openArray[X11Request]
): seq[X11Request] =
  if event.kind != X11BackendEventKind.MapRequested:
    result.add(layoutRequests)
    result.add(effectRequests)
    return

  for request in layoutRequests:
    if request.windowId == event.window.id:
      result.add(request)
  result.add(x11MapWindowRequest(event.window.id))
  for request in layoutRequests:
    if request.windowId != event.window.id:
      result.add(request)
  for request in effectRequests:
    result.add(request)

proc x11IntentsForEventEffects(
    event: X11BackendEvent, effects: openArray[Effect]
): seq[X11EffectIntent] =
  for effect in effects:
    if event.kind == X11BackendEventKind.FocusChanged and
        effect.kind == EffectKind.EffFocusWindow:
      continue
    result.add(effect.x11IntentsFor())

proc populateRequests(
    result: var X11PipelineStep, model: var Model, event: X11BackendEvent
) =
  result.intents = event.x11IntentsForEventEffects(result.admission.effects)
  let effectRequests = result.intents.x11RequestsFor()
  result.layoutRequests = model.layoutRequestsFor(event)
  result.requests = event.combineEventRequests(result.layoutRequests, effectRequests)

proc processEventDryRun*(model: var Model, event: X11BackendEvent): X11PipelineStep =
  result.admission = model.admitDryRun(event)
  result.populateRequests(model, event)
  result.dryRunExecutions = result.requests.executeDryRun()
  result.xcbRun = X11RequestRunResult(code: 0, dryRun: true)

proc processEventWithExecutor*(
    model: var Model, event: X11BackendEvent, displayName = "", dryRun = true
): X11PipelineStep =
  result.admission = model.admitDryRun(event)
  result.populateRequests(model, event)
  if result.requests.len == 0:
    result.xcbRun = X11RequestRunResult(code: 0, dryRun: dryRun)
  else:
    result.xcbRun =
      result.requests.executeWithXcb(displayName = displayName, dryRun = dryRun)

proc processEventWithActiveProbe*(
    model: var Model, event: X11BackendEvent
): X11PipelineStep =
  result.admission = model.admitDryRun(event)
  result.populateRequests(model, event)
  if result.requests.len == 0:
    result.xcbRun = X11RequestRunResult(code: 0, dryRun: false)
  else:
    result.xcbRun = result.requests.executeWithActiveProbe()

proc processCommandWithActiveProbe*(model: var Model, message: Msg): X11CommandStep =
  result.message = message
  let beforeVisible = model.projectionVisibleWindowIds()
  let before = model.shellSnapshot()
  result.effects = model.updateInPlace(message)
  let after = model.shellSnapshot()
  let stateRequests = before.minimizedStateRequestsFor(after)
  result.layoutRequests = model.layoutRequestsForProjection()
  let visibilityRequests =
    if message.kind.shouldSyncProjectionVisibility():
      projectionVisibilityRequestsFor(
        before, after, beforeVisible, model.projectionVisibleWindowIds()
      )
    else:
      @[]
  result.requests.add(result.layoutRequests)
  result.requests.add(visibilityRequests)
  result.requests.add(stateRequests)
  result.requests.add(result.effects.x11IntentsFor().x11RequestsFor())
  model.addCommandFocusRequest(message, result.requests)
  if result.requests.len == 0:
    result.xcbRun = X11RequestRunResult(code: 0, dryRun: false)
  else:
    result.xcbRun = result.requests.executeWithActiveProbe()

proc processCommandDryRun*(model: var Model, message: Msg): X11CommandStep =
  result.message = message
  let beforeVisible = model.projectionVisibleWindowIds()
  let before = model.shellSnapshot()
  result.effects = model.updateInPlace(message)
  let after = model.shellSnapshot()
  let stateRequests = before.minimizedStateRequestsFor(after)
  result.layoutRequests = model.layoutRequestsForProjection()
  let visibilityRequests =
    if message.kind.shouldSyncProjectionVisibility():
      projectionVisibilityRequestsFor(
        before, after, beforeVisible, model.projectionVisibleWindowIds()
      )
    else:
      @[]
  result.requests.add(result.layoutRequests)
  result.requests.add(visibilityRequests)
  result.requests.add(stateRequests)
  result.requests.add(result.effects.x11IntentsFor().x11RequestsFor())
  model.addCommandFocusRequest(message, result.requests)
  result.xcbRun = X11RequestRunResult(code: 0, dryRun: true)

proc processCommandWithExecutor*(
    model: var Model, message: Msg, displayName = "", dryRun = true
): X11CommandStep =
  result.message = message
  let beforeVisible = model.projectionVisibleWindowIds()
  let before = model.shellSnapshot()
  result.effects = model.updateInPlace(message)
  let after = model.shellSnapshot()
  let stateRequests = before.minimizedStateRequestsFor(after)
  result.layoutRequests = model.layoutRequestsForProjection()
  let visibilityRequests =
    if message.kind.shouldSyncProjectionVisibility():
      projectionVisibilityRequestsFor(
        before, after, beforeVisible, model.projectionVisibleWindowIds()
      )
    else:
      @[]
  result.requests.add(result.layoutRequests)
  result.requests.add(visibilityRequests)
  result.requests.add(stateRequests)
  result.requests.add(result.effects.x11IntentsFor().x11RequestsFor())
  model.addCommandFocusRequest(message, result.requests)
  if result.requests.len == 0:
    result.xcbRun = X11RequestRunResult(code: 0, dryRun: dryRun)
  else:
    result.xcbRun =
      result.requests.executeWithXcb(displayName = displayName, dryRun = dryRun)
