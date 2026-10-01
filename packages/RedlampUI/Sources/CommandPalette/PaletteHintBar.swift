import SwiftUI

/// The hint capsule, like Raycast's action bar, with a tip or the location beside it.
struct PaletteHintBar: View {
    let hints: [PaletteHint]
    let leading: [PaletteTipPart]

    var body: some View {
        HStack(spacing: 8) {
            PaletteTipLine(parts: leading)
            Spacer(minLength: 8)
            PaletteHintCapsule(hints: hints)
        }
    }
}

struct PaletteHintCapsule: View {
    let hints: [PaletteHint]
    @Environment(\.themeTokens) private var themeTokens

    var body: some View {
        let colors = ThemeColors(themeTokens)
        HStack(spacing: 0) {
            ForEach(Array(hints.enumerated()), id: \.offset) { index, hint in
                if index > 0 {
                    Rectangle()
                        .fill(colors.divider)
                        .frame(width: 1, height: 14)
                        .padding(.horizontal, 8)
                }
                HStack(spacing: 5) {
                    Text(hint.title)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(hint.isActive ? colors.accent : colors.label)
                    KeyCaps(hint.keys, active: hint.isActive)
                }
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 5)
        .fixedSize()
        // Washed like the pane, so it reads over a bright photo as well as inside the list.
        .background(colors.panelBackground.opacity(0.82), in: .capsule)
        .glassEffect(.regular, in: .capsule)
    }
}

struct PaletteTipLine: View {
    let parts: [PaletteTipPart]
    @Environment(\.themeTokens) private var themeTokens

    var body: some View {
        let colors = ThemeColors(themeTokens)
        HStack(spacing: 4) {
            ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                switch part {
                case let .text(text):
                    Text(text)
                        .font(.system(size: 11.5))
                        .foregroundStyle(colors.secondaryLabel)
                        .lineLimit(1)
                case let .keys(keys):
                    KeyCaps(keys)
                }
            }
        }
    }
}
