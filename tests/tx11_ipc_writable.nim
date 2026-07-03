import std/[json, options, sequtils, strutils, unittest]

import ../src/config/parser
import ../src/core/msg
import ../src/ipc/triad_readonly
import ../src/systems/runtime_facade
import ../src/types/model
import ../src/types/[runtime_values, shell_snapshot]
import ../src/x11/[ipc_runtime, request_builder, request_executor]

proc x11Snapshot(): ShellSnapshot =
  ShellSnapshot(
    version: 1,
    activeTag: 1,
    activeWorkspaceIdx: 1,
    workspaces: @[
      ShellWorkspace(
        tagId: 1,
        workspaceIdx: 1,
        name: "main",
        layoutMode: LayoutMode.Scroller,
        isActive: true,
        focusedWindow: 0x2a,
        occupied: true,
        outputName: "Xvfb-0",
        masterCount: 1,
        masterSplitRatio: 0.5,
      )
    ],
    windows: @[
      ShellWindow(
        id: 0x2a,
        title: "triad smoke",
        appId: "triad-smoke",
        tagId: some(1'u32),
        workspaceIdx: 1,
        outputName: "Xvfb-0",
        isFocused: true,
        actualW: 760,
        actualH: 560,
      )
    ],
    outputs: @[ShellOutput(id: 1, name: "Xvfb-0", w: 800, h: 600, isPrimary: true)],
  )

proc bindingModel(): Model =
  initRuntimeStateFromConfig(
    Config(
      workspaces: WorkspaceConfig(defaultCount: 3),
      keyBindings: @[
        KeyBindingConfig(
          key: "h",
          modifiers: 64'u32,
          command: "focus-workspace 2",
          mode: BindingMode.BindAlways,
        ),
        KeyBindingConfig(
          key: "q",
          modifiers: 64'u32,
          command: "close-window",
          mode: BindingMode.BindAlways,
        ),
        KeyBindingConfig(
          key: "Tab",
          modifiers: 64'u32,
          command: "focus-next",
          mode: BindingMode.BindAlways,
        ),
        KeyBindingConfig(
          key: "l",
          modifiers: 64'u32,
          command: "focus-right",
          mode: BindingMode.BindAlways,
        ),
        KeyBindingConfig(
          key: "n",
          modifiers: 64'u32,
          command: "switch-layout",
          mode: BindingMode.BindAlways,
        ),
        KeyBindingConfig(
          key: "m",
          modifiers: 64'u32,
          command: "maximize-column",
          mode: BindingMode.BindAlways,
        ),
        KeyBindingConfig(
          key: "x",
          modifiers: 64'u32,
          command: "spawn touch /tmp/triad-xlibre-spawn-test",
          mode: BindingMode.BindAlways,
        ),
        KeyBindingConfig(
          key: "Return",
          modifiers: 64'u32,
          command: "spawn-terminal",
          mode: BindingMode.BindAlways,
        ),
        KeyBindingConfig(
          key: "z",
          modifiers: 64'u32,
          command: "lock-session",
          mode: BindingMode.BindAlways,
        ),
      ],
      axisBindings: @[
        AxisBindingConfig(
          direction: AxisBindingDirection.AxisUp,
          modifiers: 64'u32,
          command: "focus-next",
          mode: BindingMode.BindAlways,
        )
      ],
    )
  ).model

suite "X11 writable IPC":
  test "close-window request builds one polite close request":
    let parsed = xlibreWritableRequestFor(
      """{"triad":{"version":1,"request":"xlibre-close-window","id":42}}""",
      x11Snapshot(),
    )

    check parsed.handled
    check parsed.reply.len == 0
    check parsed.requests.len == 1
    check parsed.requests[0].kind == X11RequestKind.XrqSendCloseWindow
    check parsed.requests[0].windowId == 42

  test "close-window request rejects unknown ids":
    let parsed = xlibreWritableRequestFor(
      """{"triad":{"version":1,"request":"xlibre-close-window","id":99}}""",
      x11Snapshot(),
    )
    let reply = parseJson(parsed.reply)

    check parsed.handled
    check parsed.requests.len == 0
    check not reply["ok"].getBool()
    check reply["error"].getStr().contains("unknown xlibre window id")

  test "focus-window request builds one focus request":
    let parsed = xlibreWritableRequestFor(
      """{"triad":{"version":1,"request":"xlibre-focus-window","id":42}}""",
      x11Snapshot(),
    )

    check parsed.handled
    check parsed.reply.len == 0
    check parsed.requests.len == 1
    check parsed.requests[0].kind == X11RequestKind.XrqSetInputFocus
    check parsed.requests[0].windowId == 42

  test "focus-window request rejects invalid ids":
    let parsed = xlibreWritableRequestFor(
      """{"triad":{"version":1,"request":"xlibre-focus-window","id":0}}""",
      x11Snapshot(),
    )
    let reply = parseJson(parsed.reply)

    check parsed.handled
    check parsed.requests.len == 0
    check not reply["ok"].getBool()
    check reply["error"].getStr().contains("xlibre-focus-window requires positive id")

  test "focus-workspace request builds one workspace focus message":
    let parsed = xlibreWritableRequestFor(
      """{"triad":{"version":1,"request":"xlibre-focus-workspace","workspace":2}}""",
      x11Snapshot(),
    )

    check parsed.handled
    check parsed.reply.len == 0
    check parsed.requests.len == 0
    check parsed.messages.len == 1
    check parsed.messages[0].kind == MsgKind.CmdFocusWorkspaceIndex
    check parsed.messages[0].workspaceIndex == 2

  test "move-window-to-workspace request builds one window move message":
    let parsed = xlibreWritableRequestFor(
      """{"triad":{"version":1,"request":"xlibre-move-window-to-workspace","id":42,"workspace":2,"follow":false}}""",
      x11Snapshot(),
    )

    check parsed.handled
    check parsed.reply.len == 0
    check parsed.requests.len == 0
    check parsed.messages.len == 1
    check parsed.messages[0].kind == MsgKind.CmdMoveWindowToWorkspaceIndex
    check parsed.messages[0].moveWorkspaceWindowId == 42
    check parsed.messages[0].moveWorkspaceIndex == 2
    check not parsed.messages[0].moveWorkspaceFollowWindow

  test "move-window-to-workspace defaults to following the moved window":
    let parsed = xlibreWritableRequestFor(
      """{"triad":{"version":1,"request":"xlibre-move-window-to-workspace","id":42,"workspace":2}}""",
      x11Snapshot(),
    )

    check parsed.handled
    check parsed.messages.len == 1
    check parsed.messages[0].moveWorkspaceFollowWindow

  test "move-window-to-workspace rejects unknown ids":
    let parsed = xlibreWritableRequestFor(
      """{"triad":{"version":1,"request":"xlibre-move-window-to-workspace","id":99,"workspace":2}}""",
      x11Snapshot(),
    )
    let reply = parseJson(parsed.reply)

    check parsed.handled
    check parsed.messages.len == 0
    check not reply["ok"].getBool()
    check reply["error"].getStr().contains("unknown xlibre window id")

  test "stop request is handled without model messages or xcb requests":
    let parsed = xlibreWritableRequestFor(
      """{"triad":{"version":1,"request":"xlibre-stop"}}""", x11Snapshot()
    )

    check parsed.handled
    check parsed.requestName == "xlibre-stop"
    check parsed.reply.len == 0
    check parsed.messages.len == 0
    check parsed.requests.len == 0

  test "binding dispatch resolves configured key binding to supported command":
    let parsed = xlibreWritableRequestFor(
      """{"triad":{"version":1,"request":"dispatch-binding","kind":"key","binding":"Super+h"}}""",
      bindingModel(),
      x11Snapshot(),
    )

    check parsed.handled
    check parsed.requestName == "dispatch-binding"
    check parsed.bindingDispatch.ok
    check parsed.bindingDispatch.command == "focus-workspace 2"
    check parsed.messages.len == 1
    check parsed.messages[0].kind == MsgKind.CmdFocusWorkspaceIndex
    check parsed.messages[0].workspaceIndex == 2

  test "binding dispatch resolves close-window key binding":
    let parsed = xlibreWritableRequestFor(
      """{"triad":{"version":1,"request":"dispatch-binding","kind":"key","binding":"Super+q"}}""",
      bindingModel(),
      x11Snapshot(),
    )

    check parsed.handled
    check parsed.bindingDispatch.ok
    check parsed.bindingDispatch.command == "close-window"
    check parsed.messages.len == 1
    check parsed.messages[0].kind == MsgKind.CmdCloseWindow

  test "binding dispatch resolves focus-next key binding":
    let parsed = xlibreWritableRequestFor(
      """{"triad":{"version":1,"request":"dispatch-binding","kind":"key","binding":"Super+Tab"}}""",
      bindingModel(),
      x11Snapshot(),
    )

    check parsed.handled
    check parsed.bindingDispatch.ok
    check parsed.bindingDispatch.command == "focus-next"
    check parsed.messages.len == 1
    check parsed.messages[0].kind == MsgKind.CmdFocusNext

  test "binding dispatch resolves directional focus key binding":
    let parsed = xlibreWritableRequestFor(
      """{"triad":{"version":1,"request":"dispatch-binding","kind":"key","binding":"Super+l"}}""",
      bindingModel(),
      x11Snapshot(),
    )

    check parsed.handled
    check parsed.bindingDispatch.ok
    check parsed.bindingDispatch.command == "focus-right"
    check parsed.messages.len == 1
    check parsed.messages[0].kind == MsgKind.CmdFocusDirection
    check parsed.messages[0].direction == Direction.DirRight

  test "binding dispatch resolves switch-layout key binding":
    let parsed = xlibreWritableRequestFor(
      """{"triad":{"version":1,"request":"dispatch-binding","kind":"key","binding":"Super+n"}}""",
      bindingModel(),
      x11Snapshot(),
    )

    check parsed.handled
    check parsed.bindingDispatch.ok
    check parsed.bindingDispatch.command == "switch-layout"
    check parsed.messages.len == 1
    check parsed.messages[0].kind == MsgKind.CmdSwitchLayout

  test "binding dispatch resolves maximize-column key binding":
    let parsed = xlibreWritableRequestFor(
      """{"triad":{"version":1,"request":"dispatch-binding","kind":"key","binding":"Super+m"}}""",
      bindingModel(),
      x11Snapshot(),
    )

    check parsed.handled
    check parsed.bindingDispatch.ok
    check parsed.bindingDispatch.command == "maximize-column"
    check parsed.messages.len == 1
    check parsed.messages[0].kind == MsgKind.CmdMaximizeColumn

  test "binding dispatch resolves configured spawn key binding":
    let parsed = xlibreWritableRequestFor(
      """{"triad":{"version":1,"request":"dispatch-binding","kind":"key","binding":"Super+x"}}""",
      bindingModel(),
      x11Snapshot(),
    )

    check parsed.handled
    check parsed.bindingDispatch.ok
    check parsed.bindingDispatch.command == "spawn touch /tmp/triad-xlibre-spawn-test"
    check parsed.messages.len == 1
    check parsed.messages[0].kind == MsgKind.CmdSpawn
    check parsed.messages[0].spawnCommand == @["touch", "/tmp/triad-xlibre-spawn-test"]

  test "binding dispatch resolves configured spawn-terminal key binding":
    let parsed = xlibreWritableRequestFor(
      """{"triad":{"version":1,"request":"dispatch-binding","kind":"key","binding":"Super+Return"}}""",
      bindingModel(),
      x11Snapshot(),
    )

    check parsed.handled
    check parsed.bindingDispatch.ok
    check parsed.bindingDispatch.command == "spawn-terminal"
    check parsed.messages.len == 1
    check parsed.messages[0].kind == MsgKind.CmdSpawnTerminal

  test "binding dispatch expands axis ticks into repeated supported commands":
    let parsed = xlibreWritableRequestFor(
      """{"triad":{"version":1,"request":"dispatch-binding","kind":"axis","binding":"Super+wheel-up","ticks":2}}""",
      bindingModel(),
      x11Snapshot(),
    )

    check parsed.handled
    check parsed.bindingDispatch.ok
    check parsed.bindingDispatch.dispatched == 2
    check parsed.messages.len == 2
    check parsed.messages.allIt(it.kind == MsgKind.CmdFocusNext)

  test "binding dispatch rejects unsupported configured command":
    let parsed = xlibreWritableRequestFor(
      """{"triad":{"version":1,"request":"dispatch-binding","kind":"key","binding":"Super+z"}}""",
      bindingModel(),
      x11Snapshot(),
    )
    let reply = parseJson(parsed.reply)

    check parsed.handled
    check parsed.messages.len == 0
    check not reply["ok"].getBool()
    check reply["error"].getStr().contains("not supported by XLibre")

  test "read-only handler rejects xlibre close without writable callback":
    let reply = parseJson(
      handleTriadReadOnlyRequest(
        """{"triad":{"version":1,"request":"xlibre-close-window","id":42}}""",
        x11Snapshot(),
      ).reply
    )

    check not reply["ok"].getBool()
    check reply["error"].getStr().contains("read-only")

  test "executed reply reports successful close":
    let parsed = xlibreWritableRequestFor(
      """{"triad":{"version":1,"request":"xlibre-close-window","id":42}}""",
      x11Snapshot(),
    )
    let reply = parseJson(
      replyForExecutedXlibreWritableRequest(
        parsed,
        X11RequestRunResult(
          code: 0, dryRun: false, logs: @["applied close window=0x0000002a"]
        ),
      )
    )

    check reply["ok"].getBool()
    check reply["triad"]["type"].getStr() == "xlibre-close-window"
    check reply["triad"]["window"].getInt() == 42
    check reply["triad"]["applied"].getBool()

  test "executed reply reports successful focus":
    let parsed = xlibreWritableRequestFor(
      """{"triad":{"version":1,"request":"xlibre-focus-window","id":42}}""",
      x11Snapshot(),
    )
    let reply = parseJson(
      replyForExecutedXlibreWritableRequest(
        parsed,
        X11RequestRunResult(
          code: 0, dryRun: false, logs: @["applied focus window=0x0000002a"]
        ),
      )
    )

    check reply["ok"].getBool()
    check reply["triad"]["type"].getStr() == "xlibre-focus-window"
    check reply["triad"]["window"].getInt() == 42
    check reply["triad"]["applied"].getBool()

  test "executed reply reports successful workspace focus":
    let parsed = xlibreWritableRequestFor(
      """{"triad":{"version":1,"request":"xlibre-focus-workspace","workspace":2}}""",
      x11Snapshot(),
    )
    let reply = parseJson(
      replyForExecutedXlibreWritableRequest(
        parsed,
        X11RequestRunResult(code: 0, dryRun: false, logs: @["applied focus window=0"]),
      )
    )

    check reply["ok"].getBool()
    check reply["triad"]["type"].getStr() == "xlibre-focus-workspace"
    check reply["triad"]["workspace"].getInt() == 2
    check reply["triad"]["applied"].getBool()

  test "executed reply reports successful window workspace move":
    let parsed = xlibreWritableRequestFor(
      """{"triad":{"version":1,"request":"xlibre-move-window-to-workspace","id":42,"workspace":2}}""",
      x11Snapshot(),
    )
    let reply = parseJson(
      replyForExecutedXlibreWritableRequest(
        parsed,
        X11RequestRunResult(
          code: 0, dryRun: false, logs: @["applied focus window=0x0000002a"]
        ),
      )
    )

    check reply["ok"].getBool()
    check reply["triad"]["type"].getStr() == "xlibre-move-window-to-workspace"
    check reply["triad"]["window"].getInt() == 42
    check reply["triad"]["workspace"].getInt() == 2
    check reply["triad"]["follow"].getBool()
    check reply["triad"]["applied"].getBool()

  test "executed reply reports successful stop":
    let parsed = xlibreWritableRequestFor(
      """{"triad":{"version":1,"request":"xlibre-stop"}}""", x11Snapshot()
    )
    let reply = parseJson(
      replyForExecutedXlibreWritableRequest(
        parsed, X11RequestRunResult(code: 0, dryRun: false, logs: @["stop requested"])
      )
    )

    check reply["ok"].getBool()
    check reply["triad"]["type"].getStr() == "xlibre-stop"
    check reply["triad"]["applied"].getBool()

  test "executed reply reports successful binding dispatch":
    let parsed = xlibreWritableRequestFor(
      """{"triad":{"version":1,"request":"dispatch-binding","kind":"key","binding":"Super+h"}}""",
      bindingModel(),
      x11Snapshot(),
    )
    let reply = parseJson(
      replyForExecutedXlibreWritableRequest(
        parsed, X11RequestRunResult(code: 0, dryRun: false, logs: @["applied focus"])
      )
    )

    check reply["ok"].getBool()
    check reply["triad"]["type"].getStr() == "xlibre-binding-dispatch"
    check reply["triad"]["kind"].getStr() == "key"
    check reply["triad"]["binding"].getStr() == "Super+h"
    check reply["triad"]["command"].getStr() == "focus-workspace 2"
    check reply["triad"]["applied"].getBool()
