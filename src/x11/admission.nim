import ../core/[effects, msg]
import ../systems/update
import ../types/model
import events

type X11AdmissionResult* = object
  backendEvent*: X11BackendEvent
  messages*: seq[Msg]
  effects*: seq[Effect]

proc admitDryRun*(model: var Model, event: X11BackendEvent): X11AdmissionResult =
  result.backendEvent = event
  result.messages = event.messagesFor()
  for message in result.messages:
    let (nextModel, effects) = model.update(message)
    model = nextModel
    result.effects.add(effects)

proc admitDryRun*(model: var Model, events: openArray[X11BackendEvent]): seq[
  X11AdmissionResult
] =
  for event in events:
    result.add(model.admitDryRun(event))
