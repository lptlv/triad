import std/tables
import ../types/projection_values

proc clampProportion(value: float32, lo = 0.05'f32, hi = 1.0'f32): float32 =
  clamp(value, lo, hi)

proc normalizeWindowProportion(value: float32): float32 =
  if value != value:
    1.0'f32
  else:
    clamp(value, 0.05'f32, 1.0'f32)

proc normalizeScrollAxisProportion(value: float32): float32 =
  if value != value:
    1.0'f32
  else:
    clamp(value, 0.05'f32, float32(high(int32)))

proc scaledWindowExtent(base: int32, proportion: float32): int32 =
  if base <= 0:
    return 0'i32
  let scaled = float64(base) * float64(normalizeWindowProportion(proportion))
  if scaled != scaled:
    return base
  if scaled >= float64(high(int32)):
    return high(int32)
  max(0'i32, int32(scaled))

proc scaledScrollAxisExtent(base: int32, proportion: float32): int32 =
  if base <= 0:
    return 0'i32
  let scaled = float64(base) * float64(normalizeScrollAxisProportion(proportion))
  if scaled != scaled:
    return base
  if scaled >= float64(high(int32)):
    return high(int32)
  max(0'i32, int32(scaled))

proc windowHeightProportion(
    windows: Table[ProjectionWindowId, ProjectedWindow], winId: ProjectionWindowId
): float32 =
  if windows.hasKey(winId):
    normalizeWindowProportion(windows[winId].heightProportion)
  else:
    1.0'f32

proc windowWidthProportion(
    windows: Table[ProjectionWindowId, ProjectedWindow], winId: ProjectionWindowId
): float32 =
  if windows.hasKey(winId):
    normalizeWindowProportion(windows[winId].widthProportion)
  else:
    1.0'f32

proc effectiveColumnProportion(col: ProjectedColumn): float32 =
  if col.isFullWidth: 1.0'f32 else: col.widthProportion

proc effectiveSingleColumnProportion(col: ProjectedColumn): float32 =
  if col.isFullWidth:
    1.0'f32
  elif col.scrollerSingleProportion > 0.0'f32:
    col.scrollerSingleProportion
  else:
    col.effectiveColumnProportion()

proc layoutScroller*(
    tag: var ProjectedTag,
    windows: Table[ProjectionWindowId, ProjectedWindow],
    screen: Rect,
    outerGap, innerGap: int32,
    focusCenter: bool,
    preferCenter: bool,
    centerMode: string,
): seq[RenderInstruction] =
  var instructions: seq[RenderInstruction] = @[]

  if tag.columns.len == 0:
    return instructions

  let safeOuterGap = max(0'i32, outerGap)
  let safeInnerGap = max(0'i32, innerGap)
  let usableWidth = max(0'i32, screen.w - 2 * safeOuterGap)
  let usableHeight = max(0'i32, screen.h - 2 * safeOuterGap)

  if tag.columns.len == 1 and tag.columns[0].scrollerSingleProportion > 0.0'f32:
    tag.targetViewportXOffset = 0.0'f32
    let col = tag.columns[0]
    if col.windows.len == 0:
      return instructions

    let colWidth = int32(
      float32(usableWidth) * clampProportion(col.effectiveSingleColumnProportion())
    )
    let currentX = screen.x + safeOuterGap + ((usableWidth - colWidth) div 2)
    let numWindows = col.windows.len
    let totalInnerGaps = int32(numWindows - 1) * safeInnerGap
    let usableColHeight = max(0'i32, usableHeight - totalInnerGaps)

    if numWindows == 1:
      let winId = col.windows[0]
      let winHeight =
        if col.isFullWidth:
          usableColHeight
        else:
          scaledWindowExtent(usableColHeight, windows.windowHeightProportion(winId))
      let currentY = screen.y + safeOuterGap + ((usableColHeight - winHeight) div 2)
      instructions.add(
        RenderInstruction(
          windowId: winId,
          geom: Rect(x: currentX, y: currentY, w: colWidth, h: winHeight),
        )
      )
      return instructions

    var totalHeightProp: float32 = 0.0
    for winId in col.windows:
      totalHeightProp += windows.windowHeightProportion(winId)
    if totalHeightProp <= 0:
      totalHeightProp = 1.0

    var currentY = screen.y + safeOuterGap
    for winId in col.windows:
      let winProp = windows.windowHeightProportion(winId)
      let winHeight =
        max(0'i32, int32(float32(usableColHeight) * (winProp / totalHeightProp)))

      instructions.add(
        RenderInstruction(
          windowId: winId,
          geom: Rect(x: currentX, y: currentY, w: colWidth, h: winHeight),
        )
      )
      currentY += winHeight + safeInnerGap

    return instructions

  # Calculate virtual positions and find focused column
  var virtualX: seq[int32] = @[]
  var totalVirtualWidth: int32 = 0
  var focusedColIdx = -1

  for i, col in tag.columns:
    if col.windows.contains(tag.focusedWindow):
      focusedColIdx = i

    let colWidth = scaledScrollAxisExtent(usableWidth, col.effectiveColumnProportion())
    virtualX.add(totalVirtualWidth)
    totalVirtualWidth += colWidth

  # Calculate target offset for centering
  if focusedColIdx != -1:
    let col = tag.columns[focusedColIdx]
    let colWidth = scaledScrollAxisExtent(usableWidth, col.effectiveColumnProportion())
    let colCenterX = virtualX[focusedColIdx] + (colWidth div 2)
    let screenCenterX = usableWidth div 2

    if focusCenter or centerMode == "always":
      tag.targetViewportXOffset = float32(colCenterX - screenCenterX)
    elif preferCenter or centerMode == "on-overflow":
      # Only center if the column is out of view
      let colLeft = virtualX[focusedColIdx] - int32(tag.targetViewportXOffset)
      let colRight = colLeft + colWidth
      if colLeft < 0 or colRight > usableWidth:
        tag.targetViewportXOffset = float32(colCenterX - screenCenterX)

  # Use current offset for rendering (interpolated in update.nim)
  let renderOffset = tag.currentViewportXOffset

  # Final coordinate mapping
  for i, col in tag.columns:
    let colWidth = max(
      0'i32,
      scaledScrollAxisExtent(usableWidth, col.effectiveColumnProportion()) - safeInnerGap,
    )
    let currentX = screen.x + safeOuterGap + virtualX[i] - int32(renderOffset)

    if col.windows.len == 0:
      continue

    let numWindows = col.windows.len
    let totalInnerGaps = int32(numWindows - 1) * safeInnerGap
    let usableColHeight = max(0'i32, usableHeight - totalInnerGaps)

    if numWindows == 1:
      let winId = col.windows[0]
      let winHeight =
        if col.isFullWidth:
          usableColHeight
        else:
          scaledWindowExtent(usableColHeight, windows.windowHeightProportion(winId))
      let currentY = screen.y + safeOuterGap + ((usableColHeight - winHeight) div 2)
      instructions.add(
        RenderInstruction(
          windowId: winId,
          geom: Rect(x: currentX, y: currentY, w: colWidth, h: winHeight),
        )
      )
      continue

    # Calculate sum of proportions for normalization
    var totalHeightProp: float32 = 0.0
    for winId in col.windows:
      totalHeightProp += windows.windowHeightProportion(winId)
    if totalHeightProp <= 0:
      totalHeightProp = 1.0

    var currentY = screen.y + safeOuterGap

    for winId in col.windows:
      # Vertical stacking within the column
      let winProp = windows.windowHeightProportion(winId)
      let winHeight =
        max(0'i32, int32(float32(usableColHeight) * (winProp / totalHeightProp)))

      instructions.add(
        RenderInstruction(
          windowId: winId,
          geom: Rect(x: currentX, y: currentY, w: colWidth, h: winHeight),
        )
      )

      currentY += winHeight + safeInnerGap

  return instructions

proc layoutVerticalScroller*(
    tag: var ProjectedTag,
    windows: Table[ProjectionWindowId, ProjectedWindow],
    screen: Rect,
    outerGap, innerGap: int32,
    focusCenter: bool,
    preferCenter: bool,
    centerMode: string,
): seq[RenderInstruction] =
  var instructions: seq[RenderInstruction] = @[]

  if tag.columns.len == 0:
    return instructions

  let safeOuterGap = max(0'i32, outerGap)
  let safeInnerGap = max(0'i32, innerGap)
  let usableWidth = max(0'i32, screen.w - 2 * safeOuterGap)
  let usableHeight = max(0'i32, screen.h - 2 * safeOuterGap)

  if tag.columns.len == 1 and tag.columns[0].scrollerSingleProportion > 0.0'f32:
    tag.targetViewportYOffset = 0.0'f32
    let col = tag.columns[0]
    if col.windows.len == 0:
      return instructions

    let colHeight = int32(
      float32(usableHeight) * clampProportion(col.effectiveSingleColumnProportion())
    )
    let currentY = screen.y + safeOuterGap + ((usableHeight - colHeight) div 2)
    let numWindows = col.windows.len
    let totalInnerGaps = int32(numWindows - 1) * safeInnerGap
    let usableColWidth = max(0'i32, usableWidth - totalInnerGaps)

    if numWindows == 1:
      let winId = col.windows[0]
      let winWidth =
        if col.isFullWidth:
          usableColWidth
        else:
          scaledWindowExtent(usableColWidth, windows.windowWidthProportion(winId))
      let currentX = screen.x + safeOuterGap + ((usableColWidth - winWidth) div 2)
      instructions.add(
        RenderInstruction(
          windowId: winId,
          geom: Rect(x: currentX, y: currentY, w: winWidth, h: colHeight),
        )
      )
      return instructions

    var totalWidthProp: float32 = 0.0
    for winId in col.windows:
      totalWidthProp += windows.windowWidthProportion(winId)
    if totalWidthProp <= 0:
      totalWidthProp = 1.0

    var currentX = screen.x + safeOuterGap
    for winId in col.windows:
      let winProp = windows.windowWidthProportion(winId)
      let winWidth =
        max(0'i32, int32(float32(usableColWidth) * (winProp / totalWidthProp)))

      instructions.add(
        RenderInstruction(
          windowId: winId,
          geom: Rect(x: currentX, y: currentY, w: winWidth, h: colHeight),
        )
      )
      currentX += winWidth + safeInnerGap

    return instructions

  # Calculate virtual positions and find focused column
  var virtualY: seq[int32] = @[]
  var totalVirtualHeight: int32 = 0
  var focusedColIdx = -1

  for i, col in tag.columns:
    if col.windows.contains(tag.focusedWindow):
      focusedColIdx = i

    let colHeight =
      scaledScrollAxisExtent(usableHeight, col.effectiveColumnProportion())
    virtualY.add(totalVirtualHeight)
    totalVirtualHeight += colHeight + safeInnerGap

  # Calculate target offset for centering
  if focusedColIdx != -1:
    let colHeight = int32(
      scaledScrollAxisExtent(
        usableHeight, tag.columns[focusedColIdx].effectiveColumnProportion()
      )
    )
    let colCenterY = virtualY[focusedColIdx] + (colHeight div 2)
    let screenCenterY = usableHeight div 2

    if focusCenter or centerMode == "always":
      tag.targetViewportYOffset = float32(colCenterY - screenCenterY)
    elif preferCenter or centerMode == "on-overflow":
      let colTop = virtualY[focusedColIdx] - int32(tag.targetViewportYOffset)
      let colBottom = colTop + colHeight
      if colTop < 0 or colBottom > usableHeight:
        tag.targetViewportYOffset = float32(colCenterY - screenCenterY)

  # Use current offset for rendering
  let renderOffset = tag.currentViewportYOffset

  # Final coordinate mapping
  for i, col in tag.columns:
    let colHeight = max(
      0'i32,
      scaledScrollAxisExtent(usableHeight, col.effectiveColumnProportion()) -
        safeInnerGap,
    )
    let currentY = screen.y + safeOuterGap + virtualY[i] - int32(renderOffset)

    if col.windows.len == 0:
      continue

    let numWindows = col.windows.len
    let totalInnerGaps = int32(numWindows - 1) * safeInnerGap
    let usableColWidth = max(0'i32, usableWidth - totalInnerGaps)

    if numWindows == 1:
      let winId = col.windows[0]
      let winWidth =
        if col.isFullWidth:
          usableColWidth
        else:
          scaledWindowExtent(usableColWidth, windows.windowWidthProportion(winId))
      let currentX = screen.x + safeOuterGap + ((usableColWidth - winWidth) div 2)
      instructions.add(
        RenderInstruction(
          windowId: winId,
          geom: Rect(x: currentX, y: currentY, w: winWidth, h: colHeight),
        )
      )
      continue

    # Calculate sum of proportions for normalization
    var totalWidthProp: float32 = 0.0
    for winId in col.windows:
      totalWidthProp += windows.windowWidthProportion(winId)
    if totalWidthProp <= 0:
      totalWidthProp = 1.0

    var currentX = screen.x + safeOuterGap

    for winId in col.windows:
      # Horizontal stacking within the row
      let winProp = windows.windowWidthProportion(winId)
      let winWidth =
        max(0'i32, int32(float32(usableColWidth) * (winProp / totalWidthProp)))

      instructions.add(
        RenderInstruction(
          windowId: winId,
          geom: Rect(x: currentX, y: currentY, w: winWidth, h: colHeight),
        )
      )

      currentX += winWidth + safeInnerGap

  return instructions
