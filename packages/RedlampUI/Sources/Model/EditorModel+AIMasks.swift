import Foundation
import RedlampEngineAPI

/// Subject, Sky, Background, People and Depth Range: computed by the engine, kept as bitmaps,
/// and only recomputed when the user asks (Update AI Masks).
public extension EditorModel {
    /// Whether the Create New Mask menu can make `kind` for this photo.
    func canCreateMask(_ kind: MaskKind) -> Bool {
        guard kind.isAvailable else { return false }
        return !kind.isAI || availableAIMaskKinds.contains(kind)
    }

    /// The People parts the menus offer, in Lightroom's order.
    var availablePersonParts: [PersonPart] {
        let available = engine.availablePersonParts()
        return PersonPart.allCases.filter(available.contains)
    }

    /// Computes an AI mask: a new mask, or a component of `target` with `operation`. People
    /// adds one component per person (one for all of them when subtracting or intersecting).
    func createAIMask(
        _ kind: MaskKind, part: PersonPart = .entirePerson, landscape: LandscapeClass = .vegetation,
        operation: MaskOperation = .add, addingTo target: UUID? = nil,
    ) async {
        guard info != nil, aiMaskProgress == nil else { return }
        let photo = selection
        activeTool = .masking
        cancelDrawing()
        aiMaskProgress = kind
        maskMessage = nil
        defer { aiMaskProgress = nil }
        let request = MaskRequest(
            kind: kind, part: part, combined: target != nil && operation != .add, landscape: landscape,
        )
        do {
            let masks = try await engine.computeMasks(request)
            guard selection == photo else { return }
            guard !masks.isEmpty else {
                let error: MaskComputationError = kind == .landscape ? .notFound(landscape)
                    : kind == .people && part != .entirePerson ? .notFound(part) : .nothingFound(kind)
                maskMessage = error.description
                return
            }
            var next = recipe
            let components = masks.enumerated().map { index, mask in
                MaskComponent(
                    shape: kind == .depthRange ? .depthRange(DepthRangeMask(depth: mask)) : .ai(mask),
                    operation: index == 0 && target != nil ? operation : .add,
                )
            }
            let title = kind == .people && part != .entirePerson ? part.name
                : kind == .landscape ? landscape.name : kind.name
            if let target, let index = next.masks.firstIndex(where: { $0.id == target }) {
                next.masks[index].components += components
                selectedMaskID = target
                commit(next, .mask(kind), "\(operation.name) \(title)")
            } else {
                guard next.masks.count < MaskLayer.maximumLayers else { return }
                let mask = MaskLayer(name: title, components: components)
                next.masks.append(mask)
                selectedMaskID = mask.id
                commit(next, .mask(kind), "New \(title)")
            }
            selectedComponentID = components.last?.id
        } catch {
            maskMessage = (error as? MaskComputationError)?.description ?? error.localizedDescription
        }
    }

    /// Starts an AI mask, asking first when its model needs downloading (App Review 4.2.3: the
    /// size is shown and nothing downloads without consent).
    func startAIMask(_ kind: MaskKind, operation: MaskOperation = .add, addingTo target: UUID? = nil) async {
        if let model = await engine.modelNeeded(for: kind) {
            pendingModel = (model, kind)
            drawingOperation = operation
            drawingTarget = target
            return
        }
        if kind == .objects {
            armObjectSelection(operation: operation, addingTo: target)
        } else {
            await createAIMask(kind, operation: operation, addingTo: target)
        }
    }

    /// The user agreed: downloads the pending model, then carries on with the mask.
    func downloadPendingModel() async {
        guard let (model, kind) = pendingModel else { return }
        let operation = drawingOperation
        let target = drawingTarget
        pendingModel = nil
        modelDownloadProgress = 0
        maskMessage = nil
        defer { modelDownloadProgress = nil }
        do {
            try await engine.downloadModel(model.id) { fraction in
                Task { @MainActor [weak self] in self?.modelDownloadProgress = fraction }
            }
            availableAIMaskKinds = engine.availableMaskKinds()
            modelDownloadProgress = nil
            await startAIMask(kind, operation: operation, addingTo: target)
        } catch {
            maskMessage = "\(model.name) couldn't be downloaded: \(error)"
        }
    }

    func declinePendingModel() {
        pendingModel = nil
        drawingTarget = nil
    }

    /// The AI components of the edit.
    var aiMaskCount: Int {
        masks.flatMap(\.components).count { component in
            switch component.shape {
            case .ai, .depthRange: true
            default: false
            }
        }
    }

    /// Recomputes every AI mask of the edit (of the masks `in`, when given) with today's models,
    /// keeping each component's place, operation and inversion. A person is matched by their index.
    func updateAIMasks(in masks: Set<UUID>? = nil) async {
        guard info != nil, aiMaskProgress == nil else { return }
        let photo = selection
        aiMaskProgress = .subject
        maskMessage = nil
        defer { aiMaskProgress = nil }
        let (next, failed) = await Self.recomputingAIMasks(recipe, in: masks, engine: engine)
        guard selection == photo else { return }
        if failed > 0 {
            maskMessage = "\(failed) AI mask\(failed == 1 ? "" : "s") couldn't be updated and kept their previous result."
        }
        commit(next, .mask(nil), "Update AI Masks")
    }

    /// `recipe` with its AI masks (those of the masks `in`, when given) computed again by `engine`
    /// for the photo it has open, Refine Edge strokes and all; and how many couldn't be, which keep
    /// their previous result.
    static func recomputingAIMasks(
        _ recipe: EditRecipe, in masks: Set<UUID>?, engine: any EditingEngine,
    ) async -> (recipe: EditRecipe, failed: Int) {
        var next = recipe
        var results: [MaskRequest: [AIMask]] = [:]
        var failed = 0
        for layer in next.masks.indices where masks?.contains(next.masks[layer].id) ?? true {
            for index in next.masks[layer].components.indices {
                let shape = next.masks[layer].components[index].shape
                let old: AIMask
                switch shape {
                case let .ai(mask): old = mask
                case let .depthRange(range): old = range.depth
                default: continue
                }
                let request = MaskRequest(updating: old)
                if results[request] == nil {
                    results[request] = await (try? engine.computeMasks(request)) ?? []
                }
                let found = results[request] ?? []
                guard let fresh = found.first(where: { $0.instance == old.instance }) ?? found.first else {
                    failed += 1
                    continue
                }
                if case var .depthRange(range) = shape {
                    range.depth = fresh
                    next.masks[layer].components[index].shape = .depthRange(range)
                } else {
                    // The Refine Edge brush's strokes, on the new mask's edge.
                    var fresh = fresh
                    if let strokes = old.refinements, !strokes.isEmpty,
                       let refined = try? await engine.refineMaskEdges(fresh.bitmap, along: strokes) {
                        fresh.bitmap = refined
                        fresh.refinements = strokes
                    }
                    next.masks[layer].components[index].shape = .ai(fresh)
                }
            }
        }
        return (next, failed)
    }
}
