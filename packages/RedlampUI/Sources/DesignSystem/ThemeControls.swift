import RedlampDesign
import SwiftUI

/// Theme, appearance and tint, compact, for the toolbar's Theme popover and the harness.
public struct ThemeControls: View {
    @Binding var theme: ThemeSelection

    public init(theme: Binding<ThemeSelection>) {
        _theme = theme
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ThemePicker(selection: $theme)
                .labelsHidden()
            Picker("Appearance", selection: $theme.appearance) {
                Label("Dark", systemImage: "moon.fill").tag(ThemeAppearance.dark)
                Label("Light", systemImage: "sun.max.fill").tag(ThemeAppearance.light)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .help("Dark or light half of the theme")
            VStack(alignment: .leading, spacing: 2) {
                Text("Tint").font(.callout)
                TintSlider(tint: $theme.tint)
            }
            Toggle("Tint native controls", isOn: $theme.tintsNativeControls)
                .toggleStyle(.checkbox)
                .font(.callout)
                .help("Checkboxes, segmented pickers and buttons take the theme's accent instead of the system one")
        }
    }
}

/// The theme menu, each entry with its swatch.
public struct ThemePicker: View {
    @Binding var selection: ThemeSelection

    public init(selection: Binding<ThemeSelection>) {
        _selection = selection
    }

    public var body: some View {
        Picker("Theme", selection: $selection.familyID) {
            ForEach(ThemeCatalog.families) { family in
                Label {
                    Text(family.displayName)
                } icon: {
                    ThemeDot(family: family, appearance: selection.appearance).image
                }
                .tag(family.id)
            }
        }
        .pickerStyle(.menu)
        .help("The theme the panels are drawn in")
    }
}

/// How much of the theme's hue to keep, with its percentage. It edits a draft and commits
/// on release, since every commit rebuilds the panels.
public struct TintSlider: View {
    @Binding var tint: Double
    @State private var draft: Double?

    public init(tint: Binding<Double>) {
        _tint = tint
    }

    public var body: some View {
        HStack(spacing: 8) {
            Slider(
                value: Binding(get: { draft ?? tint }, set: { draft = $0 }),
                in: 0 ... 1,
                onEditingChanged: { editing in
                    if !editing, let draft {
                        tint = draft
                        self.draft = nil
                    }
                },
            )
            .controlSize(.small)
            Text("\(Int(((draft ?? tint) * 100).rounded())) %")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)
        }
        .help("How much of the theme's hue to keep. 0 % keeps its tones in neutral grey.")
    }
}

/// A theme reduced to a dot: its panel, its label tone and its accent.
public struct ThemeDot: View {
    let family: ThemeFamily
    let appearance: ThemeAppearance
    var size: CGFloat

    public init(family: ThemeFamily, appearance: ThemeAppearance, size: CGFloat = 14) {
        self.family = family
        self.appearance = appearance
        self.size = size
    }

    public var body: some View {
        let tokens = ThemeMapping.tokens(for: family, appearance: appearance, tint: 1)
        let accent = tokens.accent ?? tokens.editedDot
        Circle()
            .fill(LinearGradient(
                colors: [tokens.panelBackground.color, tokens.value.color, accent.color],
                startPoint: .topLeading,
                endPoint: .bottomTrailing,
            ))
            .overlay(Circle().strokeBorder(.gray.opacity(0.5), lineWidth: 0.5))
            .frame(width: size, height: size)
    }

    /// The dot as an image, since menus draw only images and text.
    @MainActor public var image: Image {
        let renderer = ImageRenderer(content: self)
        renderer.scale = 2
        return renderer.nsImage.map { Image(nsImage: $0) } ?? Image(systemName: "circle.fill")
    }
}
