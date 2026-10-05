import Foundation
import RedlampEngineAPI

/// Generative Remove in the Healing tool (RM-10): with Fill set to Generative, a new Remove spot is
/// filled by the generative model, with three variations to choose from; the fill is labelled as
/// generated, and content-aware fill is a click away.
public extension EditorModel {
    /// Fills a spot gets when it's filled on its own, and each time More is asked for. Spots filled
    /// together (Remove All) get one each.
    nonisolated static let fillVariations = 3

    /// Whether this Mac is offered generative fill: the model is here, or can be downloaded.
    var offersGenerativeFill: Bool {
        switch generativeAvailability {
        case .ready, .needsModel: true
        case .unavailable: false
        }
    }

    /// Whether new Remove spots are filled generatively now.
    var fillsNewSpotsGeneratively: Bool {
        fillsGeneratively && generativeAvailability == .ready
    }

    /// Asks the engine whether generative fill can run, for the Healing tool's Fill choice.
    func loadGenerativeFill() async {
        generativeAvailability = await engine.generativeFillAvailability()
    }

    /// Downloads the generative model, then asks again.
    func downloadGenerativeModel() async {
        guard case let .needsModel(model) = generativeAvailability, generativeDownload == nil else { return }
        generativeMessage = nil
        generativeDownload = 0
        defer { generativeDownload = nil }
        do {
            try await engine.downloadModel(model.id) { fraction in
                Task { @MainActor [weak self] in
                    if self?.generativeDownload != nil {
                        self?.generativeDownload = fraction
                    }
                }
            }
        } catch {
            generativeMessage = "\(model.name) couldn't be downloaded: \(error.localizedDescription)"
        }
        await loadGenerativeFill()
    }

    /// Fills `spots` (Remove spots) generatively, one after another, `variations` fills each: a
    /// spot's first fill goes into the edit as soon as it's made, as its own step, and the others
    /// are kept to choose from, in place of those made before. With `more`, the spot keeps its fill
    /// and gains variations. Replaces any filling under way.
    func fillGeneratively(_ spots: [UUID], variations: Int = fillVariations, more: Bool = false) {
        guard generativeAvailability == .ready, let visit = currentVisit else { return }
        let ids = spots.filter { id in recipe.spots.contains { $0.id == id && $0.mode == .remove } }
        guard let first = ids.first else { return }
        cancelGenerativeFill()
        generativeMessage = nil
        generating = (first, 0)
        generatingTask = Task { [weak self] in
            for (position, id) in ids.enumerated() {
                for variation in 0 ..< variations {
                    guard let self, !Task.isCancelled, currentVisit == visit,
                          let spot = recipe.spots.first(where: { $0.id == id })
                    else { return }
                    let done = Double(position * variations + variation)
                    let total = Double(ids.count * variations)
                    generating = (id, done / total)
                    do {
                        let fills = try await engine.generateFills(
                            for: spot, in: recipe, seeds: [Int.random(in: 0 ..< (1 << 31))],
                            options: GenerativeFillOptions(),
                        ) { fraction in
                            Task { @MainActor [weak self] in
                                if self?.generating?.spot == id {
                                    self?.generating?.progress = (done + fraction) / total
                                }
                            }
                        }
                        guard !Task.isCancelled, currentVisit == visit, let fill = fills.first,
                              let now = recipe.spots.first(where: { $0.id == id }), now.hasShape(of: spot)
                        else { return }
                        if variation == 0, !more {
                            generatedFills[id] = [fill]
                        } else {
                            generatedFills[id, default: []].append(fill)
                        }
                        if variation == 0, !more || spot.fill == nil {
                            updateSpot(id, name: "Generative Fill") { $0.fill = fill }
                        }
                    } catch {
                        guard !Task.isCancelled, currentVisit == visit else { return }
                        generativeMessage = "The spot couldn't be filled: \(error.localizedDescription)"
                        generating = nil
                        return
                    }
                }
            }
            self?.generating = nil
            self?.generatingTask = nil
        }
    }

    /// Fills `id` again after it was moved or resized on the canvas, when Fill is Generative.
    func refillGeneratively(_ id: UUID) {
        guard fillsNewSpotsGeneratively,
              let spot = recipe.spots.first(where: { $0.id == id }), spot.mode == .remove, spot.fill == nil
        else { return }
        fillGeneratively([id])
    }

    /// A generated fill is pixels at a fixed place in the photo, so a spot moved or reshaped since
    /// the edit began loses its fill, and is filled from the photo until it's filled again.
    internal func dropMovedFill(_ spot: inout RetouchSpot) {
        guard let fill = spot.fill, let before = (editStart ?? recipe).spots.first(where: { $0.id == spot.id }),
              before.fill == fill, !spot.hasShape(of: before)
        else { return }
        spot.fill = nil
        if generating?.spot == spot.id {
            cancelGenerativeFill()
        }
    }

    /// The fills made for `spot` this session, and which of them the edit has.
    func fillVariations(of spot: RetouchSpot) -> (index: Int, count: Int)? {
        guard let fill = spot.fill else { return nil }
        let made = generatedFills[spot.id] ?? []
        guard let index = made.firstIndex(where: { $0.bitmap.sha256 == fill.bitmap.sha256 }) else { return (0, 1) }
        return (index, made.count)
    }

    /// Puts the next (or, with -1, the previous) of the selected spot's fills in the edit.
    func showFillVariation(_ offset: Int) {
        guard let spot = selectedSpot, let variations = fillVariations(of: spot), variations.count > 1,
              let made = generatedFills[spot.id]
        else { return }
        let next = made[(variations.index + offset + made.count) % made.count]
        updateSpot(spot.id, name: "Generative Fill Variation") { $0.fill = next }
    }

    /// Fills the selected spot from the photo around it again, as content-aware Remove does.
    func useContentAwareFill() {
        guard let spot = selectedSpot, spot.fill != nil else { return }
        updateSpot(spot.id, name: "Content-Aware Fill") { $0.fill = nil }
    }

    func cancelGenerativeFill() {
        generatingTask?.cancel()
        generatingTask = nil
        generating = nil
    }

    /// The Healing tool closed: the model's memory goes back to the Mac.
    func releaseGenerativeFill() {
        cancelGenerativeFill()
        Task { await engine.releaseGenerativeFill() }
    }
}

extension RetouchSpot {
    /// Whether `other` covers the same pixels, so a fill generated for one fits the other.
    func hasShape(of other: RetouchSpot) -> Bool {
        center == other.center && radius == other.radius && stroke == other.stroke && region == other.region
    }
}
