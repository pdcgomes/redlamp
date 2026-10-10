import Foundation
import RedlampDocument
import RedlampEngineAPI

/// Everything a keyboard shortcut or its menu item can do.
public extension EditorModel {
    /// Performs a shortcut. Returns `false` when it does not apply in the current state, so
    /// the key event can continue to the rest of the app.
    @discardableResult
    func perform(_ action: ShortcutAction, shifted: Bool = false) -> Bool {
        if action != .increaseSetting, action != .decreaseSetting {
            endNudgeRun()
        }
        let performed = runShortcut(action, shifted: shifted)
        if performed {
            activity.record(.action, action.title)
        }
        return performed
    }

    /// Report a Bug or Send Feedback, from the toolbar, the menus, the palette, or a message on
    /// screen (which `prefill` quotes).
    func sendFeedback(_ prefill: FeedbackPrefill? = nil) {
        guard !isModalDialogOpen, let onSendFeedback else { return }
        onSendFeedback(prefill)
    }

    /// What the button beside a photo's open error fills in: a request for a format Redlamp
    /// doesn't read yet, or a bug about the photo not opening.
    var openErrorReport: FeedbackPrefill? {
        guard let errorMessage else { return nil }
        return formatNotSupportedYet
            ? FeedbackPrefill(kind: .idea, featureID: "raw.unsupported", message: errorMessage)
            : FeedbackPrefill(featureID: "raw.wont-open", message: errorMessage)
    }

    /// Whether a sheet, or a drop's move, keeps `action` from running. While a drop's move runs, Undo and Redo go
    /// through: they take their turn behind its batch, so ⌘Z takes the move back once it's made.
    func isHeldByDialog(_ action: ShortcutAction) -> Bool {
        isModalDialogOpen && !(moveProgress.title != nil && (action == .undo || action == .redo))
    }

    private func runShortcut(_ action: ShortcutAction, shifted: Bool) -> Bool {
        guard !isHeldByDialog(action) else { return false }
        guard action.isAvailable else { return false }
        guard module == .develop || !action.isDevelopOnly else { return false }
        guard module == .library || !action.isLibraryOnly else { return false }
        if let performed = performHealthShortcut(action) ?? performStackShortcut(action)
            ?? performPainterShortcut(action) ?? performSourceShortcut(action) ?? performModuleShortcut(action)
            ?? performGridShortcut(action) ?? performPanelShortcut(action) ?? performFileShortcut(action)
            ?? performCullingShortcut(action, shifted: shifted) {
            return performed
        }
        switch action {
        // View
        case .beforeAfter: showBefore.toggle()
        case .nextCompareLayout: cycleCompareLayout(by: 1)
        case .previousCompareLayout: cycleCompareLayout(by: -1)
        case .toggleZoom: canvas.toggleZoom(at: nil)
        case .zoomIn: canvas.zoomIn()
        case .zoomOut: canvas.zoomOut()
        case .clipping: showClipping.toggle()
        case .rawClipping: showRawClipping.toggle()
        case .colorAssessment: colorAssessment.toggle()
        case .labReadout: showsLabReadout.toggle()
        case .infoOverlay: infoOverlay = (infoOverlay + 1) % 3
        case .lightsOut: lightsOut = (lightsOut + 1) % 3
        case .fullScreenPreview: togglePresentation()
        case .toggleToolbar: onToggleToolbar?()
        // Panels
        case .toggleSidePanels:
            let visible = leftPanelVisible || rightPanelVisible
            leftPanelVisible = !visible
            rightPanelVisible = !visible
        case .toggleAllPanels:
            let visible = leftPanelVisible || rightPanelVisible || filmstripVisible
            leftPanelVisible = !visible
            rightPanelVisible = !visible
            filmstripVisible = !visible
        case .toggleFilmstrip: filmstripVisible.toggle()
        case .toggleLeftPanel: leftPanelVisible.toggle()
        case .toggleRightPanel: rightPanelVisible.toggle()
        case .panelBasic: revealPanel(.basic)
        case .panelToneCurve: revealPanel(.toneCurve)
        case .panelColorMixer: revealPanel(.colorMixer)
        case .panelColorGrading: revealPanel(.colorGrading)
        case .panelDetail: revealPanel(.detail)
        case .panelLens: revealPanel(.lens)
        case .panelTransform: revealPanel(.transform)
        case .panelEffects: revealPanel(.effects)
        case .panelCalibration: revealPanel(.calibration)
        // Navigation
        case .previousPhoto: selectPrevious()
        case .nextPhoto: selectNext()
        // Develop
        case .undo: undo()
        case .redo: redo()
        case .copySettings: chooseSettingsToCopy()
        case .copySettingsAgain: copySettings()
        case .syncSettings: chooseSettingsToSync()
        case .syncSettingsAgain: syncSettings()
        case .undoSync: undoSync()
        case .toggleAutoSync: toggleAutoSync()
        case .selectAllPhotos: selectAllPhotos()
        case .deselectOtherPhotos: deselectOtherPhotos()
        case .pasteSettings: pasteSettings()
        case .pastePrevious: pasteFromPrevious()
        case .resetAll: resetAll()
        case .autoTone: autoTone()
        case .autoWhiteBalance:
            guard info?.supportsWhiteBalance == true else { return false }
            setWhiteBalanceMode(.auto)
        case .toggleBlackAndWhite:
            guard info != nil else { return false }
            setTreatment(recipe.treatment == .color ? .blackAndWhite : .color)
        case .whiteBalanceSelector:
            guard info?.supportsWhiteBalance == true else { return false }
            eyedropperActive.toggle()
        case .calibrateFromTarget:
            guard canCalibrateFromTarget else { return false }
            calibrationTargetActive.toggle()
        case .newSnapshot: createSnapshot()
        case .newPreset: RecipeActions.createRecipe(model: self)
        case .previousSetting: cycleFocusedParameter(by: -1)
        case .nextSetting: cycleFocusedParameter(by: 1)
        case .increaseSetting: nudgeFocusedParameter(direction: 1, large: shifted)
        case .decreaseSetting: nudgeFocusedParameter(direction: -1, large: shifted)
        // Tools
        case .maskingTool: activeTool = activeTool == .masking ? .edit : .masking
        case .cropTool: activeTool = activeTool == .crop ? .edit : .crop
        case .healTool: activeTool = activeTool == .heal ? .edit : .heal
        case .cropAspectLock: cropAspectLocked.toggle()
        case .rotateLeft: rotate(clockwise: false)
        case .rotateRight: rotate(clockwise: true)
        case .linearMask: startDrawing(.linear)
        case .radialMask: startDrawing(.radial)
        case .brushMask: startDrawing(.brush)
        case .colorRangeMask: startDrawing(.colorRange)
        case .luminanceRangeMask: startDrawing(.luminanceRange)
        case .depthRangeMask: startDrawing(.depthRange)
        // Masking
        // In the Crop tool, O and ⇧O cycle and turn its overlay, as in Lightroom.
        case .maskOverlay:
            if activeTool == .crop {
                cropOverlay = cropOverlayChoices.overlay(after: cropOverlay)
                return true
            }
            guard activeTool == .masking else { return false }
            showMaskOverlay.toggle()
        case .maskOverlayColor:
            if activeTool == .crop {
                cropOverlayTurns = (cropOverlayTurns + 1) % CropOverlay.orientations
                return true
            }
            guard activeTool == .masking else { return false }
            maskOverlayColor = maskOverlayColor.next
        // In the Healing tool, H hides and shows its spots, as in Lightroom.
        case .maskPins where activeTool == .heal: showSpots.toggle()
        case .maskPins:
            guard activeTool == .masking else { return false }
            showMaskPins.toggle()
        case .deleteMask:
            if activeTool == .heal, let spot = selectedSpotID {
                deleteSpot(spot)
                return true
            }
            guard activeTool == .masking, let mask = selectedMaskID else { return false }
            deleteMask(mask)
        case .cancel: return cancelCurrentMode()
        // Rating & flags are culling's (`EditorModel+Culling`), but for these.
        // While a brush's tool is active, [ and ] size it (Shift: feather), as in Lightroom.
        case .decreaseRating where sizedBrush != nil: nudgeSizedBrush(direction: -1, feather: shifted)
        case .increaseRating where sizedBrush != nil: nudgeSizedBrush(direction: 1, feather: shifted)
        // In the Crop tool, X swaps the crop's orientation rather than rejecting the photo.
        case .flagReject where module == .develop && activeTool == .crop: swapCropOrientation()
        // File & Edit
        case .showShortcuts: showShortcuts.toggle()
        case .commandPalette: toggleCommandPalette()
        case .findAdjustment:
            // ⌘F over the full palette narrows it to sliders; otherwise it opens or closes.
            if commandPalette?.scope == .all {
                openCommandPalette(scope: .sliders)
            } else {
                toggleCommandPalette(scope: .sliders)
            }
        case .mergeFocusStack:
            guard stackWorkspace == nil, let suggestion = stackSuggestions.first else { return false }
            mergeStack(suggestion)
        case .editFocusStack:
            guard stackWorkspace == nil, let selection, SupportedFormats.isStack(selection) else { return false }
            openStackWorkspace(selection)
        case .sendFeedback:
            guard onSendFeedback != nil else { return false }
            sendFeedback()
        case .importPhotos: ImportActions.open(model: self)
        case .importFromLightroom: return LightroomActions.open(model: self)
        case .moveEditsAndMetadata: return moveEditsAndMetadata()
        // The app's, which a key reaches through the action's menu item when the item doesn't carry the key.
        case .openFolder, .export, .exportWithPrevious, .filmLooks: return MenuBarKeys.chooseItem(of: action)
        case .testCamera:
            guard let onTestCamera else { return false }
            onTestCamera()
        default:
            return false
        }
        return true
    }

    /// Whether `perform` would do something now. The command palette dims what it can't run,
    /// and the menus disable it.
    func canPerform(_ action: ShortcutAction) -> Bool {
        guard !isHeldByDialog(action) else { return false }
        guard action.isAvailable else {
            return action == .cropTool
        }
        guard module == .develop || !action.isDevelopOnly else { return false }
        guard module == .library || !action.isLibraryOnly else { return false }
        if let available = canPerformHealthShortcut(action) ?? canPerformStackShortcut(action)
            ?? canPerformPainterShortcut(action) ?? canPerformSourceShortcut(action)
            ?? canPerformModuleShortcut(action) ?? canPerformGridShortcut(action) ?? canPerformPanelShortcut(action)
            ?? canPerformFileShortcut(action) ?? canPerformCullingShortcut(action) {
            return available
        }
        let photo = info != nil
        let whiteBalance = info?.supportsWhiteBalance == true
        let masking = activeTool == .masking
        switch action {
        case .beforeAfter, .nextCompareLayout, .previousCompareLayout, .toggleZoom, .zoomIn, .zoomOut,
             .clipping, .rawClipping, .colorAssessment, .infoOverlay:
            return photo
        case .labReadout, .lightsOut, .fullScreenPreview, .toggleToolbar, .toggleSidePanels, .toggleAllPanels,
             .toggleFilmstrip,
             .toggleLeftPanel, .toggleRightPanel, .panelBasic, .panelToneCurve, .panelColorMixer, .panelColorGrading,
             .panelDetail, .panelLens, .panelTransform, .panelEffects, .panelCalibration:
            return true
        case .selectAllPhotos: return selection != nil && photoSelection.count < items.count
        case .syncSettings, .syncSettingsAgain: return canSync
        case .undoSync: return settingsSync.canUndo
        case .toggleAutoSync: return true
        case .deselectOtherPhotos: return isMultiSelecting
        case .previousPhoto, .nextPhoto:
            guard let from = opening ?? selection, let index = library.index(of: from) else { return false }
            return items.indices.contains(index + (action == .nextPhoto ? 1 : -1))
        // A burst of arrow presses in the palette, or a run of nudges, is a step not yet
        // recorded, and ⌘Z undoes it.
        case .undo: return canUndo || commandPalette?.hasOpenStep == true || hasOpenNudgeRun
        case .redo: return canRedo
        case .pasteSettings: return hasClipboard && photo
        case .pastePrevious: return previousSelection != nil && photo
        case .copySettings, .copySettingsAgain, .resetAll, .autoTone, .toggleBlackAndWhite, .newSnapshot, .newPreset,
             .previousSetting, .nextSetting, .increaseSetting, .decreaseSetting, .findAdjustment, .export,
             .exportWithPrevious:
            return photo
        case .autoWhiteBalance, .whiteBalanceSelector: return whiteBalance
        case .calibrateFromTarget: return canCalibrateFromTarget
        case .editTool, .maskingTool, .cancel, .showShortcuts, .openFolder, .importPhotos, .filmLooks, .commandPalette:
            return true
        case .testCamera: return onTestCamera != nil
        case .importFromLightroom: return library.service?.isReady == true
        case .sendFeedback: return onSendFeedback != nil
        case .moveEditsAndMetadata: return rootMovingEdits != nil
        case .cropTool, .healTool, .rotateLeft, .rotateRight: return photo
        case .cropAspectLock: return activeTool == .crop
        case .mergeFocusStack: return stackWorkspace == nil && !stackSuggestions.isEmpty
        case .editFocusStack: return stackWorkspace == nil && selection.map(SupportedFormats.isStack) == true
        case .linearMask: return photo && canCreateMask(.linear)
        case .radialMask: return photo && canCreateMask(.radial)
        case .brushMask: return photo && canCreateMask(.brush)
        case .colorRangeMask: return photo && canCreateMask(.colorRange)
        case .luminanceRangeMask: return photo && canCreateMask(.luminanceRange)
        case .depthRangeMask: return photo && canCreateMask(.depthRange)
        case .maskOverlay, .maskOverlayColor: return masking || activeTool == .crop
        case .maskPins: return masking || activeTool == .heal
        case .deleteMask: return (masking && selectedMaskID != nil) || (activeTool == .heal && selectedSpotID != nil)
        default:
            return false
        }
    }

    // MARK: - View

    private func togglePresentation() {
        if isPresenting {
            if let saved = visibilityBeforePresenting {
                leftPanelVisible = saved.left
                rightPanelVisible = saved.right
                filmstripVisible = saved.filmstrip
            }
            visibilityBeforePresenting = nil
        } else {
            visibilityBeforePresenting = (leftPanelVisible, rightPanelVisible, filmstripVisible)
            leftPanelVisible = false
            rightPanelVisible = false
            filmstripVisible = false
        }
        isPresenting.toggle()
        onToggleFullScreen?()
    }

    /// Esc: leaves whatever temporary mode is active, innermost first; in Library, the loupe for the grid.
    private func cancelCurrentMode() -> Bool {
        let develop = module == .develop
        if showShortcuts {
            showShortcuts = false
        } else if develop, drawingKind != nil || isRefiningEdges {
            cancelDrawing()
        } else if develop, peoplePicker != nil {
            closePeoplePicker()
        } else if develop, landscapePicker != nil {
            closeLandscapePicker()
        } else if develop, eyedropperActive {
            eyedropperActive = false
        } else if develop, calibrationTargetActive || calibrationTarget != nil {
            calibrationTargetActive = false
            calibrationTarget = nil
        } else if develop, pointColorEyedropperActive {
            pointColorEyedropperActive = false
        } else if develop, isPlacingGuides {
            isPlacingGuides = false
        } else if develop, isStraightening {
            isStraightening = false
        } else if isPresenting {
            togglePresentation()
        } else if lightsOut > 0 {
            lightsOut = 0
        } else if !develop, libraryView != .grid {
            libraryView = .grid
        } else if develop, activeTool != .edit {
            activeTool = .edit
        } else {
            return false
        }
        return true
    }

    /// Opens a Develop panel (and the right-hand column) and switches to the Edit tool.
    func revealPanel(_ panel: PanelID) {
        activeTool = .edit
        rightPanelVisible = true
        if expandedPanels.contains(panel) {
            expandedPanels.remove(panel)
        } else {
            togglePanel(panel, solo: soloMode)
        }
    }

    // MARK: - Setting focus and nudges

    /// The sliders `,` and `.` step through: Basic in the Edit tool, the selected mask's
    /// adjustments in the Masking tool.
    private var focusCycle: [ParameterID] {
        if activeTool == .masking, selectedMask != nil {
            return ParameterID.localParameters.filter(\.spec.availability.isLive)
        }
        let wb: [ParameterID] = info?.supportsWhiteBalance == true ? [.temperature, .tint] : []
        return wb + [.exposure, .contrast, .highlights, .shadows, .whites, .blacks, .vibrance, .saturation]
    }

    func cycleFocusedParameter(by offset: Int) {
        let cycle = focusCycle
        guard !cycle.isEmpty else { return }
        if activeTool == .edit {
            expandedPanels.insert(.basic)
        }
        guard let current = focusedParameter, let index = cycle.firstIndex(of: current) else {
            focusedParameter = cycle.first { $0 == .exposure || $0 == .localExposure } ?? cycle[0]
            return
        }
        focusedParameter = cycle[(index + offset + cycle.count) % cycle.count]
    }

    /// `=` / `-`: a Lightroom-sized nudge (1/40 of the slider's travel; ⇧ for 1/10). A run of
    /// them on one slider is one history step, which ends when they pause, on another shortcut,
    /// on Undo, or when another photo opens.
    func nudgeFocusedParameter(direction: Double, large: Bool) {
        let cycle = focusCycle
        let parameter = focusedParameter.flatMap { cycle.contains($0) ? $0 : nil }
            ?? cycle.first { $0 == .exposure || $0 == .localExposure }
        guard let parameter, info != nil else { return }
        focusedParameter = parameter
        if let run = nudgeRun, run.parameter != parameter || run.photo != selection {
            endNudgeRun()
        }
        // A nudge during a drag is part of the drag's step.
        if nudgeRun == nil, editStart == nil {
            beginEdit(parameter)
            nudgeRun = NudgeRun(parameter: parameter, photo: selection, start: recipe)
        }
        let spec = parameter.spec
        let position = spec.position(for: sliderValue(parameter)) + direction * (large ? 0.1 : 0.025)
        setSliderValue(parameter, spec.value(atPosition: position))
        guard nudgeRun != nil else { return }
        nudgeRun?.end?.cancel()
        nudgeRun?.end = Task { [weak self] in
            try? await Task.sleep(for: NudgeRun.gap)
            guard !Task.isCancelled else { return }
            self?.endNudgeRun()
        }
    }

    internal var hasOpenNudgeRun: Bool {
        nudgeRun != nil
    }

    /// Records a run of nudges as one step. Undo calls it first, so ⌘Z during a run undoes all
    /// of it, and opening another photo does, so the step is saved with the photo it was made on.
    internal func endNudgeRun() {
        guard let run = nudgeRun else { return }
        run.end?.cancel()
        nudgeRun = nil
        // An edit begun since (a slider drag) has taken the run's place.
        guard editStart == run.start, editParameter == run.parameter else { return }
        endEdit()
    }

    // MARK: - Rating, flags and labels

    var currentMetadata: PhotoMetadata {
        photoMetadata
    }
}

/// The `=` / `-` presses since the last pause, recorded as one history step when it ends.
struct NudgeRun {
    /// The pause that ends a run, as for ⌘-scrolling a slider.
    static let gap = Duration.milliseconds(400)

    let parameter: ParameterID
    let photo: URL?
    let start: EditRecipe
    var end: Task<Void, Never>?
}
