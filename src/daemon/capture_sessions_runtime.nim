import std/json
import ../core/triad_state
import ipc_broadcast_runtime, state

proc captureSessionsJson*(daemon: TriadDaemon): JsonNode =
  triadCaptureSessionsJson(daemon.windowCaptureSessions, daemon.outputCaptureSessions)

proc broadcastCaptureSessionsChanged*(daemon: var TriadDaemon) =
  daemon.enqueueTriadBroadcast(
    triadCaptureSessionsChangedEvent(daemon.captureSessionsJson()), "capture"
  )
