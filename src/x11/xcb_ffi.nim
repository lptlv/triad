{.compile: "probe_ffi.c".}
{.passC: gorge("pkg-config --cflags xcb xcb-randr xcb-ewmh xcb-icccm").}
{.passL: gorge("pkg-config --libs xcb xcb-randr xcb-ewmh xcb-icccm").}

type
  X11ProbeLogFn* = proc(userData: pointer, message: cstring) {.cdecl.}

proc triadX11ProbeRun*(
    displayName: cstring, once: cint, logFn: X11ProbeLogFn, userData: pointer
): cint {.importc: "triad_x11_probe_run".}
