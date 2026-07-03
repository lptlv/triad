import
  std/
    [asyncdispatch, asyncnet, json, nativesockets, options, os, strutils, tables, times]
import std/posix except AF_UNIX, SOCK_STREAM, IPPROTO_IP
import chronicles
import ../core/msg
import ../types/shell_snapshot
import ../utils/behavior_log
import binding_dispatch, commands, triad_native, triad_readonly

type
  IpcServer* = object
    socketPath*: string

  TriadSubscriber* = object
    client*: AsyncSocket
    layout*: bool
    state*: bool
    window*: bool

  IpcPerfCounters* = object
    requests*: uint64
    devModeRequests*: uint64
    liveRestoreRequests*: uint64
    perfStatusRequests*: uint64
    memStatusRequests*: uint64
    triadRequests*: uint64
    textCommands*: uint64
    bindingDispatchRequests*: uint64
    invalidRequests*: uint64
    dispatchedMessages*: uint64
    triadSubscriptions*: uint64
    triadBroadcasts*: uint64
    triadBroadcastSends*: uint64
    triadBroadcastQueued*: uint64
    triadBroadcastCoalesced*: uint64
    triadBroadcastSkippedNoSubscribers*: uint64
    triadBroadcastSkippedDuplicate*: uint64
    triadBroadcastSkippedDuplicateByEvent*: uint64
    triadBroadcastQueuedBytes*: uint64
    triadBroadcastSentBytes*: uint64
    triadBroadcastSkippedBytes*: uint64
    droppedSubscribers*: uint64

const
  MaxIpcLineBytes* = 256 * 1024
  MaxIpcSubscribers* = 64
  MaxPendingIpcClients* = 64
  IpcRequestTimeoutMs* = 5000
  IpcNoRequestTimeoutMs* = -1
  IpcSubscriberSendTimeoutMs* = 250

var triadSubscribers*: seq[TriadSubscriber] = @[]
var ipcPerfCounters*: IpcPerfCounters
var ipcBroadcastEventCounts*: Table[string, uint64] = initTable[string, uint64]()
var pendingIpcClients = 0
var lastTriadBroadcastPayloadByEvent = initTable[string, string]()

proc runtimeDir*(): string =
  getEnv("XDG_RUNTIME_DIR", "/tmp")

proc triadSocketPath*(): string =
  runtimeDir() / "triad.sock"

proc unixPathExists*(path: string): bool =
  var st: Stat
  lstat(path.cstring, st) == 0

proc unixPathIsSocket*(path: string): bool =
  var st: Stat
  if lstat(path.cstring, st) != 0:
    return false
  S_ISSOCK(st.st_mode)

proc unixSocketAcceptsConnections*(path: string): Future[bool] {.async.} =
  let client = newAsyncSocket(AF_UNIX, SOCK_STREAM, IPPROTO_IP)
  try:
    let connectFuture = client.connectUnix(path)
    let completed = await connectFuture.withTimeout(100)
    if not completed:
      return true
    result = not connectFuture.failed
  except CatchableError:
    result = false
  finally:
    if not client.isClosed:
      client.close()

proc prepareUnixSocketPath(path: string): Future[bool] {.async.} =
  if not unixPathExists(path):
    return true

  if not unixPathIsSocket(path):
    error "IPC path exists but is not a Unix socket", path = path
    return false

  if await unixSocketAcceptsConnections(path):
    error "IPC socket already accepts connections; refusing to replace it", path = path
    return false

  warn "Removing stale IPC socket", path = path
  try:
    removeFile(path)
    true
  except CatchableError as e:
    error "Failed to remove stale IPC socket", path = path, error = e.msg
    false

proc recvLineLimited(
    client: AsyncSocket, maxBytes = MaxIpcLineBytes, timeoutMs = IpcRequestTimeoutMs
): Future[string] {.async.} =
  var line = ""
  let deadline = epochTime() + float(timeoutMs) / 1000.0
  while line.len <= maxBytes:
    var remainingMs = 0
    if timeoutMs >= 0:
      remainingMs = int((deadline - epochTime()) * 1000.0)
      if remainingMs <= 0:
        raise newException(IOError, "IPC request line timed out")
    let recvFuture = client.recv(1)
    if timeoutMs >= 0 and not await recvFuture.withTimeout(remainingMs):
      raise newException(IOError, "IPC request line timed out")
    elif timeoutMs < 0:
      discard await recvFuture
    let chunk = recvFuture.read()
    if chunk.len == 0:
      return ""
    if chunk[0] == '\n':
      if line.len > 0 and line[^1] == '\r':
        line.setLen(line.len - 1)
      return line
    line.add(chunk)
  raise newException(ValueError, "IPC request line exceeds " & $maxBytes & " bytes")

proc pruneTriadSubscribers() =
  var i = 0
  while i < triadSubscribers.len:
    let client = triadSubscribers[i].client
    if client == nil or client.isClosed:
      triadSubscribers.delete(i)
    else:
      inc i

proc removeTriadSubscriber(client: AsyncSocket) =
  var i = 0
  while i < triadSubscribers.len:
    let current = triadSubscribers[i].client
    if current == client or current == nil or current.isClosed:
      triadSubscribers.delete(i)
    else:
      inc i

proc watchSubscriberDisconnect(client: AsyncSocket) {.async.} =
  try:
    while client != nil and not client.isClosed:
      let chunk = await client.recv(1)
      if chunk.len == 0:
        break
  except CatchableError:
    discard
  if client != nil:
    if not client.isClosed:
      client.close()
    removeTriadSubscriber(client)

proc canSubscribeTriad(): bool =
  pruneTriadSubscribers()
  triadSubscribers.len < MaxIpcSubscribers

proc triadSubscriberScopeCounts*(): tuple[
  layoutOnly: int, stateOnly: int, layoutAndState: int, window: int
] =
  for subscriber in triadSubscribers:
    if subscriber.client == nil or subscriber.client.isClosed:
      continue
    if subscriber.window:
      inc result.window
    if subscriber.layout and subscriber.state:
      inc result.layoutAndState
    elif subscriber.layout:
      inc result.layoutOnly
    elif subscriber.state:
      inc result.stateOnly

proc triadSubscriberInterested*(eventName: string): bool =
  for subscriber in triadSubscribers:
    if subscriber.client == nil or subscriber.client.isClosed:
      continue
    if eventName == "layout" and subscriber.layout:
      return true
    if eventName == "state" and subscriber.state:
      return true
    if eventName == "window" and subscriber.window:
      return true
  false

proc recordIpcBroadcastEvent*(channel, eventName: string) =
  let key = channel & ":" & eventName
  ipcBroadcastEventCounts[key] = ipcBroadcastEventCounts.getOrDefault(key, 0'u64) + 1

proc sendWithTimeout(
    client: AsyncSocket, payload: string, timeoutMs = IpcSubscriberSendTimeoutMs
): Future[bool] {.async.} =
  let sendFuture = client.send(payload)
  if not await sendFuture.withTimeout(timeoutMs):
    return false
  try:
    sendFuture.read()
    true
  except CatchableError:
    false

proc devModeReply(): string =
  $(
    %*{
      "ok": true,
      "type": "dev-mode",
      "dev_mode": devModeEnabled(),
      "behavior_log": behaviorLogEnabled(),
    }
  )

proc devModeError(message: string): string =
  $(%*{"ok": false, "type": "dev-mode", "error": message})

proc handleDevModeControl*(line: string): Option[string] =
  let parts = line.strip().splitWhitespace()
  if parts.len == 0 or parts[0] != "dev-mode":
    return none(string)
  if parts.len == 1:
    return some(devModeReply())
  if parts.len > 2:
    return some(devModeError("usage: dev-mode [on|off|toggle|status]"))

  case parts[1]
  of "on":
    setRuntimeDevMode(true)
    some(devModeReply())
  of "off":
    setRuntimeDevMode(false)
    some(devModeReply())
  of "toggle":
    toggleRuntimeDevMode()
    some(devModeReply())
  of "status":
    some(devModeReply())
  else:
    some(devModeError("usage: dev-mode [on|off|toggle|status]"))

proc startIpcServer*(
    path: string,
    onMsg: proc(msg: Msg) {.gcsafe.},
    getSnapshot: proc(): ShellSnapshot {.gcsafe.} = nil,
    getLiveRestoreJson: proc(): string {.gcsafe.} = nil,
    getPerfStatusJson: proc(): string {.gcsafe.} = nil,
    getMemStatusJson: proc(): string {.gcsafe.} = nil,
    dispatchBinding: proc(request: BindingDispatchRequest): string {.gcsafe.} = nil,
    listenReady: Future[bool] = nil,
    requestTimeoutMs = IpcRequestTimeoutMs,
    readOnlyTriad = false,
) {.async.} =
  let server = newAsyncSocket(AF_UNIX, SOCK_STREAM, IPPROTO_IP)
  try:
    if not await prepareUnixSocketPath(path):
      if listenReady != nil and not listenReady.finished:
        listenReady.complete(false)
      if not server.isClosed:
        server.close()
      return

    server.setSockOpt(OptReuseAddr, true)
    server.bindUnix(path)
    server.listen()
  except CatchableError as e:
    error "IPC server failed to start", path = path, error = e.msg
    if listenReady != nil and not listenReady.finished:
      listenReady.complete(false)
    if not server.isClosed:
      server.close()
    return

  info "IPC server listening", path = path
  if listenReady != nil and not listenReady.finished:
    listenReady.complete(true)

  while true:
    var client: AsyncSocket
    try:
      client = await server.accept()
      if client == nil:
        warn "IPC accept returned nil client", path = path
        continue
      debug "IPC client connected", path = path
    except CatchableError as e:
      warn "IPC accept failed", path = path, error = e.msg
      continue

    let acceptedClient = client
    if pendingIpcClients >= MaxPendingIpcClients:
      warn "Rejecting IPC client; pending client cap reached",
        path = path, cap = MaxPendingIpcClients
      client.close()
      continue

    inc pendingIpcClients
    asyncCheck (
      proc() {.async.} =
        let client = acceptedClient
        var keepOpen = false
        try:
          try:
            while client != nil and not client.isClosed:
              let line = await recvLineLimited(client, timeoutMs = requestTimeoutMs)
              if line == "":
                break
              inc ipcPerfCounters.requests

              if readOnlyTriad:
                if getSnapshot == nil:
                  inc ipcPerfCounters.invalidRequests
                  await client.send(
                    """{"ok":false,"error":"read-only ipc snapshot unavailable"}""" &
                      "\L"
                  )
                  break

                let triad = handleTriadReadOnlyRequest(line, getSnapshot())
                if triad.handled:
                  inc ipcPerfCounters.triadRequests
                  if triad.reply.len > 0:
                    await client.send(triad.reply & "\L")
                  break

                inc ipcPerfCounters.invalidRequests
                await client.send(
                  """{"ok":false,"error":"read-only ipc requires native Triad JSON request"}""" &
                    "\L"
                )
                break

              let devModeControl = handleDevModeControl(line)
              if devModeControl.isSome:
                inc ipcPerfCounters.devModeRequests
                await client.send(devModeControl.get() & "\L")
                break

              if getSnapshot != nil:
                if line.strip() == "dump-live-restore-state":
                  inc ipcPerfCounters.liveRestoreRequests
                  if getLiveRestoreJson != nil:
                    await client.send(getLiveRestoreJson() & "\L")
                  else:
                    await client.send("""{"error":"live restore unavailable"}""" & "\L")
                  break

                if line.strip() == "perf-status":
                  inc ipcPerfCounters.perfStatusRequests
                  if getPerfStatusJson != nil:
                    await client.send(getPerfStatusJson() & "\L")
                  else:
                    await client.send("""{"error":"perf status unavailable"}""" & "\L")
                  break

                if line.strip() == "mem-status":
                  inc ipcPerfCounters.memStatusRequests
                  if getMemStatusJson != nil:
                    await client.send(getMemStatusJson() & "\L")
                  else:
                    await client.send(
                      """{"error":"memory status unavailable"}""" & "\L"
                    )
                  break

                let snapshot = getSnapshot()
                let triad = handleTriadRequest(line, snapshot)
                if triad.handled:
                  inc ipcPerfCounters.triadRequests
                  if (
                    triad.subscribeLayout or triad.subscribeState or
                    triad.subscribeWindow
                  ) and not canSubscribeTriad():
                    await client.send(
                      """{"ok":false,"error":"too many event-stream subscribers"}""" &
                        "\L"
                    )
                    break
                  if triad.bindingDispatch.isSome:
                    if dispatchBinding == nil:
                      await client.send(
                        bindingDispatchError("binding dispatch unavailable") & "\L"
                      )
                    else:
                      await client.send(
                        dispatchBinding(triad.bindingDispatch.get()) & "\L"
                      )
                    break
                  if triad.reply.len > 0:
                    await client.send(triad.reply & "\L")
                  for msg in triad.messages:
                    inc ipcPerfCounters.dispatchedMessages
                    onMsg(msg)
                  for event in triad.initialEvents:
                    await client.send(event & "\L")
                  if triad.subscribeLayout or triad.subscribeState or
                      triad.subscribeWindow:
                    triadSubscribers.add(
                      TriadSubscriber(
                        client: client,
                        layout: triad.subscribeLayout,
                        state: triad.subscribeState,
                        window: triad.subscribeWindow,
                      )
                    )
                    asyncCheck watchSubscriberDisconnect(client)
                    inc ipcPerfCounters.triadSubscriptions
                    keepOpen = true
                  break

              if line.strip() == "event-stream":
                inc ipcPerfCounters.invalidRequests
                await client.send(
                  """{"ok":false,"error":"event-stream requires native Triad JSON request"}""" &
                    "\L"
                )
                break
              let dispatch = parseBindingDispatchText(line)
              if dispatch.isSome:
                inc ipcPerfCounters.bindingDispatchRequests
                if dispatchBinding == nil:
                  await client.send(
                    bindingDispatchError("binding dispatch unavailable") & "\L"
                  )
                else:
                  await client.send(dispatchBinding(dispatch.get()) & "\L")
                break
              let parsed = parseTextCommand(line)
              if parsed.isSome:
                inc ipcPerfCounters.textCommands
                inc ipcPerfCounters.dispatchedMessages
                onMsg(parsed.get())
              else:
                inc ipcPerfCounters.invalidRequests
                warn "Unknown or invalid IPC command", command = line
          except CatchableError as e:
            warn "IPC client error", path = path, error = e.msg
        finally:
          dec pendingIpcClients
          if client != nil and not keepOpen and not client.isClosed:
            client.close()
    )()

proc sendIpcMsg*(path: string, msg: string) {.async.} =
  let client = newAsyncSocket(AF_UNIX, SOCK_STREAM, IPPROTO_IP)
  try:
    await client.connectUnix(path)
    await client.send(msg & "\L")
  except CatchableError:
    if not client.isClosed:
      client.close()
    raise
  client.close()

proc sendIpcRequest*(
    path: string, msg: string, timeoutMs = 3000
): Future[string] {.async.} =
  let client = newAsyncSocket(AF_UNIX, SOCK_STREAM, IPPROTO_IP)
  try:
    await client.connectUnix(path)
    await client.send(msg & "\L")
    let reply = client.recvLine()
    if await reply.withTimeout(timeoutMs):
      result = reply.read()
    else:
      raise newException(IOError, "IPC request timed out after " & $timeoutMs & " ms")
  except CatchableError:
    if not client.isClosed:
      client.close()
    raise
  client.close()

proc streamIpcRequest*(
    path: string, msg: string, onLine: proc(line: string)
) {.async.} =
  let client = newAsyncSocket(AF_UNIX, SOCK_STREAM, IPPROTO_IP)
  try:
    await client.connectUnix(path)
    await client.send(msg & "\L")
    while true:
      let line = await client.recvLine()
      if line.len == 0:
        break
      onLine(line)
  finally:
    if not client.isClosed:
      client.close()

proc broadcastTriadJson*(payload: string, eventName: string) {.async.} =
  if lastTriadBroadcastPayloadByEvent.getOrDefault(eventName) == payload:
    inc ipcPerfCounters.triadBroadcastSkippedDuplicate
    inc ipcPerfCounters.triadBroadcastSkippedDuplicateByEvent
    return
  lastTriadBroadcastPayloadByEvent[eventName] = payload

  pruneTriadSubscribers()
  inc ipcPerfCounters.triadBroadcasts
  let currentSubscribers = triadSubscribers
  for subscriber in currentSubscribers:
    let client = subscriber.client
    if client == nil or client.isClosed:
      removeTriadSubscriber(client)
    elif (eventName == "layout" and not subscriber.layout) or
        (eventName == "state" and not subscriber.state) or
        (eventName == "window" and not subscriber.window):
      discard
    else:
      try:
        if await sendWithTimeout(client, payload & "\L"):
          inc ipcPerfCounters.triadBroadcastSends
          inc ipcPerfCounters.triadBroadcastSentBytes, uint64(payload.len)
          discard
        else:
          warn "Dropping slow Triad IPC subscriber"
          inc ipcPerfCounters.droppedSubscribers
          client.close()
          removeTriadSubscriber(client)
      except CatchableError as e:
        warn "Dropping failed Triad IPC subscriber", error = e.msg
        inc ipcPerfCounters.droppedSubscribers
        client.close()
        removeTriadSubscriber(client)
