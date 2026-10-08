import Foundation
import RedlampEngineAPI

/// What a drag does in an Objects mask, as Lightroom's Rectangle Select and Brush Select.
public enum ObjectSelection: String, CaseIterable, Sendable {
    /// A box around the thing: Segment Anything's box prompt.
    case rectangle
    /// A stroke over the thing: points along it, as clicks there would be.
    case brush

    public var name: String {
        switch self {
        case .rectangle: "Rectangle"
        case .brush: "Brush"
        }
    }
}

/// Objects masks: hovering previews what a click would select; clicking, dragging a box or brushing
/// over a thing selects it, and later clicks and strokes add to it (or, with Option, take away from
/// it).
public extension EditorModel {
    func armObjectSelection(operation: MaskOperation = .add, addingTo target: UUID? = nil) {
        guard info != nil else { return }
        arm(.objects, operation: operation, target: target)
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
        await selectObject(adding: [point], excluding: excluding)
    }

    /// A stroke brushed over a thing: points spread along it, as clicks there would be.
    func selectObject(along stroke: [ImagePoint], excluding: Bool = false) async {
        await selectObject(adding: Self.prompts(along: stroke), excluding: excluding)
    }

    /// A box dragged around a thing. After the first selection it replaces the box before, and the
    /// clicks so far still count.
    func selectObject(in box: ImageRect) async {
        await selectObject(adding: [], excluding: false, box: box)
    }

    private func selectObject(adding points: [ImagePoint], excluding: Bool, box: ImageRect? = nil) async {
        guard drawingKind == .objects, let visit = currentVisit, aiMaskProgress == nil else { return }
        let existing = selectedObject
        var prompts = existing?.mask.prompts ?? []
        var excluded = existing?.mask.excludedPrompts ?? []
        if excluding {
            guard existing != nil else { return }
            excluded += points
        } else {
            prompts += points
        }
        let box = box ?? existing?.mask.box
        guard !prompts.isEmpty || box != nil else { return }
        objectHoverTask?.cancel()
        objectPreview = nil
        aiMaskProgress = .objects
        maskMessage = nil
        defer { aiMaskProgress = nil }
        do {
            guard let mask = try await engine.computeMasks(
                MaskRequest(kind: .objects, prompts: prompts, excluded: excluded, box: box),
            ).first, currentVisit == visit, drawingKind == .objects else { return }
            var next = recipe
            let name: String
            if let existing {
                next.masks[existing.location.mask].components[existing.location.component].shape = .ai(mask)
                name = excluding ? "Remove from Object" : points.isEmpty ? "Box Around Object" : "Add to Object"
            } else {
                guard let added = addDrawnComponent(.ai(mask), kind: .objects, to: &next) else { return }
                name = added
            }
            commit(next, .mask(.objects), name)
        } catch {
            maskMessage = (error as? MaskComputationError)?.description ?? error.localizedDescription
        }
    }

    /// Up to `count` points spread evenly along a stroke, by its length.
    static func prompts(along stroke: [ImagePoint], count: Int = 8) -> [ImagePoint] {
        var lengths = [0.0]
        for (a, b) in zip(stroke, stroke.dropFirst()) {
            lengths.append(lengths[lengths.count - 1] + hypot(b.x - a.x, b.y - a.y))
        }
        guard let total = lengths.last, total > 0, stroke.count > 1 else { return Array(stroke.prefix(1)) }
        let points = min(count, stroke.count)
        return (0 ..< points).map { index in
            let along = total * (Double(index) + 0.5) / Double(points)
            let end = max(lengths.firstIndex { $0 >= along } ?? lengths.count - 1, 1)
            let (a, b) = (stroke[end - 1], stroke[end])
            let segment = lengths[end] - lengths[end - 1]
            let t = segment > 0 ? (along - lengths[end - 1]) / segment : 0
            return ImagePoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
        }
    }
}
