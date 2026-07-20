import std/strutils
from std/posix import nil
import wayland/native/client
import wayland/native/common
import wayland/protocols/stable/viewporter/client as viewporter
import wayland/protocols/stable/xdgshell/client as xdg
import wayland/protocols/wayland/client as wl
import ../protocols/wlr_screencopy/client as screencopy

when defined(linux):
  const MemfdCloseOnExec = 0x0001.cuint

  proc memfd_create(
    name: cstring, flags: cuint
  ): cint {.importc, header: "<sys/mman.h>".}

type
  MirrorError* = object of CatchableError

  MirrorApp = ref object
    sourceName: string
    targetName: string
    display: ptr Display
    registry: ptr Registry
    compositor: ptr Compositor
    subcompositor: ptr Subcompositor
    shm: ptr Shm
    wmBase: ptr XdgWmBase
    viewporter: ptr WpViewporter
    captureManager: ptr ZwlrScreencopyManagerV1
    outputs: seq[OutputInfo]
    sourceOutput: ptr Output
    targetOutput: ptr Output
    parentSurface: ptr Surface
    childSurface: ptr Surface
    subsurface: ptr Subsurface
    parentViewport: ptr WpViewport
    childViewport: ptr WpViewport
    xdgSurface: ptr XdgSurface
    toplevel: ptr XdgToplevel
    backgroundBuffer: ptr Buffer
    backgroundAttached: bool
    configured: bool
    targetWidth: int32
    targetHeight: int32
    running: bool
    failed: bool
    currentFrame: ptr ZwlrScreencopyFrameV1
    captureFormat: uint32
    captureWidth: uint32
    captureHeight: uint32
    captureStride: uint32
    captureFlags: uint32
    currentSlot: BufferSlot
    waitingForBuffer: bool
    slots: seq[BufferSlot]

  OutputInfo = ref object
    app: MirrorApp
    globalName: uint32
    output: ptr Output
    name: string

  BufferSlot = ref object
    app: MirrorApp
    buffer: ptr Buffer
    format: uint32
    width: uint32
    height: uint32
    stride: uint32
    capturing: bool
    surfaceBusy: bool

proc fail(app: MirrorApp, message: string) =
  stderr.writeLine("triad_mirror: " & message)
  app.failed = true
  app.running = false

proc startCapture(app: MirrorApp)
proc supplyCaptureBuffer(app: MirrorApp)

proc onBufferRelease(data: pointer, buffer: ptr Buffer) {.nimcall.} =
  let slot = cast[BufferSlot](data)
  slot.surfaceBusy = false
  if slot.app.waitingForBuffer:
    slot.app.supplyCaptureBuffer()

var bufferListener = BufferListener(release: onBufferRelease)

proc createShmBuffer(
    app: MirrorApp, name: string, format, width, height, stride: uint32
): ptr Buffer =
  when defined(linux):
    if width == 0 or height == 0 or stride == 0:
      return nil
    let size64 = uint64(stride) * uint64(height)
    if size64 > uint64(high(int32)):
      return nil
    let size = int32(size64)
    let fd = memfd_create(name, MemfdCloseOnExec)
    if fd < 0:
      return nil
    try:
      if posix.ftruncate(fd, posix.Off(size)) != 0:
        return nil
      let pool = app.shm.createPool(fd, size)
      if pool == nil:
        return nil
      result = pool.createBuffer(0, int32(width), int32(height), int32(stride), format)
      pool.destroy()
    finally:
      discard posix.close(fd)
  else:
    discard app
    discard name
    discard format
    discard width
    discard height
    discard stride
    result = nil

proc createSlot(app: MirrorApp): BufferSlot =
  let buffer = app.createShmBuffer(
    "triad-mirror-frame", app.captureFormat, app.captureWidth, app.captureHeight,
    app.captureStride,
  )
  if buffer == nil:
    app.fail("unable to allocate a screencopy shared-memory buffer")
    return nil
  result = BufferSlot(
    app: app,
    buffer: buffer,
    format: app.captureFormat,
    width: app.captureWidth,
    height: app.captureHeight,
    stride: app.captureStride,
  )
  discard result.buffer.addListener(bufferListener.addr, cast[pointer](result))
  app.slots.add(result)

proc matchesCapture(slot: BufferSlot, app: MirrorApp): bool =
  slot.format == app.captureFormat and slot.width == app.captureWidth and
    slot.height == app.captureHeight and slot.stride == app.captureStride

proc supplyCaptureBuffer(app: MirrorApp) =
  if app.currentFrame == nil or app.failed:
    return
  var slot: BufferSlot
  for candidate in app.slots:
    if candidate.matchesCapture(app) and not candidate.capturing and
        not candidate.surfaceBusy:
      slot = candidate
      break
  if slot == nil:
    var matchingCount = 0
    for candidate in app.slots:
      if candidate.matchesCapture(app):
        inc matchingCount
    if matchingCount < 3:
      slot = app.createSlot()
    else:
      app.waitingForBuffer = true
      return
  if slot == nil:
    return
  app.waitingForBuffer = false
  app.currentSlot = slot
  slot.capturing = true
  app.currentFrame.copyWithDamage(slot.buffer)

proc updateSurfaceGeometry(app: MirrorApp) =
  if app.targetWidth <= 0 or app.targetHeight <= 0:
    return
  app.parentViewport.setDestination(app.targetWidth, app.targetHeight)
  app.xdgSurface.setWindowGeometry(0, 0, app.targetWidth, app.targetHeight)
  if not app.backgroundAttached:
    app.parentSurface.attach(app.backgroundBuffer, 0, 0)
    app.parentSurface.damageBuffer(0, 0, 1, 1)
    app.backgroundAttached = true
  app.parentSurface.commit()

proc present(app: MirrorApp, slot: BufferSlot) =
  if app.targetWidth <= 0 or app.targetHeight <= 0:
    app.fail("fullscreen target did not provide a usable size")
    return
  let sourceWidth = int64(slot.width)
  let sourceHeight = int64(slot.height)
  let targetWidth = int64(app.targetWidth)
  let targetHeight = int64(app.targetHeight)
  var width, height: int32
  if targetWidth * sourceHeight <= targetHeight * sourceWidth:
    width = app.targetWidth
    height = int32(max(1'i64, (sourceHeight * targetWidth) div sourceWidth))
  else:
    height = app.targetHeight
    width = int32(max(1'i64, (sourceWidth * targetHeight) div sourceHeight))
  app.childViewport.setDestination(width, height)
  app.subsurface.setPosition(
    (app.targetWidth - width) div 2, (app.targetHeight - height) div 2
  )
  let transform =
    if (app.captureFlags and uint32(flags_y_invert)) != 0:
      int32(OutputTransform.transform_flipped_180)
    else:
      int32(OutputTransform.transform_normal)
  app.childSurface.setBufferTransform(transform)
  app.childSurface.attach(slot.buffer, 0, 0)
  app.childSurface.damageBuffer(0, 0, int32(slot.width), int32(slot.height))
  app.childSurface.commit()
  app.parentSurface.commit()
  slot.surfaceBusy = true

proc finishFrame(app: MirrorApp) =
  if app.currentFrame != nil:
    app.currentFrame.destroy()
    app.currentFrame = nil

proc onFrameBuffer(
    data: pointer,
    frame: ptr ZwlrScreencopyFrameV1,
    format, width, height, stride: uint32,
) {.nimcall.} =
  let app = cast[MirrorApp](data)
  discard frame
  app.captureFormat = format
  app.captureWidth = width
  app.captureHeight = height
  app.captureStride = stride

proc onFrameFlags(
    data: pointer, frame: ptr ZwlrScreencopyFrameV1, flags: uint32
) {.nimcall.} =
  let app = cast[MirrorApp](data)
  discard frame
  app.captureFlags = flags

proc onFrameReady(
    data: pointer, frame: ptr ZwlrScreencopyFrameV1, tvSecHi, tvSecLo, tvNsec: uint32
) {.nimcall.} =
  let app = cast[MirrorApp](data)
  discard frame
  discard tvSecHi
  discard tvSecLo
  discard tvNsec
  let slot = app.currentSlot
  if slot == nil:
    app.fail("screencopy completed without a destination buffer")
    return
  slot.capturing = false
  app.currentSlot = nil
  app.finishFrame()
  app.present(slot)
  if app.running:
    app.startCapture()

proc onFrameFailed(data: pointer, frame: ptr ZwlrScreencopyFrameV1) {.nimcall.} =
  let app = cast[MirrorApp](data)
  discard frame
  if app.currentSlot != nil:
    app.currentSlot.capturing = false
    app.currentSlot = nil
  app.finishFrame()
  app.fail("River failed to capture the source output")

proc onFrameDamage(
    data: pointer, frame: ptr ZwlrScreencopyFrameV1, x, y, width, height: uint32
) {.nimcall.} =
  discard data
  discard frame
  discard x
  discard y
  discard width
  discard height

proc onFrameLinuxDmabuf(
    data: pointer, frame: ptr ZwlrScreencopyFrameV1, format, width, height: uint32
) {.nimcall.} =
  discard data
  discard frame
  discard format
  discard width
  discard height

proc onFrameBufferDone(data: pointer, frame: ptr ZwlrScreencopyFrameV1) {.nimcall.} =
  let app = cast[MirrorApp](data)
  discard frame
  if app.captureWidth == 0 or app.captureHeight == 0 or app.captureStride == 0:
    app.fail("River did not advertise a usable shared-memory capture format")
    return
  app.supplyCaptureBuffer()

var frameListener = ZwlrScreencopyFrameV1Listener(
  buffer: onFrameBuffer,
  flags: onFrameFlags,
  ready: onFrameReady,
  failed: onFrameFailed,
  damage: onFrameDamage,
  linuxDmabuf: onFrameLinuxDmabuf,
  bufferDone: onFrameBufferDone,
)

proc startCapture(app: MirrorApp) =
  if not app.configured or app.currentFrame != nil or not app.running:
    return
  app.captureFormat = 0
  app.captureWidth = 0
  app.captureHeight = 0
  app.captureStride = 0
  app.captureFlags = 0
  app.currentFrame = app.captureManager.captureOutput(0, app.sourceOutput)
  if app.currentFrame == nil:
    app.fail("unable to create a screencopy frame")
    return
  discard app.currentFrame.addListener(frameListener.addr, cast[pointer](app))

proc onWmPing(data: pointer, wmBase: ptr XdgWmBase, serial: uint32) {.nimcall.} =
  discard data
  wmBase.pong(serial)

var wmBaseListener = XdgWmBaseListener(ping: onWmPing)

proc onXdgSurfaceConfigure(
    data: pointer, surface: ptr XdgSurface, serial: uint32
) {.nimcall.} =
  let app = cast[MirrorApp](data)
  surface.ackConfigure(serial)
  app.configured = true
  app.updateSurfaceGeometry()
  app.startCapture()

var xdgSurfaceListener = XdgSurfaceListener(configure: onXdgSurfaceConfigure)

proc onToplevelConfigure(
    data: pointer, toplevel: ptr XdgToplevel, width, height: int32, states: ptr Array
) {.nimcall.} =
  let app = cast[MirrorApp](data)
  discard toplevel
  discard states
  if width > 0 and height > 0:
    app.targetWidth = width
    app.targetHeight = height

proc onToplevelClose(data: pointer, toplevel: ptr XdgToplevel) {.nimcall.} =
  let app = cast[MirrorApp](data)
  discard toplevel
  app.running = false

proc onToplevelConfigureBounds(
    data: pointer, toplevel: ptr XdgToplevel, width, height: int32
) {.nimcall.} =
  discard data
  discard toplevel
  discard width
  discard height

proc onToplevelWmCapabilities(
    data: pointer, toplevel: ptr XdgToplevel, capabilities: ptr Array
) {.nimcall.} =
  discard data
  discard toplevel
  discard capabilities

var toplevelListener = XdgToplevelListener(
  configure: onToplevelConfigure,
  close: onToplevelClose,
  configureBounds: onToplevelConfigureBounds,
  wmCapabilities: onToplevelWmCapabilities,
)

proc onOutputGeometry(
    data: pointer,
    output: ptr Output,
    x, y, physicalWidth, physicalHeight, subpixel: int32,
    make, model: cstring,
    transform: int32,
) {.nimcall.} =
  discard data
  discard output
  discard x
  discard y
  discard physicalWidth
  discard physicalHeight
  discard subpixel
  discard make
  discard model
  discard transform

proc onOutputMode(
    data: pointer, output: ptr Output, flags: uint32, width, height, refresh: int32
) {.nimcall.} =
  discard data
  discard output
  discard flags
  discard width
  discard height
  discard refresh

proc onOutputDone(data: pointer, output: ptr Output) {.nimcall.} =
  discard data
  discard output

proc onOutputScale(data: pointer, output: ptr Output, factor: int32) {.nimcall.} =
  discard data
  discard output
  discard factor

proc onOutputName(data: pointer, output: ptr Output, name: cstring) {.nimcall.} =
  let info = cast[OutputInfo](data)
  discard output
  info.name = $name

proc onOutputDescription(
    data: pointer, output: ptr Output, description: cstring
) {.nimcall.} =
  discard data
  discard output
  discard description

var outputListener = OutputListener(
  geometry: onOutputGeometry,
  mode: onOutputMode,
  done: onOutputDone,
  scale: onOutputScale,
  name: onOutputName,
  description: onOutputDescription,
)

proc bindGlobal(
    data: pointer,
    registry: ptr Registry,
    name: uint32,
    `interface`: cstring,
    version: uint32,
) {.nimcall.} =
  let app = cast[MirrorApp](data)
  let interfaceName = $`interface`
  case interfaceName
  of "wl_compositor":
    app.compositor = cast[ptr Compositor](registry.bind(
      name, wl_compositor_interface.addr, min(version, 4'u32)
    ))
  of "wl_subcompositor":
    app.subcompositor =
      cast[ptr Subcompositor](registry.bind(name, wl_subcompositor_interface.addr, 1))
  of "wl_shm":
    app.shm = cast[ptr Shm](registry.bind(name, wl_shm_interface.addr, 1))
  of "xdg_wm_base":
    app.wmBase = cast[ptr XdgWmBase](registry.bind(name, xdg_wm_base_interface.addr, 1))
  of "wp_viewporter":
    app.viewporter =
      cast[ptr WpViewporter](registry.bind(name, wp_viewporter_interface.addr, 1))
  of "zwlr_screencopy_manager_v1":
    if version >= 3:
      app.captureManager = cast[ptr ZwlrScreencopyManagerV1](registry.bind(
        name, zwlr_screencopy_manager_v1_interface.addr, 3
      ))
  of "wl_output":
    if version >= 4:
      let output = cast[ptr Output](registry.bind(
        name, wl_output_interface.addr, min(version, 4'u32)
      ))
      let info = OutputInfo(app: app, globalName: name, output: output)
      app.outputs.add(info)
      discard output.addListener(outputListener.addr, cast[pointer](info))
  else:
    discard

proc removeGlobal(data: pointer, registry: ptr Registry, name: uint32) {.nimcall.} =
  let app = cast[MirrorApp](data)
  discard registry
  for output in app.outputs:
    if output.globalName == name and
        (output.output == app.sourceOutput or output.output == app.targetOutput):
      app.fail("a mirrored output was disconnected")
      return

var registryListener = RegistryListener(global: bindGlobal, globalRemove: removeGlobal)

proc requireGlobals(app: MirrorApp) =
  if app.compositor == nil:
    raise newException(MirrorError, "wl_compositor is unavailable")
  if app.subcompositor == nil:
    raise newException(MirrorError, "wl_subcompositor is unavailable")
  if app.shm == nil:
    raise newException(MirrorError, "wl_shm is unavailable")
  if app.wmBase == nil:
    raise newException(MirrorError, "xdg_wm_base is unavailable")
  if app.viewporter == nil:
    raise newException(MirrorError, "wp_viewporter is unavailable")
  if app.captureManager == nil:
    raise
      newException(MirrorError, "zwlr_screencopy_manager_v1 version 3 is unavailable")

proc resolveOutputs(app: MirrorApp) =
  for info in app.outputs:
    if info.name == app.sourceName:
      app.sourceOutput = info.output
    if info.name == app.targetName:
      app.targetOutput = info.output
  if app.sourceOutput == nil:
    raise newException(MirrorError, "source output not found: " & app.sourceName)
  if app.targetOutput == nil:
    raise newException(MirrorError, "target output not found: " & app.targetName)
  if app.sourceOutput == app.targetOutput:
    raise newException(MirrorError, "source and target outputs must differ")

proc createWindow(app: MirrorApp) =
  discard app.wmBase.addListener(wmBaseListener.addr, cast[pointer](app))
  app.parentSurface = app.compositor.createSurface()
  app.childSurface = app.compositor.createSurface()
  app.xdgSurface = app.wmBase.getXdgSurface(app.parentSurface)
  discard app.xdgSurface.addListener(xdgSurfaceListener.addr, cast[pointer](app))
  app.toplevel = app.xdgSurface.getToplevel()
  discard app.toplevel.addListener(toplevelListener.addr, cast[pointer](app))
  app.toplevel.setTitle("Triad screen mirror")
  app.toplevel.setAppId("triad-mirror")
  app.toplevel.setFullscreen(app.targetOutput)
  app.subsurface = app.subcompositor.getSubsurface(app.childSurface, app.parentSurface)
  app.subsurface.setDesync()
  app.parentViewport = app.viewporter.getViewport(app.parentSurface)
  app.childViewport = app.viewporter.getViewport(app.childSurface)
  app.backgroundBuffer = app.createShmBuffer(
    "triad-mirror-background", uint32(ShmFormat.format_xrgb8888), 1, 1, 4
  )
  if app.backgroundBuffer == nil:
    raise newException(MirrorError, "unable to allocate the mirror background")
  app.parentSurface.commit()

proc runMirror*(sourceName, targetName: string): int =
  if sourceName.strip().len == 0 or targetName.strip().len == 0:
    stderr.writeLine("triad_mirror: source and target output names are required")
    return 2
  let app = MirrorApp(
    sourceName: sourceName.strip(), targetName: targetName.strip(), running: true
  )
  try:
    app.display = connectDisplay(nil)
    if app.display == nil:
      raise newException(MirrorError, "unable to connect to the Wayland display")
    app.registry = app.display.getRegistry()
    discard app.registry.addListener(registryListener.addr, cast[pointer](app))
    if app.display.roundtrip() < 0 or app.display.roundtrip() < 0:
      raise newException(MirrorError, "Wayland registry discovery failed")
    app.requireGlobals()
    app.resolveOutputs()
    app.createWindow()
    while app.running and app.display.dispatch() >= 0:
      discard
    if app.failed:
      return 1
    0
  except CatchableError as error:
    stderr.writeLine("triad_mirror: " & error.msg)
    1
  finally:
    if app.display != nil:
      app.display.disconnect()
