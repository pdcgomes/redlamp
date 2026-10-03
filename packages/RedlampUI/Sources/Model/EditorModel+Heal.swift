import Foundation
import RedlampDocument
import RedlampEngineAPI

/// The Healing tool's settings for the next spot, in the sliders' units.
public struct SpotSettings: Hashable, Sendable {
    public var size: Double = ParameterID.spotSize.spec.defaultValue
    public var feather: Double = ParameterID.spotFeather.spec.defaultValue
    public var opacity: Double = ParameterID.spotOpacity.spec.defaultValue

    public init() {}

    public subscript(parameter: ParameterID) -> Double {
        get {
            switch parameter {
            case .spotSize: size
            case .spotFeather: feather
            case .spotOpacity: opacity
            default: parameter.spec.defaultValue
            }
        }
        set {
            let value = parameter.spec.clamp(newValue)
            switch parameter {
            case .spotSize: size = value
            case .spotFeather: feather = value
            case .spotOpacity: opacity = value
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

/// The Healing tool: Heal and Clone spots (RM-01).
public extension EditorModel {
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
        spot.source = await engine.retouchSource(for: spot, recipe: recipe) ?? nearbySource(for: spot)
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
        spot.source = await engine.retouchSource(for: spot, recipe: recipe) ?? nearbySource(for: spot)
        var next = recipe
        next.spots.append(spot)
        commit(next, .retouch, "\(spot.mode.name) Brush")
        selectedSpotID = spot.id
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

    /// Heal or Clone for the next spot, and for the selected one.
    func setSpotMode(_ mode: RetouchSpot.Mode) {
        spotMode = mode
        if let id = selectedSpotID {
            updateSpot(id, name: mode.name) { $0.mode = mode }
        }
    }

    /// Asks the engine for a source again, as if the selected spot had just been placed.
    func findNewSource() async {
        guard let spot = selectedSpot else { return }
        var earlier = recipe
        earlier.spots = Array(recipe.spots.prefix { $0.id != spot.id })
        guard let source = await engine.retouchSource(for: spot, recipe: earlier) else { return }
        updateSpot(spot.id, name: "New Source") { $0.source = source }
    }

    internal func spotValue(_ parameter: ParameterID) -> Double {
        selectedSpot?[parameter] ?? spotSettings[parameter]
    }

    /// The selected spot's setting, and the next spot's.
    internal func setSpotValue(_ parameter: ParameterID, _ value: Double) {
        spotSettings[parameter] = value
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
