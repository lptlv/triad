import std/[json, tables]
import ../core/triad_state
import ../systems/runtime_facade
import ../types/model
import ../types/runtime_values
import ../utils/behavior_log
import
  child_process_runtime, ipc_broadcast_runtime, process_runner, protocol_diagnostics,
  state

proc captureTableActive(table: Table[uint32, uint32]): bool =
  table.len > 0

proc captureSessionsJson*(daemon: TriadDaemon): JsonNode =
  triadCaptureSessionsJson(
    daemon.windowCaptureSessions,
    daemon.outputCaptureSessions,
    daemon.runtimeState.readRuntimeSnapshot(),
  )

proc captureSessionsActive*(daemon: TriadDaemon): bool =
  daemon.windowCaptureSessions.captureTableActive() or
    daemon.outputCaptureSessions.captureTableActive()

proc captureSessionsSupported*(daemon: TriadDaemon): bool =
  daemon.boundProtocolVersions.getOrDefault("river_window_manager_v1", 0'u32) >=
    RiverWindowManagerCaptureSessionsVersion

proc captureSessionCommand(model: Model, event: CaptureSessionEvent): seq[string] =
  case event
  of CaptureSessionEvent.CaptureSessionStarted:
    model.captureSession.started
  of CaptureSessionEvent.CaptureSessionStopped:
    model.captureSession.stopped
  of CaptureSessionEvent.CaptureSessionNotifyNone:
    @[]

proc dispatchCaptureSessionHook(daemon: var TriadDaemon, event: CaptureSessionEvent) =
  let command = daemon.runtimeState.model.captureSessionCommand(event)
  if command.len == 0:
    return
  let captureSessions = daemon.captureSessionsJson()
  writeBehaviorEvent(
    "capture_session_hook_requested",
    %*{"event": $event, "command": command, "capture_sessions": captureSessions},
  )
  if daemon.captureSessionHook != nil:
    daemon.captureSessionHook(addr daemon, event, command)
  else:
    daemon.trackChildProcess(
      spawnCaptureSessionHook(
        daemon.runtimeState.model, event, command, captureSessions
      ),
      command[0],
    )

proc broadcastCaptureSessionsChanged*(daemon: var TriadDaemon) =
  daemon.enqueueTriadBroadcast(
    triadCaptureSessionsChangedEvent(daemon.captureSessionsJson()), "capture"
  )

proc handleCaptureSessionsChanged*(daemon: var TriadDaemon, wasActive: bool) =
  let isActive = daemon.captureSessionsActive()
  if not wasActive and isActive:
    daemon.dispatchCaptureSessionHook(CaptureSessionEvent.CaptureSessionStarted)
  elif wasActive and not isActive:
    daemon.dispatchCaptureSessionHook(CaptureSessionEvent.CaptureSessionStopped)
  daemon.broadcastCaptureSessionsChanged()
