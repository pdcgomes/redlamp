import Foundation
import RedlampDocument
import RedlampEngineAPI

/// Everything a keyboard shortcut or its menu item can do.
public extension EditorModel {
    /// Performs a shortcut. Returns `false` when it does not apply in the current state, so
    /// the key event can continue to the rest of the app.
    @discardableResult
    func perform(_ action: ShortcutAction, shifted: Bool = false) -> Bool {
        guard action.isAvailable else {
            // Planned tools still open their tool card, so the shortcut is discoverable.
            switch action {
            case .cropTool: activeTool = .crop
            case .healTool: activeTool = .heal
            default: return false
            }
            return true
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
        case .copySettings: copySettings()
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
        case .newSnapshot: createSnapshot()
        case .newPreset: RecipeActions.createRecipe(model: self)
        case .previousSetting: cycleFocusedParameter(by: -1)
        case .nextSetting: cycleFocusedParameter(by: 1)
        case .increaseSetting: nudgeFocusedParameter(direction: 1, large: shifted)
        case .decreaseSetting: nudgeFocusedParameter(direction: -1, large: shifted)
        // Tools
        case .editTool: activeTool = .edit
        case .maskingTool: activeTool = activeTool == .masking ? .edit : .masking
        case .linearMask: startDrawing(.linear)
        case .radialMask: startDrawing(.radial)
        // Masking
        case .maskOverlay:
            guard activeTool == .masking else { return false }
            showMaskOverlay.toggle()
        case .maskOverlayColor:
            guard activeTool == .masking else { return false }
            maskOverlayColor = maskOverlayColor.next
        case .maskPins:
            guard activeTool == .masking else { return false }
            showMaskPins.toggle()
        case .deleteMask:
            guard activeTool == .masking, let mask = selectedMaskID else { return false }
            deleteMask(mask)
        case .cancel: return cancelCurrentMode()
        // Rating & flags
        case .rating0, .rating1, .rating2, .rating3, .rating4, .rating5:
            let stars = [ShortcutAction.rating0, .rating1, .rating2, .rating3, .rating4, .rating5]
                .firstIndex(of: action) ?? 0
            updateMetadata(advance: shifted) { $0.rating = stars }
        case .decreaseRating: updateMetadata(advance: shifted) { $0.rating = max($0.rating - 1, 0) }
        case .increaseRating: updateMetadata(advance: shifted) { $0.rating = min($0.rating + 1, 5) }
        case .flagPick: updateMetadata(advance: shifted) { $0.flag = $0.flag == .pick ? nil : .pick }
        case .flagReject: updateMetadata(advance: shifted) { $0.flag = $0.flag == .reject ? nil : .reject }
        case .unflag: updateMetadata(advance: shifted) { $0.flag = nil }
        case .labelRed: updateMetadata(advance: shifted) { $0.label = $0.label == .red ? nil : .red }
        case .labelYellow: updateMetadata(advance: shifted) { $0.label = $0.label == .yellow ? nil : .yellow }
        case .labelGreen: updateMetadata(advance: shifted) { $0.label = $0.label == .green ? nil : .green }
        case .labelBlue: updateMetadata(advance: shifted) { $0.label = $0.label == .blue ? nil : .blue }
        // File & Edit (open and export are handled by the app, which owns the panels)
        case .showShortcuts: showShortcuts.toggle()
        case .findAdjustment: showAdjustmentSearch.toggle()
        case .openFolder, .export: return false
        default:
            return false
        }
        return true
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

    /// Esc: leaves whatever temporary mode is active, innermost first.
    private func cancelCurrentMode() -> Bool {
        if showShortcuts {
            showShortcuts = false
        } else if drawingKind != nil {
            cancelDrawing()
        } else if eyedropperActive {
            eyedropperActive = false
        } else if isPresenting {
            togglePresentation()
        } else if lightsOut > 0 {
            lightsOut = 0
        } else if activeTool != .edit {
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

    /// `=` / `-`: a Lightroom-sized nudge (1/40 of the slider's travel; ⇧ for 1/10).
    func nudgeFocusedParameter(direction: Double, large: Bool) {
        let cycle = focusCycle
        let parameter = focusedParameter.flatMap { cycle.contains($0) ? $0 : nil }
            ?? cycle.first { $0 == .exposure || $0 == .localExposure }
        guard let parameter, info != nil else { return }
        focusedParameter = parameter
        let spec = parameter.spec
        let position = spec.position(for: sliderValue(parameter)) + direction * (large ? 0.1 : 0.025)
        setSliderValue(parameter, spec.value(atPosition: position))
    }

    // MARK: - Settings

    /// Applies the settings of the previously viewed photo (Lightroom's "Previous").
    func pasteFromPrevious() {
        guard let previous = previousSelection, info != nil,
              let sidecar = SidecarStore().load(for: previous)
        else { return }
        commit(sidecar.recipe, name: "Paste from Previous")
    }

    // MARK: - Rating, flags and labels

    var currentMetadata: PhotoMetadata {
        selection.flatMap { url in items.first { $0.url == url }?.metadata } ?? PhotoMetadata()
    }

    private func updateMetadata(advance: Bool, _ change: (inout PhotoMetadata) -> Void) {
        guard let url = selection, let index = items.firstIndex(where: { $0.url == url }) else { return }
        var metadata = items[index].metadata
        change(&metadata)
        items[index].metadata = metadata
        if info != nil {
            saveNow()
        } else {
            let store = SidecarStore()
            Task.detached(priority: .utility) { try? Library.writeMetadata(metadata, for: url, store: store) }
        }
        if advance {
            selectNext()
        }
    }
}
