import Foundation
import RedlampDocument
import RedlampEngineAPI

extension HistoryAction {
    /// The icon beside a step in the History panel: a slider's panel glyph, a mask's type, or
    /// the operation's own.
    var symbol: String {
        switch self {
        case .open: "photo"
        case .clear: "clock.badge.xmark"
        case .restore: "clock.arrow.circlepath"
        case let .adjustment(parameter):
            PanelID.allCases.first { $0.parameters.contains(parameter) }?.symbol
                ?? (EditRecipe.geometryParameters.contains(parameter) ? "crop.rotate" : "slider.horizontal.3")
        case .reset: "arrow.counterclockwise"
        case .auto: "wand.and.rays"
        case .treatment: "circle.lefthalf.filled"
        case .baseLook: "camera.filters"
        case .whiteBalance: "thermometer.medium"
        case .toneCurve: PanelID.toneCurve.symbol
        case .recipe: "wand.and.stars"
        case .snapshot: "camera.viewfinder"
        case .paste: "doc.on.clipboard"
        case .crop: "crop"
        case .rotate: "rotate.right"
        case .flip: "arrow.left.and.right.righttriangle.left.righttriangle.right"
        case .straighten: "level"
        case .upright: "perspective"
        case let .mask(kind): kind?.symbol ?? EditTool.masking.symbol
        case .retouch: EditTool.heal.symbol
        case .edit: "slider.horizontal.3"
        }
    }
}

extension HistorySession {
    /// When the session started, as the History panel titles it: "Yesterday at 18:40".
    @MainActor var title: String {
        Self.titleFormatter.string(from: started)
    }

    @MainActor private static let titleFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()
}
