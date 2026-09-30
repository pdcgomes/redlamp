import RedlampDesign
import SwiftUI

extension HarnessScene {
    static var themeGallery: HarnessScene {
        HarnessScene(
            id: "theme-gallery",
            title: "Theme gallery",
            symbol: "swatchpalette",
            synopsis: "Every theme at the chosen appearance and tint — look for labels that lose contrast and accents that shout",
            section: .foundations,
        ) {
            ThemeGalleryScene()
        }
    }
}

private struct ThemeGalleryScene: View {
    @Environment(\.themeSelection) private var selection

    var body: some View {
        SpecimenGroup(
            title: "Themes",
            note: """
            Each card is a miniature panel drawn from that theme's mapped tokens: a header with its edited dot, \
            a focused and a plain slider, the three label tones, a selected pill and a well. Tint and appearance \
            come from the controls under the scene list.
            """,
        ) {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 250, maximum: 280), spacing: 16, alignment: .top)],
                spacing: 16,
            ) {
                ForEach(ThemeCatalog.families) { family in
                    ThemeCard(
                        family: family,
                        tokens: ThemeMapping.tokens(
                            for: family,
                            appearance: selection.appearance,
                            tint: selection.tint,
                        ),
                        isCurrent: family.id == selection.familyID,
                    )
                }
            }
        }
    }
}

private struct ThemeCard: View {
    let family: ThemeFamily
    let tokens: PaletteTokens
    let isCurrent: Bool

    private var accent: Color {
        tokens.accent?.color ?? .accentColor
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(family.displayName.uppercased())
                    .font(Typography.panelTitle.font)
                    .foregroundStyle(tokens.value.color)
                Circle().fill(tokens.editedDot.color).frame(width: 5, height: 5)
                Spacer()
                Text(family.id).font(.caption2.monospaced()).foregroundStyle(tokens.tertiaryLabel.color)
            }
            Rectangle().fill(tokens.divider.color).frame(height: 1)
            slider("Exposure", fraction: 0.62, focused: true)
            slider("Contrast", fraction: 0.35, focused: false)
            HStack(spacing: 10) {
                Text("Label").foregroundStyle(tokens.label.color)
                Text("Secondary").foregroundStyle(tokens.secondaryLabel.color)
                Text("Tertiary").foregroundStyle(tokens.tertiaryLabel.color)
            }
            .font(Typography.label.font)
            HStack(spacing: 6) {
                Text("Fit")
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(tokens.selection.color))
                    .foregroundStyle(tokens.labelHover.color)
                Text("100%").padding(.horizontal, 8).padding(.vertical, 3).foregroundStyle(tokens.label.color)
                Spacer()
                Text("Reset").foregroundStyle(accent)
            }
            .font(Typography.label.font)
            RoundedRectangle(cornerRadius: 6).fill(tokens.well.color).frame(height: 28)
                .overlay(alignment: .leading) {
                    Text("Well").font(Typography.caption.font).foregroundStyle(tokens.secondaryLabel.color)
                        .padding(.leading, 8)
                }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(tokens.panelBackground.color))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isCurrent ? accent : Color.primary.opacity(0.12), lineWidth: isCurrent ? 2 : 1),
        )
    }

    private func slider(_ label: String, fraction: Double, focused: Bool) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(focused ? Typography.label.font.weight(.semibold) : Typography.label.font)
                .foregroundStyle(focused ? accent : tokens.label.color)
                .frame(width: Metrics.labelWidth, alignment: .leading)
            GeometryReader { proxy in
                let width = proxy.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(tokens.track.color).frame(height: Metrics.trackHeight)
                    Capsule().fill(tokens.trackFill.color).frame(width: width * fraction, height: Metrics.trackHeight)
                    Circle()
                        .fill(tokens.thumb.color)
                        .overlay(Circle().strokeBorder(tokens.thumbStroke.color, lineWidth: 0.5))
                        .shadow(color: tokens.thumbShadow.color, radius: 1, y: 0.5)
                        .frame(width: Metrics.thumbSize, height: Metrics.thumbSize)
                        .offset(x: width * fraction - Metrics.thumbSize / 2)
                }
                .frame(maxHeight: .infinity)
            }
            .frame(height: Metrics.rowHeight)
            Text(String(format: "%+.2f", fraction - 0.5))
                .font(Typography.value.font)
                .foregroundStyle(tokens.value.color)
                .frame(width: Metrics.valueWidth, alignment: .trailing)
        }
    }
}
