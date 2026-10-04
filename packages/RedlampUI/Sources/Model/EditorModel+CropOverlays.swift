import Foundation
import Observation

/// Lightroom's Choose Overlays to Cycle and Choose Aspect Ratios (Tools ▸ Crop Guide Overlay):
/// the overlays `O` steps through, and the ratios the Aspect Ratios overlay outlines. Every one
/// is chosen at first, and at least one of each stays chosen.
public struct CropOverlayChoices: Hashable, Sendable {
    public private(set) var overlays = Set(CropOverlay.allCases)
    public private(set) var ratios = Set(CropOverlay.AspectRatio.allCases)

    public init() {}

    /// Whether `O` steps through the overlay. Clearing the last one chosen leaves it chosen.
    public subscript(overlay: CropOverlay) -> Bool {
        get { overlays.contains(overlay) }
        set {
            if newValue {
                overlays.insert(overlay)
            } else if overlays != [overlay] {
                overlays.remove(overlay)
            }
        }
    }

    /// Whether the Aspect Ratios overlay outlines the ratio. Clearing the last one chosen leaves
    /// it chosen.
    public subscript(ratio: CropOverlay.AspectRatio) -> Bool {
        get { ratios.contains(ratio) }
        set {
            if newValue {
                ratios.insert(ratio)
            } else if ratios != [ratio] {
                ratios.remove(ratio)
            }
        }
    }

    /// What `O` shows after `overlay`: the next one chosen, in Lightroom's order, wrapping. The
    /// overlay shown needn't be chosen: one just left out stays until `O` is pressed.
    public func overlay(after overlay: CropOverlay) -> CropOverlay {
        let all = CropOverlay.allCases
        let index = all.firstIndex(of: overlay)!
        return (1 ... all.count).map { all[(index + $0) % all.count] }.first(where: overlays.contains) ?? overlay
    }
}

public extension CropOverlay {
    /// The ratios the Aspect Ratios overlay can outline, Lightroom's, in its order. The raw
    /// values are the names a choice of them is kept under.
    enum AspectRatio: String, CaseIterable, Sendable {
        case square = "1x1"
        case fourByFive = "4x5"
        case letter = "8.5x11"
        case fiveBySeven = "5x7"
        case twoByThree = "2x3"
        case fourByThree = "4x3"
        case sixteenByNine = "16x9"
        case sixteenByTen = "16x10"

        /// Long side over short.
        public var value: Double {
            switch self {
            case .square: 1
            case .fourByFive: 5.0 / 4
            case .letter: 11 / 8.5
            case .fiveBySeven: 7.0 / 5
            case .twoByThree: 3.0 / 2
            case .fourByThree: 4.0 / 3
            case .sixteenByNine: 16.0 / 9
            case .sixteenByTen: 16.0 / 10
            }
        }

        public var title: String {
            switch self {
            case .square: "1 × 1"
            case .fourByFive: "4 × 5 / 8 × 10"
            case .letter: "8.5 × 11"
            case .fiveBySeven: "5 × 7"
            case .twoByThree: "2 × 3 / 4 × 6"
            case .fourByThree: "4 × 3"
            case .sixteenByNine: "16 × 9"
            case .sixteenByTen: "16 × 10"
            }
        }
    }
}

public extension EditorModel {
    /// The overlays `O` steps through and the ratios the Aspect Ratios overlay outlines, kept
    /// across launches. They are the app's, as in Lightroom: every editor shares them.
    var cropOverlayChoices: CropOverlayChoices {
        get { CropOverlayChoices.Store.shared.choices }
        set { CropOverlayChoices.Store.shared.choices = newValue }
    }
}

extension CropOverlayChoices {
    /// The choices, saved in user defaults as they change; `shared` is the app's.
    @MainActor @Observable
    final class Store {
        static let shared = Store()

        var choices: CropOverlayChoices {
            didSet { choices.save(in: defaults) }
        }

        @ObservationIgnored private let defaults: UserDefaults

        init(defaults: UserDefaults = .standard) {
            self.defaults = defaults
            choices = .saved(in: defaults)
        }
    }

    private static let defaultsKey = "app.redlamp.cropOverlays"

    static func saved(in defaults: UserDefaults = .standard) -> CropOverlayChoices {
        defaults.data(forKey: defaultsKey).flatMap { try? JSONDecoder().decode(CropOverlayChoices.self, from: $0) }
            ?? CropOverlayChoices()
    }

    func save(in defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}

/// Kept by name, so overlays and ratios added or reordered later don't change what was chosen.
extension CropOverlayChoices: Codable {
    private enum CodingKeys: String, CodingKey {
        case overlays, ratios
    }

    /// Names this version doesn't know are left out, and a list with nothing left chooses
    /// every one.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let overlayNames = try container.decodeIfPresent([String].self, forKey: .overlays) ?? []
        let ratioNames = try container.decodeIfPresent([String].self, forKey: .ratios) ?? []
        let overlays = CropOverlay.allCases.filter { overlayNames.contains($0.storedName) }
        let ratios = ratioNames.compactMap(CropOverlay.AspectRatio.init(rawValue:))
        self.init()
        if !overlays.isEmpty {
            self.overlays = Set(overlays)
        }
        if !ratios.isEmpty {
            self.ratios = Set(ratios)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(CropOverlay.allCases.filter(overlays.contains).map(\.storedName), forKey: .overlays)
        try container.encode(
            CropOverlay.AspectRatio.allCases.filter(ratios.contains).map(\.rawValue), forKey: .ratios,
        )
    }
}

private extension CropOverlay {
    var storedName: String {
        switch self {
        case .grid: "grid"
        case .thirds: "thirds"
        case .diagonal: "diagonal"
        case .goldenTriangle: "goldenTriangle"
        case .goldenRatio: "goldenRatio"
        case .goldenSpiral: "goldenSpiral"
        case .aspectRatios: "aspectRatios"
        }
    }
}
