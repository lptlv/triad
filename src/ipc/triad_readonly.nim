import std/[json, options, strutils]

import ../types/shell_snapshot
import triad_native

const ReadOnlyTriadRequests = [
  "state", "workspaces", "outputs", "windows", "focused-window", "capabilities"
]

proc errReply(message: string): string =
  $(%*{"ok": false, "error": message})

proc triadRequestName(line: string): Option[string] =
  let stripped = line.strip()
  if stripped.len == 0 or stripped[0] != '{':
    return none(string)

  var root: JsonNode
  try:
    root = parseJson(stripped)
  except CatchableError:
    return none(string)

  if root.kind != JObject or not root.hasKey("triad"):
    return none(string)
  let payload = root["triad"]
  if payload.kind != JObject or not payload.hasKey("request") or
      payload["request"].kind != JString:
    return none(string)
  some(payload["request"].getStr())

proc handleTriadReadOnlyRequest*(
    line: string, snapshot: ShellSnapshot
): TriadIpcResult =
  let requestName = triadRequestName(line)
  if requestName.isSome and requestName.get() notin ReadOnlyTriadRequests:
    return TriadIpcResult(
      handled: true,
      reply:
        errReply(
          "triad request is unavailable in read-only ipc: " & requestName.get()
        ),
    )

  result = handleTriadRequest(line, snapshot)
  if result.handled and (
    result.subscribeLayout or result.subscribeState or result.subscribeWindow or
    result.messages.len > 0 or result.bindingDispatch.isSome
  ):
    result.subscribeLayout = false
    result.subscribeState = false
    result.subscribeWindow = false
    result.initialEvents = @[]
    result.messages = @[]
    result.bindingDispatch = default(typeof(result.bindingDispatch))
    result.reply = errReply("triad request is unavailable in read-only ipc")
