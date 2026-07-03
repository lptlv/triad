import ../core/effects
import ../state/queries
import ../systems/layout_projection
import ../types/model
import ../types/projection_values
import admission, effect_adapter, events, request_builder, request_executor

type X11PipelineStep* = object
  admission*: X11AdmissionResult
  intents*: seq[X11EffectIntent]
  layoutRequests*: seq[X11Request]
  requests*: seq[X11Request]
  dryRunExecutions*: seq[X11RequestExecution]
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
    event.propertyAtom == "_NET_WM_STATE"
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

proc populateRequests(result: var X11PipelineStep, model: var Model, event: X11BackendEvent) =
  result.intents = result.admission.effects.x11IntentsFor()
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
    result.xcbRun = result.requests.executeWithXcb(displayName = displayName, dryRun = dryRun)

proc processEventWithActiveProbe*(
    model: var Model, event: X11BackendEvent
): X11PipelineStep =
  result.admission = model.admitDryRun(event)
  result.populateRequests(model, event)
  if result.requests.len == 0:
    result.xcbRun = X11RequestRunResult(code: 0, dryRun: false)
  else:
    result.xcbRun = result.requests.executeWithActiveProbe()
