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
        .showPhotosInSubfolders: ["subfolders", "folders", "nested", "include", "count", "library"],
        .showRecentlyTrashed: ["trash", "recently deleted", "deleted", "bin", "removed", "put back", "library"],
        .putBack: ["trash", "restore", "undelete", "recover", "deleted", "put back", "library"],
        .putBackBatch: ["trash", "restore", "undelete", "recover", "batch", "all", "put back", "library"],
        .showAllPhotographs: ["all photos", "every photo", "catalog", "everything", "library"],
        .showPreviousImport: ["import", "last import", "recent", "new photos", "card", "library"],
        .showMarked: ["marked", "quick collection", "mark", "b", "library"],
        .showRejected: ["rejects", "rejected", "flagged", "x", "library"],
        .newCollection: ["collection", "album", "new", "make", "group", "library"],
        .newSmartCollection: ["smart collection", "saved search", "rules", "query", "new", "library"],
        .newCollectionSet: ["collection set", "set", "folder", "group", "new", "library"],
        .addToCollection: ["collection", "album", "add", "put in", "selection", "library"],
        .addToTargetCollection: ["target", "collection", "add", "quick collection", "library"],
        .removeFromCollection: ["collection", "remove", "take out", "album", "library"],
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
        .groupByNone: ["group", "ungroup", "no groups", "flat", "library"],
        .groupByMoment: ["group", "moment", "session", "event", "time", "pause", "library"],
        .groupByDay: ["group", "day", "date", "library"],
        .groupByFolder: ["group", "folder", "library"],
        .groupByCamera: ["group", "camera", "body", "library"],
        .groupByLens: ["group", "lens", "library"],
        .groupByOrientation: ["group", "orientation", "portrait", "landscape", "square", "library"],
        .groupByMomentCamera: ["group", "moment", "camera", "body", "second shooter", "library"],
        .tighterMoments: ["moment", "tighter", "split", "more moments", "group", "library"],
        .looserMoments: ["moment", "looser", "merge", "fewer moments", "group", "library"],
        .toggleGroup: ["group", "open", "close", "collapse", "expand", "library"],
        .openAllGroups: ["group", "open", "expand", "all", "library"],
        .closeAllGroups: ["group", "close", "collapse", "all", "library"],
        .unpickedMoments: ["moment", "unpicked", "coverage", "no pick", "missing", "cull", "library"],
        .toggleStack: ["stack", "open", "close", "collapse", "expand", "burst", "raw and jpeg", "pair", "library"],
        .stackPhotos: ["stack", "group into stack", "make stack", "bundle", "burst", "library"],
        .unstackPhotos: ["stack", "unstack", "take apart", "dissolve", "ungroup", "library"],
        .moveToStackTop: ["stack", "top", "cover", "pick", "move to top", "library"],
        .openAllStacks: ["stack", "open", "expand", "all", "every photo", "raw and jpeg", "library"],
        .closeAllStacks: ["stack", "close", "collapse", "all", "library"],
        .removeFromStack: ["stack", "remove", "take out", "leave", "unstack", "library"],
        .splitStack: ["stack", "split", "divide", "break", "two stacks", "library"],
        .moveUpInStack: ["stack", "move up", "earlier", "order", "reorder", "left", "library"],
        .moveDownInStack: ["stack", "move down", "later", "order", "reorder", "right", "library"],
        .previousGroup: ["group", "moment", "previous", "back", "jump"],
        .nextGroup: ["group", "moment", "next", "jump", "skip"],
        .keywordSet1: ["keyword", "tag", "keyword set", "apply", "library"],
        .keywordSet2: ["keyword", "tag", "keyword set", "apply", "library"],
        .keywordSet3: ["keyword", "tag", "keyword set", "apply", "library"],
        .keywordSet4: ["keyword", "tag", "keyword set", "apply", "library"],
        .keywordSet5: ["keyword", "tag", "keyword set", "apply", "library"],
        .keywordSet6: ["keyword", "tag", "keyword set", "apply", "library"],
        .keywordSet7: ["keyword", "tag", "keyword set", "apply", "library"],
        .keywordSet8: ["keyword", "tag", "keyword set", "apply", "library"],
        .keywordSet9: ["keyword", "tag", "keyword set", "apply", "library"],
        .importKeywords: ["keywords", "keyword list", "import", "lightroom", "tags", "text file", "library"],
        .exportKeywords: ["keywords", "keyword list", "export", "lightroom", "tags", "text file", "library"],
        .editCaptureTime: ["capture time", "date", "time", "shift", "clock", "time zone", "taken", "library"],
        .renamePhotos: [
            "rename", "file name", "filename", "template", "naming", "batch rename", "sequence", "f2", "library",
        ],
        .moveToFolder: ["move", "folder", "organise", "organize", "file", "relocate", "library"],
        .copyToFolder: ["copy", "duplicate", "folder", "file", "library"],
        .keywordPainter: ["painter", "paint", "spray", "brush", "keywords", "tag", "keyword set", "library"],
        .moveEditsAndMetadata: [
            "sidecar", "sidecars", "redlamp file", "edits", "metadata", "on this mac", "beside the photos", "read-only",
            "where edits are kept", "folder", "library",
        ],
        .acceptHealthProposals: [
            "library health", "duplicates", "copies", "raw and jpeg", "pairs", "damaged", "wrong extension", "trash",
            "delete", "clean up", "proposals", "accept", "library",
        ],
        .keepAnyway: ["library health", "keep", "dismiss", "ignore", "not a duplicate", "proposal", "library"],
        .listAgain: ["library health", "kept anyway", "take back", "list again", "undismiss", "library"],
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
        .labelPurple: ["label", "color label", "violet"],
        .clearLabel: ["label", "color label", "none", "remove label", "unlabel"],
        .toggleMark: ["mark", "quick collection", "target", "collect", "unmark"],
        .autoAdvance: ["advance", "next photo", "caps lock", "culling", "move on"],
        .openFolder: ["import", "open", "folder", "photos"],
        .importPhotos: ["import", "card", "memory card", "sd", "camera", "copy", "ingest", "dcim", "backup"],
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
        case .showPhotosInSubfolders: "list.bullet.indent"
        case .showRecentlyTrashed: "trash"
        case .putBack: "arrow.uturn.backward.square"
        case .putBackBatch: "arrow.uturn.backward.square.fill"
        case .showAllPhotographs: "photo.on.rectangle"
        case .showPreviousImport: "square.and.arrow.down"
        case .showMarked: "circle.inset.filled"
        case .showRejected: "xmark.circle"
        case .newCollection, .addToCollection: "rectangle.stack.badge.plus"
        case .newSmartCollection: "gearshape"
        case .newCollectionSet: "square.stack.3d.up"
        case .addToTargetCollection: "plus.rectangle.on.rectangle"
        case .removeFromCollection: "rectangle.stack.badge.minus"
        case .toggleFilterBar: "line.3.horizontal.decrease.circle"
        case .toggleFilters: "line.3.horizontal.decrease"
        case .lockFilters: "lock"
        case .sortByFolder, .sortByCaptureTime, .sortByName, .sortByRating, .sortByEditTime, .sortByModified,
             .sortByFileSize: "arrow.up.arrow.down"
        case .reverseSort: "arrow.up.and.down.text.horizontal"
        case .groupByNone, .groupByMoment, .groupByDay, .groupByFolder, .groupByCamera, .groupByLens,
             .groupByOrientation, .groupByMomentCamera: "rectangle.3.group"
        case .tighterMoments: "arrow.right.and.line.vertical.and.arrow.left"
        case .looserMoments: "arrow.left.and.line.vertical.and.arrow.right"
        case .toggleGroup: "chevron.down.circle"
        case .openAllGroups: "rectangle.expand.vertical"
        case .closeAllGroups: "rectangle.compress.vertical"
        case .unpickedMoments: "flag.slash"
        case .toggleStack: "square.stack"
        case .stackPhotos: "square.stack.fill"
        case .unstackPhotos: "square.on.square.dashed"
        case .moveToStackTop: "arrow.up.square"
        case .openAllStacks: "arrow.up.left.and.arrow.down.right"
        case .closeAllStacks: "arrow.down.right.and.arrow.up.left"
        case .removeFromStack: "minus.square"
        case .splitStack: "square.split.2x1"
        case .moveUpInStack: "arrow.left.square"
        case .moveDownInStack: "arrow.right.square"
        case .previousGroup: "chevron.left.2"
        case .nextGroup: "chevron.right.2"
        case .keywordSet1, .keywordSet2, .keywordSet3, .keywordSet4, .keywordSet5, .keywordSet6, .keywordSet7,
             .keywordSet8, .keywordSet9: "tag"
        case .importKeywords: "square.and.arrow.down"
        case .exportKeywords: "square.and.arrow.up.on.square"
        case .editCaptureTime: "clock.arrow.2.circlepath"
        case .renamePhotos: "character.cursor.ibeam"
        case .moveToFolder: "folder.badge.plus"
        case .copyToFolder: "plus.square.on.square"
        case .keywordPainter: "paintbrush.pointed"
        case .moveEditsAndMetadata: "arrow.left.arrow.right"
        case .acceptHealthProposals: "checkmark.rectangle.stack"
        case .keepAnyway: "checkmark.seal"
        case .listAgain: "arrow.uturn.backward.circle"
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
        case .labelRed, .labelYellow, .labelGreen, .labelBlue, .labelPurple: "circle.fill"
        case .clearLabel: "circle.slash"
        case .toggleMark: "circle.inset.filled"
        case .autoAdvance: "arrow.right.to.line"
        case .openFolder: "folder"
        case .importPhotos: "sdcard"
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
