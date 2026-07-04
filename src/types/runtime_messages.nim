import runtime_values

type
  ScreenshotKind* {.pure.} = enum
    ShotRegion
    ShotScreen
    ShotWindow

  ScreenshotPointerMode* {.pure.} = enum
    PointerDefault
    PointerShow
    PointerHide

  MsgKind* {.pure.} = enum
    # Backend Events
    WindowCreated
    WindowDestroyed
    FocusChanged
    WindowFullscreenRequested
    WindowExitFullscreenRequested
    WindowParent
    WindowIdentifier
    WindowPid
    WindowAppId
    WindowTitle
    WindowDimensionsHint
    WindowDimensions
    WindowDecorationHint
    WindowPresentationHint
    WindowMenuRequested
    WindowMaximizeRequested
    WindowUnmaximizeRequested
    WindowMinimizeRequested
    WindowStateChanged
    WindowAdmissionSettled
    LayerFocusExclusive
    LayerFocusNonExclusive
    LayerFocusNone
    SessionLocked
    SessionUnlocked
    OutputDimensions
    OutputName
    OutputIdentity
    OutputDescription
    OutputPosition
    OutputRefreshRate
    OutputPhysicalMetadata
    OutputScale
    OutputUsable
    OutputRemoved
    ManageStart
    RenderStart
    PointerMoveRequested
    PointerResizeRequested
    OverviewPointerDragRequested
    OverviewPointerScrollRequested
    OverviewWheel
    RecentWindowPointerMotion
    PointerDelta
    PointerRelease
    ShellSurfaceInteraction
    FrameTabClicked
    FrameEmptyFocused
    ModifiersChanged

    # User Commands (IPC/Keybinds)
    CmdSetLayout
    CmdSetCustomLayout
    CmdSetNativeLayout
    CmdFrameSplitHorizontal
    CmdFrameSplitVertical
    CmdFrameUnsplit
    CmdFrameTabNext
    CmdFrameTabPrev
    CmdFrameResizeLeft
    CmdFrameResizeRight
    CmdFrameResizeUp
    CmdFrameResizeDown
    CmdFrameSplitToggle
    CmdFrameFocusParent
    CmdFrameFocusChild
    CmdFrameBindApp
    CmdFrameUnbindApp
    CmdSplitTreeSplitHorizontal
    CmdSplitTreeSplitVertical
    CmdSplitTreeSplitToggle
    CmdSplitTreeLayoutSplitHorizontal
    CmdSplitTreeLayoutSplitVertical
    CmdSplitTreeLayoutToggleSplit
    CmdSplitTreeLayoutStacking
    CmdSplitTreeLayoutTabbed
    CmdSplitTreeFocusParent
    CmdSplitTreeFocusChild
    CmdSplitTreeLayoutCycleAll
    CmdSplitTreeLayoutDefault
    CmdSplitTreeLayoutCycleList
    CmdSplitTreeFocusNextSibling
    CmdSplitTreeFocusPrevSibling
    CmdBspBalance
    CmdBspEqualize
    CmdBspPreselect
    CmdBspPreselectCancel
    CmdBspPreselectRatio
    CmdFocusNext
    CmdFocusPrev
    CmdFocusDirection
    CmdFocusLast
    CmdFocusTagLeft
    CmdFocusTagRight
    CmdFocusOccupiedTagLeft
    CmdFocusOccupiedTagRight
    CmdFocusColumnFirst
    CmdFocusColumnLast
    CmdFocusWindowOrWorkspaceUp
    CmdFocusWindowOrWorkspaceDown
    CmdMoveToTagLeft
    CmdMoveToTagRight
    CmdCloseWindow
    CmdMoveWindow
    CmdMoveWindowLeft
    CmdMoveWindowRight
    CmdMoveWindowUp
    CmdMoveWindowDown
    CmdMoveWindowUpOrToWorkspaceUp
    CmdMoveWindowDownOrToWorkspaceDown
    CmdMoveColumnLeft
    CmdMoveColumnRight
    CmdMoveColumnToFirst
    CmdMoveColumnToLast
    CmdSwapWindowUp
    CmdSwapWindowDown
    CmdConsumeWindow
    CmdExpelWindow
    CmdZoom
    CmdToggleGaps
    CmdMoveFloating
    CmdMoveToTag
    CmdMoveWindowToTag
    CmdSwapWindowToTag
    CmdRenameTag
    CmdGroupWindows
    CmdUngroupWindow
    CmdFocusNextInGroup
    CmdSetMasterCount
    CmdSetMasterRatio
    CmdAdjustMasterCount
    CmdAdjustMasterRatio
    CmdMaximizeColumn
    CmdResizeWidth
    CmdResizeHeight
    CmdSetColumnWidth
    CmdSwitchProportionPreset
    CmdAdjustGaps
    CmdToggleGapsRel # Unused
    CmdMoveToScratchpad
    CmdMoveToNamedScratchpad
    CmdToggleScratchpad
    CmdToggleNamedScratchpad
    CmdRestoreScratchpad
    CmdToggleOverview
    CmdOpenOverview
    CmdCloseOverview
    CmdOverviewTab
    CmdRecentWindowNext
    CmdRecentWindowPrev
    CmdRecentWindowConfirm
    CmdRecentWindowCancel
    CmdRecentWindowFirst
    CmdRecentWindowLast
    CmdRecentWindowScope
    CmdRecentWindowCycleScope
    CmdRecentWindowCloseCurrent
    CmdToggleFloating
    CmdSetWindowFloatingById
    CmdSetWindowMaximizedById
    CmdToggleMaximizedById
    CmdToggleFullscreen
    CmdSetWindowFullscreenById
    CmdToggleFullscreenById
    CmdExitFullscreenById
    CmdToggleMaximized
    CmdMinimize
    CmdResizeFloating
    CmdSelectWindow
    CmdFocusTag
    CmdNewWorkspace
    CmdFocusWorkspaceIndex
    CmdReorderWorkspaceIndex
    CmdMoveToWorkspaceIndex
    CmdMoveWindowToWorkspaceIndex
    CmdFocusOutput
    CmdMoveWorkspaceToOutput
    CmdMoveToOutput
    CmdFocusWindowById
    CmdCloseWindowById
    CmdSpawn
    CmdSpawnTerminal
    CmdLockSession
    CmdPowerOffMonitors
    CmdPowerOnMonitors
    CmdPowerOffMonitor
    CmdPowerOnMonitor
    CmdWarpPointer
    CmdEatNextKey
    CmdCancelEatNextKey
    CmdSwitchKeyboardLayout
    CmdToggleKeyboardShortcutsInhibit
    CmdStopManager
    CmdExitSession
    CmdExitSessionImmediate
    CmdConfirmExitSession
    CmdDismissExitSessionConfirm
    CmdFocusShellUi
    CmdSwitchShell
    CmdCycleShell
    CmdShowHotkeyOverlay
    CmdHideHotkeyOverlay
    CmdToggleHotkeyOverlay
    CmdTick
    CmdExpireStartupWindowRules
    CmdConfigReload
    CmdTriadReload
    CmdSwitchLayout
    CmdScreenshot

  Msg* = object
    case kind*: MsgKind
    of MsgKind.WindowCreated:
      windowId*: uint32
      createdParentWindowId*: uint32
      createdSwallowHostWindowId*: uint32
      createdPid*: int32
      appId*: string
      title*: string
      createdIdentifier*: string
      deferAdmission*: bool
      spawnContextOutputId*: uint32
      spawnContextSlot*: uint32
    of MsgKind.WindowDestroyed:
      destroyedId*: uint32
    of MsgKind.FocusChanged:
      newFocusedId*: uint32
    of MsgKind.WindowFullscreenRequested:
      fullscreenRequestId*: uint32
      fullscreenOutputId*: uint32
    of MsgKind.WindowExitFullscreenRequested:
      exitFullscreenRequestId*: uint32
    of MsgKind.WindowParent:
      childWindowId*: uint32
      parentWindowId*: uint32
    of MsgKind.WindowIdentifier:
      identifierWindowId*: uint32
      identifier*: string
    of MsgKind.WindowPid:
      pidWindowId*: uint32
      windowPid*: int32
    of MsgKind.WindowAppId:
      appIdWindowId*: uint32
      updatedAppId*: string
    of MsgKind.WindowTitle:
      titleWindowId*: uint32
      updatedTitle*: string
    of MsgKind.WindowDimensionsHint:
      hintWindowId*: uint32
      minWidth*, minHeight*, maxWidth*, maxHeight*: int32
    of MsgKind.WindowDimensions:
      dimensionsWindowId*: uint32
      actualWidth*, actualHeight*: int32
    of MsgKind.WindowDecorationHint:
      decorationWindowId*: uint32
      decorationHint*: uint32
    of MsgKind.WindowPresentationHint:
      presentationWindowId*: uint32
      presentationHint*: uint32
    of MsgKind.WindowMenuRequested:
      menuWindowId*: uint32
      menuX*: int32
      menuY*: int32
    of MsgKind.WindowMaximizeRequested:
      maximizeRequestId*: uint32
    of MsgKind.WindowUnmaximizeRequested:
      unmaximizeRequestId*: uint32
    of MsgKind.WindowMinimizeRequested:
      minimizeRequestId*: uint32
    of MsgKind.WindowStateChanged:
      stateWindowId*: uint32
      stateFullscreen*: bool
      stateMaximized*: bool
      stateMinimized*: bool
      stateUrgent*: bool
    of MsgKind.WindowAdmissionSettled:
      admissionWindowId*: uint32
    of MsgKind.OutputDimensions:
      outputId*: uint32
      width*: int32
      height*: int32
    of MsgKind.OutputName:
      nameOutputId*: uint32
      outputName*: string
    of MsgKind.OutputIdentity:
      identityOutputId*: uint32
      outputMake*: string
      outputModel*: string
    of MsgKind.OutputDescription:
      descriptionOutputId*: uint32
      outputDescription*: string
    of MsgKind.OutputPosition:
      positionOutputId*: uint32
      outputX*: int32
      outputY*: int32
    of MsgKind.OutputRefreshRate:
      refreshOutputId*: uint32
      outputRefreshRate*: int32
    of MsgKind.OutputPhysicalMetadata:
      metadataOutputId*: uint32
      outputPhysicalWidth*: int32
      outputPhysicalHeight*: int32
      outputTransform*: int32
    of MsgKind.OutputScale:
      scaleOutputId*: uint32
      outputScale*: float32
    of MsgKind.OutputUsable:
      usableOutputId*: uint32
      usableX*: int32
      usableY*: int32
      usableW*: int32
      usableH*: int32
    of MsgKind.OutputRemoved:
      removedOutputId*: uint32
    of MsgKind.PointerMoveRequested:
      moveWinId*: uint32
      moveSeat*: pointer # ptr RiverSeatV1
    of MsgKind.PointerResizeRequested:
      resizeWinId*: uint32
      resizeSeat*: pointer # ptr RiverSeatV1
      resizeEdges*: uint32
    of MsgKind.OverviewPointerDragRequested:
      overviewDragWinId*: uint32
      overviewDragSeat*: pointer # ptr RiverSeatV1
      overviewDragX*, overviewDragY*: int32
    of MsgKind.OverviewPointerScrollRequested:
      overviewScrollSeat*: pointer # ptr RiverSeatV1
      overviewScrollX*, overviewScrollY*: int32
    of MsgKind.OverviewWheel:
      overviewWheelX*, overviewWheelY*: int32
      overviewWheelHorizontal*, overviewWheelVertical*: int32
    of MsgKind.RecentWindowPointerMotion:
      recentPointerX*, recentPointerY*: int32
    of MsgKind.PointerDelta:
      dx*, dy*: int32
    of MsgKind.ShellSurfaceInteraction:
      shellSurfaceId*: uint32
    of MsgKind.FrameTabClicked:
      frameClickContainerKind*: FrameTabContainerKind
      frameClickContainerId*: uint32
      frameClickWindowId*: uint32
      frameClickTabIndex*: int
    of MsgKind.FrameEmptyFocused:
      frameFocusFrameId*: uint32
    of MsgKind.ModifiersChanged:
      oldModifiers*: uint32
      newModifiers*: uint32
    of MsgKind.CmdOverviewTab:
      overviewTabModifiers*: uint32
    of MsgKind.CmdMoveFloating:
      moveDX*, moveDY*: int32
    of MsgKind.CmdSetLayout:
      newLayout*: LayoutMode
      layoutTargetTag*: uint32
    of MsgKind.CmdSetCustomLayout:
      customLayout*: JanetLayoutId
      customLayoutTargetTag*: uint32
    of MsgKind.CmdSetNativeLayout:
      nativeLayout*: NativeLayoutId
      nativeLayoutTargetTag*: uint32
    of MsgKind.CmdFocusDirection:
      direction*: Direction
    of MsgKind.CmdSplitTreeLayoutCycleList:
      cycleModes*: seq[SplitTreeNodeMode]
    of MsgKind.CmdFrameResizeLeft, MsgKind.CmdFrameResizeRight,
        MsgKind.CmdFrameResizeUp, MsgKind.CmdFrameResizeDown:
      frameResizeDelta*: float32
    of MsgKind.CmdBspPreselect:
      bspPreselectDirection*: Direction
    of MsgKind.CmdBspPreselectRatio:
      bspPreselectRatio*: float32
    of MsgKind.CmdRecentWindowNext, MsgKind.CmdRecentWindowPrev:
      recentScope*: RecentWindowScope
      recentScopeSet*: bool
      recentFilter*: RecentWindowFilter
      recentFilterSet*: bool
    of MsgKind.CmdRecentWindowScope:
      recentTargetScope*: RecentWindowScope
    of MsgKind.CmdMoveToTag:
      targetTag*: uint32
    of MsgKind.CmdMoveWindowToTag:
      moveWindowId*: uint32
      moveTargetTag*: uint32
      moveFollowWindow*: bool
    of MsgKind.CmdSwapWindowToTag:
      targetTagSwap*: uint32
    of MsgKind.CmdRenameTag:
      newName*: string
    of MsgKind.CmdSwitchShell:
      shellName*: string
    of MsgKind.CmdMoveToNamedScratchpad, MsgKind.CmdToggleNamedScratchpad:
      scratchpadName*: string
    of MsgKind.CmdSetMasterCount:
      count*: int
    of MsgKind.CmdSetMasterRatio:
      ratio*: float32
    of MsgKind.CmdAdjustMasterCount:
      deltaMC*: int
    of MsgKind.CmdAdjustMasterRatio:
      deltaMR*: float32
    of MsgKind.CmdResizeWidth:
      deltaW*: float32
    of MsgKind.CmdResizeHeight:
      deltaH*: float32
    of MsgKind.CmdSetColumnWidth:
      targetWidth*: float32
    of MsgKind.CmdSwitchProportionPreset:
      proportionPresetDelta*: int
    of MsgKind.CmdAdjustGaps:
      deltaG*: int32
    of MsgKind.CmdResizeFloating:
      deltaFW*, deltaFH*: int32
    of MsgKind.CmdFocusTag:
      focusTag*: uint32
    of MsgKind.CmdFocusWorkspaceIndex, MsgKind.CmdMoveToWorkspaceIndex:
      workspaceIndex*: uint32
    of MsgKind.CmdReorderWorkspaceIndex:
      reorderWorkspaceIndex*: uint32
      reorderTargetIndex*: uint32
    of MsgKind.CmdMoveWindowToWorkspaceIndex:
      moveWorkspaceWindowId*: uint32
      moveWorkspaceIndex*: uint32
      moveWorkspaceFollowWindow*: bool
    of MsgKind.CmdFocusOutput, MsgKind.CmdMoveWorkspaceToOutput,
        MsgKind.CmdMoveToOutput, MsgKind.CmdPowerOffMonitor, MsgKind.CmdPowerOnMonitor:
      outputTarget*: string
    of MsgKind.CmdFocusWindowById:
      focusWindowId*: uint32
    of MsgKind.CmdSetWindowFloatingById:
      floatingWindowId*: uint32
      windowFloating*: bool
    of MsgKind.CmdSetWindowMaximizedById, MsgKind.CmdToggleMaximizedById:
      maximizedWindowId*: uint32
      windowMaximized*: bool
    of MsgKind.CmdCloseWindowById:
      closeWindowId*: uint32
    of MsgKind.CmdSetWindowFullscreenById, MsgKind.CmdToggleFullscreenById,
        MsgKind.CmdExitFullscreenById:
      fullscreenWindowId*: uint32
      windowFullscreen*: bool
    of MsgKind.CmdSpawn:
      spawnCommand*: seq[string]
    of MsgKind.CmdWarpPointer:
      warpX*, warpY*: int32
    of MsgKind.CmdSwitchKeyboardLayout:
      keyboardLayoutDelta*: int32
      keyboardLayoutIndex*: int32
    of MsgKind.CmdTick:
      tickElapsedMs*: int32
    of MsgKind.CmdScreenshot:
      screenshotKind*: ScreenshotKind
      screenshotPath*: string
      screenshotPointerMode*: ScreenshotPointerMode
      screenshotWriteToDisk*: bool
      screenshotCopyToClipboard*: bool
    else:
      discard
