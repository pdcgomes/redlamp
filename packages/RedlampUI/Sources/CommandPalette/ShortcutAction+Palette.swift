import RedlampEngineAPI

/// How actions appear in the command palette: their symbols and the words that find them.
extension ShortcutAction {
    /// The words people use for actions, besides their titles.
    static let paletteKeywords: [ShortcutAction: [String]] = [
        .libraryModule: ["module", "library", "browse", "photos", "catalog"],
        .developModule: ["module", "develop", "edit"],
        .previousModule: ["module", "back", "previous", "switch"],
        .gridView: ["grid", "thumbnails", "contact sheet", "library"],
        .loupeView: ["loupe", "single", "large", "library"],
        .compareView: ["compare", "side by side", "library"],
        .surveyView: ["survey", "several", "library"],
        .cycleGridStyle: ["grid", "cell style", "view options", "expanded", "compact", "extras", "library"],
        .largerThumbnails: ["thumbnail size", "bigger", "larger", "zoom", "grid", "library"],
        .smallerThumbnails: ["thumbnail size", "smaller", "grid", "library"],
        .showInFinder: ["finder", "reveal", "folder", "file", "library"],
        .toggleFilterBar: ["filter", "search", "find", "query", "library filter", "text", "attribute", "metadata"],
        .toggleFilters: ["filter", "filters off", "turn off", "library"],
        .lockFilters: ["filter", "lock", "keep", "every folder", "library"],
        .sortByFolder: ["sort", "order", "folder", "default", "library"],
        .sortByCaptureTime: ["sort", "order", "date", "taken", "time", "library"],
        .sortByName: ["sort", "order", "name", "file name", "alphabetical", "library"],
        .sortByRating: ["sort", "order", "stars", "rating", "library"],
        .sortByEditTime: ["sort", "order", "edited", "last edit", "library"],
        .sortByModified: ["sort", "order", "modified", "date", "file", "library"],
        .sortByFileSize: ["sort", "order", "size", "bytes", "largest", "library"],
        .reverseSort: ["sort", "reverse", "descending", "ascending", "order", "library"],
        .beforeAfter: ["compare", "before", "after", "original"],
        .nextCompareLayout: ["compare", "side by side", "split", "layout"],
        .previousCompareLayout: ["compare", "side by side", "split", "layout"],
        .toggleZoom: ["zoom", "fit", "100%", "1:1", "actual size"],
        .zoomIn: ["magnify", "bigger"],
        .zoomOut: ["smaller"],
        .clipping: ["clipping", "blown", "warning", "overexposed"],
        .rawClipping: ["sensor", "raw", "clipped", "overexposed"],
        .colorAssessment: ["grey", "gray", "surround", "proof"],
        .labReadout: ["lab", "l*a*b*", "readout", "values", "pixel", "histogram", "measure"],
        .infoOverlay: ["info", "metadata", "exif"],
        .lightsOut: ["dim", "lights", "focus"],
        .fullScreenPreview: ["present", "full screen", "fullscreen"],
        .toggleToolbar: ["toolbar"],
        .toggleSidePanels: ["hide panels", "sidebar", "inspector"],
        .toggleAllPanels: ["hide panels", "distraction free"],
        .toggleFilmstrip: ["filmstrip", "thumbnails"],
        .toggleLeftPanel: ["sidebar", "recipes", "history", "navigator"],
        .toggleRightPanel: ["inspector", "develop", "panels"],
        .previousPhoto: ["back", "photo", "image"],
        .nextPhoto: ["forward", "photo", "image"],
        .selectAllPhotos: ["select", "all", "photos", "filmstrip", "sync"],
        .deselectOtherPhotos: ["deselect", "select none", "only this", "filmstrip"],
        .undo: ["undo", "back"],
        .redo: ["redo"],
        .copySettings: ["sync", "settings", "copy edit", "choose"],
        .copySettingsAgain: ["sync", "settings", "copy edit", "last", "same"],
        .syncSettings: ["sync", "settings", "selection", "batch", "apply to all"],
        .syncSettingsAgain: ["sync", "settings", "selection", "batch", "last"],
        .undoSync: ["undo", "sync", "revert", "batch"],
        .toggleAutoSync: ["auto sync", "sync", "live", "selection", "batch"],
        .pasteSettings: ["sync", "settings", "paste edit"],
        .pastePrevious: ["sync", "previous", "last photo"],
        .resetAll: ["reset", "start over", "revert", "original"],
        .autoTone: ["auto", "automatic", "auto tone"],
        .autoWhiteBalance: ["auto", "wb", "white balance"],
        .toggleBlackAndWhite: ["b&w", "bw", "monochrome", "mono", "black and white", "grayscale", "greyscale"],
        .whiteBalanceSelector: ["eyedropper", "wb", "white balance", "neutral", "picker"],
        .calibrateFromTarget: [
            "calibrate", "calibration", "target", "grey card", "gray card", "colorchecker", "chart", "metered",
            "anchor", "reproduction", "exposure",
        ],
        .newSnapshot: ["snapshot", "save state"],
        .newPreset: ["preset", "recipe", "save look"],
        .virtualCopy: ["duplicate", "copy"],
        .editTool: ["develop", "edit"],
        .cropTool: ["crop", "straighten", "rotate"],
        .healTool: ["heal", "remove", "clone", "spot"],
        .maskingTool: ["mask", "local"],
        .brushMask: ["mask", "brush", "paint", "local"],
        .linearMask: ["mask", "gradient", "graduated", "local"],
        .radialMask: ["mask", "gradient", "circle", "local"],
        .colorRangeMask: ["mask", "color", "range", "local"],
        .luminanceRangeMask: ["mask", "luminance", "range", "local"],
        .depthRangeMask: ["mask", "depth", "range", "local"],
        .maskOverlay: ["mask", "overlay", "red"],
        .maskOverlayColor: ["mask", "overlay", "color"],
        .maskPins: ["mask", "pins", "handles", "spots", "outlines"],
        .deleteMask: ["mask", "remove"],
        .rating0: ["stars", "rating", "unrate", "no stars"],
        .rating1: ["stars", "rating", "one"],
        .rating2: ["stars", "rating", "two"],
        .rating3: ["stars", "rating", "three"],
        .rating4: ["stars", "rating", "four"],
        .rating5: ["stars", "rating", "five"],
        .decreaseRating: ["stars", "rating", "lower"],
        .increaseRating: ["stars", "rating", "higher"],
        .flagPick: ["flag", "pick", "keep"],
        .flagReject: ["flag", "reject", "discard"],
        .unflag: ["flag", "clear"],
        .labelRed: ["label", "color label"],
        .labelYellow: ["label", "color label"],
        .labelGreen: ["label", "color label"],
        .labelBlue: ["label", "color label"],
        .openFolder: ["import", "open", "folder", "photos"],
        .export: ["save", "jpeg", "heic", "avif", "png", "tiff", "export"],
        .exportWithPrevious: ["save", "again", "repeat", "last", "export"],
        .mergeFocusStack: ["focus stacking", "stack", "merge", "depth of field", "macro", "bracketing"],
        .editFocusStack: ["focus stacking", "stack", "frames", "depth", "retouch"],
        .showShortcuts: ["keys", "help", "shortcuts", "keyboard"],
        .filmLooks: ["film", "stocks", "looks"],
        .testCamera: ["camera", "bench", "raw support", "verify", "test", "unsupported camera"],
        .sendFeedback: [
            "bug",
            "report",
            "feedback",
            "issue",
            "problem",
            "idea",
            "feature request",
            "github",
            "crash",
            "support",
        ],
    ]

    /// The symbol beside the action in the command palette.
    var paletteSymbol: String {
        switch self {
        case .libraryModule, .gridView: "square.grid.3x3"
        case .developModule: "slider.horizontal.3"
        case .previousModule: "arrow.uturn.backward.circle"
        case .loupeView: "photo"
        case .compareView: "rectangle.split.2x1"
        case .surveyView: "rectangle.split.3x1"
        case .cycleGridStyle: "rectangle.grid.1x2"
        case .largerThumbnails: "plus.square.on.square"
        case .smallerThumbnails: "minus.square"
        case .showInFinder: "folder"
        case .toggleFilterBar: "line.3.horizontal.decrease.circle"
        case .toggleFilters: "line.3.horizontal.decrease"
        case .lockFilters: "lock"
        case .sortByFolder, .sortByCaptureTime, .sortByName, .sortByRating, .sortByEditTime, .sortByModified,
             .sortByFileSize: "arrow.up.arrow.down"
        case .reverseSort: "arrow.up.and.down.text.horizontal"
        case .beforeAfter, .nextCompareLayout, .previousCompareLayout: "rectangle.2.swap"
        case .toggleZoom: "1.magnifyingglass"
        case .zoomIn: "plus.magnifyingglass"
        case .zoomOut: "minus.magnifyingglass"
        case .clipping: "exclamationmark.triangle"
        case .rawClipping: "camera.aperture"
        case .colorAssessment: "square.dashed"
        case .labReadout: "eyedropper.halffull"
        case .infoOverlay: "info.circle"
        case .lightsOut: "lightbulb"
        case .fullScreenPreview: "arrow.up.left.and.arrow.down.right"
        case .toggleToolbar: "menubar.rectangle"
        case .toggleSidePanels, .toggleAllPanels: "rectangle.split.3x1"
        case .toggleFilmstrip: "film.stack"
        case .toggleLeftPanel: "sidebar.left"
        case .toggleRightPanel: "sidebar.right"
        case .panelBasic: PanelID.basic.symbol
        case .panelToneCurve: PanelID.toneCurve.symbol
        case .panelColorMixer: PanelID.colorMixer.symbol
        case .panelColorGrading: PanelID.colorGrading.symbol
        case .panelDetail: PanelID.detail.symbol
        case .panelLens: PanelID.lens.symbol
        case .panelTransform: PanelID.transform.symbol
        case .panelEffects: PanelID.effects.symbol
        case .panelCalibration: PanelID.calibration.symbol
        case .previousPhoto: "chevron.left"
        case .nextPhoto: "chevron.right"
        case .undo: "arrow.uturn.backward"
        case .redo: "arrow.uturn.forward"
        case .copySettings: "doc.on.doc"
        case .copySettingsAgain: "doc.on.doc.fill"
        case .syncSettings, .syncSettingsAgain: "arrow.triangle.2.circlepath"
        case .undoSync: "arrow.uturn.backward"
        case .toggleAutoSync: "arrow.triangle.2.circlepath.circle"
        case .selectAllPhotos: "checklist.checked"
        case .deselectOtherPhotos: "checklist.unchecked"
        case .pasteSettings: "doc.on.clipboard"
        case .pastePrevious: "clock.arrow.circlepath"
        case .resetAll: "arrow.counterclockwise"
        case .autoTone: "wand.and.stars"
        case .autoWhiteBalance: "thermometer.medium"
        case .toggleBlackAndWhite: "circle.lefthalf.filled"
        case .whiteBalanceSelector: "eyedropper"
        case .calibrateFromTarget: "scope"
        case .newSnapshot: "camera"
        case .newPreset: "plus.square.on.square"
        case .virtualCopy: "square.on.square"
        case .editTool: EditTool.edit.symbol
        case .cropTool, .cropAspectLock: EditTool.crop.symbol
        case .rotateLeft: "rotate.left"
        case .rotateRight: "rotate.right"
        case .healTool: EditTool.heal.symbol
        case .maskingTool: EditTool.masking.symbol
        case .brushMask: MaskKind.brush.symbol
        case .linearMask: MaskKind.linear.symbol
        case .radialMask: MaskKind.radial.symbol
        case .colorRangeMask: MaskKind.colorRange.symbol
        case .luminanceRangeMask: MaskKind.luminanceRange.symbol
        case .depthRangeMask: MaskKind.depthRange.symbol
        case .maskOverlay: "eye"
        case .maskOverlayColor: "paintpalette"
        case .maskPins: "mappin"
        case .deleteMask: "trash"
        case .rating0, .rating1, .rating2, .rating3, .rating4, .rating5, .decreaseRating, .increaseRating: "star"
        case .flagPick: "flag"
        case .flagReject: "xmark.circle"
        case .unflag: "flag.slash"
        case .labelRed, .labelYellow, .labelGreen, .labelBlue: "circle.fill"
        case .openFolder: "folder"
        case .export: "square.and.arrow.up"
        case .exportWithPrevious: "square.and.arrow.up.on.square"
        case .mergeFocusStack: "square.stack.3d.down.right"
        case .editFocusStack: "square.stack.3d.down.right.fill"
        case .showShortcuts: "keyboard"
        case .filmLooks: "film"
        case .testCamera: "camera.badge.ellipsis"
        case .sendFeedback: "exclamationmark.bubble"
        default: "command"
        }
    }
}
