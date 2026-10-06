extension ShortcutAction {
    /// What acts on Develop's canvas, tools or edit, which the Library module leaves alone: the photo isn't
    /// on screen there, so nothing would show what changed. Develop's tools (D, R, Q, ⇧W) aren't among them:
    /// from Library they open the active photo in Develop with the tool. Z is the loupe's in Library.
    var isDevelopOnly: Bool {
        switch self {
        case .beforeAfter, .nextCompareLayout, .previousCompareLayout, .zoomIn, .zoomOut, .clipping,
             .rawClipping, .colorAssessment, .infoOverlay,
             .panelBasic, .panelToneCurve, .panelColorMixer, .panelColorGrading, .panelDetail, .panelLens,
             .panelTransform, .panelEffects, .panelCalibration,
             .undo, .redo, .resetAll, .autoTone, .autoWhiteBalance, .toggleBlackAndWhite, .whiteBalanceSelector,
             .newSnapshot, .newPreset, .virtualCopy, .previousSetting, .nextSetting, .increaseSetting,
             .decreaseSetting, .findAdjustment,
             .cropAspectLock, .rotateLeft, .rotateRight,
             .brushMask, .linearMask, .radialMask, .colorRangeMask, .luminanceRangeMask, .depthRangeMask,
             .maskOverlay, .maskOverlayColor, .maskPins, .deleteMask:
            true
        default:
            false
        }
    }

    /// The Library grid's, on keys Develop gives other meanings: J cycles the cell style where Develop
    /// shows clipping, and = and - size the thumbnails where Develop steps the selected setting.
    var isLibraryOnly: Bool {
        switch self {
        case .cycleGridStyle, .largerThumbnails, .smallerThumbnails: true
        default: false
        }
    }
}
