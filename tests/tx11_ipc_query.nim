import std/[asyncdispatch, json, os]

import ../src/ipc/socket

proc usage() =
  stderr.writeLine("usage: tx11_ipc_query SOCKET REQUEST")
  quit 2

when isMainModule:
  let args = commandLineParams()
  if args.len != 2:
    usage()

  let request =
    %*{"triad": {"version": 1, "request": args[1]}}
  try:
    let reply = waitFor sendIpcRequest(args[0], $request, timeoutMs = 2000)
    stdout.writeLine(reply)
  except CatchableError as e:
    stderr.writeLine("tx11_ipc_query: " & e.msg)
    quit 1
