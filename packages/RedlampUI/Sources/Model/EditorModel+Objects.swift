import Foundation
import RedlampEngineAPI

/// Objects masks: hovering previews what a click would select; clicking selects it, and later
/// clicks add to it (or, with Option, take away from it).
public extension EditorModel {
    func armObjectSelection(operation: MaskOperation = .add, addingTo target: UUID? = nil) {
        guard info != nil else { return }
        activeTool = .masking
        drawingKind = .objects
        drawingOperation = operation
        drawingTarget = target
        drawingComponentID = nil
        objectPreview = nil
    }

    /// The object mask being refined in this selection, if a click made one.
    private var selectedObject: (mask: AIMask, location: (mask: Int, component: Int))? {
        guard let id = drawingComponentID, let location = locateComponent(id, in: recipe),
              case let .ai(mask) = recipe.masks[location.mask].components[location.component].shape,
              mask.kind == .objects
        else { return nil }
        return (mask, location)
    }

    /// Previews the object under the pointer (only before the first click: after it, clicks refine).
    func hoverObject(at point: ImagePoint?) {
        objectHoverTask?.cancel()
        guard drawingKind == .objects, let point, selectedObject == nil, let visit = currentVisit else {
            objectPreview = nil
            return
        }
        objectHoverTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(40))
            guard let self, !Task.isCancelled else { return }
            let preview = try? await engine.previewObjectMask(MaskRequest(kind: .objects, prompts: [point]))
            guard !Task.isCancelled, currentVisit == visit, drawingKind == .objects else { return }
            objectPreview = preview
        }
    }

    func selectObject(at point: ImagePoint, excluding: Bool = false) async {
        guard drawingKind == .objects, let visit = currentVisit, aiMaskProgress == nil else { return }
        objectHoverTask?.cancel()
        objectPreview = nil
        aiMaskProgress = .objects
        maskMessage = nil
        defer { aiMaskProgress = nil }
        let existing = selectedObject
        var prompts = existing?.mask.prompts ?? []
        var excluded = existing?.mask.excludedPrompts ?? []
        if excluding {
            guard existing != nil else { return }
            excluded.append(point)
        } else {
            prompts.append(point)
        }
        do {
            guard let mask = try await engine.computeMasks(
                MaskRequest(kind: .objects, prompts: prompts, excluded: excluded),
            ).first, currentVisit == visit, drawingKind == .objects else { return }
            var next = recipe
            let name: String
            if let existing {
                next.masks[existing.location.mask].components[existing.location.component].shape = .ai(mask)
                name = excluding ? "Remove from Object" : "Add to Object"
            } else {
                guard let added = addDrawnComponent(.ai(mask), kind: .objects, to: &next) else { return }
                name = added
            }
            commit(next, .mask(.objects), name)
        } catch {
            maskMessage = (error as? MaskComputationError)?.description ?? error.localizedDescription
        }
    }
}
