import std/json
import ../core/triad_state
import ../systems/runtime_facade
import ipc_broadcast_runtime, state

proc captureSessionsJson*(daemon: TriadDaemon): JsonNode =
  triadCaptureSessionsJson(
    daemon.windowCaptureSessions,
    daemon.outputCaptureSessions,
    daemon.runtimeState.readRuntimeSnapshot(),
  )

proc broadcastCaptureSessionsChanged*(daemon: var TriadDaemon) =
  daemon.enqueueTriadBroadcast(
    triadCaptureSessionsChangedEvent(daemon.captureSessionsJson()), "capture"
  )
