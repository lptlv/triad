import std/[os, strutils]

import x11/probe

const Usage = """
usage: triad_xlibre [--display DISPLAY] [--mode observe|admit|manage] [--once] [--help]

Experimental XLibre/X11 event probe and manager loop.

Options:
  --display DISPLAY  Connect to DISPLAY instead of $DISPLAY.
  --mode MODE        observe logs events, admit updates a dry-run model, manage applies XCB requests.
  --once             Claim WM ownership, dump initial state, then exit.
  --help             Show this help.
"""

proc fail(message: string) =
  stderr.writeLine("triad_xlibre: " & message)
  quit 1

proc parseMode(value: string): X11ProbeMode =
  case value
  of "observe":
    X11ProbeMode.Observe
  of "admit":
    X11ProbeMode.Admit
  of "manage":
    X11ProbeMode.Manage
  else:
    fail("unknown mode: " & value)
    X11ProbeMode.Observe

when isMainModule:
  var displayName = ""
  var once = false
  var mode = X11ProbeMode.Observe
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
    elif arg == "--mode":
      inc i
      if i >= args.len:
        fail("--mode requires a value")
      mode = parseMode(args[i])
    elif arg.startsWith("--display="):
      displayName = arg.substr("--display=".len)
      if displayName.len == 0:
        fail("--display requires a value")
    elif arg.startsWith("--mode="):
      mode = parseMode(arg.substr("--mode=".len))
    else:
      fail("unknown argument: " & arg)
    inc i

  if once and mode == X11ProbeMode.Manage:
    fail("--once cannot be used with --mode manage")

  quit runX11Probe(displayName, once, mode)
