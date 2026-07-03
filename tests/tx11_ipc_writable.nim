import std/[json, options, strutils, unittest]

import ../src/core/msg
import ../src/ipc/triad_readonly
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
