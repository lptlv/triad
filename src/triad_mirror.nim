import std/os
import mirror/app

proc usage() =
  stderr.writeLine("usage: triad_mirror SOURCE_OUTPUT TARGET_OUTPUT")

when isMainModule:
  let args = commandLineParams()
  if args.len != 2:
    usage()
    quit 2
  quit runMirror(args[0], args[1])
