import Foundation
import RedlampEngineAPI

/// Masking: Lightroom's model of masks made of components (add, subtract, intersect),
/// each mask with its own local adjustments.
public extension EditorModel {
    var selectedMask: MaskLayer? {
        selectedMaskID.flatMap { id in masks.first { $0.id == id } }
    }

    var selectedOutline: MaskOutline? {
        selectedMaskID.flatMap { id in maskOutlines.first { $0.id == id } }
    }

    /// The selected component's structure, observing only mask structure.
    var selectedComponentOutline: MaskOutline.Component? {
        guard let mask = selectedOutline else { return nil }
        return mask.components.first { $0.id == selectedComponentID } ?? mask.components.last
    }

    var selectedComponent: MaskComponent? {
        guard let mask = selectedMask else { return nil }
        return mask.components.first { $0.id == selectedComponentID } ?? mask.components.last
    }

    // MARK: - Drawing

    /// Arms the canvas: the next drag draws a shape of `kind`.
    func startDrawing(_ kind: MaskKind, operation: MaskOperation = .add, addingTo target: UUID? = nil) {
        guard canCreateMask(kind), info != nil else { return }
        if kind.isAI {
            Task { await startAIMask(kind, operation: operation, addingTo: target) }
            return
        }
        activeTool = .masking
        edgeBrushTarget = nil
        drawingKind = kind
        drawingOperation = operation
        drawingTarget = target
        drawingComponentID = nil
    }

    func cancelDrawing() {
        drawingKind = nil
        drawingTarget = nil
        drawingComponentID = nil
        edgeBrushTarget = nil
    }

    /// Creates the armed shape and starts a live edit; call `updateComponent` while
    /// dragging and `finishDrawing` at the end.
    func beginDrawing(_ shape: MaskShape) {
        guard let kind = drawingKind else { return }
        beginEdit()
        let component = MaskComponent(shape: shape, operation: drawingTarget == nil ? .add : drawingOperation)
        var next = recipe
        if let target = drawingTarget, let index = next.masks.firstIndex(where: { $0.id == target }) {
            next.masks[index].components.append(component)
            selectedMaskID = target
        } else {
            guard next.masks.count < MaskLayer.maximumLayers else { return }
            let mask = MaskLayer(name: "Mask \(nextMaskNumber)", components: [component])
            next.masks.append(mask)
            selectedMaskID = mask.id
        }
        selectedComponentID = component.id
        pendingDrawingName = drawingTarget == nil ? "New \(kind.name)" : "Add \(kind.name)"
        pendingDrawingKind = kind
        applyLive(next)
        drawingKind = nil
        drawingTarget = nil
    }

    func finishDrawing() {
        endEdit(.mask(pendingDrawingKind), pendingDrawingName ?? "New Mask")
        pendingDrawingName = nil
        pendingDrawingKind = nil
    }

    /// Adds a component made with a tool that stays armed (brush, range samplers): to
    /// `drawingTarget` with `drawingOperation`, or as a new mask. Selects it and makes it the
    /// one later strokes or samples go into. Returns the history name, or nil when no mask fits.
    internal func addDrawnComponent(_ shape: MaskShape, kind: MaskKind, to next: inout EditRecipe) -> String? {
        let component = MaskComponent(shape: shape, operation: drawingTarget == nil ? .add : drawingOperation)
        let name: String
        if let target = drawingTarget, let index = next.masks.firstIndex(where: { $0.id == target }) {
            next.masks[index].components.append(component)
            selectedMaskID = target
            name = "Add \(kind.name)"
        } else {
            guard next.masks.count < MaskLayer.maximumLayers else { return nil }
            let mask = MaskLayer(name: "Mask \(nextMaskNumber)", components: [component])
            next.masks.append(mask)
            selectedMaskID = mask.id
            name = "New \(kind.name)"
        }
        selectedComponentID = component.id
        drawingComponentID = component.id
        drawingTarget = nil
        return name
    }

    internal var nextMaskNumber: Int {
        let numbers = recipe.masks.compactMap { Int($0.name.replacingOccurrences(of: "Mask ", with: "")) }
        return (numbers.max() ?? 0) + 1
    }

    // MARK: - Editing shapes

    /// Live shape update during a drag (inside a `beginEdit` / `endEdit` pair), or with a `name`
    /// a step of its own.
    func updateComponent(_ componentID: UUID, in maskID: UUID, shape: MaskShape, name: String? = nil) {
        mutateMask(maskID, name: name, kind: shape.kind) { mask in
            if let index = mask.components.firstIndex(where: { $0.id == componentID }) {
                mask.components[index].shape = shape
            }
        }
    }

    func setComponentInverted(_ componentID: UUID, in maskID: UUID, _ inverted: Bool) {
        mutateMask(
            maskID,
            name: inverted ? "Invert Component" : "Uninvert Component",
            kind: kind(of: componentID),
        ) { mask in
            if let index = mask.components.firstIndex(where: { $0.id == componentID }) {
                mask.components[index].inverted = inverted
            }
        }
    }

    func setComponentOperation(_ componentID: UUID, in maskID: UUID, _ operation: MaskOperation) {
        mutateMask(maskID, name: "\(operation.name) Component", kind: kind(of: componentID)) { mask in
            if let index = mask.components.firstIndex(where: { $0.id == componentID }) {
                mask.components[index].operation = operation
            }
        }
    }

    /// Reuses another mask's coverage as a component of `maskID`.
    func addMaskReference(_ referencedID: UUID, to maskID: UUID, operation: MaskOperation) {
        guard referencedID != maskID, let referenced = recipe.mask(referencedID) else { return }
        let component = MaskComponent(shape: .maskReference(MaskReference(maskID: referencedID)), operation: operation)
        mutateMask(maskID, name: "\(operation.name) \(referenced.name)", kind: .existingMask) { mask in
            mask.components.append(component)
        }
        selectedMaskID = maskID
        selectedComponentID = component.id
    }

    /// Moves a component of `maskID` to `target`'s place, as dragging it onto `target` does. The
    /// components combine in order, so this can change what the mask covers.
    func moveComponent(_ componentID: UUID, in maskID: UUID, onto target: UUID) {
        guard componentID != target, let mask = recipe.mask(maskID),
              let from = mask.components.firstIndex(where: { $0.id == componentID }),
              let to = mask.components.firstIndex(where: { $0.id == target })
        else { return }
        mutateMask(maskID, name: "Reorder Components", kind: kind(of: componentID)) { mask in
            mask.components.insert(mask.components.remove(at: from), at: to)
        }
    }

    func deleteComponent(_ componentID: UUID, in maskID: UUID) {
        guard let mask = recipe.mask(maskID) else { return }
        if mask.components.count <= 1 {
            deleteMask(maskID)
            return
        }
        mutateMask(maskID, name: "Delete Component", kind: kind(of: componentID)) { mask in
            mask.components.removeAll { $0.id == componentID }
        }
        if selectedComponentID == componentID {
            selectedComponentID = nil
        }
    }

    // MARK: - Masks

    func selectMask(_ id: UUID?) {
        selectedMaskID = id
        selectedComponentID = nil
    }

    func deleteMask(_ id: UUID) {
        guard let mask = recipe.mask(id) else { return }
        let next = recipe.removingMasks([id])
        if selectedMaskID == id {
            selectedMaskID = next.masks.last?.id
            selectedComponentID = nil
        }
        commit(next, .mask(nil), "Delete \(mask.name)")
    }

    func duplicateMask(_ id: UUID, inverted: Bool = false) {
        guard let original = recipe.mask(id), recipe.masks.count < MaskLayer.maximumLayers else { return }
        var copy = original
        copy.id = UUID()
        copy.name = "\(original.name) Copy"
        copy.components = original.components.map { component in
            var duplicate = component
            duplicate.id = UUID()
            if inverted {
                duplicate.inverted.toggle()
            }
            return duplicate
        }
        var next = recipe
        next.masks.append(copy)
        selectedMaskID = copy.id
        commit(next, .mask(nil), inverted ? "Duplicate and Invert \(original.name)" : "Duplicate \(original.name)")
    }

    /// Moves mask `id` to `target`'s place, as dragging it onto `target` in the Masks panel does.
    /// Masks add up, so the order changes only the list.
    func moveMask(_ id: UUID, onto target: UUID) {
        guard id != target, let from = recipe.masks.firstIndex(where: { $0.id == id }),
              let to = recipe.masks.firstIndex(where: { $0.id == target })
        else { return }
        var next = recipe
        next.masks.insert(next.masks.remove(at: from), at: to)
        commit(next, .mask(nil), "Reorder Masks")
    }

    func renameMask(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let index = recipe.masks.firstIndex(where: { $0.id == id }) else { return }
        var next = recipe
        next.masks[index].name = trimmed
        commit(next, .mask(nil), "Rename Mask") { $0.mask(id)?.name ?? "" }
    }

    func toggleMaskVisibility(_ id: UUID) {
        guard let mask = recipe.mask(id) else { return }
        mutateMask(id, name: mask.isVisible ? "Hide \(mask.name)" : "Show \(mask.name)") { $0.isVisible.toggle() }
    }

    func resetMaskAdjustments(_ id: UUID) {
        guard let mask = recipe.mask(id), let index = recipe.masks.firstIndex(where: { $0.id == id }) else { return }
        var next = recipe
        next.masks[index].resetAdjustments()
        commit(next, .reset, "Reset \(mask.name)")
    }

    func deleteAllMasks() {
        var next = recipe
        next.masks = []
        selectMask(nil)
        commit(next, .mask(nil), "Delete All Masks")
    }

    // MARK: - Mask Curves

    /// The selected mask's curve for `channel`.
    func maskCurve(_ channel: MaskCurves.Channel) -> [CurvePoint] {
        selectedMask?.curves?[channel] ?? EditRecipe.linearPointCurve
    }

    /// Sets the selected mask's curve for `channel`: live during a drag, otherwise as a step.
    func setMaskCurve(_ channel: MaskCurves.Channel, _ points: [CurvePoint]) {
        guard let mask = selectedMask else { return }
        mutateMask(mask.id, name: "\(mask.name) Curve") { layer in
            var curves = layer.curves ?? MaskCurves()
            curves[channel] = points
            layer.curves = curves
        }
    }

    func resetMaskCurves() {
        guard let mask = selectedMask, mask.curves != nil else { return }
        mutateMask(mask.id, name: "Reset \(mask.name) Curves") { $0.curves = nil }
    }

    // MARK: - Mask sliders

    /// Values for mask-scoped sliders (local adjustments, Amount, Feather).
    func maskValue(_ parameter: ParameterID) -> Double {
        if ParameterID.brushParameters.contains(parameter) {
            return brushes[activeBrush][parameter]
        }
        guard let mask = selectedMask else { return parameter.spec.defaultValue }
        return Self.maskValue(parameter, of: mask, component: selectedComponent)
    }

    /// A mask slider's value in `recipe`, for the mask and component it would show.
    internal static func maskValue(
        _ parameter: ParameterID,
        in recipe: EditRecipe,
        mask: UUID?,
        component: UUID?,
    ) -> Double {
        guard let layer = mask.flatMap(recipe.mask) else { return parameter.spec.defaultValue }
        return maskValue(
            parameter,
            of: layer,
            component: layer.components.first { $0.id == component }
                ?? layer.components.last,
        )
    }

    private static func maskValue(_ parameter: ParameterID, of mask: MaskLayer, component: MaskComponent?) -> Double {
        switch parameter {
        case .maskAmount:
            return mask.amount
        case .maskDetail:
            return mask.detail
        case .maskFeather:
            if case let .radial(gradient) = component?.shape {
                return gradient.feather
            }
            return parameter.spec.defaultValue
        case .maskColorRefine:
            if case let .colorRange(range) = component?.shape {
                return range.refine
            }
            return parameter.spec.defaultValue
        case .maskAIFeather, .maskAIEdge:
            if case let .ai(ai) = component?.shape {
                return parameter == .maskAIFeather ? ai.feather : ai.edge
            }
            return parameter.spec.defaultValue
        default:
            return mask[parameter]
        }
    }

    func setMaskValue(_ parameter: ParameterID, _ value: Double) {
        let quantized = parameter.spec.quantize(value)
        if ParameterID.brushParameters.contains(parameter) {
            brushes[activeBrush][parameter] = quantized
            return
        }
        guard let maskID = selectedMaskID else { return }
        let componentID = selectedComponent?.id
        let before = recipe
        mutateMask(maskID, name: nil) { mask in
            switch parameter {
            case .maskAmount:
                mask.amount = quantized
            case .maskDetail:
                mask.detail = quantized
            case .maskFeather:
                if let index = mask.components.firstIndex(where: { $0.id == componentID }),
                   case var .radial(gradient) = mask.components[index].shape {
                    gradient.feather = quantized
                    mask.components[index].shape = .radial(gradient)
                }
            case .maskColorRefine:
                if let index = mask.components.firstIndex(where: { $0.id == componentID }),
                   case var .colorRange(range) = mask.components[index].shape {
                    range.refine = quantized
                    mask.components[index].shape = .colorRange(range)
                }
            case .maskAIFeather, .maskAIEdge:
                if let index = mask.components.firstIndex(where: { $0.id == componentID }),
                   case var .ai(ai) = mask.components[index].shape {
                    if parameter == .maskAIFeather {
                        ai.feather = quantized
                    } else {
                        ai.edge = quantized
                    }
                    mask.components[index].shape = .ai(ai)
                }
            default:
                mask[parameter] = quantized
            }
        }
        // Outside a drag (typed values, resets) each change is its own history step.
        if editStart == nil, recipe != before {
            recordStep(for: parameter, from: before)
        }
    }

    // MARK: - Slider routing

    /// Sliders call these; mask-scoped parameters go to the selected mask.
    func sliderValue(_ parameter: ParameterID) -> Double {
        if parameter.isSpotScoped {
            return spotValue(parameter)
        }
        return parameter.isMaskScoped ? maskValue(parameter) : value(parameter)
    }

    func setSliderValue(_ parameter: ParameterID, _ value: Double) {
        if parameter.isSpotScoped {
            setSpotValue(parameter, value)
        } else if parameter.isMaskScoped {
            setMaskValue(parameter, value)
        } else {
            setValue(parameter, value)
        }
    }

    func resetSlider(_ parameter: ParameterID) {
        if parameter.isSpotScoped {
            setSpotValue(parameter, parameter.spec.defaultValue)
        } else if parameter.isMaskScoped {
            setMaskValue(parameter, parameter.spec.defaultValue)
        } else {
            reset(parameter)
        }
    }

    // MARK: - Helpers

    /// Applies `change` to one mask. With a `name`, records a history step; without,
    /// it is part of a live edit.
    private func mutateMask(
        _ id: UUID, name: String?, kind: MaskKind? = nil, _ change: (inout MaskLayer) -> Void,
    ) {
        guard let index = recipe.masks.firstIndex(where: { $0.id == id }) else { return }
        var next = recipe
        change(&next.masks[index])
        guard next != recipe else { return }
        if let name, editStart == nil {
            commit(next, .mask(kind), name)
        } else {
            applyLive(next)
        }
    }

    /// The type of a component of the edit.
    internal func kind(of componentID: UUID) -> MaskKind? {
        locateComponent(componentID, in: recipe).flatMap { recipe.masks[$0.mask].components[$0.component].shape.kind }
    }
}
