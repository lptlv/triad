import std/[json, options, os, sequtils, strutils, unittest]
import ../src/core/[layout_selection_codec, native_layout_codec]
import ../src/core/msg
import ../src/daemon/shell_runner
import
  ../src/ipc/[
    binding_dispatch, command_help, command_registry, commands, triad_native,
  ]
import ../src/types/[model, runtime_values, shell_snapshot]

proc installAppIdentityFixture() =
  let apps =
    getTempDir() / ("triad-compat-apps-" & $getCurrentProcessId()) / "applications"
  if dirExists(apps.parentDir()):
    removeDir(apps.parentDir())
  createDir(apps)
  writeFile(
    apps / "Alacritty.desktop",
    """
[Desktop Entry]
Name=Alacritty
Exec=alacritty
Icon=Alacritty
Categories=System;TerminalEmulator;
""",
  )
  putEnv("XDG_DATA_HOME", apps.parentDir())
  putEnv("XDG_DATA_DIRS", "")

proc snapshotForShell(): ShellSnapshot =
  ShellSnapshot(
    version: 1,
    activeTag: 1,
    activeWorkspaceIdx: 1,
    layoutCycle: @[LayoutMode.Scroller, LayoutMode.Grid, LayoutMode.Monocle],
    keyboardLayoutNames: @["us", "de"],
    keyboardLayoutIndex: 0,
    workspaces:
      @[
        ShellWorkspace(
          tagId: 1,
          workspaceIdx: 1,
          name: "main",
          layoutMode: LayoutMode.Scroller,
          isActive: true,
          focusedWindow: 10,
          occupied: true,
          outputName: "triad-0",
          columns: @[ShellColumn(idx: 1, widthProportion: 0.5, windows: @[10'u32])],
          masterCount: 1,
          masterSplitRatio: 0.5,
        ),
        ShellWorkspace(
          tagId: 2,
          workspaceIdx: 2,
          name: "web",
          layoutMode: LayoutMode.Grid,
          outputName: "triad-0",
          masterCount: 1,
          masterSplitRatio: 0.5,
        ),
        ShellWorkspace(
          tagId: 3,
          workspaceIdx: 3,
          name: "",
          layoutMode: LayoutMode.Scroller,
          outputName: "triad-0",
          masterCount: 1,
          masterSplitRatio: 0.5,
        ),
      ],
    windows:
      @[
        ShellWindow(
          id: 10,
          parentId: 9,
          title: "Terminal",
          appId: "Alacritty",
          tagId: some(1'u32),
          workspaceIdx: 1,
          outputName: "triad-0",
          colIdx: 1,
          winIdx: 1,
          isFocused: true,
          widthProportion: 0.5,
          heightProportion: 1.0,
          actualW: 777,
          actualH: 555,
        )
      ],
    outputs:
      @[
        ShellOutput(
          id: 0,
          name: "triad-0",
          w: 1920,
          h: 1080,
          refreshRate: 144000,
          physicalWidth: 600,
          physicalHeight: 340,
          scale: 2.0,
          transform: 1,
          isPrimary: true,
        )
      ],
  )

proc handleTriadRequest(line: string, snapshot: ShellSnapshot): TriadIpcResult =
  triad_native.handleTriadRequest(line, snapshot)

proc handleTriadAction(action: string, payload: JsonNode): TriadIpcResult =
  var actionPayload =
    %*{"version": TriadIpcVersion, "request": "action", "action": action}
  for key, value in payload:
    actionPayload[key] = value
  handleTriadRequest($(%*{"triad": actionPayload}), snapshotForShell())

proc handleTriadAction(action: string): TriadIpcResult =
  handleTriadAction(action, newJObject())

proc checkTriadActionMatchesText(action, textCommand: string, payload = newJObject()) =
  let actual = handleTriadAction(action, payload)
  let expected = parseTextCommand(textCommand)
  check parseJson(actual.reply)["ok"].getBool()
  check actual.messages.len == 1
  check expected.isSome
  check repr(actual.messages[0]) == repr(expected.get())

proc sampleCommand(
    spec: CommandSpec
): tuple[action: string, textCommand: string, payload: JsonNode] =
  result.action = spec.name
  result.payload = newJObject()
  case spec.argShape
  of CommandArgShape.NoArgs:
    result.textCommand = spec.name
  of CommandArgShape.OptionalWindowId, CommandArgShape.RequiredWindowId:
    result.textCommand = spec.name & " 42"
    result.payload["id"] = %42
  of CommandArgShape.WindowTagFollow:
    result.textCommand = spec.name & " 42 3 true"
    result.payload["id"] = %42
    result.payload["tag"] = %3
    result.payload["follow"] = %true
  of CommandArgShape.WindowWorkspaceFollow:
    result.textCommand = spec.name & " 42 2 true"
    result.payload["id"] = %42
    result.payload["workspace_idx"] = %2
    result.payload["follow"] = %true
  of CommandArgShape.WindowBool:
    result.textCommand = spec.name & " 42 true"
    result.payload["id"] = %42
    result.payload["value"] = %true
  of CommandArgShape.TagLayout:
    result.textCommand = spec.name & " 3 grid"
    result.payload["tag"] = %3
    result.payload["layout"] = %"grid"
  of CommandArgShape.RequiredTag:
    result.textCommand = spec.name & " 3"
    result.payload["tag"] = %3
  of CommandArgShape.RequiredWorkspaceIdx:
    result.textCommand = spec.name & " 2"
    result.payload["workspace_idx"] = %2
  of CommandArgShape.RequiredName:
    result.textCommand = spec.name & " named scratch"
    result.payload["name"] = %"named scratch"
  of CommandArgShape.RequiredOutput:
    result.textCommand = spec.name & " HDMI-A-1"
    result.payload["output"] = %"HDMI-A-1"
  of CommandArgShape.RequiredFloatDelta:
    result.textCommand = spec.name & " -0.25"
    result.payload["delta"] = %(-0.25)
  of CommandArgShape.RequiredFloatValue:
    result.textCommand = spec.name & " 0.75"
    result.payload["value"] = %0.75
  of CommandArgShape.RequiredIntCount:
    result.textCommand = spec.name & " 2"
    result.payload["count"] = %2
  of CommandArgShape.RequiredIntDelta:
    result.textCommand = spec.name & " -1"
    result.payload["delta"] = %(-1)
  of CommandArgShape.OptionalIntDelta:
    result.textCommand = spec.name & " -1"
    result.payload["delta"] = %(-1)
  of CommandArgShape.MoveDelta:
    result.textCommand = spec.name & " 12 -34"
    result.payload["dx"] = %12
    result.payload["dy"] = %(-34)
  of CommandArgShape.ResizeDelta:
    result.textCommand = spec.name & " 12 -34"
    result.payload["dw"] = %12
    result.payload["dh"] = %(-34)
  of CommandArgShape.RecentAdvance:
    result.textCommand = spec.name & " --scope output --filter app-id"
    result.payload["scope"] = %"output"
    result.payload["filter"] = %"app-id"
  of CommandArgShape.RecentScope:
    result.textCommand = spec.name & " workspace"
    result.payload["scope"] = %"workspace"
  of CommandArgShape.SpawnArgv:
    result.textCommand = spec.name & " sh -lc echo"
    result.payload["argv"] = %*["sh", "-lc", "echo"]
  of CommandArgShape.SplitTreeModeList:
    result.textCommand = spec.name & " splith stacking"
    result.payload["argv"] = %*["splith", "stacking"]
  of CommandArgShape.OptionalFloatDelta:
    result.textCommand = spec.name & " 0.05"
    result.payload["delta"] = %0.05
  of CommandArgShape.KeyboardLayoutTarget:
    result.textCommand = spec.name & " next"
    result.payload["layout"] = %"next"
  of CommandArgShape.WarpPointer:
    result.textCommand = spec.name & " 12 34"
    result.payload["x"] = %12
    result.payload["y"] = %34
  of CommandArgShape.Screenshot:
    result.textCommand =
      spec.name & " --path /tmp/triad.png --show-pointer --clipboard-only"
    result.payload["path"] = %"/tmp/triad.png"
    result.payload["show_pointer"] = %true
    result.payload["write_to_disk"] = %false
    result.payload["copy_to_clipboard"] = %true

proc writeFakeRecoveringShell(
    tmp: string
): tuple[fakeShell: string, logPath: string, statePath: string] =
  result.fakeShell = tmp / "fake-shell"
  result.logPath = tmp / "calls.log"
  result.statePath = tmp / "state"
  writeFile(
    result.fakeShell,
    """
#!/bin/sh
printf '%s\n' "$*" >> "$TRIAD_FAKE_SHELL_LOG"
if [ "$1" = "stop" ]; then
  exit 0
fi
count=0
if [ -f "$TRIAD_FAKE_SHELL_STATE" ]; then
  count="$(cat "$TRIAD_FAKE_SHELL_STATE")"
fi
count=$((count + 1))
printf '%s\n' "$count" > "$TRIAD_FAKE_SHELL_STATE"
handoffs="${TRIAD_FAKE_SHELL_HANDOFFS:-0}"
if [ "$count" -le "$handoffs" ]; then
  exit 0
fi
sleep 30
""",
  )
  setFilePermissions(result.fakeShell, {fpUserRead, fpUserWrite, fpUserExec})

proc singleShellModel(
    launch: seq[string], stop: seq[string] = @[], enabled = true
): Model =
  Model(
    shells: ShellsConfig(
      configured: true,
      enabled: enabled,
      active: "test-shell",
      profiles: @[ShellProfileConfig(name: "test-shell", launch: launch, stop: stop)],
    )
  )

suite "Shell compatibility contracts":
  setup:
    installAppIdentityFixture()

  test "Triad native reads and layout commands use shell snapshots":
    var snapshot = snapshotForShell()
    snapshot.overviewActive = true
    snapshot.customLayouts =
      @[
        JanetLayoutConfig(
          id: janetLayoutId("notion"),
          fallback: nativeSelection(nativeLayoutId("frame-tree"), LayoutMode.Scroller),
        )
      ]
    snapshot.layoutCycleSelections =
      @[
        builtinSelection(LayoutMode.Scroller),
        customSelection(
          janetLayoutId("notion"),
          nativeSelection(nativeLayoutId("frame-tree"), LayoutMode.Scroller),
        ),
      ]

    let stateReply =
      handleTriadRequest("""{"triad":{"version":1,"request":"state"}}""", snapshot)
    check stateReply.handled
    let state = parseJson(stateReply.reply)["triad"]["state"]
    check state["capabilities"]["overview"].getBool()
    check state["capabilities"]["workspace_content_scroll"].getBool()
    check state["capabilities"]["keyboard_layout"].getBool()
    check state["capabilities"]["monitor_power"].getBool()
    check state["overview"]["is_open"].getBool()
    check state["layout"]["active_tag"].getInt() == 1
    check state["outputs"][0]["name"].getStr() == "triad-0"
    check state["outputs"][0]["scale"].getFloat() == 2.0
    check state["outputs"][0]["transform"].getStr() == "90"
    check state["windows"][0]["workspace_idx"].getInt() == 1
    check state["windows"][0]["parent_id"].getInt() == 9

    let workspacesReply =
      handleTriadRequest("""{"triad":{"version":1,"request":"workspaces"}}""", snapshot)
    let workspaces = parseJson(workspacesReply.reply)["triad"]["workspaces"]
    check workspaces[0]["tag_id"].getInt() == 1
    check workspaces[0]["workspace_idx"].getInt() == 1
    check workspaces[0]["focused_window_id"].getInt() == 10

    let outputsReply =
      handleTriadRequest("""{"triad":{"version":1,"request":"outputs"}}""", snapshot)
    let outputs = parseJson(outputsReply.reply)["triad"]["outputs"]
    check outputs[0]["name"].getStr() == "triad-0"
    check outputs[0]["physical_width"].getInt() == 600
    check outputs[0]["scale"].getFloat() == 2.0

    let windowsReply =
      handleTriadRequest("""{"triad":{"version":1,"request":"windows"}}""", snapshot)
    check parseJson(windowsReply.reply)["triad"]["windows"][0]["id"].getInt() == 10

    let focusedWindowReply = handleTriadRequest(
      """{"triad":{"version":1,"request":"focused-window"}}""", snapshot
    )
    check parseJson(focusedWindowReply.reply)["triad"]["window"]["id"].getInt() == 10

    let overviewReply = handleTriadRequest(
      """{"triad":{"version":1,"request":"overview-state"}}""", snapshot
    )
    check parseJson(overviewReply.reply)["triad"]["overview"]["is_open"].getBool()

    let keyboardLayoutsReply = handleTriadRequest(
      """{"triad":{"version":1,"request":"keyboard-layouts"}}""", snapshot
    )
    let keyboardLayouts =
      parseJson(keyboardLayoutsReply.reply)["triad"]["keyboard_layouts"]
    check keyboardLayouts["names"][0].getStr() == "us"
    check keyboardLayouts["current_idx"].getInt() == 0

    let capabilitiesReply = handleTriadRequest(
      """{"triad":{"version":1,"request":"capabilities"}}""", snapshot
    )
    let capabilities = parseJson(capabilitiesReply.reply)["triad"]["capabilities"]
    check parseJson(capabilitiesReply.reply)["triad"]["type"].getStr() == "capabilities"
    check capabilities["workspace_creation"].getBool()
    check capabilities["workspace_content_scroll"].getBool()
    check capabilities["output_metadata"].getBool()
    check capabilities["keyboard_layout"].getBool()
    check capabilities["monitor_power"].getBool()

    let setLayout = handleTriadRequest(
      """{"triad":{"version":1,"request":"set-layout","layout":"deck","target":{"workspace_idx":2}}}""",
      snapshot,
    )
    check parseJson(setLayout.reply)["ok"].getBool()
    check setLayout.messages.len == 1
    check setLayout.messages[0].kind == MsgKind.CmdSetCustomLayout
    check setLayout.messages[0].customLayout.layoutIdString() == "deck"
    check setLayout.messages[0].customLayoutTargetTag == 2

    let setTGMix = handleTriadRequest(
      """{"triad":{"version":1,"request":"set-layout","layout":"tgmix"}}""", snapshot
    )
    check parseJson(setTGMix.reply)["ok"].getBool()
    check setTGMix.messages.len == 1
    check setTGMix.messages[0].kind == MsgKind.CmdSetCustomLayout
    check setTGMix.messages[0].customLayout.layoutIdString() == "tgmix"

    let layoutStateReply = handleTriadRequest(
      """{"triad":{"version":1,"request":"layout-state"}}""", snapshot
    )
    let layoutState = parseJson(layoutStateReply.reply)["triad"]["state"]
    check layoutState["layouts"].getElems().anyIt(
      it["kind"].getStr() == "custom" and it["id"].getStr() == "notion" and
        it["fallback_layout"].getStr() == "frame-tree"
    )
    check layoutState["layout_cycle_entries"].getElems().anyIt(
      it["kind"].getStr() == "custom" and it["id"].getStr() == "notion" and
        it["fallback_layout"].getStr() == "frame-tree"
    )

    let commandsReply = handleTriadRequest(
      """{"triad":{"version":1,"request":"commands"}}""", snapshotForShell()
    )
    check parseJson(commandsReply.reply)["ok"].getBool()
    let catalog = parseJson(commandsReply.reply)["triad"]["catalog"]
    check catalog["commands"].getElems().anyIt(it["name"].getStr() == "focus-next")
    check catalog["special_requests"].getElems().anyIt(
      it["name"].getStr() == "layout-state"
    )
    check catalog["special_requests"].getElems().anyIt(
      it["name"].getStr() == "capabilities"
    )
    check catalog["special_requests"].getElems().anyIt(
      it["name"].getStr() == "workspaces"
    )

    let dispatchReply = handleTriadRequest(
      """{"triad":{"version":1,"request":"dispatch-binding","kind":"key","binding":"Super+h"}}""",
      snapshotForShell(),
    )
    check dispatchReply.bindingDispatch.isSome
    check dispatchReply.bindingDispatch.get().kind == BindingDispatchKind.BindKey
    check dispatchReply.bindingDispatch.get().binding == "Super+h"

  test "Triad command registry has unique resolvable action names":
    var seen: seq[string] = @[]
    for name in allCommandNames():
      check name.len > 0
    for spec in CommandSpecs:
      check spec.name notin seen
      seen.add(spec.name)
      let canonical = resolveCommandSpec(spec.name)
      check canonical.isSome
      check canonical.get().id == spec.id
      if spec.aliases.len > 0:
        for alias in spec.aliases.split('|'):
          check alias notin seen
          seen.add(alias)
          let resolved = resolveCommandSpec(alias)
          check resolved.isSome
          check resolved.get().id == spec.id

  test "Triad msg help and catalog are generated from command registry":
    let help = renderMsgHelp()
    check help.contains("triad msg [--socket PATH] <command> [arguments]")
    check help.contains("triad msg [--socket PATH] validate <command...>")
    check help.contains("focus-next")
    check help.contains("triad msg state")
    check help.contains("triad msg capabilities")
    check help.contains("triad msg workspaces")
    check help.contains("triad msg dispatch-binding")
    check help.contains("triad msg mem-status")

    let topHelp = renderTriadHelp()
    check topHelp.contains("validate-config")
    check topHelp.contains("triad msg --help")

    let focusHelp = renderMsgHelp("focus-workspace")
    check focusHelp.contains("Usage: triad msg focus-workspace <workspace-idx>")
    check focusHelp.contains("required-workspace-idx")

    let newWorkspaceHelp = renderMsgHelp("new-workspace")
    check newWorkspaceHelp.contains("Usage: triad msg new-workspace")
    check newWorkspaceHelp.contains("none")

    let keyboardLayoutHelp = renderMsgHelp("switch-keyboard-layout")
    check keyboardLayoutHelp.contains(
      "Usage: triad msg switch-keyboard-layout [next|prev|index]"
    )

    let aliasHelp = renderMsgHelp("toggle-fullscreen")
    check aliasHelp.contains("fullscreen-window [window-id]")
    check aliasHelp.contains("toggle-fullscreen")

    let catalog = commandCatalogJson()
    check catalog["commands"].len == CommandSpecs.len
    check catalog["commands"].getElems().anyIt(
      it["name"].getStr() == "focus-next" and it["arg_shape"].getStr() == "none"
    )
    check catalog["commands"].getElems().anyIt(
      it["name"].getStr() == "new-workspace" and it["arg_shape"].getStr() == "none"
    )
    check catalog["special_requests"].getElems().anyIt(
      it["name"].getStr() == "state" and it["usage"].getStr() == "triad msg state"
    )
    check catalog["special_requests"].getElems().anyIt(
      it["name"].getStr() == "capabilities" and
        it["usage"].getStr() == "triad msg capabilities"
    )
    check catalog["special_requests"].getElems().anyIt(
      it["name"].getStr() == "workspaces" and
        it["usage"].getStr() == "triad msg workspaces"
    )
    check catalog["special_requests"].getElems().anyIt(
      it["name"].getStr() == "mem-status" and
        it["usage"].getStr() == "triad msg mem-status"
    )

    check triadMsgRequestPayload("state").isSome
    check triadMsgRequestPayload("capabilities").isSome
    check triadMsgRequestPayload("workspaces").isSome
    check triadMsgRequestPayload("outputs").isSome
    check triadMsgRequestPayload("windows").isSome
    check triadMsgRequestPayload("focused-window").isSome
    check triadMsgRequestPayload("overview-state").isSome
    check triadMsgRequestPayload("keyboard-layouts").isSome
    let dispatchPayload =
      triadMsgRequestPayload("dispatch-binding axis Super+wheel-up 2")
    check dispatchPayload.isSome
    check parseJson(dispatchPayload.get())["triad"]["request"].getStr() ==
      "dispatch-binding"
    check parseBindingDispatchText("dispatch-binding gesture Super+swipe-left 3")
    .get().fingers == 3'u32
    let stream = parseJson(nativeEventStreamPayload(@["layout"]))
    check stream["triad"]["request"].getStr() == "event-stream"
    check stream["triad"]["events"][0].getStr() == "layout"
    let windowStream = parseJson(nativeEventStreamPayload(@["window"]))
    check windowStream["triad"]["events"][0].getStr() == "window"

    let docs =
      readFile("docs/ipc.md") & "\n" & readFile("docs/comp/config-command-matrix.md")
    let commandList = renderCommandList()
    for spec in CommandSpecs:
      check commandList.contains(spec.name) or docs.contains(spec.name)

  test "Triad native actions mirror text IPC commands":
    for spec in CommandSpecs:
      let sample = sampleCommand(spec)
      checkTriadActionMatchesText(sample.action, sample.textCommand, sample.payload)
      if spec.aliases.len > 0:
        for alias in spec.aliases.split('|'):
          checkTriadActionMatchesText(alias, sample.textCommand, sample.payload)

    let badAction = handleTriadAction("spawn", %*{"argv": []})
    check not parseJson(badAction.reply)["ok"].getBool()
    check badAction.messages.len == 0

    let badWindowId = handleTriadAction("focus-window", %*{"id": "bad"})
    check not parseJson(badWindowId.reply)["ok"].getBool()
    check badWindowId.messages.len == 0

    let keyboardNext = handleTriadAction("switch-keyboard-layout", %*{"layout": "next"})
    check parseJson(keyboardNext.reply)["ok"].getBool()
    check keyboardNext.messages[0].kind == MsgKind.CmdSwitchKeyboardLayout
    check keyboardNext.messages[0].keyboardLayoutDelta == 1
    check keyboardNext.messages[0].keyboardLayoutIndex == -1

    let keyboardIndex = handleTriadAction("switch-keyboard-layout", %*{"layout": 1})
    check parseJson(keyboardIndex.reply)["ok"].getBool()
    check keyboardIndex.messages[0].kind == MsgKind.CmdSwitchKeyboardLayout
    check keyboardIndex.messages[0].keyboardLayoutIndex == 1
    check keyboardIndex.messages[0].keyboardLayoutDelta == 0

    let badScreenshot = handleTriadAction(
      "screenshot", %*{"write_to_disk": false, "copy_to_clipboard": false}
    )
    check not parseJson(badScreenshot.reply)["ok"].getBool()
    check badScreenshot.messages.len == 0

  test "event streams start with current snapshot state":
    let triad = handleTriadRequest(
      """{"triad":{"version":1,"request":"event-stream","events":["layout","state"]}}""",
      snapshotForShell(),
    )
    check triad.subscribeLayout
    check triad.subscribeState
    check triad.initialEvents.len == 2

    let windowTriad = handleTriadRequest(
      """{"triad":{"version":1,"request":"event-stream","events":["window"]}}""",
      snapshotForShell(),
    )
    check windowTriad.subscribeWindow
    check not windowTriad.subscribeLayout
    check not windowTriad.subscribeState
    check windowTriad.initialEvents.len == 0

  test "workspace JSON surfaces preserve urgency":
    let capabilitiesReply = handleTriadRequest(
      """{"triad":{"version":1,"request":"capabilities"}}""", snapshotForShell()
    )
    let capabilities = parseJson(capabilitiesReply.reply)["triad"]["capabilities"]
    check capabilities["workspace_urgency"].getBool()

    var snapshot = snapshotForShell()
    snapshot.workspaces[0].isUrgent = true

    let stateReply = handleTriadRequest(
      """{"triad":{"version":1,"request":"state"}}""", snapshot
    )
    let workspaces =
      parseJson(stateReply.reply)["triad"]["state"]["layout"]["workspaces"]
    check workspaces.len > 0
    check workspaces[0]["is_urgent"].getBool()

  test "window JSON surfaces preserve urgency":
    var snapshot = snapshotForShell()
    snapshot.windows[0].isUrgent = true

    let triadReply = handleTriadRequest(
      """{"triad":{"version":1,"request":"state"}}""", snapshot
    )
    let triadWindows = parseJson(triadReply.reply)["triad"]["state"]["windows"]
    check triadWindows[0]["is_urgent"].getBool()

  test "Shell switching stops old profile before launching new profile":
    let tmp = getTempDir() / ("triad-shell-switch-" & $getCurrentProcessId())
    if dirExists(tmp):
      removeDir(tmp)
    createDir(tmp)
    defer:
      if dirExists(tmp):
        removeDir(tmp)

    let fake = tmp / "fake-shell"
    let logPath = tmp / "calls.log"
    writeFile(
      fake,
      """
#!/bin/sh
printf '%s\n' "$*" >> "$TRIAD_FAKE_SHELL_LOG"
exit 0
""",
    )
    setFilePermissions(fake, {fpUserRead, fpUserWrite, fpUserExec})

    let oldLog = getEnv("TRIAD_FAKE_SHELL_LOG", "")
    putEnv("TRIAD_FAKE_SHELL_LOG", logPath)
    defer:
      putEnv("TRIAD_FAKE_SHELL_LOG", oldLog)

    let previous = Model(
      shells: ShellsConfig(
        configured: true,
        enabled: true,
        active: "old",
        profiles:
          @[
            ShellProfileConfig(
              name: "old", launch: @[fake, "launch-old"], stop: @[fake, "stop-old"]
            ),
            ShellProfileConfig(
              name: "new", launch: @[fake, "launch-new"], stop: @[fake, "stop-new"]
            ),
          ],
      )
    )
    let current = Model(
      shells: ShellsConfig(
        configured: true,
        enabled: true,
        active: "new",
        profiles: previous.shells.profiles,
      )
    )

    var runner = ShellRunner()
    runner.switchShell(previous, current, "test switch")
    let calls = readFile(logPath).splitLines().filterIt(it.len > 0)
    check calls == @["stop-old", "launch-new"]

  test "Shell profiles receive native Triad environment":
    let tmp = getTempDir() / ("triad-shell-native-env-" & $getCurrentProcessId())
    if dirExists(tmp):
      removeDir(tmp)
    createDir(tmp)
    defer:
      if dirExists(tmp):
        removeDir(tmp)

    let fake = tmp / "fake-shell"
    let logPath = tmp / "env.log"
    writeFile(
      fake,
      """
#!/bin/sh
printf '%s|%s|%s|%s\n' "$TRIAD_SOCKET" "$XDG_CURRENT_DESKTOP" "$XDG_SESSION_DESKTOP" "$DESKTOP_SESSION" > "$TRIAD_FAKE_SHELL_LOG"
exit 0
""",
    )
    setFilePermissions(fake, {fpUserRead, fpUserWrite, fpUserExec})

    let oldLog = getEnv("TRIAD_FAKE_SHELL_LOG", "")
    let oldRuntimeDir = getEnv("XDG_RUNTIME_DIR", "")
    putEnv("TRIAD_FAKE_SHELL_LOG", logPath)
    putEnv("XDG_RUNTIME_DIR", tmp)
    defer:
      putEnv("TRIAD_FAKE_SHELL_LOG", oldLog)
      putEnv("XDG_RUNTIME_DIR", oldRuntimeDir)

    let model = Model(
      shells: ShellsConfig(
        configured: true,
        enabled: true,
        active: "dank",
        profiles: @[ShellProfileConfig(name: "dank", launch: @[fake])],
      )
    )
    var runner = ShellRunner()

    runner.switchShell(Model(), model, "test native env")
    check readFile(logPath).strip() == tmp / "triad.sock" & "|triad|triad|triad"

  test "Shell watchdog falls back when active tracked shell exits":
    let tmp = getTempDir() / ("triad-shell-watchdog-exit-" & $getCurrentProcessId())
    if dirExists(tmp):
      removeDir(tmp)
    createDir(tmp)
    defer:
      if dirExists(tmp):
        removeDir(tmp)

    let fake = tmp / "fake-shell"
    writeFile(
      fake,
      """
#!/bin/sh
if [ "$1" = "launch-dank" ]; then
  sleep 1
  exit 7
fi
sleep 5
""",
    )
    setFilePermissions(fake, {fpUserRead, fpUserWrite, fpUserExec})

    let model = Model(
      shells: ShellsConfig(
        configured: true,
        enabled: true,
        active: "dank",
        cycle: @["waybar", "dank"],
        watchdog: ShellWatchdogConfig(
          enabled: true, fallback: "waybar", exclusiveFocusTimeoutMs: 30000
        ),
        profiles:
          @[
            ShellProfileConfig(
              name: "dank", launch: @[fake, "launch-dank"], stop: @[fake, "stop-dank"]
            ),
            ShellProfileConfig(name: "waybar", launch: @[fake, "launch-waybar"]),
          ],
      )
    )
    var runner = ShellRunner()
    runner.switchShell(Model(), model, "test spawn")
    check runner.trackedShellRunning()

    sleep(1200)
    let fallback = runner.pollShellWatchdog(model, 2000)
    check fallback.isSome
    check fallback.get() == "waybar"
    check runner.trackedProcess == nil

  test "Shell watchdog falls back after exclusive layer focus timeout":
    let model = Model(
      layerFocusExclusive: true,
      shells: ShellsConfig(
        configured: true,
        enabled: true,
        active: "dank",
        watchdog: ShellWatchdogConfig(
          enabled: true, fallback: "waybar", exclusiveFocusTimeoutMs: 10
        ),
        profiles:
          @[
            ShellProfileConfig(name: "dank", launch: @["dms", "run"]),
            ShellProfileConfig(name: "waybar", launch: @["waybar"]),
          ],
      ),
    )
    var runner = ShellRunner()
    check runner.pollShellWatchdog(model, 1000).isNone
    let fallback = runner.pollShellWatchdog(model, 1011)
    check fallback.isSome
    check fallback.get() == "waybar"

  test "Shell startup stops stale configured profiles before active launch":
    let tmp = getTempDir() / ("triad-shell-startup-cleanup-" & $getCurrentProcessId())
    if dirExists(tmp):
      removeDir(tmp)
    createDir(tmp)
    defer:
      if dirExists(tmp):
        removeDir(tmp)

    let fake = tmp / "fake-shell"
    let logPath = tmp / "calls.log"
    writeFile(
      fake,
      """
#!/bin/sh
printf '%s\n' "$*" >> "$TRIAD_FAKE_SHELL_LOG"
if [ "$1" = "launch-noctalia" ]; then
  sleep 5
fi
exit 0
""",
    )
    setFilePermissions(fake, {fpUserRead, fpUserWrite, fpUserExec})

    let oldLog = getEnv("TRIAD_FAKE_SHELL_LOG", "")
    putEnv("TRIAD_FAKE_SHELL_LOG", logPath)
    defer:
      putEnv("TRIAD_FAKE_SHELL_LOG", oldLog)

    let model = Model(
      shells: ShellsConfig(
        configured: true,
        enabled: true,
        active: "noctalia",
        profiles:
          @[
            ShellProfileConfig(
              name: "noctalia",
              launch: @[fake, "launch-noctalia"],
              stop: @[fake, "stop-noctalia"],
            ),
            ShellProfileConfig(
              name: "waybar", launch: @[fake], stop: @[fake, "stop-waybar"]
            ),
            ShellProfileConfig(
              name: "dank", launch: @[fake], stop: @[fake, "stop-dank"]
            ),
          ],
      )
    )
    var runner = ShellRunner(spawnPending: true)
    defer:
      runner.stopTrackedShell("test cleanup")

    runner.spawnPendingShell(model, "initial manage")

    let calls = readFile(logPath).splitLines().filterIt(it.len > 0)
    check calls == @["stop-noctalia", "stop-waybar", "stop-dank", "launch-noctalia"]

  test "Shell unchanged reload can recover untracked active profile":
    var runner = ShellRunner()
    check runner.needsShellRecovery(singleShellModel(@["missing-shell"]))
    check not runner.needsShellRecovery(
      singleShellModel(@["missing-shell"], enabled = false)
    )

  test "Shell spawn handoff refreshes configured profile":
    let tmp = getTempDir() / ("triad-shell-handoff-" & $getCurrentProcessId())
    if dirExists(tmp):
      removeDir(tmp)
    createDir(tmp)
    defer:
      if dirExists(tmp):
        removeDir(tmp)

    let fakeShell = tmp / "fake-shell"
    let logPath = tmp / "calls.log"
    writeFile(
      fakeShell,
      """
#!/bin/sh
printf '%s\n' "$*" >> "$TRIAD_FAKE_SHELL_LOG"
exit "${TRIAD_FAKE_SHELL_EXIT:-0}"
""",
    )
    setFilePermissions(fakeShell, {fpUserRead, fpUserWrite, fpUserExec})

    let oldLog = getEnv("TRIAD_FAKE_SHELL_LOG", "")
    let oldExit = getEnv("TRIAD_FAKE_SHELL_EXIT", "")
    putEnv("TRIAD_FAKE_SHELL_LOG", logPath)
    putEnv("TRIAD_FAKE_SHELL_EXIT", "0")
    defer:
      putEnv("TRIAD_FAKE_SHELL_LOG", oldLog)
      putEnv("TRIAD_FAKE_SHELL_EXIT", oldExit)

    var runner = ShellRunner(spawnPending: true)
    let model = singleShellModel(@[fakeShell, "launch"], @[fakeShell, "stop"])

    runner.spawnPendingShell(model, "test")

    let calls = readFile(logPath)
    check calls.count("launch") >= 2
    check calls.count("stop") >= 2

  test "Shell double handoff schedules recovery until tracked":
    let tmp = getTempDir() / ("triad-shell-recovery-" & $getCurrentProcessId())
    if dirExists(tmp):
      removeDir(tmp)
    createDir(tmp)
    defer:
      if dirExists(tmp):
        removeDir(tmp)

    let fake = writeFakeRecoveringShell(tmp)

    let oldLog = getEnv("TRIAD_FAKE_SHELL_LOG", "")
    let oldState = getEnv("TRIAD_FAKE_SHELL_STATE", "")
    let oldHandoffs = getEnv("TRIAD_FAKE_SHELL_HANDOFFS", "")
    putEnv("TRIAD_FAKE_SHELL_LOG", fake.logPath)
    putEnv("TRIAD_FAKE_SHELL_STATE", fake.statePath)
    putEnv("TRIAD_FAKE_SHELL_HANDOFFS", "2")
    defer:
      putEnv("TRIAD_FAKE_SHELL_LOG", oldLog)
      putEnv("TRIAD_FAKE_SHELL_STATE", oldState)
      putEnv("TRIAD_FAKE_SHELL_HANDOFFS", oldHandoffs)

    var runner = ShellRunner(spawnPending: true)
    let model = singleShellModel(@[fake.fakeShell, "launch"], @[fake.fakeShell, "stop"])
    defer:
      runner.stopTrackedShell("test cleanup")

    runner.spawnPendingShell(model, "test")

    check runner.recoveryPending
    check runner.recoveryAttempts == 0
    check readFile(fake.statePath).strip() == "2"

    runner.nextRecoveryMs = 0
    check runner.pollShellRecovery(model, 0)
    check not runner.recoveryPending
    check runner.trackedShellRunning()
    check readFile(fake.statePath).strip() == "3"

    let calls = readFile(fake.logPath)
    check calls.count("stop") >= 2

  test "Shell recovery exhausts repeated handoffs":
    let tmp = getTempDir() / ("triad-shell-recovery-exhaust-" & $getCurrentProcessId())
    if dirExists(tmp):
      removeDir(tmp)
    createDir(tmp)
    defer:
      if dirExists(tmp):
        removeDir(tmp)

    let fake = writeFakeRecoveringShell(tmp)

    let oldLog = getEnv("TRIAD_FAKE_SHELL_LOG", "")
    let oldState = getEnv("TRIAD_FAKE_SHELL_STATE", "")
    let oldHandoffs = getEnv("TRIAD_FAKE_SHELL_HANDOFFS", "")
    putEnv("TRIAD_FAKE_SHELL_LOG", fake.logPath)
    putEnv("TRIAD_FAKE_SHELL_STATE", fake.statePath)
    putEnv("TRIAD_FAKE_SHELL_HANDOFFS", "99")
    defer:
      putEnv("TRIAD_FAKE_SHELL_LOG", oldLog)
      putEnv("TRIAD_FAKE_SHELL_STATE", oldState)
      putEnv("TRIAD_FAKE_SHELL_HANDOFFS", oldHandoffs)

    var runner = ShellRunner(spawnPending: true)
    let model = singleShellModel(@[fake.fakeShell, "launch"], @[fake.fakeShell, "stop"])

    runner.spawnPendingShell(model, "test")
    check runner.recoveryPending

    for attempt in 1 .. MaxShellRecoveryAttempts:
      runner.nextRecoveryMs = 0
      check runner.pollShellRecovery(model, 0)
      if attempt < MaxShellRecoveryAttempts:
        check runner.recoveryPending
        check runner.recoveryAttempts == attempt
      else:
        check not runner.recoveryPending

    check readFile(fake.statePath).strip() == "5"
    let calls = readFile(fake.logPath)
    check calls.count("stop") >= 4

  test "Shell config reload handoff schedules recovery":
    let tmp = getTempDir() / ("triad-shell-config-recovery-" & $getCurrentProcessId())
    if dirExists(tmp):
      removeDir(tmp)
    createDir(tmp)
    defer:
      if dirExists(tmp):
        removeDir(tmp)

    let fake = writeFakeRecoveringShell(tmp)

    let oldLog = getEnv("TRIAD_FAKE_SHELL_LOG", "")
    let oldState = getEnv("TRIAD_FAKE_SHELL_STATE", "")
    let oldHandoffs = getEnv("TRIAD_FAKE_SHELL_HANDOFFS", "")
    putEnv("TRIAD_FAKE_SHELL_LOG", fake.logPath)
    putEnv("TRIAD_FAKE_SHELL_STATE", fake.statePath)
    putEnv("TRIAD_FAKE_SHELL_HANDOFFS", "1")
    defer:
      putEnv("TRIAD_FAKE_SHELL_LOG", oldLog)
      putEnv("TRIAD_FAKE_SHELL_STATE", oldState)
      putEnv("TRIAD_FAKE_SHELL_HANDOFFS", oldHandoffs)

    var runner = ShellRunner()
    let model = singleShellModel(@[fake.fakeShell, "launch"], @[fake.fakeShell, "stop"])
    defer:
      runner.stopTrackedShell("test cleanup")

    runner.switchShell(Model(), model, "config reload recovery")
    check runner.recoveryPending

    runner.nextRecoveryMs = 0
    check runner.pollShellRecovery(model, 0)
    check not runner.recoveryPending
    check runner.trackedShellRunning()
    check readFile(fake.statePath).strip() == "2"

  test "Shell failed spawn kills stale configured profile":
    let tmp = getTempDir() / ("triad-shell-failed-" & $getCurrentProcessId())
    if dirExists(tmp):
      removeDir(tmp)
    createDir(tmp)
    defer:
      if dirExists(tmp):
        removeDir(tmp)

    let fakeShell = tmp / "fake-shell"
    let logPath = tmp / "calls.log"
    writeFile(
      fakeShell,
      """
#!/bin/sh
printf '%s\n' "$*" >> "$TRIAD_FAKE_SHELL_LOG"
if [ "$1" = "stop" ]; then
  exit 0
fi
exit "${TRIAD_FAKE_SHELL_EXIT:-9}"
""",
    )
    setFilePermissions(fakeShell, {fpUserRead, fpUserWrite, fpUserExec})

    let oldLog = getEnv("TRIAD_FAKE_SHELL_LOG", "")
    let oldExit = getEnv("TRIAD_FAKE_SHELL_EXIT", "")
    putEnv("TRIAD_FAKE_SHELL_LOG", logPath)
    putEnv("TRIAD_FAKE_SHELL_EXIT", "9")
    defer:
      putEnv("TRIAD_FAKE_SHELL_LOG", oldLog)
      putEnv("TRIAD_FAKE_SHELL_EXIT", oldExit)

    var runner = ShellRunner(spawnPending: true)
    let model = singleShellModel(@[fakeShell, "launch"], @[fakeShell, "stop"])

    runner.spawnPendingShell(model, "test")

    let calls = readFile(logPath)
    check calls.contains("launch")
    check calls.contains("stop")

  test "text IPC remains Triad-native":
    let msg = parseTextCommand("focus-workspace 2")
    check msg.isSome
    check msg.get().kind == MsgKind.CmdFocusWorkspaceIndex
    check msg.get().workspaceIndex == 2
    check parseTextCommand("power-off-monitors").get().kind ==
      MsgKind.CmdPowerOffMonitors
    check parseTextCommand("power-on-monitors").get().kind == MsgKind.CmdPowerOnMonitors
    let powerOffMonitor = parseTextCommand("power-off-monitor DP-3").get()
    check powerOffMonitor.kind == MsgKind.CmdPowerOffMonitor
    check powerOffMonitor.outputTarget == "DP-3"
    let powerOnMonitor = parseTextCommand("power-on-monitor DP-3").get()
    check powerOnMonitor.kind == MsgKind.CmdPowerOnMonitor
    check powerOnMonitor.outputTarget == "DP-3"
    check parseTextCommand("mmsg -g -A").isNone
