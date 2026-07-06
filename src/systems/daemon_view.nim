import std/options
from ../core/layout_selection_codec import layoutIdString
from ../core/native_layout_codec import FrameTreeLayoutId, nativeLayoutIdString
import ../state/engine
from ../types/runtime_values import PointerOpKind
import presentation_policy, window_rules
import recent_windows

proc runtimeWindowId*(model: Model, winId: WindowId): uint32 =
  if winId == NullWindowId:
    return 0'u32
  let winOpt = model.windowData(winId)
  if winOpt.isSome:
    return uint32(winOpt.get().externalId)
  0'u32

proc externalWindowId*(winId: uint32): ExternalWindowId =
  ExternalWindowId(uint32(winId))

proc externalOutputId*(outputId: uint32): ExternalOutputId =
  ExternalOutputId(outputId)

proc windowForRiverId*(model: Model, winId: uint32): WindowId =
  model.windowForExternal(winId.externalWindowId())

proc outputForRiverId*(model: Model, outputId: uint32): OutputId =
  model.outputForExternal(outputId.externalOutputId())

proc riverIdForWindow*(model: Model, winId: WindowId): uint32 =
  model.runtimeWindowId(winId)

proc riverIdForOutput*(model: Model, outputId: OutputId): uint32 =
  if outputId == NullOutputId:
    return 0
  let outputOpt = model.outputData(outputId)
  if outputOpt.isSome:
    return uint32(outputOpt.get().externalId)
  0

proc activeFocusRiverId*(model: Model): uint32 =
  let scratchpad = model.activeScratchpadWindow()
  if scratchpad != NullWindowId:
    return model.riverIdForWindow(scratchpad)
  if model.activeTag == NullTagId:
    return 0'u32
  let tagOpt = model.tagData(model.activeTag)
  if tagOpt.isSome:
    return model.riverIdForWindow(tagOpt.get().focusedWindow)
  0'u32

proc highlightRiverId*(model: Model): uint32 =
  if model.recentWindowsActive:
    return model.riverIdForWindow(model.selectedRecentWindow())
  if model.overviewActive:
    return model.riverIdForWindow(model.selectedOverviewWindow())
  model.activeFocusRiverId()

proc draggedPointerRiverId*(model: Model): uint32 =
  let op = model.pointerOp
  if op.kind == PointerOpKind.OpMove and (not op.tiled or op.dragActive):
    return model.riverIdForWindow(op.windowId)
  0'u32

proc windowRenderFocused*(model: Model, winId: uint32): bool =
  if winId == 0:
    return false
  if model.recentWindowsActive or model.overviewActive:
    return winId == model.highlightRiverId()
  let logicalId = model.windowForRiverId(winId)
  if logicalId == NullWindowId:
    return false
  let tagOpt = model.tagData(model.activeTag)
  if tagOpt.isSome and
      tagOpt.get().nativeLayoutId.nativeLayoutIdString() == FrameTreeLayoutId:
    let winOpt = model.windowData(logicalId)
    if winOpt.isSome and not winOpt.get().isFloating and
        not winOpt.get().isUnmanagedGlobal:
      let frameId = model.frameForWindowOnTag(model.activeTag, logicalId)
      return frameId != NullFrameId and frameId == tagOpt.get().focusedFrame
  winId == model.activeFocusRiverId()

proc primaryOutputRiverId*(model: Model): uint32 =
  model.riverIdForOutput(model.primaryOutput)

proc activeLayerDefaultOutputRiverId*(model: Model): uint32 =
  let activeOutput = model.riverIdForOutput(model.activeOutput)
  if activeOutput != 0:
    return activeOutput
  model.primaryOutputRiverId()

proc visibleScratchpadRiverId*(model: Model): uint32 =
  let scratchpad = model.activeScratchpadWindow()
  if scratchpad != NullWindowId:
    return model.riverIdForWindow(scratchpad)
  0'u32

proc activeLayoutSupportsMaximize*(model: Model): bool =
  let tagOpt = model.tagData(model.activeTag)
  tagOpt.isSome and tagOpt.get().customLayoutId.layoutIdString().len == 0 and
    tagOpt.get().nativeLayoutId.nativeLayoutIdString().len == 0 and
    tagOpt.get().layoutMode.layoutSupportsMaximize()

proc tagSupportsMaximizedPresentation(model: Model, tagId: TagId): bool =
  let tagOpt = model.tagData(tagId)
  tagOpt.isSome and tagOpt.get().customLayoutId.layoutIdString().len == 0 and
    tagOpt.get().nativeLayoutId.nativeLayoutIdString().len == 0 and
    tagOpt.get().layoutMode.layoutSupportsMaximize()

proc windowUsesBorderlessPresentation*(model: Model, logicalId: WindowId): bool =
  if logicalId == NullWindowId or model.overviewActive or model.recentWindowsActive:
    return false
  let winOpt = model.windowData(logicalId)
  if winOpt.isNone:
    return false
  let win = winOpt.get()
  if win.isFullscreen and not win.isMinimized:
    return true
  if not win.isMaximized or win.isMinimized or win.isFloating:
    return false
  let position = model.firstWindowPosition(logicalId)
  position.found and model.tagSupportsMaximizedPresentation(position.tagId) and
    not model.columnFullWidthForWindowOnTag(position.tagId, logicalId)

proc renderWindowBorder*(
    model: Model, logicalId: WindowId, focused: bool
): tuple[width: int32, activeColor: uint32, inactiveColor: uint32] =
  if model.recentWindowsVisible():
    return (width: 0'i32, activeColor: 0'u32, inactiveColor: 0'u32)
  if model.windowUsesBorderlessPresentation(logicalId):
    return (width: 0'i32, activeColor: 0'u32, inactiveColor: 0'u32)
  model.effectiveWindowBorder(logicalId, focused)

proc effectivelyMaximizedForRiverId*(model: Model, winId: uint32): bool =
  let logicalId = model.windowForRiverId(winId)
  if logicalId == NullWindowId:
    return false
  let winOpt = model.windowData(logicalId)
  if winOpt.isNone:
    return false
  let win = winOpt.get()
  win.isMaximized and not win.isMinimized and not win.isFloating and
    model.activeLayoutSupportsMaximize() and
    not model.columnFullWidthForWindowOnTag(model.activeTag, logicalId)

proc windowDataForRiverId*(model: Model, winId: uint32): Option[WindowData] =
  let logicalId = model.windowForRiverId(winId)
  if logicalId == NullWindowId:
    return none(WindowData)
  model.windowData(logicalId)

proc hasRiverWindow*(model: Model, winId: uint32): bool =
  model.windowForRiverId(winId) != NullWindowId

proc proposalDimensionsWithMax(
    win: WindowData, w, h: int32, honorMinimums: bool, maxWidth, maxHeight: int32
): tuple[w, h: int32] =
  result.w = max(0'i32, w)
  result.h = max(0'i32, h)
  if honorMinimums and win.minWidth > 0:
    result.w = max(result.w, win.minWidth)
  if honorMinimums and win.minHeight > 0:
    result.h = max(result.h, win.minHeight)
  if maxWidth > 0:
    result.w = min(result.w, maxWidth)
  if maxHeight > 0:
    result.h = min(result.h, maxHeight)

proc proposalDimensions*(
    win: WindowData, w, h: int32, honorMinimums: bool, honorMaximums = true
): tuple[w, h: int32] =
  win.proposalDimensionsWithMax(
    w,
    h,
    honorMinimums,
    if honorMaximums: win.maxWidth else: 0'i32,
    if honorMaximums: win.maxHeight else: 0'i32,
  )

proc boundedDimensions*(win: WindowData, w, h: int32): tuple[w, h: int32] =
  win.proposalDimensions(w, h, honorMinimums = true)

proc needsCellClip*(win: WindowData, cellW, cellH: int32): bool =
  let safeW = max(0'i32, cellW)
  let safeH = max(0'i32, cellH)
  (win.actualW > safeW and safeW > 0) or (win.actualH > safeH and safeH > 0) or
    (win.minWidth > safeW and safeW > 0) or (win.minHeight > safeH and safeH > 0)

proc boundedDimensionsForRiverId*(
    model: Model, winId: uint32, w, h: int32
): tuple[w, h: int32] =
  let winOpt = model.windowDataForRiverId(winId)
  if winOpt.isSome:
    return winOpt.get().boundedDimensions(w, h)
  (w: max(0'i32, w), h: max(0'i32, h))

proc proposalDimensionsForRiverId*(
    model: Model, winId: uint32, w, h: int32, honorMinimums: bool, honorMaximums = true
): tuple[w, h: int32] =
  let logicalId = model.windowForRiverId(winId)
  let winOpt = model.windowData(logicalId)
  if winOpt.isSome:
    let win = winOpt.get()
    var maxWidth = if honorMaximums: win.maxWidth else: 0'i32
    var maxHeight = if honorMaximums: win.maxHeight else: 0'i32
    if not honorMaximums:
      let ruleMatch = model.windowRuleFor(logicalId, win)
      if ruleMatch.found:
        if ruleMatch.rule.maxWidthSet:
          maxWidth = win.maxWidth
        if ruleMatch.rule.maxHeightSet:
          maxHeight = win.maxHeight
    return win.proposalDimensionsWithMax(w, h, honorMinimums, maxWidth, maxHeight)
  (w: max(0'i32, w), h: max(0'i32, h))

proc manageDimensionBoundsForRiverId*(model: Model, winId: uint32): tuple[w, h: int32] =
  let logicalId = model.windowForRiverId(winId)
  let winOpt = model.windowData(logicalId)
  if winOpt.isNone:
    return (w: 0'i32, h: 0'i32)
  let win = winOpt.get()
  let ruleMatch = model.windowRuleFor(logicalId, win)
  if ruleMatch.found:
    if ruleMatch.rule.maxWidthSet:
      result.w = win.maxWidth
    if ruleMatch.rule.maxHeightSet:
      result.h = win.maxHeight
