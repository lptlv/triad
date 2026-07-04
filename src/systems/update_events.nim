import std/[json, options]
import ../core/[effects, msg]
import ../state/engine
from ../types/runtime_values import FrameTabContainerKind, PointerOpKind
import ../utils/behavior_log
import focus
import outputs
import recent_windows
import runtime
import update_effects
import window_lifecycle
import window_state

proc externallyFocusedTag(model: Model, winId: WindowId): TagId =
  if model.activeTag != NullTagId and
      model.placementForWindowOnTag(model.activeTag, winId).isSome:
    return model.activeTag

  for tagId, _ in model.tagsWithId():
    if model.tagVisibleOnOutput(tagId) and
        model.placementForWindowOnTag(tagId, winId).isSome:
      return tagId

  NullTagId

proc setExternalFocus(model: var Model, externalId: ExternalWindowId): bool =
  if model.overviewActive and externalId == NullExternalWindowId:
    return false
  if model.overviewActive:
    let winId = model.windowForExternal(externalId)
    if winId == NullWindowId or model.overviewWindowIds().find(winId) == -1:
      return false
    discard model.setOverviewActive(false)
    discard model.setOverviewWorkspacePreviewsActive(false)
    discard model.clearOverviewSelection()
    return model.focusWindow(winId, restorePopupTree = false)
  let tagId = model.activeTag
  let tagOpt = model.tagData(tagId)
  if tagOpt.isNone:
    return false
  if externalId == NullExternalWindowId:
    return model.setTagFocus(tagId, NullWindowId)
  let winId = model.windowForExternal(externalId)
  if winId == NullWindowId:
    return false
  let focusedTag = model.externallyFocusedTag(winId)
  if focusedTag == NullTagId:
    return false
  if focusedTag != tagId:
    discard model.setActiveWorkspace(focusedTag)
  model.focusWindow(winId, restorePopupTree = false)

proc focusClickedFrameTab(
    model: var Model,
    containerKind: FrameTabContainerKind,
    containerId: uint32,
    windowId: uint32,
    tabIndex: int,
): bool =
  if model.overviewActive:
    writeBehaviorEvent(
      "frame_tab_click_noop",
      %*{"reason": "overview_active", "target_window_id": windowId},
    )
    return false
  let beforeTag = model.activeTag
  let beforeFocus =
    if beforeTag != NullTagId and model.tagData(beforeTag).isSome:
      model.runtimeWindowId(model.tagData(beforeTag).get().focusedWindow)
    else:
      0'u32
  let clicked = model.windowForExternal(ExternalWindowId(windowId))
  if clicked == NullWindowId:
    writeBehaviorEvent(
      "frame_tab_click_noop",
      %*{
        "reason": "unknown_window",
        "container_kind": $containerKind,
        "container_id": containerId,
        "target_window_id": windowId,
        "tab_index": tabIndex,
      },
    )
    return false
  case containerKind
  of FrameTabContainerKind.FrameTree:
    result = model.focusFrameTabWindow(FrameId(containerId), clicked)
  of FrameTabContainerKind.SplitTree:
    result = model.focusSplitTreeTabWindow(SplitNodeId(containerId), clicked)
  if not result:
    writeBehaviorEvent(
      "frame_tab_click_noop",
      %*{
        "reason": "stale_container_or_window",
        "container_kind": $containerKind,
        "container_id": containerId,
        "target_window_id": windowId,
        "tab_index": tabIndex,
      },
    )
    return false
  result = model.focusWindow(clicked, restorePopupTree = false) or result
  let afterTag = model.activeTag
  let afterFocus =
    if afterTag != NullTagId and model.tagData(afterTag).isSome:
      model.runtimeWindowId(model.tagData(afterTag).get().focusedWindow)
    else:
      0'u32
  writeBehaviorEvent(
    "frame_tab_click_reducer",
    %*{
      "container_kind": $containerKind,
      "container_id": containerId,
      "target_window_id": windowId,
      "target_logical_window_id": uint32(clicked),
      "tab_index": tabIndex,
      "before_tag": uint32(beforeTag),
      "after_tag": uint32(afterTag),
      "before_focus": beforeFocus,
      "after_focus": afterFocus,
      "dirty": result,
    },
  )

proc applyEvent*(model: var Model, msg: Msg): UpdateStep =
  case msg.kind
  of MsgKind.ManageStart:
    let scratchpad = model.activeScratchpadWindow()
    let focused =
      if scratchpad != NullWindowId:
        scratchpad
      else:
        model.focusedOnActiveTag()
    if focused != NullWindowId:
      let workspaceChanged = model.recordWorkspace(model.activeTag)
      let focusChanged = model.recordFocus(focused)
      let externalId = model.runtimeWindowId(focused)
      let shouldReassertFocus =
        scratchpad != NullWindowId or workspaceChanged or focusChanged
      if shouldReassertFocus:
        if not model.sessionLocked and not model.layerFocusExclusive:
          result.effects.add(
            Effect(kind: EffectKind.EffFocusWindow, focusId: externalId)
          )
      result.dirty = workspaceChanged or focusChanged
  of MsgKind.OutputDimensions:
    result.dirty = model.setOutputDimensionsForExternal(
      msg.outputId.externalOutputId(), msg.width, msg.height
    )
  of MsgKind.OutputName:
    result.dirty = model.setOutputNameForExternal(
      msg.nameOutputId.externalOutputId(), msg.outputName
    )
  of MsgKind.OutputIdentity:
    result.dirty = model.setOutputIdentityForExternal(
      msg.identityOutputId.externalOutputId(), msg.outputMake, msg.outputModel
    )
  of MsgKind.OutputDescription:
    result.dirty = model.setOutputDescriptionForExternal(
      msg.descriptionOutputId.externalOutputId(), msg.outputDescription
    )
  of MsgKind.OutputPosition:
    result.dirty = model.setOutputPositionForExternal(
      msg.positionOutputId.externalOutputId(), msg.outputX, msg.outputY
    )
  of MsgKind.OutputRefreshRate:
    result.dirty = model.setOutputRefreshRateForExternal(
      msg.refreshOutputId.externalOutputId(), msg.outputRefreshRate
    )
  of MsgKind.OutputPhysicalMetadata:
    result.dirty = model.setOutputPhysicalMetadataForExternal(
      msg.metadataOutputId.externalOutputId(),
      msg.outputPhysicalWidth,
      msg.outputPhysicalHeight,
      msg.outputTransform,
    )
  of MsgKind.OutputScale:
    result.dirty = model.setOutputScaleForExternal(
      msg.scaleOutputId.externalOutputId(), msg.outputScale
    )
  of MsgKind.OutputUsable:
    result.dirty = model.setOutputUsableForExternal(
      msg.usableOutputId.externalOutputId(),
      msg.usableX,
      msg.usableY,
      msg.usableW,
      msg.usableH,
    )
  of MsgKind.OutputRemoved:
    for winId in model.removeOutputForExternal(msg.removedOutputId.externalOutputId()):
      result.dirty = true
  of MsgKind.WindowCreated:
    let winId = model.createWindowForExternal(
      msg.windowId.externalWindowId(),
      msg.appId,
      msg.title,
      msg.createdIdentifier,
      msg.createdPid,
      msg.createdParentWindowId.externalWindowId(),
      msg.createdSwallowHostWindowId.externalWindowId(),
      msg.deferAdmission,
      msg.spawnContextOutputId,
      msg.spawnContextSlot,
      msg.createdHasParentedRoleHint,
      msg.createdParentedRoleHint,
    )
    result.dirty = winId != NullWindowId
  of MsgKind.WindowDestroyed:
    result.dirty = model.destroyWindowForExternal(msg.destroyedId.externalWindowId())
  of MsgKind.WindowDimensions:
    if model.recentWindowsActive or model.overviewActive:
      result.dirty = false
    else:
      result.dirty = model.updateWindowDimensionsForExternal(
        msg.dimensionsWindowId.externalWindowId(), msg.actualWidth, msg.actualHeight
      )
  of MsgKind.WindowDecorationHint:
    result.dirty = model.updateWindowDecorationHintForExternal(
      msg.decorationWindowId.externalWindowId(), msg.decorationHint
    )
  of MsgKind.WindowPresentationHint:
    result.dirty = model.updateWindowPresentationHintForExternal(
      msg.presentationWindowId.externalWindowId(), msg.presentationHint
    )
  of MsgKind.WindowParentedRoleHint:
    result.dirty = model.updateWindowParentedRoleHintForExternal(
      msg.parentedRoleWindowId.externalWindowId(), msg.parentedRoleHint
    )
  of MsgKind.WindowParent:
    result.dirty = model.updateWindowParentForExternal(
      msg.childWindowId.externalWindowId(), msg.parentWindowId.externalWindowId()
    )
  of MsgKind.WindowIdentifier:
    let externalId = msg.identifierWindowId.externalWindowId()
    result.dirty =
      model.updateWindowIdentifierAndRestoreForExternal(externalId, msg.identifier)
  of MsgKind.WindowPid:
    result.dirty = model.updateWindowPidForExternal(
      msg.pidWindowId.externalWindowId(), msg.windowPid
    )
  of MsgKind.WindowAppId:
    result.dirty = model.updateWindowAppIdForExternal(
      msg.appIdWindowId.externalWindowId(), msg.updatedAppId
    )
  of MsgKind.WindowTitle:
    let titleUpdate = model.updateWindowTitleForExternalDetailed(
      msg.titleWindowId.externalWindowId(), msg.updatedTitle
    )
    result.dirty = titleUpdate.dirty
    if titleUpdate.manageDirty:
      result.effects.add(Effect(kind: EffectKind.EffManageDirty))
  of MsgKind.WindowDimensionsHint:
    result.dirty = model.updateWindowDimensionsHintForExternal(
      msg.hintWindowId.externalWindowId(),
      msg.minWidth,
      msg.minHeight,
      msg.maxWidth,
      msg.maxHeight,
    )
  of MsgKind.WindowMenuRequested:
    if model.windowMenuCommand.len > 0 and
        model.windowForExternal(msg.menuWindowId.externalWindowId()) != NullWindowId:
      result.effects.add(
        Effect(
          kind: EffectKind.EffSpawnWindowMenu,
          windowMenuCommand: model.windowMenuCommand,
          windowMenuId: msg.menuWindowId,
          windowMenuX: msg.menuX,
          windowMenuY: msg.menuY,
        )
      )
  of MsgKind.ShellSurfaceInteraction:
    if msg.shellSurfaceId != 0 and not model.sessionLocked and
        not model.layerFocusExclusive:
      result.effects.add(
        Effect(
          kind: EffectKind.EffFocusShellSurface, focusShellSurfaceId: msg.shellSurfaceId
        )
      )
    if model.hotkeyOverlayOpen:
      result.dirty = model.setHotkeyOverlayOpen(false)
  of MsgKind.FrameTabClicked:
    result.dirty = model.focusClickedFrameTab(
      msg.frameClickContainerKind, msg.frameClickContainerId, msg.frameClickWindowId,
      msg.frameClickTabIndex,
    )
  of MsgKind.FrameEmptyFocused:
    result.dirty =
      not model.overviewActive and model.focusFrameOnly(FrameId(msg.frameFocusFrameId))
  of MsgKind.ModifiersChanged:
    discard model.setActiveModifiers(msg.newModifiers)
    if model.overviewTabModeActive and
        (msg.newModifiers and model.overviewTabModeModifiers) !=
        model.overviewTabModeModifiers:
      result.dirty = model.closeOverviewMode() or result.dirty
    if model.recentWindowsActive and msg.newModifiers == 0:
      let selected = model.confirmedRecentWindow()
      result.dirty = selected != NullWindowId
      if selected != NullWindowId:
        result.dirty = model.focusWindow(selected) or result.dirty
  of MsgKind.LayerFocusExclusive:
    result.dirty = model.setLayerFocusExclusive(true)
  of MsgKind.LayerFocusNonExclusive, MsgKind.LayerFocusNone:
    result.dirty = model.setLayerFocusExclusive(false)
  of MsgKind.SessionLocked:
    result.dirty = model.setSessionLocked(true)
    result.dirty = model.setExitSessionConfirmOpen(false) or result.dirty
  of MsgKind.SessionUnlocked:
    result.dirty = model.setSessionLocked(false)
    result.dirty = model.setLayerFocusExclusive(false) or result.dirty
    let focused = model.focusedOnActiveTag()
    if focused != NullWindowId:
      let externalId = model.runtimeWindowId(focused)
      result.effects.add(Effect(kind: EffectKind.EffFocusWindow, focusId: externalId))
  of MsgKind.PointerMoveRequested:
    if model.beginPointerMove(msg.moveWinId.externalWindowId()):
      result.effects.add(
        Effect(kind: EffectKind.EffOpStartPointer, opSeat: msg.moveSeat)
      )
  of MsgKind.PointerResizeRequested:
    if model.beginPointerResize(msg.resizeWinId.externalWindowId(), msg.resizeEdges):
      result.effects.add(
        Effect(
          kind: EffectKind.EffInformResizeStart, resizeLifecycleWinId: msg.resizeWinId
        )
      )
      result.effects.add(
        Effect(kind: EffectKind.EffOpStartPointer, opSeat: msg.resizeSeat)
      )
  of MsgKind.OverviewPointerDragRequested:
    if model.beginOverviewDrag(
      msg.overviewDragWinId.externalWindowId(), msg.overviewDragX, msg.overviewDragY
    ):
      result.dirty = true
      result.effects.add(
        Effect(kind: EffectKind.EffOpStartPointer, opSeat: msg.overviewDragSeat)
      )
  of MsgKind.OverviewPointerScrollRequested:
    if model.beginOverviewScroll(msg.overviewScrollX, msg.overviewScrollY):
      result.dirty = true
      result.effects.add(
        Effect(kind: EffectKind.EffOpStartPointer, opSeat: msg.overviewScrollSeat)
      )
  of MsgKind.OverviewWheel:
    result.dirty = model.handleOverviewWheel(
      msg.overviewWheelX, msg.overviewWheelY, msg.overviewWheelHorizontal,
      msg.overviewWheelVertical,
    )
  of MsgKind.RecentWindowPointerMotion:
    result.dirty = model.selectRecentWindowAt(msg.recentPointerX, msg.recentPointerY)
  of MsgKind.PointerDelta:
    result.dirty = model.applyPointerDelta(msg.dx, msg.dy)
  of MsgKind.PointerRelease:
    result.dirty = model.pointerOp.kind != PointerOpKind.OpNone
    let resized = model.finishPointerOp()
    if resized != NullWindowId:
      result.effects.add(
        Effect(
          kind: EffectKind.EffInformResizeEnd,
          resizeLifecycleWinId: model.runtimeWindowId(resized),
        )
      )
  of MsgKind.FocusChanged:
    result.dirty = model.setExternalFocus(msg.newFocusedId.externalWindowId())
  of MsgKind.WindowFullscreenRequested:
    result.dirty = model.requestFullscreenForExternal(
      msg.fullscreenRequestId.externalWindowId(),
      msg.fullscreenOutputId.externalOutputId(),
    )
    if result.dirty:
      discard
  of MsgKind.WindowExitFullscreenRequested:
    result.dirty =
      model.exitFullscreenForExternal(msg.exitFullscreenRequestId.externalWindowId())
  of MsgKind.WindowMaximizeRequested:
    result.dirty =
      model.requestMaximizeForExternal(msg.maximizeRequestId.externalWindowId())
  of MsgKind.WindowUnmaximizeRequested:
    result.dirty =
      model.requestUnmaximizeForExternal(msg.unmaximizeRequestId.externalWindowId())
  of MsgKind.WindowMinimizeRequested:
    result.dirty =
      model.requestMinimizeForExternal(msg.minimizeRequestId.externalWindowId())
  of MsgKind.WindowStateChanged:
    result.dirty = model.updateWindowStateForExternal(
      msg.stateWindowId.externalWindowId(),
      msg.stateFullscreen,
      msg.stateMaximized,
      msg.stateMinimized,
      msg.stateUrgent,
    )
  of MsgKind.WindowAdmissionSettled:
    result.dirty =
      model.settleWindowAdmissionForExternal(msg.admissionWindowId.externalWindowId())
  else:
    discard
