import std/[json, options, strutils, unittest]

import ../src/ipc/triad_readonly
import ../src/types/[runtime_values, shell_snapshot]

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

suite "X11 read-only native IPC":
  test "serves snapshot requests":
    let reply = parseJson(
      handleTriadReadOnlyRequest(
        """{"triad":{"version":1,"request":"windows"}}""", x11Snapshot()
      ).reply
    )

    check reply["ok"].getBool()
    check reply["triad"]["type"].getStr() == "windows"
    check reply["triad"]["windows"][0]["id"].getInt() == 0x2a

  test "rejects commands and event streams":
    let action = parseJson(
      handleTriadReadOnlyRequest(
        """{"triad":{"version":1,"request":"action","action":"focus-view"}}""",
        x11Snapshot(),
      ).reply
    )
    let stream = parseJson(
      handleTriadReadOnlyRequest(
        """{"triad":{"version":1,"request":"event-stream","events":["state"]}}""",
        x11Snapshot(),
      ).reply
    )

    check not action["ok"].getBool()
    check action["error"].getStr().contains("read-only")
    check not stream["ok"].getBool()
    check stream["error"].getStr().contains("read-only")

  test "serves runtime status when provided":
    let reply = parseJson(
      handleTriadReadOnlyRequest(
        """{"triad":{"version":1,"request":"runtime-status"}}""",
        x11Snapshot(),
        %*{
          "backend": "xlibre",
          "mode": "manage",
          "socket_path": "/tmp/triad-xlibre.sock",
          "read_only": true,
          "writable_ipc": true,
          "binding_dispatch_ipc": true,
          "general_command_ipc": false,
          "window_count": 1,
          "output_count": 1,
        },
      ).reply
    )

    check reply["ok"].getBool()
    check reply["triad"]["type"].getStr() == "runtime-status"
    check reply["triad"]["status"]["backend"].getStr() == "xlibre"
    check reply["triad"]["status"]["writable_ipc"].getBool()
    check reply["triad"]["status"]["binding_dispatch_ipc"].getBool()
    check not reply["triad"]["status"]["general_command_ipc"].getBool()

  test "runtime status reports unavailable without provider":
    let reply = parseJson(
      handleTriadReadOnlyRequest(
        """{"triad":{"version":1,"request":"runtime-status"}}""", x11Snapshot()
      ).reply
    )

    check not reply["ok"].getBool()
    check reply["error"].getStr().contains("runtime status unavailable")
