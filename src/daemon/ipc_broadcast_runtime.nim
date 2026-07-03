import std/asyncdispatch
import ../ipc/socket
import state

proc removePendingBroadcast(
    daemon: var TriadDaemon, kind: IpcBroadcastKind, eventName: string
): bool =
  var i = 0
  while i < daemon.pendingIpcBroadcasts.len:
    let pending = daemon.pendingIpcBroadcasts[i]
    if pending.kind == kind and pending.eventName == eventName:
      daemon.pendingIpcBroadcasts.delete(i)
      result = true
    else:
      inc i

proc enqueueTriadBroadcast*(
    daemon: var TriadDaemon, payload: string, eventName: string
) =
  if not triadSubscriberInterested(eventName):
    inc ipcPerfCounters.triadBroadcastSkippedNoSubscribers
    inc ipcPerfCounters.triadBroadcastSkippedBytes, uint64(payload.len)
    return

  inc ipcPerfCounters.triadBroadcastQueued
  inc ipcPerfCounters.triadBroadcastQueuedBytes, uint64(payload.len)
  recordIpcBroadcastEvent("triad", eventName)
  if daemon.removePendingBroadcast(IpcBroadcastKind.Triad, eventName):
    inc ipcPerfCounters.triadBroadcastCoalesced

  daemon.pendingIpcBroadcasts.add(
    PendingIpcBroadcast(
      kind: IpcBroadcastKind.Triad, eventName: eventName, payload: payload
    )
  )

proc flushIpcBroadcasts*(daemon: var TriadDaemon) =
  if daemon.pendingIpcBroadcasts.len == 0:
    return

  let pending = daemon.pendingIpcBroadcasts
  daemon.pendingIpcBroadcasts = @[]
  for broadcast in pending:
    case broadcast.kind
    of IpcBroadcastKind.Triad:
      asyncCheck broadcastTriadJson(broadcast.payload, broadcast.eventName)
