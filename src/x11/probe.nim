import atoms, xcb_ffi

proc probeLogCallback(userData: pointer, message: cstring) {.cdecl.} =
  discard userData
  if message != nil:
    stdout.writeLine($message)
    stdout.flushFile()

proc runX11Probe*(displayName = "", once = false): int =
  let display =
    if displayName.len == 0:
      nil
    else:
      displayName.cstring
  discard RequiredX11Atoms
  int(triadX11ProbeRun(display, cint(ord(once)), probeLogCallback, nil))
