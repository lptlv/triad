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
          key: "h",
          modifiers: 68'u32,
          command: "move-window-left",
          mode: BindingMode.BindAlways,
        ),
        KeyBindingConfig(
          key: "l",
          modifiers: 72'u32,
          command: "move-column-right",
          mode: BindingMode.BindAlways,
        ),
        KeyBindingConfig(
          key: "j",
          modifiers: 68'u32,
          command: "swap-window-down",
          mode: BindingMode.BindAlways,
        ),
        KeyBindingConfig(
          key: "r",
          modifiers: 64'u32,
          command: "resize-width 0.1",
          mode: BindingMode.BindAlways,
        ),
        KeyBindingConfig(
          key: "t",
          modifiers: 64'u32,
          command: "resize-height -0.1",
          mode: BindingMode.BindAlways,
        ),
        KeyBindingConfig(
          key: "u",
          modifiers: 64'u32,
          command: "set-column-width 0.5",
          mode: BindingMode.BindAlways,
        ),
        KeyBindingConfig(
          key: "p",
          modifiers: 64'u32,
          command: "switch-proportion-preset -1",
          mode: BindingMode.BindAlways,
        ),
        KeyBindingConfig(
          key: "o",
          modifiers: 64'u32,
          command: "master-count 2",
          mode: BindingMode.BindAlways,
        ),
        KeyBindingConfig(
          key: "d",
          modifiers: 64'u32,
          command: "adjust-master-count 1",
          mode: BindingMode.BindAlways,
        ),
        KeyBindingConfig(
          key: "i",
          modifiers: 64'u32,
          command: "master-ratio 0.6",
          mode: BindingMode.BindAlways,
        ),
        KeyBindingConfig(
          key: "a",
          modifiers: 64'u32,
          command: "adjust-master-ratio -0.05",
          mode: BindingMode.BindAlways,
        ),
        KeyBindingConfig(
          key: "g",
          modifiers: 64'u32,
          command: "toggle-gaps",
          mode: BindingMode.BindAlways,
        ),
        KeyBindingConfig(
          key: "g",
          modifiers: 65'u32,
          command: "adjust-gaps 2",
          mode: BindingMode.BindAlways,
        ),
        KeyBindingConfig(
          key: "w",
          modifiers: 64'u32,
          command: "focus-tag 2",
          mode: BindingMode.BindAlways,
        ),
        KeyBindingConfig(
          key: "e",
          modifiers: 64'u32,
          command: "focus-tag-right",
          mode: BindingMode.BindAlways,
        ),
        KeyBindingConfig(
          key: "e",
          modifiers: 65'u32,
          command: "focus-occupied-tag-right",
          mode: BindingMode.BindAlways,
        ),
        KeyBindingConfig(
          key: "y",
          modifiers: 68'u32,
          command: "move-to-tag-left",
          mode: BindingMode.BindAlways,
        ),
        KeyBindingConfig(
          key: "y",
          modifiers: 65'u32,
          command: "move-to-tag 2",
          mode: BindingMode.BindAlways,
        ),
        KeyBindingConfig(
          key: "y",
          modifiers: 72'u32,
          command: "swap-to-tag 2",
          mode: BindingMode.BindAlways,
        ),
        KeyBindingConfig(
          key: "t",
          modifiers: 68'u32,
          command: "toggle-floating",
          mode: BindingMode.BindAlways,
        ),
        KeyBindingConfig(
          key: "z", modifiers: 65'u32, command: "zoom", mode: BindingMode.BindAlways
        ),
        KeyBindingConfig(
          key: "z",
          modifiers: 72'u32,
          command: "consume-window",
          mode: BindingMode.BindAlways,
        ),
        KeyBindingConfig(
          key: "z",
          modifiers: 68'u32,
          command: "expel-window",
          mode: BindingMode.BindAlways,
        ),
        KeyBindingConfig(
          key: "f",
          modifiers: 64'u32,
          command: "maximize-window-to-edges",
          mode: BindingMode.BindAlways,
        ),
        KeyBindingConfig(
          key: "f",
          modifiers: 65'u32,
          command: "fullscreen-window",
          mode: BindingMode.BindAlways,
        ),
        KeyBindingConfig(
          key: "b", modifiers: 65'u32, command: "minimize", mode: BindingMode.BindAlways
        ),
        KeyBindingConfig(
          key: "c", modifiers: 64'u32, command: "scroller", mode: BindingMode.BindAlways
        ),
        KeyBindingConfig(
          key: "v",
          modifiers: 64'u32,
          command: "vertical-scroller",
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

  test "binding dispatch resolves move-window key binding":
    let parsed = xlibreWritableRequestFor(
      """{"triad":{"version":1,"request":"dispatch-binding","kind":"key","binding":"Super+Ctrl+h"}}""",
      bindingModel(),
      x11Snapshot(),
    )

    check parsed.handled
    check parsed.bindingDispatch.ok
    check parsed.bindingDispatch.command == "move-window-left"
    check parsed.messages.len == 1
    check parsed.messages[0].kind == MsgKind.CmdMoveWindowLeft

  test "binding dispatch resolves move-column key binding":
    let parsed = xlibreWritableRequestFor(
      """{"triad":{"version":1,"request":"dispatch-binding","kind":"key","binding":"Super+Alt+l"}}""",
      bindingModel(),
      x11Snapshot(),
    )

    check parsed.handled
    check parsed.bindingDispatch.ok
    check parsed.bindingDispatch.command == "move-column-right"
    check parsed.messages.len == 1
    check parsed.messages[0].kind == MsgKind.CmdMoveColumnRight

  test "binding dispatch resolves swap-window key binding":
    let parsed = xlibreWritableRequestFor(
      """{"triad":{"version":1,"request":"dispatch-binding","kind":"key","binding":"Super+Ctrl+j"}}""",
      bindingModel(),
      x11Snapshot(),
    )

    check parsed.handled
    check parsed.bindingDispatch.ok
    check parsed.bindingDispatch.command == "swap-window-down"
    check parsed.messages.len == 1
    check parsed.messages[0].kind == MsgKind.CmdSwapWindowDown

  test "binding dispatch resolves resize-width key binding":
    let parsed = xlibreWritableRequestFor(
      """{"triad":{"version":1,"request":"dispatch-binding","kind":"key","binding":"Super+r"}}""",
      bindingModel(),
      x11Snapshot(),
    )

    check parsed.handled
    check parsed.bindingDispatch.ok
    check parsed.bindingDispatch.command == "resize-width 0.1"
    check parsed.messages.len == 1
    check parsed.messages[0].kind == MsgKind.CmdResizeWidth
    check parsed.messages[0].deltaW == 0.1'f32

  test "binding dispatch resolves resize-height key binding":
    let parsed = xlibreWritableRequestFor(
      """{"triad":{"version":1,"request":"dispatch-binding","kind":"key","binding":"Super+t"}}""",
      bindingModel(),
      x11Snapshot(),
    )

    check parsed.handled
    check parsed.bindingDispatch.ok
    check parsed.bindingDispatch.command == "resize-height -0.1"
    check parsed.messages.len == 1
    check parsed.messages[0].kind == MsgKind.CmdResizeHeight
    check parsed.messages[0].deltaH == -0.1'f32

  test "binding dispatch resolves set-column-width key binding":
    let parsed = xlibreWritableRequestFor(
      """{"triad":{"version":1,"request":"dispatch-binding","kind":"key","binding":"Super+u"}}""",
      bindingModel(),
      x11Snapshot(),
    )

    check parsed.handled
    check parsed.bindingDispatch.ok
    check parsed.bindingDispatch.command == "set-column-width 0.5"
    check parsed.messages.len == 1
    check parsed.messages[0].kind == MsgKind.CmdSetColumnWidth
    check parsed.messages[0].targetWidth == 0.5'f32

  test "binding dispatch resolves switch-proportion-preset key binding":
    let parsed = xlibreWritableRequestFor(
      """{"triad":{"version":1,"request":"dispatch-binding","kind":"key","binding":"Super+p"}}""",
      bindingModel(),
      x11Snapshot(),
    )

    check parsed.handled
    check parsed.bindingDispatch.ok
    check parsed.bindingDispatch.command == "switch-proportion-preset -1"
    check parsed.messages.len == 1
    check parsed.messages[0].kind == MsgKind.CmdSwitchProportionPreset
    check parsed.messages[0].proportionPresetDelta == -1

  test "binding dispatch resolves master-count key binding":
    let parsed = xlibreWritableRequestFor(
      """{"triad":{"version":1,"request":"dispatch-binding","kind":"key","binding":"Super+o"}}""",
      bindingModel(),
      x11Snapshot(),
    )

    check parsed.handled
    check parsed.bindingDispatch.ok
    check parsed.bindingDispatch.command == "master-count 2"
    check parsed.messages.len == 1
    check parsed.messages[0].kind == MsgKind.CmdSetMasterCount
    check parsed.messages[0].count == 2

  test "binding dispatch resolves adjust-master-count key binding":
    let parsed = xlibreWritableRequestFor(
      """{"triad":{"version":1,"request":"dispatch-binding","kind":"key","binding":"Super+d"}}""",
      bindingModel(),
      x11Snapshot(),
    )

    check parsed.handled
    check parsed.bindingDispatch.ok
    check parsed.bindingDispatch.command == "adjust-master-count 1"
    check parsed.messages.len == 1
    check parsed.messages[0].kind == MsgKind.CmdAdjustMasterCount
    check parsed.messages[0].deltaMC == 1

  test "binding dispatch resolves master-ratio key binding":
    let parsed = xlibreWritableRequestFor(
      """{"triad":{"version":1,"request":"dispatch-binding","kind":"key","binding":"Super+i"}}""",
      bindingModel(),
      x11Snapshot(),
    )

    check parsed.handled
    check parsed.bindingDispatch.ok
    check parsed.bindingDispatch.command == "master-ratio 0.6"
    check parsed.messages.len == 1
    check parsed.messages[0].kind == MsgKind.CmdSetMasterRatio
    check parsed.messages[0].ratio == 0.6'f32

  test "binding dispatch resolves adjust-master-ratio key binding":
    let parsed = xlibreWritableRequestFor(
      """{"triad":{"version":1,"request":"dispatch-binding","kind":"key","binding":"Super+a"}}""",
      bindingModel(),
      x11Snapshot(),
    )

    check parsed.handled
    check parsed.bindingDispatch.ok
    check parsed.bindingDispatch.command == "adjust-master-ratio -0.05"
    check parsed.messages.len == 1
    check parsed.messages[0].kind == MsgKind.CmdAdjustMasterRatio
    check parsed.messages[0].deltaMR == -0.05'f32

  test "binding dispatch resolves toggle-gaps key binding":
    let parsed = xlibreWritableRequestFor(
      """{"triad":{"version":1,"request":"dispatch-binding","kind":"key","binding":"Super+g"}}""",
      bindingModel(),
      x11Snapshot(),
    )

    check parsed.handled
    check parsed.bindingDispatch.ok
    check parsed.bindingDispatch.command == "toggle-gaps"
    check parsed.messages.len == 1
    check parsed.messages[0].kind == MsgKind.CmdToggleGaps

  test "binding dispatch resolves adjust-gaps key binding":
    let parsed = xlibreWritableRequestFor(
      """{"triad":{"version":1,"request":"dispatch-binding","kind":"key","binding":"Super+Shift+g"}}""",
      bindingModel(),
      x11Snapshot(),
    )

    check parsed.handled
    check parsed.bindingDispatch.ok
    check parsed.bindingDispatch.command == "adjust-gaps 2"
    check parsed.messages.len == 1
    check parsed.messages[0].kind == MsgKind.CmdAdjustGaps
    check parsed.messages[0].deltaG == 2

  test "binding dispatch resolves focus-tag key binding":
    let parsed = xlibreWritableRequestFor(
      """{"triad":{"version":1,"request":"dispatch-binding","kind":"key","binding":"Super+w"}}""",
      bindingModel(),
      x11Snapshot(),
    )

    check parsed.handled
    check parsed.bindingDispatch.ok
    check parsed.bindingDispatch.command == "focus-tag 2"
    check parsed.messages.len == 1
    check parsed.messages[0].kind == MsgKind.CmdFocusTag
    check parsed.messages[0].focusTag == 2

  test "binding dispatch resolves focus-tag-right key binding":
    let parsed = xlibreWritableRequestFor(
      """{"triad":{"version":1,"request":"dispatch-binding","kind":"key","binding":"Super+e"}}""",
      bindingModel(),
      x11Snapshot(),
    )

    check parsed.handled
    check parsed.bindingDispatch.ok
    check parsed.bindingDispatch.command == "focus-tag-right"
    check parsed.messages.len == 1
    check parsed.messages[0].kind == MsgKind.CmdFocusTagRight

  test "binding dispatch resolves focus-occupied-tag key binding":
    let parsed = xlibreWritableRequestFor(
      """{"triad":{"version":1,"request":"dispatch-binding","kind":"key","binding":"Super+Shift+e"}}""",
      bindingModel(),
      x11Snapshot(),
    )

    check parsed.handled
    check parsed.bindingDispatch.ok
    check parsed.bindingDispatch.command == "focus-occupied-tag-right"
    check parsed.messages.len == 1
    check parsed.messages[0].kind == MsgKind.CmdFocusOccupiedTagRight

  test "binding dispatch resolves move-to-tag-left key binding":
    let parsed = xlibreWritableRequestFor(
      """{"triad":{"version":1,"request":"dispatch-binding","kind":"key","binding":"Super+Ctrl+y"}}""",
      bindingModel(),
      x11Snapshot(),
    )

    check parsed.handled
    check parsed.bindingDispatch.ok
    check parsed.bindingDispatch.command == "move-to-tag-left"
    check parsed.messages.len == 1
    check parsed.messages[0].kind == MsgKind.CmdMoveToTagLeft

  test "binding dispatch resolves move-to-tag key binding":
    let parsed = xlibreWritableRequestFor(
      """{"triad":{"version":1,"request":"dispatch-binding","kind":"key","binding":"Super+Shift+y"}}""",
      bindingModel(),
      x11Snapshot(),
    )

    check parsed.handled
    check parsed.bindingDispatch.ok
    check parsed.bindingDispatch.command == "move-to-tag 2"
    check parsed.messages.len == 1
    check parsed.messages[0].kind == MsgKind.CmdMoveToTag
    check parsed.messages[0].targetTag == 2

  test "binding dispatch resolves swap-to-tag key binding":
    let parsed = xlibreWritableRequestFor(
      """{"triad":{"version":1,"request":"dispatch-binding","kind":"key","binding":"Super+Alt+y"}}""",
      bindingModel(),
      x11Snapshot(),
    )

    check parsed.handled
    check parsed.bindingDispatch.ok
    check parsed.bindingDispatch.command == "swap-to-tag 2"
    check parsed.messages.len == 1
    check parsed.messages[0].kind == MsgKind.CmdSwapWindowToTag
    check parsed.messages[0].targetTagSwap == 2

  test "binding dispatch resolves toggle-floating key binding":
    let parsed = xlibreWritableRequestFor(
      """{"triad":{"version":1,"request":"dispatch-binding","kind":"key","binding":"Super+Ctrl+t"}}""",
      bindingModel(),
      x11Snapshot(),
    )

    check parsed.handled
    check parsed.bindingDispatch.ok
    check parsed.bindingDispatch.command == "toggle-floating"
    check parsed.messages.len == 1
    check parsed.messages[0].kind == MsgKind.CmdToggleFloating

  test "binding dispatch resolves zoom key binding":
    let parsed = xlibreWritableRequestFor(
      """{"triad":{"version":1,"request":"dispatch-binding","kind":"key","binding":"Super+Shift+z"}}""",
      bindingModel(),
      x11Snapshot(),
    )

    check parsed.handled
    check parsed.bindingDispatch.ok
    check parsed.bindingDispatch.command == "zoom"
    check parsed.messages.len == 1
    check parsed.messages[0].kind == MsgKind.CmdZoom

  test "binding dispatch resolves consume-window key binding":
    let parsed = xlibreWritableRequestFor(
      """{"triad":{"version":1,"request":"dispatch-binding","kind":"key","binding":"Super+Alt+z"}}""",
      bindingModel(),
      x11Snapshot(),
    )

    check parsed.handled
    check parsed.bindingDispatch.ok
    check parsed.bindingDispatch.command == "consume-window"
    check parsed.messages.len == 1
    check parsed.messages[0].kind == MsgKind.CmdConsumeWindow

  test "binding dispatch resolves expel-window key binding":
    let parsed = xlibreWritableRequestFor(
      """{"triad":{"version":1,"request":"dispatch-binding","kind":"key","binding":"Super+Ctrl+z"}}""",
      bindingModel(),
      x11Snapshot(),
    )

    check parsed.handled
    check parsed.bindingDispatch.ok
    check parsed.bindingDispatch.command == "expel-window"
    check parsed.messages.len == 1
    check parsed.messages[0].kind == MsgKind.CmdExpelWindow

  test "binding dispatch resolves maximize-to-edges key binding":
    let parsed = xlibreWritableRequestFor(
      """{"triad":{"version":1,"request":"dispatch-binding","kind":"key","binding":"Super+f"}}""",
      bindingModel(),
      x11Snapshot(),
    )

    check parsed.handled
    check parsed.bindingDispatch.ok
    check parsed.bindingDispatch.command == "maximize-window-to-edges"
    check parsed.messages.len == 1
    check parsed.messages[0].kind == MsgKind.CmdToggleMaximized

  test "binding dispatch resolves fullscreen key binding":
    let parsed = xlibreWritableRequestFor(
      """{"triad":{"version":1,"request":"dispatch-binding","kind":"key","binding":"Super+Shift+f"}}""",
      bindingModel(),
      x11Snapshot(),
    )

    check parsed.handled
    check parsed.bindingDispatch.ok
    check parsed.bindingDispatch.command == "fullscreen-window"
    check parsed.messages.len == 1
    check parsed.messages[0].kind == MsgKind.CmdToggleFullscreen

  test "binding dispatch resolves minimize key binding":
    let parsed = xlibreWritableRequestFor(
      """{"triad":{"version":1,"request":"dispatch-binding","kind":"key","binding":"Super+Shift+b"}}""",
      bindingModel(),
      x11Snapshot(),
    )

    check parsed.handled
    check parsed.bindingDispatch.ok
    check parsed.bindingDispatch.command == "minimize"
    check parsed.messages.len == 1
    check parsed.messages[0].kind == MsgKind.CmdMinimize

  test "binding dispatch resolves core scroller layout key binding":
    let parsed = xlibreWritableRequestFor(
      """{"triad":{"version":1,"request":"dispatch-binding","kind":"key","binding":"Super+c"}}""",
      bindingModel(),
      x11Snapshot(),
    )

    check parsed.handled
    check parsed.bindingDispatch.ok
    check parsed.bindingDispatch.command == "scroller"
    check parsed.messages.len == 1
    check parsed.messages[0].kind == MsgKind.CmdSetLayout
    check parsed.messages[0].newLayout == LayoutMode.Scroller

  test "binding dispatch resolves core vertical scroller layout key binding":
    let parsed = xlibreWritableRequestFor(
      """{"triad":{"version":1,"request":"dispatch-binding","kind":"key","binding":"Super+v"}}""",
      bindingModel(),
      x11Snapshot(),
    )

    check parsed.handled
    check parsed.bindingDispatch.ok
    check parsed.bindingDispatch.command == "vertical-scroller"
    check parsed.messages.len == 1
    check parsed.messages[0].kind == MsgKind.CmdSetLayout
    check parsed.messages[0].newLayout == LayoutMode.VerticalScroller

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
