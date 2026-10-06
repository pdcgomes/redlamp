extension ShortcutAction {
    /// What acts on Develop's canvas, tools or edit, which the Library module leaves alone: the photo isn't
    /// on screen there, so nothing would show what changed. Develop's tools (D, R, Q, ⇧W) aren't among them:
    /// from Library they open the active photo in Develop with the tool.
    var isDevelopOnly: Bool {
        switch self {
        case .beforeAfter, .nextCompareLayout, .previousCompareLayout, .toggleZoom, .zoomIn, .zoomOut, .clipping,
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
}
