{.compile: "probe_ffi.c".}
{.passC: gorge("pkg-config --cflags xcb xcb-randr xcb-ewmh xcb-icccm").}
{.passL: gorge("pkg-config --libs xcb xcb-randr xcb-ewmh xcb-icccm").}

import events

type
  X11ProbeLogFn* = proc(userData: pointer, message: cstring) {.cdecl.}
  X11ProbeEventFn* = proc(
    userData: pointer, event: ptr X11ProbeEvent
  ) {.cdecl.}

proc triadX11ProbeRun*(
    displayName: cstring,
    once: cint,
    logFn: X11ProbeLogFn,
    eventFn: X11ProbeEventFn,
    userData: pointer,
): cint {.importc: "triad_x11_probe_run".}
