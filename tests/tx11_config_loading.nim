import std/[os, unittest]

import ../src/state/engine
import ../src/x11/probe

suite "X11 config loading":
  test "loads XLibre model from explicit Triad config":
    let dir = getTempDir() / ("triad-x11-config-" & $getCurrentProcessId())
    createDir(dir)
    let path = dir / "config.kdl"
    writeFile(
      path,
      """
layout {
  gaps 24
}

workspaces {
  default-count 4
}
""",
    )

    let loaded = loadX11Model(path)

    check loaded.ok
    check loaded.path == path.absolutePath().normalizedPath()
    check loaded.error.len == 0
    check loaded.model.shellSnapshot().workspaces.len == 4

    removeFile(path)
    removeDir(dir)

  test "rejects invalid XLibre config explicitly":
    let dir = getTempDir() / ("triad-x11-bad-config-" & $getCurrentProcessId())
    createDir(dir)
    let path = dir / "config.kdl"
    writeFile(path, "bindngs {}\n")

    let loaded = loadX11Model(path)

    check not loaded.ok
    check loaded.path == path.absolutePath().normalizedPath()
    check loaded.error.len > 0

    removeFile(path)
    removeDir(dir)
