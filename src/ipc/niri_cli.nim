import std/[json, options, strutils]

type
  NiriCliKind* {.pure.} = enum
    NckInvalid
    NckValidate
    NckRequest

  NiriCliRequest* = object
    kind*: NiriCliKind
    jsonOutput*: bool
    stream*: bool
    socketPayload*: string
    unwrapKey*: string
    error*: string

proc intArg(arg: string): Option[int] =
  try:
    let value = parseInt(arg)
    if value > 0:
      return some(value)
  except CatchableError:
    discard
  none(int)

proc workspaceReference(arg: string): Option[JsonNode] =
  let index = intArg(arg)
  if index.isSome:
    return some(%*{"Index": index.get()})
  if arg.len > 0:
    return some(%*{"Name": arg})
  none(JsonNode)

proc optionValue(args: seq[string], name: string): Option[string] =
  for i in 0 ..< args.len:
    if args[i] == name and i + 1 < args.len:
      return some(args[i + 1])
  none(string)

proc hasFlag(args: seq[string], name: string): bool =
  args.contains(name)

proc pointerFlagValue(args: seq[string], fallback: bool): bool =
  if args.hasFlag("--hide-pointer"):
    return false
  if args.hasFlag("--show-pointer"):
    return true
  fallback

proc writeToDiskValue(args: seq[string]): bool =
  not args.hasFlag("--no-write-to-disk")

proc argsAfterTerminator(args: seq[string]): seq[string] =
  if args.len <= 1:
    return @[]
  if args[1] == "--":
    if args.len <= 2:
      return @[]
    return args[2 ..^ 1]
  args[1 ..^ 1]

proc requestName(command: string): Option[string] =
  case command.normalize()
  of "outputs":
    some("Outputs")
  of "workspaces":
    some("Workspaces")
  of "windows":
    some("Windows")
  of "focusedwindow", "focused-window":
    some("FocusedWindow")
  of "overviewstate", "overview-state":
    some("OverviewState")
  of "keyboardlayouts", "keyboard-layouts":
    some("KeyboardLayouts")
  of "casts":
    some("Casts")
  else:
    none(string)

proc actionPayload(args: seq[string]): Option[JsonNode] =
  if args.len == 0:
    return none(JsonNode)

  case args[0].normalize()
  of "focusworkspace", "focus-workspace":
    if args.len < 2:
      return none(JsonNode)
    let reference = workspaceReference(args[1])
    if reference.isSome:
      return some(%*{"Action": {"FocusWorkspace": {"reference": reference.get()}}})
  of "focusworkspaceup", "focus-workspace-up":
    return some(%*{"Action": {"FocusWorkspaceUp": {}}})
  of "focusworkspacedown", "focus-workspace-down":
    return some(%*{"Action": {"FocusWorkspaceDown": {}}})
  of "focuscolumnleft", "focus-column-left":
    return some(%*{"Action": {"FocusColumnLeft": {}}})
  of "focuscolumnright", "focus-column-right":
    return some(%*{"Action": {"FocusColumnRight": {}}})
  of "focuswindowup", "focus-window-up":
    return some(%*{"Action": {"FocusWindowUp": {}}})
  of "focuswindowdown", "focus-window-down":
    return some(%*{"Action": {"FocusWindowDown": {}}})
  of "focuswindoworworkspaceup", "focus-window-or-workspace-up":
    return some(%*{"Action": {"FocusWindowOrWorkspaceUp": {}}})
  of "focuswindoworworkspacedown", "focus-window-or-workspace-down":
    return some(%*{"Action": {"FocusWindowOrWorkspaceDown": {}}})
  of "focuscolumnfirst", "focus-column-first":
    return some(%*{"Action": {"FocusColumnFirst": {}}})
  of "focuscolumnlast", "focus-column-last":
    return some(%*{"Action": {"FocusColumnLast": {}}})
  of "movecolumnleft", "move-column-left":
    return some(%*{"Action": {"MoveColumnLeft": {}}})
  of "movecolumnright", "move-column-right":
    return some(%*{"Action": {"MoveColumnRight": {}}})
  of "movecolumntofirst", "move-column-to-first":
    return some(%*{"Action": {"MoveColumnToFirst": {}}})
  of "movecolumntolast", "move-column-to-last":
    return some(%*{"Action": {"MoveColumnToLast": {}}})
  of "movewindowup", "move-window-up":
    return some(%*{"Action": {"MoveWindowUp": {}}})
  of "movewindowdown", "move-window-down":
    return some(%*{"Action": {"MoveWindowDown": {}}})
  of "movewindowuportoworkspaceup", "move-window-up-or-to-workspace-up":
    return some(%*{"Action": {"MoveWindowUpOrToWorkspaceUp": {}}})
  of "movewindowdownortoworkspacedown", "move-window-down-or-to-workspace-down":
    return some(%*{"Action": {"MoveWindowDownOrToWorkspaceDown": {}}})
  of "movewindowleft", "move-window-left":
    return some(%*{"Action": {"MoveWindowLeft": {}}})
  of "movewindowright", "move-window-right":
    return some(%*{"Action": {"MoveWindowRight": {}}})
  of "toggleoverview", "toggle-overview":
    return some(%*{"Action": {"ToggleOverview": {}}})
  of "openoverview", "open-overview":
    return some(%*{"Action": {"OpenOverview": {}}})
  of "closeoverview", "close-overview":
    return some(%*{"Action": {"CloseOverview": {}}})
  of "togglekeyboardshortcutsinhibit", "toggle-keyboard-shortcuts-inhibit":
    return some(%*{"Action": {"ToggleKeyboardShortcutsInhibit": {}}})
  of "fullscreenwindow", "fullscreen-window":
    let id = optionValue(args, "--id")
    if id.isSome:
      let win = intArg(id.get())
      if win.isSome:
        return some(%*{"Action": {"FullscreenWindow": {"id": win.get()}}})
      return none(JsonNode)
    return some(%*{"Action": {"FullscreenWindow": {}}})
  of "maximizecolumn", "maximize-column":
    return some(%*{"Action": {"MaximizeColumn": {}}})
  of "maximizewindowtoedges", "maximize-window-to-edges":
    let id = optionValue(args, "--id")
    if id.isSome:
      let win = intArg(id.get())
      if win.isSome:
        return some(%*{"Action": {"MaximizeWindowToEdges": {"id": win.get()}}})
    return some(%*{"Action": {"MaximizeWindowToEdges": {}}})
  of "togglewindowfloating", "toggle-window-floating":
    let id = optionValue(args, "--id")
    if id.isSome:
      let win = intArg(id.get())
      if win.isSome:
        return some(%*{"Action": {"ToggleWindowFloating": {"id": win.get()}}})
      return none(JsonNode)
    return some(%*{"Action": {"ToggleWindowFloating": {}}})
  of "focuswindow", "focus-window":
    let id = optionValue(args, "--id")
    if id.isSome:
      let win = intArg(id.get())
      if win.isSome:
        return some(%*{"Action": {"FocusWindow": {"id": win.get()}}})
  of "closewindow", "close-window":
    let id = optionValue(args, "--id")
    if id.isSome:
      let win = intArg(id.get())
      if win.isSome:
        return some(%*{"Action": {"CloseWindow": {"id": win.get()}}})
    return some(%*{"Action": {"CloseWindow": {}}})
  of "focusmonitor", "focus-monitor":
    if args.len >= 2 and args[1].len > 0:
      return some(%*{"Action": {"FocusMonitor": {"output": args[1]}}})
  of "moveworkspacetoindex", "move-workspace-to-index":
    if args.len >= 2:
      let index = intArg(args[1])
      if index.isSome:
        let reference = optionValue(args, "--reference")
        if reference.isSome:
          let parsedReference = workspaceReference(reference.get())
          if parsedReference.isNone:
            return none(JsonNode)
          return some(
            %*{
              "Action": {
                "MoveWorkspaceToIndex": {
                  "index": index.get(), "reference": parsedReference.get()
                }
              }
            }
          )
        return some(%*{"Action": {"MoveWorkspaceToIndex": {"index": index.get()}}})
  of "movewindowtoworkspace", "move-window-to-workspace":
    if args.len >= 2:
      let reference = workspaceReference(args[1])
      if reference.isSome:
        var payload = %*{"reference": reference.get()}
        let windowId = optionValue(args, "--window-id")
        if windowId.isSome:
          let id = intArg(windowId.get())
          if id.isNone:
            return none(JsonNode)
          payload["window_id"] = %id.get()
        let focus = optionValue(args, "--focus")
        if focus.isSome:
          case focus.get().normalize()
          of "true":
            payload["focus"] = %true
          of "false":
            payload["focus"] = %false
          else:
            return none(JsonNode)
        return some(%*{"Action": {"MoveWindowToWorkspace": payload}})
  of "movewindowtomonitor", "move-window-to-monitor":
    if args.len >= 2 and args[1].len > 0:
      var payload = %*{"output": args[1]}
      let id = optionValue(args, "--id")
      if id.isSome:
        let windowId = intArg(id.get())
        if windowId.isNone:
          return none(JsonNode)
        payload["id"] = %windowId.get()
      return some(%*{"Action": {"MoveWindowToMonitor": payload}})
  of "moveworkspacetomonitor", "move-workspace-to-monitor":
    if args.len >= 2 and args[1].len > 0:
      var payload = %*{"output": args[1]}
      let reference = optionValue(args, "--reference")
      if reference.isSome:
        let parsedReference = workspaceReference(reference.get())
        if parsedReference.isNone:
          return none(JsonNode)
        payload["reference"] = parsedReference.get()
      return some(%*{"Action": {"MoveWorkspaceToMonitor": payload}})
  of "movewindowtofloating", "move-window-to-floating", "movewindowtotiling",
      "move-window-to-tiling":
    let floating = args[0].normalize() in ["movewindowtofloating", "move-window-to-floating"]
    var payload = newJObject()
    let id = optionValue(args, "--id")
    if id.isSome:
      let windowId = intArg(id.get())
      if windowId.isNone:
        return none(JsonNode)
      payload["id"] = %windowId.get()
    let actionName = if floating: "MoveWindowToFloating" else: "MoveWindowToTiling"
    var action = newJObject()
    action[actionName] = payload
    return some(%*{"Action": action})
  of "switchpresetcolumnwidth", "switch-preset-column-width":
    return some(%*{"Action": {"SwitchPresetColumnWidth": {}}})
  of "showhotkeyoverlay", "show-hotkey-overlay":
    return some(%*{"Action": {"ShowHotkeyOverlay": {}}})
  of "loadconfigfile", "load-config-file":
    return some(
      %*{
        "Action": {"LoadConfigFile": {"path": optionValue(args, "--path").get("")}}
      }
    )
  of "poweroffmonitors", "power-off-monitors":
    return some(%*{"Action": {"PowerOffMonitors": {}}})
  of "poweronmonitors", "power-on-monitors":
    return some(%*{"Action": {"PowerOnMonitors": {}}})
  of "spawn":
    let command = args.argsAfterTerminator()
    if command.len > 0:
      return some(%*{"Action": {"Spawn": {"command": command}}})
  of "spawnsh", "spawn-sh":
    let command = args.argsAfterTerminator()
    if command.len > 0:
      return some(%*{"Action": {"SpawnSh": {"command": command.join(" ")}}})
  of "switchlayout", "switch-layout":
    let layout = if args.len >= 2 and args[1].normalize() == "next": "Next" else: "Prev"
    return some(%*{"Action": {"SwitchLayout": {"layout": layout}}})
  of "setworkspacename", "set-workspace-name":
    let name =
      if args.len >= 2:
        args[1]
      else:
        ""
    return
      some(%*{"Action": {"SetWorkspaceName": {"name": name, "workspace": newJNull()}}})
  of "unsetworkspacename", "unset-workspace-name":
    return some(%*{"Action": {"UnsetWorkspaceName": {"workspace": newJNull()}}})
  of "quit":
    return some(
      %*{
        "Action": {"Quit": {"skip_confirmation": args.contains("--skip-confirmation")}}
      }
    )
  of "screenshot":
    return some(
      %*{
        "Action": {
          "Screenshot": {
            "path": optionValue(args, "--path").get(""),
            "show_pointer": pointerFlagValue(args, true),
            "write_to_disk": writeToDiskValue(args),
          }
        }
      }
    )
  of "screenshotscreen", "screenshot-screen":
    return some(
      %*{
        "Action": {
          "ScreenshotScreen": {
            "path": optionValue(args, "--path").get(""),
            "show_pointer": pointerFlagValue(args, true),
            "write_to_disk": writeToDiskValue(args),
          }
        }
      }
    )
  of "screenshotwindow", "screenshot-window":
    return some(
      %*{
        "Action": {
          "ScreenshotWindow": {
            "path": optionValue(args, "--path").get(""),
            "show_pointer": pointerFlagValue(args, false),
            "write_to_disk": writeToDiskValue(args),
          }
        }
      }
    )
  else:
    discard

  none(JsonNode)

proc buildNiriCliRequest*(args: seq[string]): NiriCliRequest =
  if args.len == 0:
    return NiriCliRequest(kind: NiriCliKind.NckInvalid, error: "missing command")

  if args[0] == "validate":
    return NiriCliRequest(kind: NiriCliKind.NckValidate)

  if args[0] != "msg":
    return NiriCliRequest(
      kind: NiriCliKind.NckInvalid, error: "unsupported niri command: " & args[0]
    )

  var jsonOutput = false
  var msgArgs: seq[string] = @[]
  for i in 1 ..< args.len:
    case args[i]
    of "-j", "--json":
      jsonOutput = true
    else:
      msgArgs.add(args[i])

  if msgArgs.len == 0:
    return
      NiriCliRequest(kind: NiriCliKind.NckInvalid, error: "missing niri msg request")

  if msgArgs[0] == "action":
    let actionArgs =
      if msgArgs.len > 1:
        msgArgs[1 ..^ 1]
      else:
        @[]
    let payload = actionPayload(actionArgs)
    if payload.isNone:
      return
        NiriCliRequest(kind: NiriCliKind.NckInvalid, error: "unsupported niri action")
    return NiriCliRequest(
      kind: NiriCliKind.NckRequest,
      jsonOutput: jsonOutput,
      socketPayload: $payload.get(),
    )

  if msgArgs[0] == "output":
    return NiriCliRequest(
      kind: NiriCliKind.NckInvalid, error: "Triad does not support Niri output mutation"
    )

  case msgArgs[0].normalize()
  of "eventstream", "event-stream":
    return NiriCliRequest(
      kind: NiriCliKind.NckRequest,
      jsonOutput: jsonOutput,
      stream: true,
      socketPayload: "\"EventStream\"",
    )
  else:
    discard

  let req = requestName(msgArgs[0])
  if req.isNone:
    return NiriCliRequest(
      kind: NiriCliKind.NckInvalid, error: "unsupported niri msg request: " & msgArgs[0]
    )

  NiriCliRequest(
    kind: NiriCliKind.NckRequest,
    jsonOutput: jsonOutput,
    socketPayload: "\"" & req.get() & "\"",
    unwrapKey: req.get(),
  )

proc unwrapNiriReply*(
    reply: string, unwrapKey: string
): tuple[ok: bool, output: string] =
  try:
    let parsed = parseJson(reply)
    if parsed.kind == JObject and parsed.hasKey("Err"):
      return (false, parsed["Err"].getStr())
    if parsed.kind == JObject and parsed.hasKey("Ok"):
      let ok = parsed["Ok"]
      if unwrapKey.len > 0 and ok.kind == JObject and ok.hasKey(unwrapKey):
        return (true, $ok[unwrapKey])
      return (true, $ok)
  except CatchableError as e:
    return (false, "invalid socket reply: " & e.msg)

  (false, "invalid socket reply")
