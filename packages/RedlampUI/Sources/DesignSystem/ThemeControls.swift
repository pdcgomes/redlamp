import RedlampDesign
import SwiftUI

/// Theme, appearance and tint, for the app's Theme popover and the harness.
public struct ThemeControls: View {
    @Binding var theme: ThemeSelection
    @State private var draftTint: Double?

    public init(theme: Binding<ThemeSelection>) {
        _theme = theme
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Theme", selection: $theme.familyID) {
                ForEach(ThemeCatalog.families) { family in
                    Label {
                        Text(family.displayName)
                    } icon: {
                        ThemeDot(family: family, appearance: theme.appearance).image
                    }
                    .tag(family.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .help("The theme the panels are drawn in")
            Picker("Appearance", selection: $theme.appearance) {
                Label("Dark", systemImage: "moon.fill").tag(ThemeAppearance.dark)
                Label("Light", systemImage: "sun.max.fill").tag(ThemeAppearance.light)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .help("Dark or light half of the theme")
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Tint")
                    Spacer()
                    Text("\(Int(((draftTint ?? theme.tint) * 100).rounded())) %")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
                // Edits a draft and commits on release, since every commit rebuilds the panels.
                Slider(
                    value: Binding(get: { draftTint ?? theme.tint }, set: { draftTint = $0 }),
                    in: 0 ... 1,
                    onEditingChanged: { editing in
                        if !editing, let draftTint {
                            theme.tint = draftTint
                            self.draftTint = nil
                        }
                    },
                )
                .controlSize(.small)
                .help("How much of the theme's hue to keep. 0 % keeps its tones in neutral grey.")
            }
            Toggle("Tint native controls", isOn: $theme.tintsNativeControls)
                .toggleStyle(.checkbox)
                .font(.callout)
                .help("Checkboxes, segmented pickers and buttons take the theme's accent instead of the system one")
        }
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
