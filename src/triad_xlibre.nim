import std/[os, strutils]

import x11/probe

const Usage = """
usage: triad_xlibre [--display DISPLAY] [--once] [--help]

Experimental XLibre/X11 event probe. Typed events are mapped to dry-run Triad
messages and logged without applying them to the model.

Options:
  --display DISPLAY  Connect to DISPLAY instead of $DISPLAY.
  --once             Claim WM ownership, dump initial state, then exit.
  --help             Show this help.
"""

proc fail(message: string) =
  stderr.writeLine("triad_xlibre: " & message)
  quit 1

when isMainModule:
  var displayName = ""
  var once = false
  let args = commandLineParams()
  var i = 0
  while i < args.len:
    let arg = args[i]
    if arg == "--help" or arg == "-h":
      stdout.write(Usage)
      quit 0
    elif arg == "--once":
      once = true
    elif arg == "--display":
      inc i
      if i >= args.len:
        fail("--display requires a value")
      displayName = args[i]
    elif arg.startsWith("--display="):
      displayName = arg.substr("--display=".len)
      if displayName.len == 0:
        fail("--display requires a value")
    else:
      fail("unknown argument: " & arg)
    inc i

  quit runX11Probe(displayName, once)
