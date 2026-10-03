import AppKit
import Foundation
import RedlampDocument
import RedlampEngineAPI

/// The Healing tool's settings for the next spot, in the sliders' units.
public struct SpotSettings: Hashable, Sendable {
    public var size: Double = ParameterID.spotSize.spec.defaultValue
    public var feather: Double = ParameterID.spotFeather.spec.defaultValue
    public var opacity: Double = ParameterID.spotOpacity.spec.defaultValue
    public var visualize: Double = ParameterID.spotVisualize.spec.defaultValue

    public init() {}

    public subscript(parameter: ParameterID) -> Double {
        get {
            switch parameter {
            case .spotSize: size
            case .spotFeather: feather
            case .spotOpacity: opacity
            case .spotVisualize: visualize
            default: parameter.spec.defaultValue
            }
        }
        set {
            let value = parameter.spec.clamp(newValue)
            switch parameter {
            case .spotSize: size = value
            case .spotFeather: feather = value
            case .spotOpacity: opacity = value
            case .spotVisualize: visualize = value
            default: break
            }
        }
    }
}

extension RetouchSpot {
    /// Size 1...100 as a radius (a fraction of the image height): from a speck of dust to a fifth
    /// of the photo, finer at the small end.
    static func radius(size: Double) -> Double {
        0.004 + 0.2 * pow(min(max(size, 1), 100) / 100, 2)
    }

    static func size(radius: Double) -> Double {
        min(max(100 * (max(radius - 0.004, 0) / 0.2).squareRoot(), 1), 100)
    }

    subscript(parameter: ParameterID) -> Double {
        switch parameter {
        case .spotSize: Self.size(radius: radius)
        case .spotFeather: feather
        case .spotOpacity: opacity
        default: parameter.spec.defaultValue
        }
    }
}

/// What a click in the Healing tool does: add a spot, or pick a person or an object to remove.
public enum SpotPick: String, CaseIterable, Sendable {
    case spot
    case person
    case object

    public var name: String {
        switch self {
        case .spot: "Spot"
        case .person: "Person"
        case .object: "Object"
        }
    }
}

/// The Healing tool: Remove, Heal and Clone spots (RM-01, RM-07, RM-08).
public extension EditorModel {
    /// How far a picked person or object's mask grows to cover its edge and contact shadow, as a
    /// fraction of the image height.
    static let regionGrowth = 0.005

    /// Removes the person or object under `point` (`spotPick`), its own mask grown a little.
    func pickRegion(at point: ImagePoint) async {
        guard info != nil, spotPick != .spot, !isPickingRegion else { return }
        let pick = spotPick
        let kind: MaskKind = pick == .person ? .people : .objects
        pickMessage = nil
        guard availableAIMaskKinds.contains(kind) else {
            pickMessage = "Picking \(pick.name.lowercased())s isn't available for this photo."
            return
        }
        if let model = await engine.modelNeeded(for: kind) {
            pickMessage = "Picking objects needs \(model.name), from Settings › Models."
            return
        }
        isPickingRegion = true
        defer { isPickingRegion = false }
        do {
            let found = try await engine.computeMasks(
                pick == .person ? MaskRequest(kind: .people) : MaskRequest(kind: .objects, prompts: [point]),
            )
            let chosen = pick == .person ? Self.mask(at: point, in: found) : found.first
            guard let mask = chosen else {
                pickMessage = pick == .person ? "No one is there." : "Nothing was found there."
                return
            }
            let spot = RetouchSpot(
                mode: .remove, center: mask.center, source: mask.center, region: mask, radius: Self.regionGrowth,
                feather: spotSettings.feather, opacity: spotSettings.opacity,
            )
            var next = recipe
            next.spots.append(spot)
            commit(next, .retouch, "Remove \(pick.name)")
            selectedSpotID = spot.id
        } catch {
            pickMessage = "\(error)"
        }
    }

    /// The mask covering `point`, or else the one whose middle is nearest.
    internal static func mask(at point: ImagePoint, in masks: [AIMask]) -> AIMask? {
        let covering = masks.first { mask in
            guard let png = mask.bitmap.png, let bitmap = NSBitmapImageRep(data: png) else { return false }
            let x = min(max(Int(point.x * Double(bitmap.pixelsWide)), 0), bitmap.pixelsWide - 1)
            let y = min(max(Int(point.y * Double(bitmap.pixelsHigh)), 0), bitmap.pixelsHigh - 1)
            return (bitmap.colorAt(x: x, y: y)?.whiteComponent ?? 0) >= 0.5
        }
        return covering ?? masks.min { a, b in
            hypot(a.center.x - point.x, a.center.y - point.y) < hypot(b.center.x - point.x, b.center.y - point.y)
        }
    }

    var selectedSpot: RetouchSpot? {
        selectedSpotID.flatMap { id in recipe.spots.first { $0.id == id } }
    }

    /// Adds a spot at `center` with the tool's settings, copying from the source the engine finds.
    func addSpot(at center: ImagePoint) async {
        guard info != nil else { return }
        var spot = RetouchSpot(
            mode: spotMode, center: center, source: center, radius: RetouchSpot.radius(size: spotSettings.size),
            feather: spotSettings.feather, opacity: spotSettings.opacity,
        )
        if spot.mode.usesSource {
            spot.source = await engine.retouchSource(for: spot, recipe: recipe) ?? nearbySource(for: spot)
        }
        var next = recipe
        next.spots.append(spot)
        commit(next, .retouch, spot.mode.name)
        selectedSpotID = spot.id
    }

    /// Adds a brushed spot along `points`, painted with the tool's settings; a stroke too short to
    /// be one adds a circle.
    func addStroke(_ points: [ImagePoint]) async {
        guard info != nil, let first = points.first else { return }
        let radius = RetouchSpot.radius(size: spotSettings.size)
        let aspect = Double(info?.pixelSize.width ?? 1) / Double(max(info?.pixelSize.height ?? 1, 1))
        // A quarter of the brush apart is plenty to follow the hand.
        var kept = [first]
        for point in points.dropFirst() {
            let last = kept[kept.count - 1]
            if hypot((point.x - last.x) * aspect, point.y - last.y) >= radius / 4 {
                kept.append(point)
            }
        }
        guard kept.count > 1 else {
            await addSpot(at: first)
            return
        }
        var spot = RetouchSpot(
            mode: spotMode, center: first, source: first,
            stroke: kept.dropFirst().map { ImagePoint(x: $0.x - first.x, y: $0.y - first.y) },
            radius: radius, feather: spotSettings.feather, opacity: spotSettings.opacity,
        )
        if spot.mode.usesSource {
            spot.source = await engine.retouchSource(for: spot, recipe: recipe) ?? nearbySource(for: spot)
        }
        var next = recipe
        next.spots.append(spot)
        commit(next, .retouch, "\(spot.mode.name) Brush")
        selectedSpotID = spot.id
    }

    /// Heals every speck of sensor dust the engine finds, in one step.
    func removeDust() async {
        guard info != nil, !isFindingDust else { return }
        isFindingDust = true
        defer { isFindingDust = false }
        let found = await engine.detectDust(recipe: recipe, sensitivity: 50)
        guard !found.isEmpty else {
            dustMessage = "No dust found."
            return
        }
        var spots: [RetouchSpot] = []
        for speck in found {
            var spot = RetouchSpot(center: speck.center, source: speck.center, radius: speck.radius)
            spot.source = await engine.retouchSource(for: spot, recipe: recipe) ?? nearbySource(for: spot)
            spots.append(spot)
        }
        var next = recipe
        next.spots += spots
        commit(next, .retouch, "Remove Dust")
        selectedSpotID = nil
        dustMessage = spots.count == 1 ? "Healed 1 speck of dust." : "Healed \(spots.count) specks of dust."
    }

    /// Remove Dust across the selection: the specks found in the same place on the sensor in
    /// several of its photos are healed in all of them, the open photo as a step of its own history,
    /// the others as one batch Undo can put back (`SettingsSync`).
    func removeDustInSelection() async {
        guard isMultiSelecting, let open = selection, info != nil, !isFindingDust, settingsSync.progress == nil else {
            return
        }
        saveNow()
        isFindingDust = true
        defer {
            isFindingDust = false
            dustSearch = nil
        }
        let photos = selectedPhotos.map { url in
            (url: url, recipe: url == open ? recipe : settingsSync.store.load(for: url)?.recipe ?? EditRecipe())
        }
        dustSearch = SettingsSync.Progress(title: "Finding Dust", done: 0, total: photos.count)
        let finder = makeWorkerEngine?() ?? engine
        let found = await finder.detectDust(in: photos, sensitivity: 50) { [weak self] done in
            Task { @MainActor in self?.dustSearch?.done = done }
        }
        let specks = Set(found.values.flatMap { $0.map { "\($0.center.x),\($0.center.y)" } }).count
        guard !found.isEmpty else {
            dustMessage = "No dust found in the same place in two or more photos."
            return
        }
        if let own = found[open], !own.isEmpty {
            var next = recipe
            for speck in own {
                var spot = RetouchSpot(center: speck.center, source: speck.center, radius: speck.radius)
                spot.source = await engine.retouchSource(for: spot, recipe: recipe) ?? nearbySource(for: spot)
                next.spots.append(spot)
            }
            commit(next, .retouch, "Remove Dust")
        }
        settingsSync.run(.healDust(found), on: otherSelectedPhotos, title: "Remove Dust", done: written)
        dustMessage = "Healed \(specks == 1 ? "1 speck" : "\(specks) specks") of dust in \(found.count == 1 ? "1 photo" : "\(found.count) photos")."
    }

    /// Changes a spot as part of a drag (between `beginEdit` and `endEdit`), or as one step.
    func updateSpot(_ id: UUID, name: String? = nil, _ change: (inout RetouchSpot) -> Void) {
        guard let index = recipe.spots.firstIndex(where: { $0.id == id }) else { return }
        var next = recipe
        change(&next.spots[index])
        if let name, editStart == nil {
            commit(next, .retouch, name)
        } else {
            applyLive(next)
        }
    }

    func deleteSpot(_ id: UUID) {
        var next = recipe
        next.spots.removeAll { $0.id == id }
        commit(next, .retouch, "Delete Spot")
        if selectedSpotID == id {
            selectedSpotID = nil
        }
    }

    func deleteAllSpots() {
        var next = recipe
        next.spots = []
        commit(next, .retouch, "Delete All Spots")
        selectedSpotID = nil
    }

    /// Remove, Heal or Clone for the next spot, and for the selected one. A Remove spot becoming
    /// Heal or Clone finds a source first.
    func setSpotMode(_ mode: RetouchSpot.Mode) async {
        spotMode = mode
        guard var spot = selectedSpot else { return }
        spot.mode = mode
        if mode.usesSource, spot.source == spot.center {
            var earlier = recipe
            earlier.spots = Array(recipe.spots.prefix { $0.id != spot.id })
            spot.source = await engine.retouchSource(for: spot, recipe: earlier) ?? nearbySource(for: spot)
        }
        let changed = spot
        updateSpot(spot.id, name: mode.name) { $0 = changed }
    }

    /// Asks the engine for a source again, as if the selected spot had just been placed.
    func findNewSource() async {
        guard let spot = selectedSpot, spot.mode.usesSource else { return }
        var earlier = recipe
        earlier.spots = Array(recipe.spots.prefix { $0.id != spot.id })
        guard let source = await engine.retouchSource(for: spot, recipe: earlier) else { return }
        updateSpot(spot.id, name: "New Source") { $0.source = source }
    }

    internal func spotValue(_ parameter: ParameterID) -> Double {
        guard parameter != .spotVisualize else { return spotSettings.visualize }
        return selectedSpot?[parameter] ?? spotSettings[parameter]
    }

    /// The selected spot's setting, and the next spot's.
    internal func setSpotValue(_ parameter: ParameterID, _ value: Double) {
        spotSettings[parameter] = value
        guard parameter != .spotVisualize else {
            requestRender()
            return
        }
        guard let id = selectedSpotID else { return }
        let value = spotSettings[parameter]
        updateSpot(id, name: editStart == nil ? "Spot \(parameter.spec.label)" : nil) { spot in
            switch parameter {
            case .spotSize: spot.radius = RetouchSpot.radius(size: value)
            case .spotFeather: spot.feather = value
            case .spotOpacity: spot.opacity = value
            default: break
            }
        }
    }

    /// Two and a half radii to the side of a circle, or below (or above) a stroke, when the engine
    /// finds nothing better.
    private func nearbySource(for spot: RetouchSpot) -> ImagePoint {
        guard spot.stroke.isEmpty else {
            let ys = spot.points().map(\.y)
            let step = (ys.max() ?? 0) - (ys.min() ?? 0) + spot.radius * 2.5
            let below = (ys.max() ?? 0) + step + spot.radius <= 1
            return ImagePoint(x: spot.center.x, y: spot.center.y + (below ? step : -step))
        }
        let size = info?.pixelSize ?? PixelSize(width: 1, height: 1)
        let aspect = Double(size.height) / Double(max(size.width, 1))
        let step = spot.radius * 2.5 * aspect
        let x = spot.center.x + step <= 1 - spot.radius * aspect ? spot.center.x + step : spot.center.x - step
        return ImagePoint(x: x, y: spot.center.y)
    }
}
