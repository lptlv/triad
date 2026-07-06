import std/[math, options]
import ../core/layout_descriptor_codec
import ../core/layout_selection_codec
import ../core/native_layout_codec
import ../state/engine
import ../types/projection_values as rv
from ../types/runtime_values import
  FrameSplitOrientation, JanetLayoutId, LayoutMode, NativeLayoutId, PointerDropKind,
  PointerOpKind
from ../types/system_views import PointerDropPreview
import focus, layout_projection, overview_geometry, placement, workspaces

const ShiftModifier = 1'u32
const PointerDragThresholdSquared = 64'i32
const PointerDragAutoScrollEdge = 30'i32
const PointerDragAutoScrollDelayMs = 100'i32
const PointerDragAutoScrollMaxPxPerMs = 1.5'f32
const PointerResizeDoubleClickMs = 400'i64
const EdgeTop = 1'u32
const EdgeBottom = 2'u32
const EdgeLeft = 4'u32
const EdgeRight = 8'u32
const EdgeHorizontal = EdgeLeft or EdgeRight
const EdgeVertical = EdgeTop or EdgeBottom

type
  DropWindowCandidate = object
    winId: WindowId
    winIdx: int
    geom: Rect

  DropColumnCandidate = object
    columnId: ColumnId
    columnIdx: int
    startPos: int32
    endPos: int32
    windows: seq[DropWindowCandidate]

  ScrollerDropTarget = object
    found: bool
    outputId: OutputId
    tagId: TagId
    kind: PointerDropKind
    columnId: ColumnId
    columnIdx: int
    windowIdx: int

proc tickElapsedMs(msgElapsedMs: int32): int32 =
  if msgElapsedMs > 0: msgElapsedMs else: DefaultFrameIntervalMs

proc keyboardShortcutsInhibited*(model: Model): bool =
  if model.sessionLocked or model.layerFocusExclusive:
    return false
  let tagOpt = model.tagData(model.activeTag)
  if tagOpt.isNone:
    return false
  let winId = tagOpt.get().focusedWindow
  let winOpt = model.windowData(winId)
  if winOpt.isNone:
    return false
  let win = winOpt.get()
  win.keyboardShortcutsInhibit and not win.keyboardShortcutsInhibitBypass

proc setLayerFocusExclusive*(model: var Model, exclusive: bool): bool =
  model.setLayerFocusExclusiveState(exclusive)

proc setSessionLocked*(model: var Model, locked: bool): bool =
  model.setSessionLockedState(locked)

proc setActiveModifiers*(model: var Model, modifiers: uint32): bool =
  model.setActiveModifiersState(modifiers)

proc activeTagUsesCoreScroller(model: Model): bool =
  let tagOpt = model.tagData(model.activeTag)
  if tagOpt.isNone:
    return false
  let tag = tagOpt.get()
  tag.customLayoutId.layoutIdString().len == 0 and
    tag.nativeLayoutId.nativeLayoutIdString().len == 0 and
    tag.layoutMode in {LayoutMode.Scroller, LayoutMode.VerticalScroller}

proc tagUsesCoreScroller(model: Model, tagId: TagId): bool =
  let tagOpt = model.tagData(tagId)
  if tagOpt.isNone:
    return false
  let tag = tagOpt.get()
  tag.customLayoutId.layoutIdString().len == 0 and
    tag.nativeLayoutId.nativeLayoutIdString().len == 0 and
    tag.layoutMode in {LayoutMode.Scroller, LayoutMode.VerticalScroller}

proc activeTagUsesNativeLayout(model: Model): bool =
  let tagOpt = model.tagData(model.activeTag)
  tagOpt.isSome and tagOpt.get().nativeLayoutId.nativeLayoutIdString().len > 0

proc tagUsesAlgorithmicPointerLayout(tag: TagData): bool =
  if tag.nativeLayoutId.nativeLayoutIdString().len > 0:
    return false
  let customId = tag.customLayoutId.layoutIdString()
  if customId.len > 0:
    return customId.isBundledAlgorithmicLayoutId()
  tag.layoutMode notin {LayoutMode.Scroller, LayoutMode.VerticalScroller}

proc activeTagUsesAlgorithmicPointerLayout(model: Model): bool =
  let tagOpt = model.tagData(model.activeTag)
  tagOpt.isSome and tagOpt.get().tagUsesAlgorithmicPointerLayout()

proc activeTagSupportsTiledPointerMove(model: Model): bool =
  model.activeTagUsesCoreScroller() or model.activeTagUsesNativeLayout() or
    model.activeTagUsesAlgorithmicPointerLayout()

proc visibleTiledWindowOrder(model: Model, tagId: TagId): seq[WindowId] =
  for _, column in model.columnsOnTagWithId(tagId):
    for winId, win in model.windowsOnColumnWithId(column.id):
      if win.windowAdmitted() and not win.isFloating and not win.isMinimized and
          not win.isUnmanagedGlobal and not model.windowHiddenByGroup(winId):
        result.add(winId)

proc activeAlgorithmicResizeOrientation(
    model: Model
): tuple[supported: bool, orientation: FrameSplitOrientation] =
  let tagOpt = model.tagData(model.activeTag)
  if tagOpt.isNone or not tagOpt.get().tagUsesAlgorithmicPointerLayout():
    return
  let tag = tagOpt.get()
  let customId = tag.customLayoutId.layoutIdString()
  if customId.len == 0:
    return
  let layoutId = customId
  let visible = model.visibleTiledWindowOrder(model.activeTag)
  let masterCount = min(max(1, tag.masterCount), visible.len)
  if visible.len <= masterCount:
    return
  case layoutId
  of "tile", "deck", "center-tile", "right-tile":
    (true, FrameSplitOrientation.Horizontal)
  of "vertical-tile", "vertical-deck":
    (true, FrameSplitOrientation.Vertical)
  of "tgmix":
    if visible.len <= 3:
      (true, FrameSplitOrientation.Horizontal)
    else:
      (false, FrameSplitOrientation.Horizontal)
  else:
    (false, FrameSplitOrientation.Horizontal)

proc activeTagSupportsTiledPointerResize(model: Model): bool =
  model.activeTagUsesCoreScroller() or model.activeTagUsesNativeLayout() or
    model.activeAlgorithmicResizeOrientation().supported

proc visibleInstructionGeom(model: Model, winId: WindowId): Rect =
  let winOpt = model.windowData(winId)
  if winOpt.isNone:
    return Rect()
  let externalId = rv.ProjectionWindowId(uint32(winOpt.get().externalId))
  if externalId == 0'u32:
    return Rect()
  for instr in model.activeFocusLayoutInstructions():
    if instr.windowId == externalId:
      return instr.geom
  Rect()

proc sourcePlacement(
    model: Model, tagId: TagId, winId: WindowId
): tuple[found: bool, columnId: ColumnId, winIdx: int] =
  let placementOpt = model.placementForWindowOnTag(tagId, winId)
  if placementOpt.isNone:
    return (false, NullColumnId, -1)
  let placement = placementOpt.get()
  (true, placement.columnId, int(placement.windowIdx) - 1)

proc windowCountOnColumn(model: Model, columnId: ColumnId): int =
  for _, _ in model.windowsOnColumnWithId(columnId):
    inc result

proc usableWorkspaceWidth(model: Model, screen: Rect): int32 =
  max(0'i32, screen.w - 2 * max(0'i32, model.outerGaps))

proc usableWorkspaceHeight(model: Model, screen: Rect): int32 =
  max(0'i32, screen.h - 2 * max(0'i32, model.outerGaps))

proc scrollerColumnWidthProportion(
    model: Model, screen: Rect, visibleWidth: int32
): float32 =
  let usableWidth = model.usableWorkspaceWidth(screen)
  if usableWidth <= 0:
    return 1.0'f32
  (float32(max(0'i32, visibleWidth) + max(0'i32, model.innerGaps)) + 0.5'f32) /
    float32(usableWidth)

proc verticalScrollerRowHeightProportion(
    model: Model, screen: Rect, visibleHeight: int32
): float32 =
  let usableHeight = model.usableWorkspaceHeight(screen)
  if usableHeight <= 0:
    return 1.0'f32
  (float32(max(0'i32, visibleHeight) + max(0'i32, model.innerGaps)) + 0.5'f32) /
    float32(usableHeight)

proc scrollerWindowHeightProportion(
    model: Model, screen: Rect, columnId: ColumnId, visibleHeight: int32
): float32 =
  let count = max(1, model.windowCountOnColumn(columnId))
  let totalInnerGaps = int32(count - 1) * max(0'i32, model.innerGaps)
  let usableHeight = max(0'i32, model.usableWorkspaceHeight(screen) - totalInnerGaps)
  if usableHeight <= 0:
    return 1.0'f32
  (float32(max(0'i32, visibleHeight)) + 0.5'f32) / float32(usableHeight)

proc verticalScrollerWindowWidthProportion(
    model: Model, screen: Rect, columnId: ColumnId, visibleWidth: int32
): float32 =
  let count = max(1, model.windowCountOnColumn(columnId))
  let totalInnerGaps = int32(count - 1) * max(0'i32, model.innerGaps)
  let usableWidth = max(0'i32, model.usableWorkspaceWidth(screen) - totalInnerGaps)
  if usableWidth <= 0:
    return 1.0'f32
  (float32(max(0'i32, visibleWidth)) + 0.5'f32) / float32(usableWidth)

proc resizeEdgesUnder(geom: Rect, x, y: int32): uint32 =
  if geom.w <= 0 or geom.h <= 0:
    return 0'u32
  if x < geom.x or y < geom.y or x >= geom.x + geom.w or y >= geom.y + geom.h:
    return 0'u32
  let localX = x - geom.x
  let localY = y - geom.y
  if localX < geom.w div 3:
    result = result or EdgeLeft
  elif localX >= (geom.w * 2) div 3:
    result = result or EdgeRight
  if localY < geom.h div 3:
    result = result or EdgeTop
  elif localY >= (geom.h * 2) div 3:
    result = result or EdgeBottom

proc resolveResizeEdges(geom: Rect, x, y: int32, requestedEdges: uint32): uint32 =
  let hitEdges = resizeEdgesUnder(geom, x, y)
  if hitEdges != 0'u32:
    return hitEdges
  requestedEdges and (EdgeHorizontal or EdgeVertical)

proc tiledResizeContext(
    model: Model,
    externalId: ExternalWindowId,
    startX, startY: int32,
    requestedEdges = 0'u32,
): tuple[
  ok: bool,
  winId: WindowId,
  tagId: TagId,
  columnId: ColumnId,
  winIdx: int,
  geom: Rect,
  edges: uint32,
] =
  let winId = model.windowForExternal(externalId)
  let winOpt = model.windowData(winId)
  if winOpt.isNone or winOpt.get().isFloating:
    return
  if not winOpt.get().windowAdmitted() or winOpt.get().isMinimized or
      winOpt.get().isUnmanagedGlobal or not model.activeTagSupportsTiledPointerResize():
    return
  let tagId = model.activeTag
  let placement = model.sourcePlacement(tagId, winId)
  let geom = model.visibleInstructionGeom(winId)
  if tagId == NullTagId or not placement.found or geom.w <= 0 or geom.h <= 0:
    return
  let edges = resolveResizeEdges(geom, startX, startY, requestedEdges)
  if edges == 0'u32:
    return
  if model.activeTagUsesAlgorithmicPointerLayout():
    let resize = model.activeAlgorithmicResizeOrientation()
    if not resize.supported:
      return
    if resize.orientation == FrameSplitOrientation.Horizontal and
        (edges and EdgeHorizontal) == 0'u32:
      return
    if resize.orientation == FrameSplitOrientation.Vertical and
        (edges and EdgeVertical) == 0'u32:
      return
  (
    ok: true,
    winId: winId,
    tagId: tagId,
    columnId: placement.columnId,
    winIdx: placement.winIdx,
    geom: geom,
    edges: edges,
  )

proc handlePointerResizeDoubleClick*(
    model: var Model,
    externalId: ExternalWindowId,
    startX, startY: int32,
    startedMs: int64,
): tuple[handled: bool, dirty: bool] =
  if startedMs <= 0:
    return (false, false)
  let context = model.tiledResizeContext(externalId, startX, startY)
  if not context.ok:
    return (false, false)
  let tagOpt = model.tagData(context.tagId)
  if tagOpt.isNone or not model.activeTagUsesCoreScroller():
    return (false, false)
  let winOpt = model.windowData(context.winId)
  if winOpt.isNone:
    return (false, false)
  let lastMs = winOpt.get().lastInteractiveResizeStartMs
  let lastEdges = winOpt.get().lastInteractiveResizeEdges
  discard model.setWindowInteractiveResizeStart(context.winId, startedMs, context.edges)
  if lastMs <= 0 or startedMs - lastMs > PointerResizeDoubleClickMs:
    return (false, false)

  let intersection = lastEdges and context.edges
  if intersection == 0'u32:
    return (false, false)

  discard model.setWindowInteractiveResizeStart(context.winId, 0'i64, 0'u32)
  let tag = tagOpt.get()
  if tag.layoutMode == LayoutMode.Scroller:
    if (intersection and EdgeHorizontal) != 0:
      return (true, model.toggleColumnFullWidth(context.columnId))
    if (intersection and EdgeVertical) != 0:
      return (true, model.setWindowHeightProportion(context.winId, 1.0'f32))
  elif tag.layoutMode == LayoutMode.VerticalScroller:
    if (intersection and EdgeVertical) != 0:
      return (true, model.toggleColumnFullWidth(context.columnId))
    if (intersection and EdgeHorizontal) != 0:
      return (true, model.setWindowWidthProportion(context.winId, 1.0'f32))
  (false, false)

proc clearDropTarget(op: var PointerOpData) =
  op.dropKind = PointerDropKind.DropNone
  op.dropOutput = NullOutputId
  op.dropTag = NullTagId
  op.dropColumn = NullColumnId
  op.dropColumnIdx = -1
  op.dropFrame = NullFrameId
  op.dropWindow = NullWindowId
  op.dropWindowIdx = -1

proc rectContainsPoint(rect: Rect, x, y: int32): bool =
  x >= rect.x and y >= rect.y and x < rect.x + rect.w and y < rect.y + rect.h

proc edgeAutoScrollAmount(pos, start, size: int32): int32 =
  if size <= 0:
    return 0
  let endPos = start + size
  if pos < start + PointerDragAutoScrollEdge:
    return
      -min(
        PointerDragAutoScrollEdge, max(0'i32, start + PointerDragAutoScrollEdge - pos)
      )
  if pos >= endPos - PointerDragAutoScrollEdge:
    return min(
      PointerDragAutoScrollEdge,
      max(0'i32, pos - (endPos - PointerDragAutoScrollEdge) + 1),
    )
  0

proc edgeAutoScrollDelta(amount, elapsedMs: int32): int32 =
  if amount == 0:
    return 0
  let sign = if amount < 0: -1'i32 else: 1'i32
  let normalized =
    float32(abs(amount)) / max(1.0'f32, float32(PointerDragAutoScrollEdge))
  let pixels =
    normalized * PointerDragAutoScrollMaxPxPerMs * float32(elapsedMs.tickElapsedMs())
  sign * max(1'i32, int32(round(pixels)))

proc outputUnderPointer(model: Model, x, y: int32): Option[OutputId] =
  for outputId in model.sortedOutputIdsByExternal():
    let screen = model.outputScreen(outputId)
    if screen.w > 0 and screen.h > 0 and screen.rectContainsPoint(x, y):
      return some(outputId)
  if model.outputCount() == 0:
    return some(NullOutputId)
  none(OutputId)

proc sourceScrollerEdgeOutput(model: Model, op: PointerOpData): Option[OutputId] =
  if op.sourceTag == NullTagId or not model.tagUsesCoreScroller(op.sourceTag):
    return none(OutputId)
  let outputId = model.workspaceOutput(op.sourceTag)
  if outputId == NullOutputId:
    return none(OutputId)
  let tagOpt = model.tagData(op.sourceTag)
  if tagOpt.isNone:
    return none(OutputId)
  let screen = model.outputScreen(outputId)
  if screen.w <= 0 or screen.h <= 0:
    return none(OutputId)

  let vertical = tagOpt.get().layoutMode == LayoutMode.VerticalScroller
  let primary = if vertical: op.currentY else: op.currentX
  let secondary = if vertical: op.currentX else: op.currentY
  let primaryStart = if vertical: screen.y else: screen.x
  let primaryEnd = primaryStart + (if vertical: screen.h else: screen.w)
  let secondaryStart = if vertical: screen.x else: screen.y
  let secondaryEnd = secondaryStart + (if vertical: screen.w else: screen.h)

  if secondary < secondaryStart or secondary >= secondaryEnd:
    return none(OutputId)
  if primary >= primaryStart - PointerDragAutoScrollEdge and
      primary < primaryStart + PointerDragAutoScrollEdge:
    return some(outputId)
  if primary >= primaryEnd - PointerDragAutoScrollEdge and
      primary < primaryEnd + PointerDragAutoScrollEdge:
    return some(outputId)
  none(OutputId)

proc pointerTargetTag(model: Model, outputId: OutputId): TagId =
  if outputId == NullOutputId:
    return model.activeTag
  result = model.outputActiveTag(outputId)
  if result == NullTagId and model.workspaceOutput(model.activeTag) == outputId:
    result = model.activeTag

proc instructionGeom(
    instructions: openArray[rv.RenderInstruction], externalId: ExternalWindowId
): Option[Rect] =
  let projected = rv.ProjectionWindowId(uint32(externalId))
  if projected == 0'u32:
    return none(Rect)
  for instr in instructions:
    if instr.windowId == projected:
      return some(instr.geom)
  none(Rect)

proc axisStart(geom: Rect, vertical: bool): int32 =
  if vertical: geom.y else: geom.x

proc axisEnd(geom: Rect, vertical: bool): int32 =
  if vertical:
    geom.y + geom.h
  else:
    geom.x + geom.w

proc axisPoint(x, y: int32, vertical: bool): int32 =
  if vertical: y else: x

proc absDistance(a, b: int32): int64 =
  abs(int64(a) - int64(b))

proc scrollerDropColumns(
    model: Model,
    tagId: TagId,
    instructions: openArray[rv.RenderInstruction],
    op: PointerOpData,
    vertical: bool,
): seq[DropColumnCandidate] =
  var projectedIdx = 0
  for columnId, _ in model.columnsOnTagWithId(tagId):
    var projectedWindowIdx = 0
    var column = DropColumnCandidate(
      columnId: columnId,
      columnIdx: projectedIdx,
      startPos: high(int32),
      endPos: low(int32),
    )
    for winId, win in model.windowsOnColumnWithId(columnId):
      if tagId == op.sourceTag and winId == op.windowId:
        continue
      if not win.windowAdmitted() or win.isFloating or win.isMinimized or
          win.isUnmanagedGlobal or model.windowHiddenByGroup(winId):
        continue
      let geomOpt = instructions.instructionGeom(win.externalId)
      if geomOpt.isNone:
        continue
      let geom = geomOpt.get()
      column.startPos = min(column.startPos, geom.axisStart(vertical))
      column.endPos = max(column.endPos, geom.axisEnd(vertical))
      column.windows.add(
        DropWindowCandidate(winId: winId, winIdx: projectedWindowIdx, geom: geom)
      )
      inc projectedWindowIdx
    if column.windows.len > 0:
      result.add(column)
      inc projectedIdx

proc columnInsertionPosition(
    columns: openArray[DropColumnCandidate], idx: int, gap: int32
): int32 =
  if columns.len == 0:
    return 0
  if idx <= 0:
    return columns[0].startPos
  if idx >= columns.len:
    return columns[^1].endPos + gap
  columns[idx].startPos

proc closestColumnInsertion(
    columns: openArray[DropColumnCandidate], primary, gap: int32
): tuple[idx: int, dist: int64] =
  result = (0, high(int64))
  for idx in 0 .. columns.len:
    let dist = primary.absDistance(columns.columnInsertionPosition(idx, gap))
    if dist < result.dist:
      result = (idx, dist)

proc columnForInsertionPosition(
    columns: openArray[DropColumnCandidate], primary, gap: int32
): int =
  if columns.len == 0 or primary < columns[0].startPos:
    return -1
  if primary >= columns.columnInsertionPosition(columns.len, gap):
    return columns.len
  for idx, column in columns:
    if column.startPos > primary:
      return idx - 1
  columns.high

proc stackInsertionPosition(
    column: DropColumnCandidate, gapIdx: int, vertical: bool, gap: int32
): int32 =
  if column.windows.len == 0:
    return 0
  if gapIdx <= 0:
    return column.windows[0].geom.axisStart(not vertical)
  if gapIdx >= column.windows.len:
    return column.windows[^1].geom.axisEnd(not vertical) + gap
  column.windows[gapIdx].geom.axisStart(not vertical)

proc closestStackInsertion(
    column: DropColumnCandidate, stack: int32, vertical: bool, gap: int32
): tuple[windowIdx: int, dist: int64] =
  result = (0, high(int64))
  for gapIdx in 0 .. column.windows.len:
    let dist = stack.absDistance(column.stackInsertionPosition(gapIdx, vertical, gap))
    if dist < result.dist:
      let windowIdx =
        if gapIdx <= 0:
          column.windows[0].winIdx
        elif gapIdx >= column.windows.len:
          column.windows[^1].winIdx + 1
        else:
          column.windows[gapIdx].winIdx
      result = (windowIdx, dist)

proc scrollerDropTarget(model: Model, op: PointerOpData): ScrollerDropTarget =
  let edgeOutput = model.sourceScrollerEdgeOutput(op)
  let outputOpt =
    if edgeOutput.isSome:
      edgeOutput
    else:
      model.outputUnderPointer(op.currentX, op.currentY)
  if outputOpt.isNone:
    return
  let outputId = outputOpt.get()
  let tagId = model.pointerTargetTag(outputId)
  if tagId == NullTagId or not model.tagUsesCoreScroller(tagId):
    return
  let tagOpt = model.tagData(tagId)
  if tagOpt.isNone:
    return
  let screen =
    if outputId == NullOutputId:
      model.activeWorkspaceScreen()
    else:
      model.outputScreen(outputId)
  let excludeWindowId = if tagId == op.sourceTag: op.windowId else: NullWindowId
  let instructions =
    model.scrollerLayoutInstructionsForTag(tagId, screen, excludeWindowId)
  let vertical = tagOpt.get().layoutMode == LayoutMode.VerticalScroller
  let columns = model.scrollerDropColumns(tagId, instructions, op, vertical)
  if columns.len == 0:
    return ScrollerDropTarget(
      found: true,
      outputId: outputId,
      tagId: tagId,
      kind: PointerDropKind.DropNewColumnAt,
      columnId: NullColumnId,
      columnIdx: 0,
      windowIdx: 0,
    )

  let gap = max(0'i32, model.innerGaps)
  let gapShift = gap div 2
  let primary = axisPoint(op.currentX, op.currentY, vertical) + gapShift
  let stack = axisPoint(op.currentX, op.currentY, not vertical) + gapShift
  let columnGap = columns.closestColumnInsertion(primary, gap)
  let columnIdx = columns.columnForInsertionPosition(primary, gap)
  if columnIdx < 0 or columnIdx >= columns.len:
    return ScrollerDropTarget(
      found: true,
      outputId: outputId,
      tagId: tagId,
      kind: PointerDropKind.DropNewColumnAt,
      columnId: NullColumnId,
      columnIdx: columnGap.idx,
      windowIdx: 0,
    )

  let stackGap = columns[columnIdx].closestStackInsertion(stack, vertical, gap)
  if columnGap.dist <= stackGap.dist:
    ScrollerDropTarget(
      found: true,
      outputId: outputId,
      tagId: tagId,
      kind: PointerDropKind.DropNewColumnAt,
      columnId: NullColumnId,
      columnIdx: columnGap.idx,
      windowIdx: 0,
    )
  else:
    ScrollerDropTarget(
      found: true,
      outputId: outputId,
      tagId: tagId,
      kind: PointerDropKind.DropIntoColumn,
      columnId: columns[columnIdx].columnId,
      columnIdx: columns[columnIdx].columnIdx,
      windowIdx: stackGap.windowIdx,
    )

proc updateScrollerDropTarget(model: Model, op: var PointerOpData) =
  op.clearDropTarget()
  let target = model.scrollerDropTarget(op)
  if not target.found:
    return
  op.dropKind = target.kind
  op.dropOutput = target.outputId
  op.dropTag = target.tagId
  op.dropColumn = target.columnId
  op.dropColumnIdx = target.columnIdx
  op.dropWindowIdx = target.windowIdx

proc effectivePointerDropOuterGap(
    model: Model, instructions: openArray[rv.RenderInstruction]
): int32 =
  if model.smartGaps and instructions.len <= 1:
    0'i32
  else:
    max(0'i32, model.outerGaps)

proc clampNewColumnPreview(
    rect: var Rect, screen: Rect, vertical: bool, outerGap: int32
) =
  if vertical:
    let startY = screen.y + outerGap
    let endY = screen.y + screen.h - outerGap
    rect.y = max(rect.y, startY - rect.h div 2)
    rect.y = min(rect.y, endY - rect.h div 2)
  else:
    let startX = screen.x + outerGap
    let endX = screen.x + screen.w - outerGap
    rect.x = max(rect.x, startX - rect.w div 2)
    rect.x = min(rect.x, endX - rect.w div 2)

proc pointerDropNewColumnPreview(
    screen: Rect,
    columns: openArray[DropColumnCandidate],
    columnIdx: int,
    vertical: bool,
    outerGap, innerGap: int32,
): Rect =
  const HintPrimary = 300'i32
  let usableX = screen.x + outerGap
  let usableY = screen.y + outerGap
  let usableW = max(1'i32, screen.w - outerGap * 2)
  let usableH = max(1'i32, screen.h - outerGap * 2)

  if vertical:
    result = Rect(x: usableX, y: usableY, w: usableW, h: HintPrimary)
    if columns.len > 0:
      if columnIdx <= 0:
        result.y = columns[0].startPos - HintPrimary - innerGap
      elif columnIdx >= columns.len:
        result.y = columns[^1].endPos + innerGap
      else:
        result.y = columns[columnIdx].startPos - HintPrimary div 2 - innerGap div 2
  else:
    result = Rect(x: usableX, y: usableY, w: HintPrimary, h: usableH)
    if columns.len > 0:
      if columnIdx <= 0:
        result.x = columns[0].startPos - HintPrimary - innerGap
      elif columnIdx >= columns.len:
        result.x = columns[^1].endPos + innerGap
      else:
        result.x = columns[columnIdx].startPos - HintPrimary div 2 - innerGap div 2

  result.clampNewColumnPreview(screen, vertical, outerGap)

proc pointerDropStackPreview(
    column: DropColumnCandidate, windowIdx: int, vertical: bool, innerGap: int32
): Rect =
  const
    EdgeHint = 150'i32
    MiddleHint = 300'i32
  if column.windows.len == 0:
    return

  let gapIdx = max(0, min(windowIdx, column.windows.len))
  let primarySize = max(1'i32, column.endPos - column.startPos)
  let stackPos = column.stackInsertionPosition(gapIdx, vertical, innerGap)
  let stackSize =
    if gapIdx <= 0 or gapIdx >= column.windows.len: EdgeHint else: MiddleHint
  let stackStart =
    if gapIdx <= 0:
      stackPos
    elif gapIdx >= column.windows.len:
      stackPos - innerGap - stackSize
    else:
      stackPos - innerGap div 2 - stackSize div 2

  if vertical:
    Rect(x: stackStart, y: column.startPos, w: stackSize, h: primarySize)
  else:
    Rect(x: column.startPos, y: stackStart, w: primarySize, h: stackSize)

proc algorithmicWindowDropKind(geom: Rect, x, y: int32): PointerDropKind =
  let leftDist = x.absDistance(geom.x)
  let rightDist = x.absDistance(geom.x + geom.w)
  let topDist = y.absDistance(geom.y)
  let bottomDist = y.absDistance(geom.y + geom.h)
  let closest = min(min(leftDist, rightDist), min(topDist, bottomDist))
  if closest == leftDist or closest == topDist:
    PointerDropKind.DropWindowBefore
  else:
    PointerDropKind.DropWindowAfter

proc algorithmicWindowDropPreview(geom: Rect, x, y: int32): Rect =
  let leftDist = x.absDistance(geom.x)
  let rightDist = x.absDistance(geom.x + geom.w)
  let topDist = y.absDistance(geom.y)
  let bottomDist = y.absDistance(geom.y + geom.h)
  let closest = min(min(leftDist, rightDist), min(topDist, bottomDist))
  if closest == leftDist:
    return Rect(x: geom.x, y: geom.y, w: max(1'i32, geom.w div 2), h: geom.h)
  if closest == rightDist:
    let width = max(1'i32, geom.w div 2)
    return Rect(x: geom.x + geom.w - width, y: geom.y, w: width, h: geom.h)
  if closest == topDist:
    return Rect(x: geom.x, y: geom.y, w: geom.w, h: max(1'i32, geom.h div 2))
  let height = max(1'i32, geom.h div 2)
  Rect(x: geom.x, y: geom.y + geom.h - height, w: geom.w, h: height)

proc updateAlgorithmicDropTarget(model: Model, op: var PointerOpData) =
  op.clearDropTarget()
  if op.sourceTag != model.activeTag or not model.activeTagUsesAlgorithmicPointerLayout():
    return
  let sourceWin = model.windowData(op.windowId)
  if sourceWin.isNone:
    return
  let sourceExternal = rv.ProjectionWindowId(uint32(sourceWin.get().externalId))
  var fallbackWin = NullWindowId
  var fallbackGeom = Rect()
  var fallbackDist = high(int64)
  for instr in model.activeFocusLayoutInstructions():
    if instr.windowId == sourceExternal:
      continue
    let targetWin = model.windowForExternal(ExternalWindowId(uint32(instr.windowId)))
    if targetWin == NullWindowId:
      continue
    let geom = instr.geom
    if geom.w <= 0 or geom.h <= 0:
      continue
    if geom.rectContainsPoint(op.currentX, op.currentY):
      fallbackWin = targetWin
      fallbackGeom = geom
      fallbackDist = 0
      break
    let centerX = geom.x + geom.w div 2
    let centerY = geom.y + geom.h div 2
    let dx = int64(op.currentX) - int64(centerX)
    let dy = int64(op.currentY) - int64(centerY)
    let dist = dx * dx + dy * dy
    if dist < fallbackDist:
      fallbackWin = targetWin
      fallbackGeom = geom
      fallbackDist = dist
  if fallbackWin == NullWindowId:
    return
  let target = model.sourcePlacement(op.sourceTag, fallbackWin)
  if not target.found:
    return
  op.dropTag = op.sourceTag
  op.dropWindow = fallbackWin
  op.dropColumn = target.columnId
  op.dropWindowIdx = target.winIdx
  op.dropKind = fallbackGeom.algorithmicWindowDropKind(op.currentX, op.currentY)

proc pointerDropPreview(model: Model, op: PointerOpData): PointerDropPreview =
  if op.kind != PointerOpKind.OpMove or not op.tiled or not op.dragActive or
      op.dropFloating or op.dropKind == PointerDropKind.DropNone or
      op.dropTag == NullTagId:
    return

  let tagOpt = model.tagData(op.dropTag)
  if tagOpt.isNone:
    return

  if not model.tagUsesCoreScroller(op.dropTag):
    if op.dropTag != model.activeTag or
        not tagOpt.get().tagUsesAlgorithmicPointerLayout() or
        op.dropWindow == NullWindowId:
      return
    for instr in model.activeFocusLayoutInstructions():
      if model.windowForExternal(ExternalWindowId(uint32(instr.windowId))) ==
          op.dropWindow:
        let rect = instr.geom.algorithmicWindowDropPreview(op.currentX, op.currentY)
        if rect.w <= 0 or rect.h <= 0:
          return
        return PointerDropPreview(found: true, outputId: op.dropOutput, rect: rect)
    return

  let screen =
    if op.dropOutput == NullOutputId:
      model.activeWorkspaceScreen()
    else:
      model.outputScreen(op.dropOutput)
  let instructions =
    model.scrollerLayoutInstructionsForTag(op.dropTag, screen, op.windowId)
  let tag = tagOpt.get()
  let vertical = tag.layoutMode == LayoutMode.VerticalScroller
  let columns = model.scrollerDropColumns(op.dropTag, instructions, op, vertical)
  let outerGap = model.effectivePointerDropOuterGap(instructions)
  let innerGap = max(0'i32, model.innerGaps)

  var rect: Rect
  case op.dropKind
  of PointerDropKind.DropNewColumnAt:
    rect = pointerDropNewColumnPreview(
      screen, columns, op.dropColumnIdx, vertical, outerGap, innerGap
    )
  of PointerDropKind.DropIntoColumn:
    var foundColumn = false
    var column = DropColumnCandidate()
    for candidate in columns:
      if candidate.columnId == op.dropColumn or candidate.columnIdx == op.dropColumnIdx:
        column = candidate
        foundColumn = true
        break
    if not foundColumn:
      return
    rect = column.pointerDropStackPreview(op.dropWindowIdx, vertical, innerGap)
  of PointerDropKind.DropColumnBefore:
    rect = pointerDropNewColumnPreview(
      screen, columns, op.dropColumnIdx, vertical, outerGap, innerGap
    )
  of PointerDropKind.DropColumnAfter:
    rect = pointerDropNewColumnPreview(
      screen, columns, op.dropColumnIdx + 1, vertical, outerGap, innerGap
    )
  of PointerDropKind.DropWindowBefore, PointerDropKind.DropWindowAfter:
    return
  of PointerDropKind.DropNone:
    return

  if rect.w <= 0 or rect.h <= 0:
    return
  PointerDropPreview(found: true, outputId: op.dropOutput, rect: rect)

proc pointerDropPreview*(model: Model): PointerDropPreview =
  model.pointerDropPreview(model.pointerOp)

proc updateNativeDropTarget(model: Model, op: var PointerOpData) =
  op.clearDropTarget()
  if op.sourceTag != model.activeTag:
    return
  let tagOpt = model.tagData(model.activeTag)
  if tagOpt.isNone or tagOpt.get().nativeLayoutId.nativeLayoutIdString().len == 0:
    return
  let x = op.currentX
  let y = op.currentY
  let sourceWin = model.windowData(op.windowId)
  if sourceWin.isNone:
    return
  let sourceExternal = uint32(sourceWin.get().externalId)
  for instr in model.activeFocusLayoutInstructions():
    if uint32(instr.windowId) == sourceExternal:
      continue
    let geom = instr.geom
    if x < geom.x or y < geom.y or x >= geom.x + geom.w or y >= geom.y + geom.h:
      continue
    let targetWin = model.windowForExternal(ExternalWindowId(uint32(instr.windowId)))
    if targetWin == NullWindowId:
      continue
    op.dropTag = op.sourceTag
    op.dropWindow = targetWin
    op.dropKind = PointerDropKind.DropIntoColumn
    if tagOpt.get().nativeLayoutId.nativeLayoutIdString() == FrameTreeLayoutId:
      op.dropFrame = model.frameForWindowOnTag(op.sourceTag, targetWin)
    return

proc updateTiledDropTarget(model: Model, op: var PointerOpData) =
  if model.activeTagUsesCoreScroller():
    model.updateScrollerDropTarget(op)
  elif model.activeTagUsesNativeLayout():
    model.updateNativeDropTarget(op)
  else:
    model.updateAlgorithmicDropTarget(op)

proc preparePointerDropTargetTag(model: var Model, op: PointerOpData): bool =
  if op.dropTag == op.sourceTag:
    return true
  if not model.removeWindowFromTag(op.sourceTag, op.windowId):
    return false
  discard model.sourceWorkspaceFallbackFocus(op.sourceTag)
  true

proc commitScrollerDrop(model: var Model, op: PointerOpData): bool =
  if op.dropKind == PointerDropKind.DropNone or op.dropTag == NullTagId:
    return false
  let winOpt = model.windowData(op.windowId)
  if winOpt.isNone:
    return false
  let source = model.sourcePlacement(op.sourceTag, op.windowId)
  if not source.found:
    return false
  let sourceColumn = model.column(source.columnId)
  let sourceWidth =
    if sourceColumn.isSome:
      sourceColumn.get().widthProportion
    else:
      model.defaultColumnWidth()
  let sourceFullWidth = sourceColumn.isSome and sourceColumn.get().isFullWidth
  let sourceSingleProportion =
    if sourceColumn.isSome:
      sourceColumn.get().scrollerSingleProportion
    else:
      0.0'f32
  let sourceColumnIdx = int(model.columnIndexForTag(op.sourceTag, source.columnId)) - 1

  case op.dropKind
  of PointerDropKind.DropNewColumnAt:
    var targetIdx = max(0, op.dropColumnIdx)
    if op.dropTag == op.sourceTag and sourceColumnIdx >= 0 and
        model.windowCountOnColumn(source.columnId) == 1:
      result = model.moveColumn(op.dropTag, sourceColumnIdx, max(0, targetIdx))
    elif model.preparePointerDropTargetTag(op):
      let newColumn = model.addPlacedWindowColumn(
        op.dropTag,
        op.windowId,
        targetIdx,
        widthProportion = sourceWidth,
        isFullWidth = sourceFullWidth,
        scrollerSingleProportion = sourceSingleProportion,
      )
      result = newColumn != NullColumnId
  of PointerDropKind.DropIntoColumn:
    if op.dropColumn == NullColumnId:
      return false
    var targetIdx = max(0, op.dropWindowIdx)
    if model.preparePointerDropTargetTag(op):
      result =
        model.moveWindowToColumn(op.dropTag, op.windowId, op.dropColumn, targetIdx)
  of PointerDropKind.DropColumnBefore, PointerDropKind.DropColumnAfter:
    if op.dropColumn == NullColumnId:
      return false
    let targetColumnIdx = int(model.columnIndexForTag(op.dropTag, op.dropColumn)) - 1
    if targetColumnIdx < 0:
      return false
    let insertAfter = op.dropKind == PointerDropKind.DropColumnAfter
    if op.dropTag == op.sourceTag and source.columnId != op.dropColumn and
        sourceColumnIdx >= 0 and model.windowCountOnColumn(source.columnId) == 1:
      var targetIdx = targetColumnIdx + (if insertAfter: 1 else: 0)
      if sourceColumnIdx < targetIdx:
        dec targetIdx
      result = model.moveColumn(op.dropTag, sourceColumnIdx, max(0, targetIdx))
    elif model.preparePointerDropTargetTag(op):
      let targetIdx = targetColumnIdx + (if insertAfter: 1 else: 0)
      let newColumn = model.addPlacedWindowColumn(
        op.dropTag,
        op.windowId,
        targetIdx,
        widthProportion = sourceWidth,
        isFullWidth = sourceFullWidth,
        scrollerSingleProportion = sourceSingleProportion,
      )
      result = newColumn != NullColumnId
  of PointerDropKind.DropWindowBefore, PointerDropKind.DropWindowAfter:
    result = false
  of PointerDropKind.DropNone:
    result = false
  if result:
    if op.dropOutput != NullOutputId:
      discard model.setActiveOutput(op.dropOutput)
      discard model.setOutputTag(op.dropOutput, op.dropTag)
    let tagOpt = model.tagData(op.dropTag)
    if tagOpt.isSome:
      discard model.focusWorkspaceSlot(tagOpt.get().slot)
    discard model.setTagFocus(op.dropTag, op.windowId)
    discard model.requestTagViewportRetarget(op.dropTag)

proc commitNativeDrop(model: var Model, op: PointerOpData): bool =
  if op.dropTag == NullTagId or op.dropWindow == NullWindowId:
    return false
  let tagOpt = model.tagData(op.dropTag)
  if tagOpt.isNone:
    return false
  let nativeId = tagOpt.get().nativeLayoutId.nativeLayoutIdString()
  if nativeId == FrameTreeLayoutId:
    if op.dropFrame == NullFrameId:
      return false
    result = model.addWindowToFrame(op.dropTag, op.windowId, op.dropFrame)
    if result:
      discard model.setFrameActiveWindow(op.dropFrame, op.windowId)
      discard model.setFocusedFrame(op.dropTag, op.dropFrame)
  elif nativeId.len > 0:
    result = model.swapPlacedWindows(op.dropTag, op.windowId, op.dropTag, op.dropWindow)
  if result:
    discard model.setTagFocus(op.dropTag, op.windowId)
    discard model.requestTagViewportRetarget(op.dropTag)

proc commitAlgorithmicDrop(model: var Model, op: PointerOpData): bool =
  if op.dropTag == NullTagId or op.dropTag != op.sourceTag or
      op.dropWindow == NullWindowId:
    return false
  case op.dropKind
  of PointerDropKind.DropWindowBefore, PointerDropKind.DropWindowAfter:
    result = model.moveWindowBeforeAfter(
      op.dropTag,
      op.windowId,
      op.dropWindow,
      op.dropKind == PointerDropKind.DropWindowAfter,
    )
  else:
    result = false
  if result:
    discard model.setTagFocus(op.dropTag, op.windowId)
    discard model.requestTagViewportRetarget(op.dropTag)

proc algorithmicWindowInMasterGroup(model: Model, tagId: TagId, winId: WindowId): bool =
  let tagOpt = model.tagData(tagId)
  if tagOpt.isNone:
    return false
  let tag = tagOpt.get()
  let customId = tag.customLayoutId.layoutIdString()
  let deckLike =
    customId in ["deck", "vertical-deck"] or
    (customId.len == 0 and tag.layoutMode in {LayoutMode.Deck, LayoutMode.VerticalDeck})
  if deckLike:
    return true
  let visible = model.visibleTiledWindowOrder(tagId)
  let idx = visible.find(winId)
  idx >= 0 and idx < min(max(1, tag.masterCount), visible.len)

proc beginPointerMove*(
    model: var Model, externalId: ExternalWindowId, startX = 0'i32, startY = 0'i32
): bool =
  let winId = model.windowForExternal(externalId)
  let winOpt = model.windowData(winId)
  if winOpt.isNone:
    return false
  if not winOpt.get().windowAdmitted() or winOpt.get().isMinimized or
      winOpt.get().isUnmanagedGlobal:
    return false
  if not winOpt.get().isFloating:
    if not model.activeTagSupportsTiledPointerMove():
      return false
    let tagId = model.activeTag
    let placement = model.sourcePlacement(tagId, winId)
    let geom = model.visibleInstructionGeom(winId)
    if tagId == NullTagId or not placement.found or geom.w <= 0 or geom.h <= 0:
      return false
    discard model.setTagFocus(tagId, winId)
    return model.setPointerOpState(
      PointerOpData(
        kind: PointerOpKind.OpMove,
        windowId: winId,
        initialGeom: geom,
        tiled: true,
        sourceTag: tagId,
        sourceColumn: placement.columnId,
        sourceWindowIdx: placement.winIdx,
        dropColumnIdx: -1,
        dropWindowIdx: -1,
        startX: startX,
        startY: startY,
        currentX: startX,
        currentY: startY,
        dropFloating: false,
      )
    )
  let projectedGeom = model.visibleInstructionGeom(winId)
  model.setPointerOpState(
    PointerOpData(
      kind: PointerOpKind.OpMove,
      windowId: winId,
      initialGeom:
        if projectedGeom.w > 0 and projectedGeom.h > 0:
          projectedGeom
        else:
          winOpt.get().floatingGeom,
      startX: startX,
      startY: startY,
      currentX: startX,
      currentY: startY,
      dropColumnIdx: -1,
      dropWindowIdx: -1,
      dropFloating: true,
    )
  )

proc beginPointerResize*(
    model: var Model,
    externalId: ExternalWindowId,
    edges: uint32,
    startX = 0'i32,
    startY = 0'i32,
    startedMs = 0'i64,
): bool =
  let winId = model.windowForExternal(externalId)
  let winOpt = model.windowData(winId)
  if winOpt.isNone:
    return false
  if not winOpt.get().windowAdmitted() or winOpt.get().isMinimized or
      winOpt.get().isUnmanagedGlobal:
    return false
  if not winOpt.get().isFloating:
    let context = model.tiledResizeContext(externalId, startX, startY, edges)
    if not context.ok:
      return false
    if startedMs > 0:
      discard model.setWindowInteractiveResizeStart(winId, startedMs, context.edges)
    discard model.setTagFocus(context.tagId, winId)
    return model.setPointerOpState(
      PointerOpData(
        kind: PointerOpKind.OpResize,
        windowId: winId,
        initialGeom: context.geom,
        edges: context.edges,
        tiled: true,
        sourceTag: context.tagId,
        sourceColumn: context.columnId,
        sourceWindowIdx: context.winIdx,
        resizeColumn: context.columnId,
        startX: startX,
        startY: startY,
        currentX: startX,
        currentY: startY,
      )
    )
  let resolvedEdges =
    resolveResizeEdges(winOpt.get().floatingGeom, startX, startY, edges)
  if resolvedEdges == 0'u32:
    return false
  model.setPointerOpState(
    PointerOpData(
      kind: PointerOpKind.OpResize,
      windowId: winId,
      initialGeom: winOpt.get().floatingGeom,
      edges: resolvedEdges,
      startX: startX,
      startY: startY,
      currentX: startX,
      currentY: startY,
      dropFloating: true,
    )
  )

proc overviewScreen(model: Model, outputId: OutputId = NullOutputId): rv.Rect =
  if outputId != NullOutputId:
    return model.outputScreen(outputId)
  model.activeWorkspaceScreen()

proc overviewOutputUnderPointer(model: Model, x, y: int32): Option[OutputId] =
  let outputId = model.overviewOutputAt(x, y)
  if outputId != NullOutputId:
    return some(outputId)
  if model.sortedOutputIdsByExternal().len == 0:
    return some(NullOutputId)
  none(OutputId)

proc updateOverviewDragHover(
    model: var Model, op: var PointerOpData, elapsedMs = 0'i32
): bool =
  let outputOpt = model.overviewOutputUnderPointer(op.currentX, op.currentY)
  if outputOpt.isNone:
    op.hoverSlot = 0
    op.hoverElapsedMs = 0
    return model.setPointerOpState(op)
  op.outputId = outputOpt.get()
  let target = model.overviewDropTargetAtForOutput(
    op.outputId, model.overviewScreen(op.outputId), op.currentX, op.currentY
  )
  let slot =
    if target.kind in {OverviewDropKind.DropWorkspace, OverviewDropKind.DropDynamicGap}:
      target.slot
    else:
      0'u32
  if op.hoverSlot == slot:
    op.hoverElapsedMs = max(0'i32, op.hoverElapsedMs + max(0'i32, elapsedMs))
  else:
    op.hoverSlot = slot
    op.hoverElapsedMs = 0
  model.setPointerOpState(op)

proc beginOverviewDrag*(
    model: var Model, externalId: ExternalWindowId, x, y: int32
): bool =
  if not model.overviewUsesWorkspacePreviews():
    return false
  let outputOpt = model.overviewOutputUnderPointer(x, y)
  if outputOpt.isNone:
    return false
  let outputId = outputOpt.get()
  let screen = model.overviewScreen(outputId)
  let winId = model.windowForExternal(externalId)
  if winId != NullWindowId and model.overviewWindowIds().find(winId) == -1:
    return false
  if winId == NullWindowId and
      model.overviewWorkspaceSlotAtForOutput(outputId, screen, x, y) == 0:
    return false
  if winId != NullWindowId:
    discard model.setOverviewSelection(winId)
  var op = PointerOpData(
    kind: PointerOpKind.OpOverviewDrag,
    windowId: winId,
    startX: x,
    startY: y,
    currentX: x,
    currentY: y,
    outputId: outputId,
  )
  discard model.updateOverviewDragHover(op)
  true

proc beginOverviewScroll*(model: var Model, x, y: int32): bool =
  if not model.overviewUsesWorkspacePreviews():
    return false
  let outputOpt = model.overviewOutputUnderPointer(x, y)
  if outputOpt.isNone:
    return false
  let outputId = outputOpt.get()
  let screen = model.overviewScreen(outputId)
  let slot =
    model.overviewWorkspaceSlotAtForOutput(outputId, screen, x, y, extendedX = true)
  if slot == 0:
    return false
  let tagId = model.tagForSlot(slot)
  let tagOpt = model.tagData(tagId)
  if tagOpt.isNone:
    return false
  let startOffset =
    if tagOpt.get().layoutMode == rv.LayoutMode.VerticalScroller:
      tagOpt.get().currentViewportYOffset
    else:
      tagOpt.get().currentViewportXOffset
  model.setPointerOpState(
    PointerOpData(
      kind: PointerOpKind.OpOverviewScroll,
      startX: x,
      startY: y,
      currentX: x,
      currentY: y,
      outputId: outputId,
      startScrollOffset: startOffset,
      hoverSlot: slot,
    )
  )

proc signedStep(value: int32): int =
  if value > 0:
    return 1
  if value < 0:
    return -1
  0

proc overviewWorkspaceUnderPointerSlot(
    model: Model, outputId: OutputId, x, y: int32
): uint32 =
  model.overviewWorkspaceSlotAtForOutput(
    outputId, model.overviewScreen(outputId), x, y, extendedX = true
  )

proc focusOverviewColumnWheel(model: var Model, x, y: int32, step: int): bool =
  if step == 0:
    return false
  let outputOpt = model.overviewOutputUnderPointer(x, y)
  if outputOpt.isNone:
    return false
  let outputId = outputOpt.get()
  let slot = model.overviewWorkspaceUnderPointerSlot(outputId, x, y)
  if slot == 0:
    return false
  result = model.focusWorkspaceSlot(slot)
  result = model.focusColumnByStep(step) or result

proc handleOverviewWheel*(model: var Model, x, y, horizontal, vertical: int32): bool =
  if not model.overviewUsesWorkspacePreviews():
    return false

  let modifiers = model.activeModifiers
  if modifiers == 0'u32:
    result = model.focusOverviewColumnWheel(x, y, horizontal.signedStep())
    let workspaceStep = vertical.signedStep()
    if workspaceStep != 0:
      let outputOpt = model.overviewOutputUnderPointer(x, y)
      if outputOpt.isSome:
        let outputId = outputOpt.get()
        let slot = model.overviewWorkspaceUnderPointerSlot(outputId, x, y)
        if slot != 0:
          result = model.focusWorkspaceSlot(slot) or result
          result =
            model.focusOverviewWorkspaceStepForOutput(outputId, workspaceStep) or result
  elif modifiers == ShiftModifier:
    result = model.focusOverviewColumnWheel(x, y, vertical.signedStep())

proc closeOverviewMode*(model: var Model): bool =
  result = model.setOverviewActive(false)
  result = model.setOverviewWorkspacePreviewsActive(false) or result
  result = model.clearOverviewSelection() or result
  result = model.setOverviewTabModeActive(false, 0'u32) or result

proc closeOverviewFromPointer(model: var Model): bool =
  model.closeOverviewMode()

proc overviewDragPastThreshold(op: PointerOpData): bool =
  abs(op.totalDX) >= OverviewDragThreshold or abs(op.totalDY) >= OverviewDragThreshold

proc closeOverviewToSlot(model: var Model, slot: uint32): bool =
  if slot == 0:
    return false
  result = model.focusWorkspaceSlot(slot)
  result = model.closeOverviewFromPointer() or result

proc commitOverviewDrag(model: var Model, op: PointerOpData, activateDrop: bool): bool =
  let outputOpt = model.overviewOutputUnderPointer(op.currentX, op.currentY)
  if outputOpt.isNone:
    if op.windowId != NullWindowId:
      result = model.focusWindow(op.windowId)
      result = model.closeOverviewFromPointer() or result
    return
  let outputId = outputOpt.get()
  let target = model.overviewDropTargetAtForOutput(
    outputId, model.overviewScreen(outputId), op.currentX, op.currentY
  )

  if op.windowId == NullWindowId:
    if not op.overviewDragPastThreshold() and
        target.kind == OverviewDropKind.DropWorkspace:
      return model.closeOverviewToSlot(target.slot)
    return false

  if op.overviewDragPastThreshold() and
      target.kind in {OverviewDropKind.DropWorkspace, OverviewDropKind.DropDynamicGap} and
      target.slot != 0:
    if target.kind == OverviewDropKind.DropDynamicGap and target.outputId != NullOutputId:
      let targetTag = model.ensureWorkspaceSlot(target.slot)
      if targetTag != NullTagId:
        discard model.setTagOutput(targetTag, target.outputId)
        if activateDrop:
          discard model.setOutputTag(target.outputId, targetTag)
          discard model.setActiveOutput(target.outputId)
    result = model.moveWindowToSlot(op.windowId, target.slot, activateDrop)
    if activateDrop and result:
      result = model.focusWindow(op.windowId) or result
      result = model.closeOverviewFromPointer() or result
  else:
    result = model.focusWindow(op.windowId)
    result = model.closeOverviewFromPointer() or result

proc panOverviewWorkspace(model: var Model, op: PointerOpData, dx, dy: int32): bool =
  if op.hoverSlot == 0:
    return false
  let tagId = model.tagForSlot(op.hoverSlot)
  let tagOpt = model.tagData(tagId)
  if tagOpt.isNone:
    return false
  let zoom = model.effectiveOverviewZoom()
  let delta =
    if tagOpt.get().layoutMode == rv.LayoutMode.VerticalScroller:
      -float32(dy) / zoom
    else:
      -float32(dx) / zoom
  let offset = op.startScrollOffset + delta
  if tagOpt.get().layoutMode == rv.LayoutMode.VerticalScroller:
    result =
      model.setTagViewportTarget(tagId, tagOpt.get().targetViewportXOffset, offset)
    result =
      model.setTagViewportCurrent(tagId, tagOpt.get().currentViewportXOffset, offset) or
      result
  else:
    result =
      model.setTagViewportTarget(tagId, offset, tagOpt.get().targetViewportYOffset)
    result =
      model.setTagViewportCurrent(tagId, offset, tagOpt.get().currentViewportYOffset) or
      result

proc togglePointerDropMode*(model: var Model): bool =
  var op = model.pointerOp
  if op.kind != PointerOpKind.OpMove:
    return false
  let winOpt = model.windowData(op.windowId)
  if winOpt.isNone:
    return false

  if op.tiled:
    op.dropFloating = not op.dropFloating
    if not op.dragActive:
      op.dragActive = true
    if op.dragActive and not op.dropFloating:
      model.updateTiledDropTarget(op)
    return model.setPointerOpState(op)

  if not winOpt.get().isFloating or not model.activeTagSupportsTiledPointerMove():
    return false
  let tagId = model.activeTag
  let placement = model.sourcePlacement(tagId, op.windowId)
  if tagId == NullTagId or not placement.found:
    return false
  op.tiled = true
  op.dropFloating = false
  op.dragActive = true
  op.sourceTag = tagId
  op.sourceColumn = placement.columnId
  op.sourceWindowIdx = placement.winIdx
  op.dropColumnIdx = -1
  op.dropWindowIdx = -1
  model.updateTiledDropTarget(op)
  model.setPointerOpState(op)

proc applyPointerDelta*(
    model: var Model, dx, dy: int32, pointerX = 0'i32, pointerY = 0'i32
): bool =
  let op = model.pointerOp
  if op.kind == PointerOpKind.OpNone:
    return false
  let currentX =
    if pointerX != 0'i32 or pointerY != 0'i32:
      pointerX
    else:
      op.startX + dx
  let currentY =
    if pointerX != 0'i32 or pointerY != 0'i32:
      pointerY
    else:
      op.startY + dy
  if op.kind == PointerOpKind.OpOverviewDrag:
    var next = op
    next.totalDX = dx
    next.totalDY = dy
    next.currentX = currentX
    next.currentY = currentY
    return model.updateOverviewDragHover(next)
  if op.kind == PointerOpKind.OpOverviewScroll:
    var next = op
    next.totalDX = dx
    next.totalDY = dy
    next.currentX = currentX
    next.currentY = currentY
    discard model.setPointerOpState(next)
    return model.panOverviewWorkspace(op, dx, dy)

  let winOpt = model.windowData(op.windowId)
  if winOpt.isNone:
    return false

  if op.tiled:
    var next = op
    next.totalDX = dx
    next.totalDY = dy
    next.currentX = currentX
    next.currentY = currentY
    case op.kind
    of PointerOpKind.OpMove:
      if not next.dragActive and dx * dx + dy * dy >= PointerDragThresholdSquared:
        next.dragActive = true
      if next.dragActive and not next.dropFloating:
        model.updateTiledDropTarget(next)
      return model.setPointerOpState(next)
    of PointerOpKind.OpResize:
      discard model.setPointerOpState(next)
      let screen = model.activeWorkspaceScreen()
      let tagOpt = model.tagData(op.sourceTag)
      if tagOpt.isNone:
        return false
      let tag = tagOpt.get()
      var dirty = false
      if model.activeTagUsesCoreScroller():
        if (next.edges and EdgeHorizontal) != 0'u32:
          let signedDx =
            if (next.edges and 4'u32) != 0:
              -dx
            else:
              dx
          if tag.layoutMode == LayoutMode.Scroller:
            let targetWidth = next.initialGeom.w + signedDx
            dirty =
              model.setColumnWidth(
                next.resizeColumn,
                model.scrollerColumnWidthProportion(screen, targetWidth),
              ) or dirty
          else:
            let targetWidth = next.initialGeom.w + signedDx
            dirty =
              model.setWindowWidthProportion(
                next.windowId,
                model.verticalScrollerWindowWidthProportion(
                  screen, next.resizeColumn, targetWidth
                ),
              ) or dirty
        if (next.edges and EdgeVertical) != 0'u32:
          let signedDy =
            if (next.edges and 1'u32) != 0:
              -dy
            else:
              dy
          if tag.layoutMode == LayoutMode.Scroller:
            let targetHeight = next.initialGeom.h + signedDy
            dirty =
              model.setWindowHeightProportion(
                next.windowId,
                model.scrollerWindowHeightProportion(
                  screen, next.resizeColumn, targetHeight
                ),
              ) or dirty
          else:
            let targetHeight = next.initialGeom.h + signedDy
            dirty =
              model.setColumnWidth(
                next.resizeColumn,
                model.verticalScrollerRowHeightProportion(screen, targetHeight),
              ) or dirty
      elif model.activeTagUsesNativeLayout():
        let incDx = dx - op.totalDX
        let incDy = dy - op.totalDY
        let nativeId = tag.nativeLayoutId.nativeLayoutIdString()
        if (next.edges and EdgeHorizontal) != 0'u32 and screen.w > 0:
          let signedDx =
            if (next.edges and 4'u32) != 0:
              -incDx
            else:
              incDx
          if nativeId == FrameTreeLayoutId:
            dirty =
              model.adjustFocusedFrameSplit(
                model.activeTag,
                FrameSplitOrientation.Horizontal,
                float32(signedDx) / float32(screen.w),
              ) or dirty
          else:
            dirty = model.resizeWidth(float32(signedDx) / float32(screen.w)) or dirty
        if (next.edges and EdgeVertical) != 0'u32 and screen.h > 0:
          let signedDy =
            if (next.edges and 1'u32) != 0:
              -incDy
            else:
              incDy
          if nativeId == FrameTreeLayoutId:
            dirty =
              model.adjustFocusedFrameSplit(
                model.activeTag,
                FrameSplitOrientation.Vertical,
                float32(signedDy) / float32(screen.h),
              ) or dirty
          else:
            dirty = model.resizeHeight(float32(signedDy) / float32(screen.h)) or dirty
      else:
        let resize = model.activeAlgorithmicResizeOrientation()
        if resize.supported:
          let incDx = dx - op.totalDX
          let incDy = dy - op.totalDY
          let direction =
            if model.algorithmicWindowInMasterGroup(op.sourceTag, op.windowId):
              1.0'f32
            else:
              -1.0'f32
          if resize.orientation == FrameSplitOrientation.Horizontal and
              (next.edges and EdgeHorizontal) != 0'u32 and screen.w > 0:
            let signedDx =
              if (next.edges and EdgeLeft) != 0:
                -incDx
              else:
                incDx
            dirty =
              model.setTagMasterRatio(
                op.sourceTag,
                tag.masterSplitRatio + direction * float32(signedDx) / float32(screen.w),
              ) or dirty
          elif resize.orientation == FrameSplitOrientation.Vertical and
              (next.edges and EdgeVertical) != 0'u32 and screen.h > 0:
            let signedDy =
              if (next.edges and EdgeTop) != 0:
                -incDy
              else:
                incDy
            dirty =
              model.setTagMasterRatio(
                op.sourceTag,
                tag.masterSplitRatio + direction * float32(signedDy) / float32(screen.h),
              ) or dirty
      return dirty
    of PointerOpKind.OpNone, PointerOpKind.OpOverviewDrag,
        PointerOpKind.OpOverviewScroll:
      return false

  var geom = winOpt.get().floatingGeom
  case op.kind
  of PointerOpKind.OpMove:
    var next = op
    next.totalDX = dx
    next.totalDY = dy
    next.currentX = currentX
    next.currentY = currentY
    return model.setPointerOpState(next)
  of PointerOpKind.OpResize:
    if op.edges == 0'u32:
      return false
    var next = op
    next.totalDX = dx
    next.totalDY = dy
    next.currentX = currentX
    next.currentY = currentY
    if (next.edges and EdgeVertical) != 0'u32:
      if (op.edges and 1) != 0:
        geom.y = op.initialGeom.y + dy
        geom.h = max(model.effectiveFloatingMinHeight(), op.initialGeom.h - dy)
      elif (op.edges and 2) != 0:
        geom.h = max(model.effectiveFloatingMinHeight(), op.initialGeom.h + dy)
    if (next.edges and EdgeHorizontal) != 0'u32:
      if (op.edges and 4) != 0:
        geom.x = op.initialGeom.x + dx
        geom.w = max(model.effectiveFloatingMinWidth(), op.initialGeom.w - dx)
      elif (op.edges and 8) != 0:
        geom.w = max(model.effectiveFloatingMinWidth(), op.initialGeom.w + dx)
    let stateDirty = model.setPointerOpState(next)
    return model.setWindowFloatingGeom(op.windowId, geom) or stateDirty
  of PointerOpKind.OpNone:
    return false
  of PointerOpKind.OpOverviewDrag, PointerOpKind.OpOverviewScroll:
    return false

proc finishPointerOp*(model: var Model): core.WindowId =
  let op = model.pointerOp
  if op.kind == PointerOpKind.OpOverviewDrag:
    discard model.commitOverviewDrag(op, activateDrop = false)
    discard model.clearPointerOp()
    return NullWindowId
  if op.kind == PointerOpKind.OpOverviewScroll:
    discard model.clearPointerOp()
    return NullWindowId
  if op.tiled and op.kind == PointerOpKind.OpMove and op.dragActive:
    if op.dropFloating:
      var geom = op.initialGeom
      geom.x += op.totalDX
      geom.y += op.totalDY
      discard model.setWindowFloating(op.windowId, true, geom)
      discard model.setWindowManualFloatingGeom(op.windowId, geom)
    else:
      let winOpt = model.windowData(op.windowId)
      if winOpt.isSome and winOpt.get().isFloating:
        discard model.setWindowFloating(op.windowId, false)
    if op.dropFloating:
      discard
    elif model.activeTagUsesCoreScroller():
      discard model.commitScrollerDrop(op)
    elif model.activeTagUsesNativeLayout():
      discard model.commitNativeDrop(op)
    else:
      discard model.commitAlgorithmicDrop(op)
  elif not op.tiled and op.kind == PointerOpKind.OpMove and
      (op.totalDX != 0 or op.totalDY != 0):
    var geom = op.initialGeom
    geom.x += op.totalDX
    geom.y += op.totalDY
    discard model.setWindowManualFloatingGeom(op.windowId, geom)
  result = if op.kind == PointerOpKind.OpResize: op.windowId else: NullWindowId
  discard model.clearPointerOp()

proc activeScrollerPointerDrag*(model: Model): bool =
  let op = model.pointerOp
  if op.kind != PointerOpKind.OpMove or not op.tiled or not op.dragActive or
      op.dropFloating:
    return false
  let tagId = if op.dropTag != NullTagId: op.dropTag else: op.sourceTag
  model.tagUsesCoreScroller(tagId)

proc tickPointerDragAutoScroll*(
    model: var Model, elapsedMs = DefaultFrameIntervalMs
): bool =
  if not model.activeScrollerPointerDrag():
    return false
  var op = model.pointerOp
  let tagId = if op.dropTag != NullTagId: op.dropTag else: op.sourceTag
  let tagOpt = model.tagData(tagId)
  if tagOpt.isNone:
    return false
  let outputId =
    if op.dropOutput != NullOutputId:
      op.dropOutput
    else:
      model.workspaceOutput(tagId)
  let screen =
    if outputId != NullOutputId:
      model.outputScreen(outputId)
    else:
      model.activeWorkspaceScreen()
  if screen.w <= 0 or screen.h <= 0:
    return false

  let tag = tagOpt.get()
  var amount = 0'i32
  if tag.layoutMode == LayoutMode.Scroller:
    amount = edgeAutoScrollAmount(op.currentX, screen.x, screen.w)
  elif tag.layoutMode == LayoutMode.VerticalScroller:
    amount = edgeAutoScrollAmount(op.currentY, screen.y, screen.h)

  let tickMs = elapsedMs.tickElapsedMs()
  if amount == 0:
    if op.dragAutoScrollElapsedMs != 0:
      op.dragAutoScrollElapsedMs = 0
      discard model.setPointerOpState(op)
      return true
    return false

  op.dragAutoScrollElapsedMs = max(0'i32, op.dragAutoScrollElapsedMs + tickMs)
  if op.dragAutoScrollElapsedMs < PointerDragAutoScrollDelayMs:
    discard model.setPointerOpState(op)
    return true

  let delta = edgeAutoScrollDelta(amount, tickMs)
  if delta == 0:
    discard model.setPointerOpState(op)
    return true

  if tag.layoutMode == LayoutMode.Scroller:
    let target = tag.targetViewportXOffset + float32(delta)
    let current = tag.currentViewportXOffset + float32(delta)
    result = model.setTagViewportTarget(tagId, target, tag.targetViewportYOffset)
    result =
      model.setTagViewportCurrent(tagId, current, tag.currentViewportYOffset) or result
  elif tag.layoutMode == LayoutMode.VerticalScroller:
    let target = tag.targetViewportYOffset + float32(delta)
    let current = tag.currentViewportYOffset + float32(delta)
    result = model.setTagViewportTarget(tagId, tag.targetViewportXOffset, target)
    result =
      model.setTagViewportCurrent(tagId, tag.currentViewportXOffset, current) or result

  if result:
    model.updateScrollerDropTarget(op)
  discard model.setPointerOpState(op)
  result = true

proc tickOverviewPointerHold*(
    model: var Model, elapsedMs = DefaultFrameIntervalMs
): bool =
  var op = model.pointerOp
  if op.kind != PointerOpKind.OpOverviewDrag or not op.overviewDragPastThreshold():
    return false
  discard model.updateOverviewDragHover(op, elapsedMs.tickElapsedMs())
  false

proc moveFloatingFocused*(model: var Model, dx, dy: int32): bool =
  let tagOpt = model.tagData(model.activeTag)
  if tagOpt.isNone:
    return false
  let winId = tagOpt.get().focusedWindow
  let winOpt = model.windowData(winId)
  if winOpt.isNone or not winOpt.get().isFloating:
    return false
  var geom = winOpt.get().floatingGeom
  geom.x += dx
  geom.y += dy
  model.setWindowManualFloatingGeom(winId, geom)

proc resizeFloatingFocused*(model: var Model, dw, dh: int32): bool =
  let tagOpt = model.tagData(model.activeTag)
  if tagOpt.isNone:
    return false
  let winId = tagOpt.get().focusedWindow
  let winOpt = model.windowData(winId)
  if winOpt.isNone or not winOpt.get().isFloating:
    return false
  var geom = winOpt.get().floatingGeom
  geom.w = max(model.effectiveFloatingMinWidth(), geom.w + dw)
  geom.h = max(model.effectiveFloatingMinHeight(), geom.h + dh)
  model.setWindowFloatingGeom(winId, geom)

proc adjustGaps*(model: var Model, delta: int32): bool =
  model.outerGaps = max(0'i32, model.outerGaps + delta)
  model.innerGaps = model.outerGaps div 2
  true

proc toggleGaps*(model: var Model): bool =
  if model.outerGaps > 0:
    model.previousOuterGaps = model.outerGaps
    model.previousInnerGaps = model.innerGaps
    model.outerGaps = 0
    model.innerGaps = 0
  else:
    model.outerGaps = model.previousOuterGaps
    model.innerGaps = model.previousInnerGaps
  true

proc renameActiveWorkspace*(model: var Model, name: string): bool =
  let tagId = model.activeTag
  tagId != NullTagId and model.setTagName(tagId, name)

proc groupFocusedWindow*(model: var Model): bool =
  let tagOpt = model.tagData(model.activeTag)
  if tagOpt.isNone:
    return false
  if tagOpt.get().nativeLayoutId.nativeLayoutIdString() == BspTreeLayoutId:
    return false
  let focused = tagOpt.get().focusedWindow
  if focused == NullWindowId or
      model.placementForWindowOnTag(model.activeTag, focused).isNone:
    return false

  var visible: seq[WindowId] = @[]
  for instr in model.activeFocusLayoutInstructions():
    let winId = model.windowForExternal(ExternalWindowId(uint32(instr.windowId)))
    if winId != NullWindowId and visible.find(winId) == -1 and
        model.placementForWindowOnTag(model.activeTag, winId).isSome:
      visible.add(winId)
  let focusedIdx = visible.find(focused)
  if focusedIdx == -1 or visible.len <= 1:
    return false

  let neighbor = visible[(focusedIdx + 1) mod visible.len]
  var members: seq[WindowId] = @[]
  for winId in [focused, neighbor]:
    let groupId = model.groupForWindow(winId)
    if groupId != NullGroupId:
      let groupOpt = model.groupData(groupId)
      if groupOpt.isSome:
        for member in groupOpt.get().windows:
          if members.find(member) == -1:
            members.add(member)
    elif members.find(winId) == -1:
      members.add(winId)
  if members.len <= 1:
    return false

  if tagOpt.get().nativeLayoutId.nativeLayoutIdString() == FrameTreeLayoutId:
    var frameId = model.frameForWindowOnTag(model.activeTag, focused)
    if frameId == NullFrameId:
      frameId = model.focusedFrameOrRoot(model.activeTag)
    if frameId == NullFrameId:
      return false
    for member in members:
      discard model.addWindowToFrame(model.activeTag, member, frameId)
    discard model.setFrameActiveWindow(frameId, focused)
    discard model.setFocusedFrame(model.activeTag, frameId)
  else:
    let placement = model.placementForWindowOnTag(model.activeTag, focused)
    if placement.isNone:
      return false
    let columnId = placement.get().columnId
    var targetIdx = int(placement.get().windowIdx)
    for member in members:
      if member == focused:
        continue
      discard model.moveWindowToColumn(model.activeTag, member, columnId, targetIdx)
      inc targetIdx

  let groupId = model.addGroup(members, focused)
  if groupId == NullGroupId:
    return false
  discard model.setTagFocus(model.activeTag, focused)
  true

proc ungroupFocusedWindow*(model: var Model): bool =
  let focused = model.focusedOnActiveTag()
  focused != NullWindowId and model.ungroupWindow(focused)

proc focusNextInGroup*(model: var Model): bool =
  let focused = model.focusedOnActiveTag()
  if focused == NullWindowId:
    return false
  let groupId = model.groupForWindow(focused)
  let groupOpt = model.groupData(groupId)
  if groupOpt.isNone or groupOpt.get().windows.len <= 1:
    return false
  let group = groupOpt.get()
  var idx = group.windows.find(group.activeWindow)
  if idx == -1:
    idx = group.windows.find(focused)
  if idx == -1:
    return false
  let next = group.windows[(idx + 1) mod group.windows.len]
  discard model.setGroupActiveWindow(next)
  model.focusWindow(next)

proc animatedViewportOffset(
    current, target, speed, snapThreshold: float32
): tuple[value: float32, changed: bool] =
  let delta = target - current
  if speed <= 0.0'f32 or abs(delta) <= snapThreshold:
    return (target, abs(delta) > 0.0'f32)
  (current + delta * speed, true)

proc elapsedAnimationSpeed(speed: float32, elapsedMs: int32): float32 =
  if speed <= 0.0'f32 or speed >= 1.0'f32:
    return speed
  let frames =
    max(0.0'f32, float32(elapsedMs.tickElapsedMs()) / float32(DefaultFrameIntervalMs))
  1.0'f32 - pow(1.0'f32 - speed, frames)

proc renderedViewportOffset(value: float32): int32 =
  int32(round(value))

proc tickAnimations*(model: var Model, elapsedMs = DefaultFrameIntervalMs): bool =
  if not model.enableAnimations:
    return false
  let tickOverviewPreviews = model.overviewUsesWorkspacePreviews()
  if model.overviewActive and not tickOverviewPreviews:
    return false
  let speed = model.animationSpeed.elapsedAnimationSpeed(elapsedMs)
  let snapThreshold = max(model.animationSnapThreshold, 0.01'f32)
  if tickOverviewPreviews:
    let previewSlots = model.previewSlots()
    for tagId, tag in model.tagsWithId():
      if previewSlots.find(tag.slot) == -1:
        continue
      var currentX = tag.currentViewportXOffset
      var currentY = tag.currentViewportYOffset
      let beforeRenderX = renderedViewportOffset(currentX)
      let beforeRenderY = renderedViewportOffset(currentY)
      let nextX = animatedViewportOffset(
        currentX, tag.targetViewportXOffset, speed, snapThreshold
      )
      let nextY = animatedViewportOffset(
        currentY, tag.targetViewportYOffset, speed, snapThreshold
      )
      currentX = nextX.value
      currentY = nextY.value
      let changed = nextX.changed or nextY.changed
      if changed:
        discard model.setTagViewportCurrent(tagId, currentX, currentY)
        let afterRenderX = renderedViewportOffset(currentX)
        let afterRenderY = renderedViewportOffset(currentY)
        result =
          result or beforeRenderX != afterRenderX or beforeRenderY != afterRenderY
  else:
    let tagOpt = model.tagData(model.activeTag)
    if tagOpt.isNone:
      return false
    let tag = tagOpt.get()
    var currentX = tag.currentViewportXOffset
    var currentY = tag.currentViewportYOffset
    let beforeRenderX = renderedViewportOffset(currentX)
    let beforeRenderY = renderedViewportOffset(currentY)
    let nextX =
      animatedViewportOffset(currentX, tag.targetViewportXOffset, speed, snapThreshold)
    let nextY =
      animatedViewportOffset(currentY, tag.targetViewportYOffset, speed, snapThreshold)
    currentX = nextX.value
    currentY = nextY.value
    let changed = nextX.changed or nextY.changed
    if changed:
      discard model.setTagViewportCurrent(model.activeTag, currentX, currentY)
      let afterRenderX = renderedViewportOffset(currentX)
      let afterRenderY = renderedViewportOffset(currentY)
      result = result or beforeRenderX != afterRenderX or beforeRenderY != afterRenderY

proc hasPendingViewportAnimation*(model: Model): bool =
  if not model.enableAnimations:
    return false
  let tickOverviewPreviews = model.overviewUsesWorkspacePreviews()
  if model.overviewActive and not tickOverviewPreviews:
    return false
  let snapThreshold = max(model.animationSnapThreshold, 0.01'f32)
  if tickOverviewPreviews:
    let previewSlots = model.previewSlots()
    for _, tag in model.tagsWithId():
      if previewSlots.find(tag.slot) == -1:
        continue
      if abs(tag.targetViewportXOffset - tag.currentViewportXOffset) > 0.0'f32 or
          abs(tag.targetViewportYOffset - tag.currentViewportYOffset) > 0.0'f32:
        if model.animationSpeed <= 0.0'f32:
          return true
        if abs(tag.targetViewportXOffset - tag.currentViewportXOffset) > snapThreshold or
            abs(tag.targetViewportYOffset - tag.currentViewportYOffset) > snapThreshold:
          return true
  else:
    let tagOpt = model.tagData(model.activeTag)
    if tagOpt.isNone:
      return false
    let tag = tagOpt.get()
    if abs(tag.targetViewportXOffset - tag.currentViewportXOffset) > 0.0'f32 or
        abs(tag.targetViewportYOffset - tag.currentViewportYOffset) > 0.0'f32:
      if model.animationSpeed <= 0.0'f32:
        return true
      if abs(tag.targetViewportXOffset - tag.currentViewportXOffset) > snapThreshold or
          abs(tag.targetViewportYOffset - tag.currentViewportYOffset) > snapThreshold:
        return true
      return true

proc needsFrameTick*(model: Model): bool =
  if model.activeScrollerPointerDrag():
    return true
  if model.hasPendingViewportAnimation():
    return true
  if model.pendingRecentFocusWindow != NullWindowId:
    return true
  if model.recentWindowsActive and
      model.recentWindowsOpenElapsedMs < model.recentWindows.openDelayMs:
    return true
  if model.layoutSwitchToastOpen:
    return true
  model.pendingDialogFocusWindows.len > 0

proc frameTickReasons*(model: Model): seq[string] =
  if model.activeScrollerPointerDrag():
    result.add("pointer-drag-autoscroll")
  if model.hasPendingViewportAnimation():
    result.add("viewport-animation")
  if model.pendingRecentFocusWindow != NullWindowId:
    result.add("recent-focus")
  if model.recentWindowsActive and
      model.recentWindowsOpenElapsedMs < model.recentWindows.openDelayMs:
    result.add("recent-window-open-delay")
  if model.layoutSwitchToastOpen:
    result.add("layout-switch-toast")
  if model.pendingDialogFocusWindows.len > 0:
    result.add("dialog-focus")

proc openLayoutSwitchToast*(
    model: var Model,
    layout: LayoutMode,
    customLayout = JanetLayoutId(""),
    nativeLayout = NativeLayoutId(""),
): bool =
  if not model.layoutSwitchToast.enabled or model.layoutSwitchToast.timeoutMs <= 0:
    return false
  result =
    not model.layoutSwitchToastOpen or model.layoutSwitchToastElapsedMs != 0 or
    model.layoutSwitchToastLayout != layout or
    string(model.layoutSwitchToastCustomLayout) != string(customLayout) or
    string(model.layoutSwitchToastNativeLayout) != string(nativeLayout)
  model.layoutSwitchToastOpen = true
  model.layoutSwitchToastElapsedMs = 0
  model.layoutSwitchToastLayout = layout
  model.layoutSwitchToastCustomLayout = customLayout
  model.layoutSwitchToastNativeLayout = nativeLayout

proc tickLayoutSwitchToast*(
    model: var Model, elapsedMs = DefaultFrameIntervalMs
): bool =
  if not model.layoutSwitchToastOpen:
    return false
  model.layoutSwitchToastElapsedMs += elapsedMs.tickElapsedMs()
  if model.layoutSwitchToastElapsedMs >= model.layoutSwitchToast.timeoutMs:
    model.layoutSwitchToastOpen = false
    model.layoutSwitchToastElapsedMs = 0
    return true
  false
