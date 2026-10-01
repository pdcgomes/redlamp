import AppKit
import Observation
import RedlampDesign

/// The app's theme choice, kept in user defaults. Setting it installs the theme's tokens
/// in `Palette` straight away, before any view redraws.
@MainActor @Observable
public final class ThemeSettings {
    public var selection: ThemeSelection {
        didSet {
            Palette.current = selection.tokens
            save()
        }
    }

    /// How much of the system's blurred glass shows through the floating panels: 0 paints
    /// them in the theme's panel color, 1 leaves them clear glass. Kept apart from
    /// `selection`, which rebuilds the panels when it changes, so the slider can move live.
    public var panelTransparency: Double {
        didSet { defaults.set(panelTransparency, forKey: Keys.panelTransparency) }
    }

    /// The opacity of the theme's panel color over the glass. Reduce Transparency (in
    /// Accessibility settings) makes the panels solid.
    public var panelOpacity: Double {
        reducesTransparency ? 1 : 1 - panelTransparency
    }

    private var reducesTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var accessibilityObserver: (any NSObjectProtocol)?

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var selection = ThemeSelection()
        if let id = defaults.string(forKey: Keys.family), ThemeCatalog.families.contains(where: { $0.id == id }) {
            selection.familyID = id
        }
        if let appearance = defaults.string(forKey: Keys.appearance).flatMap(ThemeAppearance.init(rawValue:)) {
            selection.appearance = appearance
        }
        if defaults.object(forKey: Keys.tint) != nil {
            selection.tint = min(max(defaults.double(forKey: Keys.tint), 0), 1)
        }
        selection.tintsNativeControls = defaults.bool(forKey: Keys.nativeControls)
        self.selection = selection
        panelTransparency = defaults.object(forKey: Keys.panelTransparency) == nil
            ? 0.6
            : min(max(defaults.double(forKey: Keys.panelTransparency), 0), 1)
        Palette.current = selection.tokens
        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main,
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reducesTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
            }
        }
    }

    private func save() {
        defaults.set(selection.familyID, forKey: Keys.family)
        defaults.set(selection.appearance.rawValue, forKey: Keys.appearance)
        defaults.set(selection.tint, forKey: Keys.tint)
        defaults.set(selection.tintsNativeControls, forKey: Keys.nativeControls)
    }

    private enum Keys {
        static let family = "themeFamily"
        static let appearance = "themeAppearance"
        static let tint = "themeTint"
        static let nativeControls = "themeTintsNativeControls"
        static let panelTransparency = "panelTransparency"
    }
}
