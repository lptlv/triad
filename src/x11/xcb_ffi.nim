{.compile: "probe_ffi.c".}
{.
  passC:
    gorge("pkg-config --cflags xcb xcb-randr xcb-ewmh xcb-icccm xcb-xinput xcb-xkb")
.}
{.
  passL: gorge("pkg-config --libs xcb xcb-randr xcb-ewmh xcb-icccm xcb-xinput xcb-xkb")
.}

import events, request_builder

type
  X11ProbeLogFn* = proc(userData: pointer, message: cstring) {.cdecl.}
  X11ProbeEventFn* = proc(userData: pointer, event: ptr X11ProbeEvent) {.cdecl.}
  X11ProbeTickFn* = proc(userData: pointer) {.cdecl.}
  X11RequestLogFn* = proc(userData: pointer, message: cstring) {.cdecl.}

  X11KeyGrab* {.bycopy.} = object
    keysym*: uint32
    modifiers*: uint32
    binding*: array[128, char]

  X11ButtonGrab* {.bycopy.} = object
    button*: uint32
    modifiers*: uint32
    binding*: array[128, char]

  X11AxisGrab* {.bycopy.} = object
    button*: uint32
    modifiers*: uint32
    binding*: array[128, char]

proc triadX11ProbeRun*(
  displayName: cstring,
  once: cint,
  logFn: X11ProbeLogFn,
  eventFn: X11ProbeEventFn,
  tickFn: X11ProbeTickFn,
  userData: pointer,
): cint {.importc: "triad_x11_probe_run".}

proc triadX11ExecuteRequests*(
  displayName: cstring,
  requests: ptr X11Request,
  count: cuint,
  dryRun: cint,
  logFn: X11RequestLogFn,
  userData: pointer,
): cint {.importc: "triad_x11_execute_requests".}

proc triadX11ExecuteRequestsOnActiveProbe*(
  requests: ptr X11Request, count: cuint, logFn: X11RequestLogFn, userData: pointer
): cint {.importc: "triad_x11_execute_requests_on_active_probe".}

proc triadX11StopActiveProbe*(): cint {.importc: "triad_x11_stop_active_probe".}

proc triadX11ConfigureActiveKeyGrabs*(
  grabs: ptr X11KeyGrab, count: cuint
): cint {.importc: "triad_x11_configure_active_key_grabs".}

proc triadX11ConfigureActiveButtonGrabs*(
  grabs: ptr X11ButtonGrab, count: cuint
): cint {.importc: "triad_x11_configure_active_button_grabs".}

proc triadX11ConfigureActiveAxisGrabs*(
  grabs: ptr X11AxisGrab, count: cuint
): cint {.importc: "triad_x11_configure_active_axis_grabs".}
