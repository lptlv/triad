import ../core/effects
import ../types/model
import admission, effect_adapter, events, request_builder, request_executor

type X11PipelineStep* = object
  admission*: X11AdmissionResult
  intents*: seq[X11EffectIntent]
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

proc processEventDryRun*(model: var Model, event: X11BackendEvent): X11PipelineStep =
  result.admission = model.admitDryRun(event)
  result.intents = result.admission.effects.x11IntentsFor()
  result.requests = event.requestsForEventEffects(result.admission.effects)
  result.dryRunExecutions = result.requests.executeDryRun()
  result.xcbRun = X11RequestRunResult(code: 0, dryRun: true)

proc processEventWithExecutor*(
    model: var Model, event: X11BackendEvent, displayName = "", dryRun = true
): X11PipelineStep =
  result.admission = model.admitDryRun(event)
  result.intents = result.admission.effects.x11IntentsFor()
  result.requests = event.requestsForEventEffects(result.admission.effects)
  if result.requests.len == 0:
    result.xcbRun = X11RequestRunResult(code: 0, dryRun: dryRun)
  else:
    result.xcbRun = result.requests.executeWithXcb(displayName = displayName, dryRun = dryRun)

proc processEventWithActiveProbe*(
    model: var Model, event: X11BackendEvent
): X11PipelineStep =
  result.admission = model.admitDryRun(event)
  result.intents = result.admission.effects.x11IntentsFor()
  result.requests = event.requestsForEventEffects(result.admission.effects)
  if result.requests.len == 0:
    result.xcbRun = X11RequestRunResult(code: 0, dryRun: false)
  else:
    result.xcbRun = result.requests.executeWithActiveProbe()
