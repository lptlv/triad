type
  X11AtomName* {.pure.} = enum
    XaWmProtocols
    XaWmDeleteWindow
    XaWmTransientFor
    XaWmNormalHints
    XaWmClass
    XaWmName
    XaNetWmName
    XaNetWmPid
    XaNetWmState
    XaNetWmWindowType
    XaNetActiveWindow
    XaNetCloseWindow
    XaNetSupported
    XaNetSupportingWmCheck
    XaUtf8String
    XaCardinal
    XaWindow

const RequiredX11Atoms* = [
  "WM_PROTOCOLS", "WM_DELETE_WINDOW", "WM_TRANSIENT_FOR", "WM_NORMAL_HINTS", "WM_CLASS",
  "WM_NAME", "_NET_WM_NAME", "_NET_WM_PID", "_NET_WM_STATE", "_NET_WM_WINDOW_TYPE",
  "_NET_ACTIVE_WINDOW", "_NET_CLOSE_WINDOW", "_NET_SUPPORTED",
  "_NET_SUPPORTING_WM_CHECK", "UTF8_STRING", "CARDINAL", "WINDOW",
]
