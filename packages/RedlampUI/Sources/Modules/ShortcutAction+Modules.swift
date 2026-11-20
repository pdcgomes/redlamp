extension ShortcutAction {
    /// What acts on Develop's canvas, tools or edit, which the Library module leaves alone: the photo isn't
    /// on screen there, so nothing would show what changed. Develop's tools (D, R, Q, ⇧W) aren't among them:
    /// from Library they open the active photo in Develop with the tool. Z is the loupe's in Library, and
    /// Undo and Redo take back and make again the newest change of either module (`EditorModel+LibraryUndo`).
    var isDevelopOnly: Bool {
        switch self {
        case .beforeAfter, .nextCompareLayout, .previousCompareLayout, .zoomIn, .zoomOut, .clipping,
             .rawClipping, .colorAssessment, .labReadout, .infoOverlay,
             .panelBasic, .panelToneCurve, .panelColorMixer, .panelColorGrading, .panelDetail, .panelLens,
             .panelTransform, .panelEffects, .panelCalibration,
             .resetAll, .autoTone, .autoWhiteBalance, .toggleBlackAndWhite, .whiteBalanceSelector,
             .calibrateFromTarget, .newSnapshot, .newPreset, .createVersion, .previousSetting, .nextSetting,
             .increaseSetting, .decreaseSetting, .findAdjustment,
             .cropAspectLock, .rotateLeft, .rotateRight,
             .brushMask, .linearMask, .radialMask, .colorRangeMask, .luminanceRangeMask, .depthRangeMask,
             .maskOverlay, .maskOverlayColor, .maskPins, .deleteMask, .maskPanelMasks, .maskPanelMask,
             .maskPanelAdjustments:
            true
        default:
            false
        }
    }

    /// The Library grid's, on keys Develop gives other meanings: J cycles the cell style where Develop
    /// shows clipping, = and - size the thumbnails where Develop steps the selected setting, \ shows
    /// the filter bar where Develop shows Before / After, ⌘N makes a collection where Develop makes a
    /// snapshot, ⌫ takes photos out of a collection where Develop deletes a mask, ⇧[ and ⇧] move a
    /// photo in its stack where Develop steps the rating and advances, or feathers a brush, and ↓ and ↑ are
    /// Compare's Swap and Make Select, which Develop leaves to the control that has the keyboard.
    var isLibraryOnly: Bool {
        switch self {
        case .cycleGridStyle, .largerThumbnails, .smallerThumbnails, .toggleFilterBar, .newCollection,
             .removeFromCollection, .moveUpInStack, .moveDownInStack, .swapCompared, .makeSelect: true
        default: false
        }
    }
}
