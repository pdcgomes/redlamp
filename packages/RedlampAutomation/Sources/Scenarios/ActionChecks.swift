#if DEBUG || REDLAMP_PROFILING
    import AppKit
    import RedlampCanvas
    import RedlampEngineAPI
    @_spi(Harness) import RedlampUI

    /// How to check one action: what to set up so it applies, what it changes, and how to put
    /// things back. Every action in `ShortcutAction` has one, so a new action without a check
    /// fails the contract tests.
    struct ActionCheck: Sendable {
        let action: ShortcutAction
        /// Sets the editor up so the action applies.
        var setUp: @Sendable (RunningApp) throws -> Void = { _ in }
        /// What the action changes, read before and after; nil when running is the effect
        /// (the activity log records it).
        var observe: (@MainActor @Sendable (EditorModel) -> String)?
        /// Puts the editor back.
        var restore: @Sendable (RunningApp) throws -> Void = { _ in }
        /// The app runs it from the menu itself (Open, Export, Film Looks), not the editor.
        var appRuns = false
        /// Why it can't be checked here, if it can't.
        var unavailable: String?

        /// Toggles back when pressed again.
        static func toggle(
            _ action: ShortcutAction,
            setUp: @escaping @Sendable (RunningApp) throws -> Void = { _ in },
            _ observe: @escaping @MainActor @Sendable (EditorModel) -> String,
        ) -> ActionCheck {
            ActionCheck(action: action, setUp: setUp, observe: observe, restore: { app in
                try app.main { _ = $0.perform(action) }
            })
        }

        /// Changes the edit; undone afterwards.
        static func edit(_ action: ShortcutAction, setUp: @escaping @Sendable (RunningApp) throws -> Void = { _ in
        }) -> ActionCheck {
            ActionCheck(
                action: action,
                setUp: setUp,
                observe: { "\($0.historyIndex)/\($0.history.count)" },
                restore: { app in
                    try app.main { $0.undo() }
                },
            )
        }

        /// Chooses a tool or a drawing mode; Edit afterwards.
        static func tool(_ action: ShortcutAction, setUp: @escaping @Sendable (RunningApp) throws -> Void = { _ in
        }) -> ActionCheck {
            ActionCheck(action: action, setUp: setUp, observe: toolState, restore: { app in
                try app.main { model in
                    if model.drawingKind != nil {
                        model.perform(.cancel)
                    }
                    model.activeTool = .edit
                }
            })
        }

        /// Opens a sheet; Escape closes it, as its Cancel button's key.
        static func sheet(_ action: ShortcutAction, appRuns: Bool = false) -> ActionCheck {
            ActionCheck(action: action, observe: { _ in sheetState() }, restore: { app in
                try app.pressInSheet(KeyCombo(.escape))
                try app.waitForNoSheet("\(action.title)'s sheet")
            }, appRuns: appRuns)
        }

        @MainActor static func sheetState() -> String {
            let sheet = NSApp.modalWindow ?? Views.editorWindow?.attachedSheet
            return sheet.map { "\(type(of: $0)) \($0.title)" } ?? "none"
        }

        @MainActor static func toolState(_ model: EditorModel) -> String {
            "\(model.activeTool) \(String(describing: model.drawingKind)) \(model.isBrushing)"
        }

        @MainActor static func windows() -> String {
            NSApp.windows.filter { $0.isVisible && !($0.windowController is EditorWindowController) }
                .map(\.title).sorted().joined(separator: ",")
        }

        @MainActor static func rating(_ model: EditorModel) -> String {
            let metadata = model.photoMetadata
            return "\(metadata.rating) \(String(describing: metadata.flag)) \(String(describing: metadata.label)) "
                + "\(String(describing: metadata.customLabel)) \(metadata.mark)"
        }

        static let all: [ActionCheck] = ShortcutAction.allCases.map(check)

        // swiftlint:disable:next cyclomatic_complexity function_body_length
        static func check(_ action: ShortcutAction) -> ActionCheck {
            switch action {
            // Modules
            case .libraryModule, .developModule, .previousModule, .gridView, .loupeView, .compareView, .surveyView:
                module(action)
            // Library
            case .cycleGridStyle, .largerThumbnails, .smallerThumbnails: grid(action)
            case .toggleFilterBar, .toggleFilters, .lockFilters, .sortByFolder, .sortByCaptureTime, .sortByName,
                 .sortByRating, .sortByEditTime, .sortByModified, .sortByFileSize, .reverseSort:
                filter(action)
            case .groupByNone, .groupByMoment, .groupByDay, .groupByFolder, .groupByCamera, .groupByLens,
                 .groupByOrientation, .groupByMomentCamera, .toggleGroup, .openAllGroups, .closeAllGroups:
                groups(action)
            case .showInFinder:
                ActionCheck(action: action, setUp: { app in
                    try app.main { $0.libraryViews.revealInFinder = { Revealed.photos.append(contentsOf: $0) } }
                }, observe: { _ in "\(Revealed.photos.count)" }, restore: { app in
                    try app.main { $0.libraryViews.revealInFinder = Revealed.finder }
                })
            case .showPhotosInSubfolders:
                ActionCheck(action: action, observe: { "\($0.library.includesSubfolders)" }, restore: { app in
                    try app.main { _ = $0.perform(action) }
                    try app.wait("the folder listed again", timeout: 20) { !$0.library.isListing }
                })
            case .showRecentlyTrashed:
                ActionCheck(action: action, setUp: { app in
                    try app.wait("the library to open", timeout: 60) { $0.library.canShowRecentlyTrashed }
                }, observe: { "\($0.library.showsRecentlyTrashed)" }, restore: { app in
                    let photos = app.photos
                    try app.main { model in
                        model.showFolder(photos)
                        model.showModule(.develop)
                    }
                    try app
                        .wait("the photos folder again", timeout: 20) { $0.folder == photos && !$0.library.isListing }
                })
            case .putBack, .putBackBatch:
                ActionCheck(action: action, unavailable: "needs a photo in Recently Trashed: checked by its scenario")
            // View
            case .beforeAfter: .toggle(action) { "\($0.showBefore)" }
            case .nextCompareLayout, .previousCompareLayout:
                ActionCheck(action: action, observe: { "\($0.showBefore) \($0.compareLayout)" }, restore: { app in
                    try app.main { model in
                        model.showBefore = false
                        model.compareLayout = .toggle
                    }
                })
            case .toggleZoom: .toggle(action) { "\($0.canvas.zoom)" }
            case .zoomIn:
                ActionCheck(action: action, setUp: { app in
                    try app.waitForCanvas()
                    try app.main { $0.canvas.zoom = .fit }
                }, observe: { "\($0.canvas.zoom)" }, restore: { app in
                    try app.main { $0.canvas.zoom = .fit }
                })
            case .zoomOut:
                ActionCheck(action: action, setUp: { app in
                    try app.waitForCanvas()
                    try app.main { $0.canvas.zoom = .scale(2) }
                }, observe: { "\($0.canvas.zoom)" }, restore: { app in
                    try app.main { $0.canvas.zoom = .fit }
                })
            case .clipping: .toggle(action) { "\($0.showClipping)" }
            case .rawClipping: .toggle(action) { "\($0.showRawClipping)" }
            case .colorAssessment: .toggle(action) { "\($0.colorAssessment)" }
            case .labReadout: .toggle(action) { "\($0.showsLabReadout)" }
            case .infoOverlay:
                ActionCheck(action: action, observe: { "\($0.infoOverlay)" }, restore: { app in
                    try app.main { $0.infoOverlay = 0 }
                })
            case .lightsOut:
                ActionCheck(action: action, observe: { "\($0.lightsOut)" }, restore: { app in
                    try app.main { $0.lightsOut = 0 }
                })
            case .fullScreenPreview: .toggle(action) { "\($0.isPresenting)" }
            case .toggleToolbar:
                .toggle(action) { _ in "\(Views.editorWindow?.toolbar?.isVisible ?? false)" }
            // Panels
            case .toggleSidePanels, .toggleAllPanels, .toggleFilmstrip, .toggleLeftPanel, .toggleRightPanel:
                .toggle(action) { "\($0.leftPanelVisible) \($0.rightPanelVisible) \($0.filmstripVisible)" }
            case .panelBasic, .panelToneCurve, .panelColorMixer, .panelColorGrading, .panelDetail,
                 .panelLens, .panelTransform, .panelEffects, .panelCalibration:
                .toggle(action) { $0.expandedPanels.map(\.rawValue).sorted().joined(separator: ",") }
            // Navigation
            case .previousPhoto:
                ActionCheck(action: action, setUp: { app in
                    try app.main { model in model.select(model.items[1].url) }
                    try app.settle()
                }, observe: { $0.selection?.lastPathComponent ?? "" }, restore: { app in try app.settle() })
            case .nextPhoto:
                ActionCheck(action: action, observe: { $0.selection?.lastPathComponent ?? "" }, restore: { app in
                    try app.main { model in model.select(model.items[0].url) }
                    try app.settle()
                })
            case .selectAllPhotos:
                ActionCheck(action: action, observe: { "\($0.selectedPhotos.count)" }, restore: { app in
                    try app.main { $0.deselectOtherPhotos() }
                })
            case .deselectOtherPhotos:
                ActionCheck(action: action, setUp: { app in
                    try app.main { $0.selectAllPhotos() }
                }, observe: { "\($0.selectedPhotos.count)" })
            // Develop
            case .undo:
                ActionCheck(action: action, setUp: { app in
                    try app.main { $0.setSliderValue(.exposure, 0.35) }
                }, observe: { "\($0.historyIndex)" })
            case .redo:
                ActionCheck(action: action, setUp: { app in
                    try app.main { model in
                        model.setSliderValue(.exposure, 0.4)
                        model.undo()
                    }
                }, observe: { "\($0.historyIndex)" }, restore: { app in try app.main { $0.undo() } })
            case .copySettings, .syncSettings:
                ActionCheck(action: action, setUp: { app in
                    if action == .syncSettings {
                        try app.main { $0.selectAllPhotos() }
                    }
                }, observe: { model in "\(model.settingsChooser != nil) \(sheetState())" }, restore: { app in
                    try app.pressInSheet(KeyCombo(.escape))
                    try app.wait("the settings checklist to close") { $0.settingsChooser == nil }
                    try app.main { $0.deselectOtherPhotos() }
                })
            case .copySettingsAgain:
                ActionCheck(action: action, observe: nil)
            case .pasteSettings:
                ActionCheck(action: action, setUp: { app in
                    try app.main { $0.copySettings() }
                }, observe: nil)
            case .pastePrevious:
                ActionCheck(action: action, setUp: { app in
                    try app.main { model in model.select(model.items[1].url) }
                    try app.settle()
                    try app.main { model in model.select(model.items[0].url) }
                    try app.settle()
                }, observe: nil)
            case .resetAll:
                ActionCheck(action: action, setUp: { app in
                    try app.main { $0.setSliderValue(.exposure, 0.45) }
                }, observe: { "\($0.value(.exposure))" })
            case .syncSettingsAgain:
                ActionCheck(action: action, setUp: { app in
                    try app.main { model in
                        model.setSliderValue(.vibrance, 9)
                        model.selectAllPhotos()
                    }
                }, observe: nil, restore: { app in
                    try app.wait("the sync to finish", timeout: 120) { $0.settingsSync.progress == nil }
                    try app.main { model in
                        if model.settingsSync.canUndo {
                            _ = model.perform(.undoSync)
                        }
                        model.deselectOtherPhotos()
                    }
                    try app.wait("the sync's undo to finish", timeout: 120) { $0.settingsSync.progress == nil }
                })
            case .undoSync:
                ActionCheck(action: action, setUp: { app in
                    try app.main { model in
                        model.setSliderValue(.vibrance, 12)
                        model.selectAllPhotos()
                        model.perform(.syncSettingsAgain)
                    }
                    try app.wait("the sync to finish", timeout: 120) { $0.settingsSync.canUndo }
                }, observe: { "\($0.settingsSync.canUndo)" }, restore: { app in
                    try app.wait("the sync's undo to finish", timeout: 120) { $0.settingsSync.progress == nil }
                    try app.main { $0.deselectOtherPhotos() }
                })
            case .toggleAutoSync: .toggle(action) { "\($0.settingsSync.isAutoSyncing)" }
            case .autoTone, .rotateLeft, .rotateRight: .edit(action)
            case .autoWhiteBalance:
                ActionCheck(action: action, setUp: { app in
                    try app.main { $0.setWhiteBalanceMode(.asShot) }
                }, observe: { "\($0.whiteBalanceMode)" }, restore: { app in try app.main { $0.undo() } })
            case .toggleBlackAndWhite: .toggle(action) { "\($0.treatment)" }
            case .whiteBalanceSelector:
                ActionCheck(action: action, observe: { "\($0.eyedropperActive)" }, restore: { app in
                    try app.main { $0.eyedropperActive = false }
                })
            case .calibrateFromTarget:
                ActionCheck(action: action, setUp: { app in
                    try app.main { $0.setBaseLook(BuiltInBaseLook.reproduction.reference) }
                }, observe: { "\($0.calibrationTargetActive)" }, restore: { app in
                    try app.main { model in
                        model.calibrationTargetActive = false
                        model.undo()
                    }
                })
            case .newSnapshot:
                ActionCheck(action: action, observe: { "\($0.snapshots.count)" }, restore: { app in
                    try app.main { model in model.snapshots.last.map(model.deleteSnapshot) }
                })
            case .newPreset: .sheet(action)
            case .virtualCopy:
                ActionCheck(action: action, unavailable: "planned for \(action.plannedPhase ?? "a later phase")")
            case .previousSetting, .nextSetting:
                ActionCheck(action: action, setUp: { app in
                    try app.main { $0.focusedParameter = .contrast }
                }, observe: { "\(String(describing: $0.focusedParameter))" })
            case .increaseSetting, .decreaseSetting:
                ActionCheck(action: action, setUp: { app in
                    try app.main { $0.focusedParameter = .contrast }
                }, observe: { "\($0.value(.contrast))" }, restore: { app in
                    try app.main { $0.reset(.contrast) }
                })
            case .findAdjustment, .commandPalette:
                ActionCheck(action: action, observe: { "\($0.commandPalette != nil)" }, restore: { app in
                    try app.main { $0.closeCommandPalette() }
                })
            // Tools
            case .editTool:
                ActionCheck(action: action, setUp: { app in
                    try app.main { $0.activeTool = .crop }
                }, observe: toolState)
            case .cropTool, .healTool, .maskingTool: .tool(action)
            case .cropAspectLock:
                ActionCheck(action: action, setUp: { app in
                    try app.main { $0.activeTool = .crop }
                }, observe: { "\($0.cropAspectLocked)" }, restore: { app in
                    try app.main { model in
                        model.perform(.cropAspectLock)
                        model.activeTool = .edit
                    }
                })
            case .brushMask, .linearMask, .radialMask, .colorRangeMask, .luminanceRangeMask, .depthRangeMask:
                .tool(action)
            case .maskOverlay:
                .toggle(action, setUp: { app in try app.main { $0.activeTool = .masking } }) { "\($0.showMaskOverlay)" }
            case .maskOverlayColor:
                ActionCheck(action: action, setUp: { app in
                    try app.main { $0.activeTool = .masking }
                }, observe: { "\($0.maskOverlayColor)" })
            case .maskPins:
                .toggle(action, setUp: { app in try app.main { $0.activeTool = .masking } }) { "\($0.showMaskPins)" }
            case .deleteMask:
                ActionCheck(action: action, setUp: { app in
                    try app.main { model in
                        model.activeTool = .masking
                        model.applyDebugCommand("radial", "0.5:0.5:0.2:0.15")
                    }
                    try app.wait("the radial mask to be drawn") { !$0.masks.isEmpty && $0.selectedMaskID != nil }
                }, observe: { "\($0.masks.count)" }, restore: { app in try app.main { $0.activeTool = .edit } })
            case .cancel:
                ActionCheck(action: action, setUp: { app in
                    try app.main { _ = $0.perform(.linearMask) }
                }, observe: toolState, restore: { app in try app.main { $0.activeTool = .edit } })
            // Ratings, flags and labels
            case .rating0:
                ActionCheck(action: action, setUp: { app in
                    try app.main { _ = $0.perform(.rating4) }
                }, observe: rating)
            case .rating1, .rating2, .rating3, .rating4, .rating5, .increaseRating:
                ActionCheck(
                    action: action,
                    observe: rating,
                    restore: { app in try app.main { _ = $0.perform(.rating0) } },
                )
            case .decreaseRating:
                ActionCheck(action: action, setUp: { app in
                    try app.main { _ = $0.perform(.rating3) }
                }, observe: rating, restore: { app in try app.main { _ = $0.perform(.rating0) } })
            case .flagPick, .flagReject:
                ActionCheck(
                    action: action,
                    observe: rating,
                    restore: { app in try app.main { _ = $0.perform(.unflag) } },
                )
            case .unflag:
                ActionCheck(action: action, setUp: { app in
                    try app.main { _ = $0.perform(.flagPick) }
                }, observe: rating)
            case .labelRed, .labelYellow, .labelGreen, .labelBlue, .labelPurple, .toggleMark: .toggle(action, rating)
            case .clearLabel:
                ActionCheck(action: action, setUp: { app in
                    try app.main { _ = $0.perform(.labelRed) }
                }, observe: rating)
            case .autoAdvance: .toggle(action) { "\($0.autoAdvance)" }
            // File and Edit
            case .openFolder:
                ActionCheck(action: action, observe: { _ in "\(NSApp.modalWindow is NSOpenPanel)" }, restore: { app in
                    try app.main { _ in (NSApp.modalWindow as? NSOpenPanel)?.cancel(nil) }
                    try app.waitForNoSheet("the Open panel")
                }, appRuns: true)
            case .export: .sheet(action, appRuns: true)
            case .exportWithPrevious:
                // The dialog, or straight away with the last export's settings.
                ActionCheck(
                    action: action,
                    observe: { model in "\(sheetState()) \(model.exportStatus ?? "")" },
                    restore: { app in
                        if try app.sheetIsUp() {
                            try app.pressInSheet(KeyCombo(.escape))
                            try app.waitForNoSheet("the Export dialog")
                        }
                        try app.wait("the export to finish", timeout: 60) { $0.exportStatus == nil }
                    },
                    appRuns: true,
                )
            case .mergeFocusStack:
                ActionCheck(
                    action: action,
                    unavailable: "needs a focus bracket: checked by the focus-stacking scenarios",
                )
            case .editFocusStack:
                ActionCheck(
                    action: action,
                    unavailable: "needs a stack document: checked by the focus-stacking scenarios",
                )
            case .showShortcuts:
                ActionCheck(action: action, observe: { "\($0.showShortcuts)" }, restore: { app in
                    try app.main { $0.showShortcuts = false }
                })
            case .filmLooks:
                ActionCheck(action: action, observe: { _ in windows() }, restore: { app in
                    try app.main { _ in NSApp.windows.first { $0.title == "Film Looks" }?.close() }
                }, appRuns: true)
            case .importPhotos:
                ActionCheck(action: action, setUp: { app in
                    try app.main { _ in ImportWindowController.ignoresVolumes = true }
                }, observe: { _ in windows() }, restore: { app in
                    try app.main { _ in ImportWindowController.current?.close() }
                    try app.wait("the import window to close") { _ in ImportWindowController.current == nil }
                })
            case .sendFeedback: .sheet(action)
            case .testCamera:
                ActionCheck(action: action, observe: { _ in windows() }, restore: { app in
                    try app.main { _ in
                        NSApp.windows.first { $0.isVisible && $0.title.localizedCaseInsensitiveContains("camera") }?
                            .close()
                    }
                })
            }
        }

        /// Runs the check through `path` (a key press or the menu item).
        func run(_ app: RunningApp, via path: InputPath) throws {
            if let unavailable {
                throw ScenarioSkip(unavailable)
            }
            try setUp(app)
            app.pause(0.05)
            let before = try observe.map { observe in try app.main { observe($0) } }
            let enabled = try app.main { $0.canPerform(action) }
            try app.expect(enabled || appRuns, "\(action.title) isn't available after its set-up")
            if path == .key, let combo = action.combos.first, !combo.command,
               case let .character(character) = combo.key,
               try !app.main({ _ in Keyboard.hasKey(for: character) }) {
                // This keyboard layout has no key for it: run it as such a person would.
                try app.runFromPalette(action)
                if let observe, let before {
                    try app
                        .wait("\(action.title) to change what it changes (was \(before))", timeout: 5) {
                            observe($0) != before
                        }
                }
                try restore(app)
                return
            }
            switch path {
            case .key where action.combos.first.map { $0.command && ($0.shift || $0.option) } == true:
                if case .character = action.combos.first?.key {
                    try app.expectKeyBinding(action)
                } else {
                    try app.expectArrowKeyBinding(action)
                }
                try app.choose(action, expectPerformed: !appRuns)
            case .key: try app.press(action, expectPerformed: !appRuns)
            case .menu: try app.choose(action, expectPerformed: !appRuns)
            default: throw ScenarioFailure("Actions run by key or menu")
            }
            if let observe, let before {
                try app.wait("\(action.title) to change what it changes (was \(before))", timeout: 5) { model in
                    observe(model) != before
                }
            }
            try restore(app)
        }
    }
#endif
