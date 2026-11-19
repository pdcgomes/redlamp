import AppKit
import Observation
import RedlampCanvas

/// The grey around the photo in Develop, as Lightroom's right-click on the canvas chooses it. The Library's views
/// keep `PhotoSurround`'s dark grey.
public enum DevelopBackground: String, CaseIterable, Sendable {
    case white, lightGray, gray, mediumGray, darkGray, black

    public var title: String {
        switch self {
        case .white: "White"
        case .lightGray: "Light Gray"
        case .gray: "Gray"
        case .mediumGray: "Medium Gray"
        case .darkGray: "Dark Gray"
        case .black: "Black"
        }
    }

    /// The sRGB grey, 0 to 255, as Lightroom draws each (its dark grey being the canvas's own).
    var gray: Int {
        switch self {
        case .white: 0xFF
        case .lightGray: 0xE3
        case .gray: 0xBB
        case .mediumGray: 0x77
        case .darkGray: 0x1F
        case .black: 0x01
        }
    }

    /// Linear, as the canvas clears to it.
    var level: Double {
        if self == .darkGray {
            return CanvasMetalView.defaultSurround
        }
        let encoded = Double(gray) / 255
        return encoded <= 0.04045 ? encoded / 12.92 : pow((encoded + 0.055) / 1.055, 2.4)
    }
}

/// Develop's background, saved in user defaults as it changes; `shared` is the app's.
@MainActor @Observable
final class DevelopBackgroundPreference: NSObject {
    static let shared = DevelopBackgroundPreference()
    static let defaultsKey = "app.redlamp.developBackground"

    var background: DevelopBackground {
        didSet { defaults.set(background.rawValue, forKey: Self.defaultsKey) }
    }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        background = defaults.string(forKey: Self.defaultsKey).flatMap(DevelopBackground.init) ?? .darkGray
        super.init()
    }

    /// The menu a right-click on the canvas outside the photo opens.
    func menu() -> NSMenu {
        let menu = NSMenu(title: "Background")
        for (index, choice) in DevelopBackground.allCases.enumerated() {
            let item = NSMenuItem(title: choice.title, action: #selector(choose(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.state = choice == background ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    @objc private func choose(_ sender: NSMenuItem) {
        background = DevelopBackground.allCases[sender.tag]
    }
}

public extension EditorModel {
    /// View › Background Color, and a right-click on the canvas outside the photo: the grey around the photo in
    /// Develop. The app's, kept across launches; dark grey at first. Lights Out and the Color Assessment View
    /// replace it while they're on.
    var developBackground: DevelopBackground {
        get { DevelopBackgroundPreference.shared.background }
        set { DevelopBackgroundPreference.shared.background = newValue }
    }
}
