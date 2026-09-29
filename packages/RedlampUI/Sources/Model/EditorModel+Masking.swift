import Foundation
import RedlampEngineAPI

/// Masking: Lightroom's model of masks made of components (add, subtract, intersect),
/// each mask with its own local adjustments.
public extension EditorModel {
    var selectedMask: MaskLayer? {
        selectedMaskID.flatMap { recipe.mask($0) }
    }

    var selectedComponent: MaskComponent? {
        guard let mask = selectedMask else { return nil }
        return mask.components.first { $0.id == selectedComponentID } ?? mask.components.last
    }

    // MARK: - Drawing

    /// Arms the canvas: the next drag draws a shape of `kind`.
    func startDrawing(_ kind: MaskKind, operation: MaskOperation = .add, addingTo target: UUID? = nil) {
        guard kind.isAvailable, info != nil else { return }
        activeTool = .masking
        drawingKind = kind
        drawingOperation = operation
        drawingTarget = target
    }

    func cancelDrawing() {
        drawingKind = nil
        drawingTarget = nil
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
        applyLive(next)
        drawingKind = nil
        drawingTarget = nil
    }

    func finishDrawing() {
        endEdit(name: pendingDrawingName ?? "New Mask")
        pendingDrawingName = nil
    }

    private var nextMaskNumber: Int {
        let numbers = recipe.masks.compactMap { Int($0.name.replacingOccurrences(of: "Mask ", with: "")) }
        return (numbers.max() ?? 0) + 1
    }

    // MARK: - Editing shapes

    /// Live shape update during a drag (inside a `beginEdit` / `endEdit` pair).
    func updateComponent(_ componentID: UUID, in maskID: UUID, shape: MaskShape) {
        mutateMask(maskID, name: nil) { mask in
            if let index = mask.components.firstIndex(where: { $0.id == componentID }) {
                mask.components[index].shape = shape
            }
        }
    }

    func setComponentInverted(_ componentID: UUID, in maskID: UUID, _ inverted: Bool) {
        mutateMask(maskID, name: inverted ? "Invert Component" : "Uninvert Component") { mask in
            if let index = mask.components.firstIndex(where: { $0.id == componentID }) {
                mask.components[index].inverted = inverted
            }
        }
    }

    func setComponentOperation(_ componentID: UUID, in maskID: UUID, _ operation: MaskOperation) {
        mutateMask(maskID, name: "\(operation.name) Component") { mask in
            if let index = mask.components.firstIndex(where: { $0.id == componentID }) {
                mask.components[index].operation = operation
            }
        }
    }

    func deleteComponent(_ componentID: UUID, in maskID: UUID) {
        guard let mask = recipe.mask(maskID) else { return }
        if mask.components.count <= 1 {
            deleteMask(maskID)
            return
        }
        mutateMask(maskID, name: "Delete Component") { mask in
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
        var next = recipe
        next.masks.removeAll { $0.id == id }
        if selectedMaskID == id {
            selectedMaskID = next.masks.last?.id
            selectedComponentID = nil
        }
        commit(next, name: "Delete \(mask.name)")
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
        commit(next, name: inverted ? "Duplicate and Invert \(original.name)" : "Duplicate \(original.name)")
    }

    func renameMask(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        mutateMask(id, name: "Rename Mask") { $0.name = trimmed }
    }

    func toggleMaskVisibility(_ id: UUID) {
        guard let mask = recipe.mask(id) else { return }
        mutateMask(id, name: mask.isVisible ? "Hide \(mask.name)" : "Show \(mask.name)") { $0.isVisible.toggle() }
    }

    func resetMaskAdjustments(_ id: UUID) {
        guard let mask = recipe.mask(id) else { return }
        mutateMask(id, name: "Reset \(mask.name)") { $0.resetAdjustments() }
    }

    func deleteAllMasks() {
        var next = recipe
        next.masks = []
        selectMask(nil)
        commit(next, name: "Delete All Masks")
    }

    // MARK: - Mask sliders

    /// Values for mask-scoped sliders (local adjustments, Amount, Feather).
    func maskValue(_ parameter: ParameterID) -> Double {
        guard let mask = selectedMask else { return parameter.spec.defaultValue }
        switch parameter {
        case .maskAmount:
            return mask.amount
        case .maskFeather:
            if case let .radial(gradient) = selectedComponent?.shape {
                return gradient.feather
            }
            return parameter.spec.defaultValue
        default:
            return mask[parameter]
        }
    }

    func setMaskValue(_ parameter: ParameterID, _ value: Double) {
        guard let maskID = selectedMaskID else { return }
        let quantized = parameter.spec.quantize(value)
        let componentID = selectedComponent?.id
        let before = recipe
        mutateMask(maskID, name: nil) { mask in
            switch parameter {
            case .maskAmount:
                mask.amount = quantized
            case .maskFeather:
                if let index = mask.components.firstIndex(where: { $0.id == componentID }),
                   case var .radial(gradient) = mask.components[index].shape {
                    gradient.feather = quantized
                    mask.components[index].shape = .radial(gradient)
                }
            default:
                mask[parameter] = quantized
            }
        }
        // Outside a drag (typed values, resets) each change is its own history step.
        if editStart == nil, recipe != before {
            recordHistory(historyName(for: parameter))
        }
    }

    // MARK: - Slider routing

    /// Sliders call these; mask-scoped parameters go to the selected mask.
    func sliderValue(_ parameter: ParameterID) -> Double {
        parameter.isMaskScoped ? maskValue(parameter) : value(parameter)
    }

    func setSliderValue(_ parameter: ParameterID, _ value: Double) {
        if parameter.isMaskScoped {
            setMaskValue(parameter, value)
        } else {
            setValue(parameter, value)
        }
    }

    func resetSlider(_ parameter: ParameterID) {
        if parameter.isMaskScoped {
            setMaskValue(parameter, parameter.spec.defaultValue)
        } else {
            reset(parameter)
        }
    }

    // MARK: - Helpers

    /// Applies `change` to one mask. With a `name`, records a history step; without,
    /// it is part of a live edit.
    private func mutateMask(_ id: UUID, name: String?, _ change: (inout MaskLayer) -> Void) {
        guard let index = recipe.masks.firstIndex(where: { $0.id == id }) else { return }
        var next = recipe
        change(&next.masks[index])
        guard next != recipe else { return }
        if let name, editStart == nil {
            commit(next, name: name)
        } else {
            applyLive(next)
        }
    }
}
