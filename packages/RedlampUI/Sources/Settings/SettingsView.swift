import AppKit
import RedlampDesign
import RedlampEngineAPI
import SwiftUI

/// The Settings window (⌘,): one tab per section, each a grouped form.
public struct SettingsView: View {
    /// Where donations go. App Review rejects links to outside payment, so an App Store build needs a tip jar instead.
    public static let supportURL = URL(string: "https://ko-fi.com/pdcgomes")!

    @Bindable var theme: ThemeSettings
    let engine: (any EditingEngine)?

    public init(theme: ThemeSettings, engine: (any EditingEngine)? = nil) {
        self.theme = theme
        self.engine = engine
    }

    public var body: some View {
        TabView {
            Tab("Appearance", systemImage: "paintpalette") {
                AppearanceSettings(theme: theme)
            }
            if let engine {
                Tab("Models", systemImage: "cpu") {
                    ModelsSettings(engine: engine)
                }
            }
            Tab("About", systemImage: "info.circle") {
                AboutSettings()
            }
        }
        .frame(width: 500)
        .preferredColorScheme(theme.selection.appearance == .dark ? .dark : .light)
    }
}

private struct AppearanceSettings: View {
    @Bindable var theme: ThemeSettings

    var body: some View {
        Form {
            Section {
                ThemePicker(selection: $theme.selection)
                Picker("Appearance", selection: $theme.selection.appearance) {
                    Label("Dark", systemImage: "moon.fill").tag(ThemeAppearance.dark)
                    Label("Light", systemImage: "sun.max.fill").tag(ThemeAppearance.light)
                }
                .pickerStyle(.segmented)
                LabeledContent("Tint") {
                    TintSlider(tint: $theme.selection.tint)
                }
            } footer: {
                Text("""
                Neutral is Redlamp's own grey, which never tints your judgment of color. \
                Lower the tint to keep a theme's tones without its hue.
                """)
                .formFooter()
            }
            Section {
                LabeledContent("Transparency") {
                    TransparencySlider(transparency: $theme.panelTransparency)
                }
            } footer: {
                Text("""
                How much of the blurred window background shows through the panels and the \
                filmstrip. At 0 % they are solid, so a zoomed-in photo passing beneath them \
                can't tint them. Reduce Transparency in Accessibility settings makes them solid.
                """)
                .formFooter()
            }
            Section {
                Toggle("Tint native controls", isOn: $theme.selection.tintsNativeControls)
            } footer: {
                Text("""
                Checkboxes, segmented pickers and buttons take the theme's accent \
                instead of the one chosen in System Settings.
                """)
                .formFooter()
            }
            CommandPaletteThemeSettings(theme: theme)
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// The command palette's theme: the app's, or one of its own from the same themes.
private struct CommandPaletteThemeSettings: View {
    @Bindable var theme: ThemeSettings

    var body: some View {
        Section {
            Picker("Theme", selection: Binding(
                get: { theme.paletteSelection != nil },
                // Starts from the app's theme, so choosing one changes only what's picked.
                set: { theme.paletteSelection = $0 ? (theme.paletteSelection ?? theme.selection) : nil },
            )) {
                Text("Same as the app").tag(false)
                Text("Its own").tag(true)
            }
            .pickerStyle(.segmented)
            if theme.paletteSelection != nil {
                ThemePicker(selection: paletteSelection)
                Picker("Appearance", selection: paletteSelection.appearance) {
                    Label("Dark", systemImage: "moon.fill").tag(ThemeAppearance.dark)
                    Label("Light", systemImage: "sun.max.fill").tag(ThemeAppearance.light)
                }
                .pickerStyle(.segmented)
                LabeledContent("Tint") {
                    TintSlider(tint: paletteSelection.tint)
                }
            }
        } header: {
            Text("Command Palette")
        } footer: {
            Text("""
            The command palette (⌘K) floats over the photo. Give it its own theme to set it \
            apart from the panels, for example a light palette over a dark editor.
            """)
            .formFooter()
        }
    }

    private var paletteSelection: Binding<ThemeSelection> {
        Binding(
            get: { theme.paletteSelection ?? theme.selection },
            set: { theme.paletteSelection = $0 },
        )
    }
}

private struct AboutSettings: View {
    private let info = Bundle.main.infoDictionary ?? [:]

    var body: some View {
        VStack(spacing: 6) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 112, height: 112)
                .padding(.bottom, 6)
            Text(info["CFBundleDisplayName"] as? String ?? "Redlamp")
                .font(.title2.weight(.semibold))
            Text(version)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Text("Redlamp develops your raw photos without ever touching the originals.")
                .multilineTextAlignment(.center)
                .padding(.top, 10)
            Link("Support Redlamp", destination: SettingsView.supportURL)
                .padding(.top, 4)
            if let copyright = info["NSHumanReadableCopyright"] as? String {
                Text(copyright)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 32)
    }

    private var version: String {
        let short = info["CFBundleShortVersionString"] as? String ?? "–"
        let build = info["CFBundleVersion"] as? String
        return build.map { "Version \(short) (\($0))" } ?? "Version \(short)"
    }
}

extension Text {
    func formFooter() -> some View {
        font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
