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

    /// The command palette's own theme, from the same families and tokens; `nil` draws it
    /// in `selection`, the app's.
    public var paletteSelection: ThemeSelection? {
        didSet { savePalette() }
    }

    /// The opacity of the theme's panel color over the glass. Reduce Transparency (in
    /// Accessibility settings) makes the panels solid. A light theme keeps at least
    /// `lightPanelMinimumOpacity`: the glass shows the dark canvas behind the panels, which
    /// would turn a light panel grey and its grey labels unreadable.
    public var panelOpacity: Double {
        guard !reducesTransparency else { return 1 }
        let opacity = 1 - panelTransparency
        return selection.appearance == .light ? max(opacity, Self.lightPanelMinimumOpacity) : opacity
    }

    public static let lightPanelMinimumOpacity = 0.85

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
        if let id = defaults.string(forKey: Keys.paletteFamily),
           ThemeCatalog.families.contains(where: { $0.id == id }) {
            var palette = ThemeSelection(familyID: id)
            if let appearance = defaults.string(forKey: Keys.paletteAppearance)
                .flatMap(ThemeAppearance.init(rawValue:)) {
                palette.appearance = appearance
            }
            if defaults.object(forKey: Keys.paletteTint) != nil {
                palette.tint = min(max(defaults.double(forKey: Keys.paletteTint), 0), 1)
            }
            paletteSelection = palette
        }
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

    private func savePalette() {
        guard let paletteSelection else {
            for key in [Keys.paletteFamily, Keys.paletteAppearance, Keys.paletteTint] {
                defaults.removeObject(forKey: key)
            }
            return
        }
        defaults.set(paletteSelection.familyID, forKey: Keys.paletteFamily)
        defaults.set(paletteSelection.appearance.rawValue, forKey: Keys.paletteAppearance)
        defaults.set(paletteSelection.tint, forKey: Keys.paletteTint)
    }

    private enum Keys {
        static let family = "themeFamily"
        static let appearance = "themeAppearance"
        static let tint = "themeTint"
        static let nativeControls = "themeTintsNativeControls"
        static let panelTransparency = "panelTransparency"
        static let paletteFamily = "commandPaletteThemeFamily"
        static let paletteAppearance = "commandPaletteThemeAppearance"
        static let paletteTint = "commandPaletteThemeTint"
    }
}
