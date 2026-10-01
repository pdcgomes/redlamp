import Foundation
import RedlampEngineAPI

/// Mask presets (built-in adaptive ones and the user's), AI masks following a paste, and edge
/// refinement.
public extension EditorModel {
    private static let presetsKey = "app.redlamp.maskPresets"

    /// The user's saved mask presets.
    var userMaskPresets: [MaskPreset] {
        get {
            UserDefaults.standard.data(forKey: Self.presetsKey)
                .flatMap { try? JSONDecoder().decode([MaskPreset].self, from: $0) } ?? []
        }
        set {
            UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: Self.presetsKey)
            maskPresetsVersion += 1
        }
    }

    var maskPresets: [MaskPreset] {
        _ = maskPresetsVersion
        return MaskPreset.builtIn + userMaskPresets
    }

    /// Whether this photo can make every AI mask the preset needs.
    func canApply(_ preset: MaskPreset) -> Bool {
        info != nil && preset.aiKinds.allSatisfy(canCreateMask)
    }

    func saveMaskPreset(from maskID: UUID, name: String) {
        guard let mask = recipe.mask(maskID) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        var presets = userMaskPresets
        presets.removeAll { $0.name == trimmed }
        presets.append(MaskPreset(mask, name: trimmed.isEmpty ? mask.name : trimmed))
        userMaskPresets = presets
    }

    func deleteMaskPreset(_ id: String) {
        userMaskPresets.removeAll { $0.id == id }
    }

    /// Adds the preset as a new mask, computing its AI components for this photo.
    func applyMaskPreset(_ preset: MaskPreset) async {
        guard info != nil, aiMaskProgress == nil else { return }
        let photo = selection
        activeTool = .masking
        aiMaskProgress = preset.aiKinds.first ?? .subject
        maskMessage = nil
        defer { aiMaskProgress = nil }
        var components: [MaskComponent] = []
        for component in preset.components {
            switch component {
            case let .shape(shape, operation, inverted):
                components.append(MaskComponent(shape: shape, operation: operation, inverted: inverted))
            case let .ai(kind, part, operation, inverted):
                do {
                    let masks = try await engine.computeMasks(MaskRequest(kind: kind, part: part, combined: true))
                    for (index, mask) in masks.enumerated() {
                        components.append(MaskComponent(
                            shape: kind == .depthRange ? .depthRange(DepthRangeMask(depth: mask)) : .ai(mask),
                            operation: index == 0 ? operation : .add, inverted: inverted,
                        ))
                    }
                } catch {
                    maskMessage = "\(preset.name): \((error as? MaskComputationError)?.description ?? "\(error)")"
                    return
                }
            }
        }
        guard selection == photo, !components.isEmpty, recipe.masks.count < MaskLayer.maximumLayers else { return }
        var mask = MaskLayer(
            name: preset.name, components: components, amount: preset.amount, adjustments: preset.localAdjustments,
        )
        mask.detail = preset.detail
        var next = recipe
        next.masks.append(mask)
        selectedMaskID = mask.id
        selectedComponentID = components.last?.id
        commit(next, name: "Apply \(preset.name)")
    }

    /// Pasted AI masks were made for another photo: compute them again for this one, as
    /// Lightroom does when syncing.
    func updatePastedAIMasks() {
        guard aiMaskCount > 0 else { return }
        Task { await updateAIMasks() }
    }

    /// Snaps an AI mask's edges to the photo's (a wider guided filter than when it was made).
    func refineEdges(_ componentID: UUID, in maskID: UUID) async {
        guard let component = recipe.mask(maskID)?.components.first(where: { $0.id == componentID }) else { return }
        let bitmap: MaskBitmap
        switch component.shape {
        case let .ai(mask): bitmap = mask.bitmap
        default: return
        }
        do {
            let refined = try await engine.refineMaskEdges(bitmap)
            guard case var .ai(mask) = recipe.mask(maskID)?.components.first(where: { $0.id == componentID })?.shape
            else { return }
            mask.bitmap = refined
            updateComponent(componentID, in: maskID, shape: .ai(mask), name: "Refine Edges")
        } catch {
            maskMessage = "The edges couldn't be refined: \(error)"
        }
    }
}
