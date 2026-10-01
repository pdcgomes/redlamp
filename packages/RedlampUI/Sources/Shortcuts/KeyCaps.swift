import SwiftUI

/// Keys drawn as keycaps, one chip per key (`⇧` `⌘` `C`), as Raycast draws them. Used by
/// the ⌘/ sheet, the command palette's rows and its hint bar.
@_spi(Harness) public struct KeyCaps: View {
    let keys: [String]
    var active = false
    var dimmed = false
    @Environment(\.themeTokens) private var themeTokens

    public init(_ keys: [String], active: Bool = false, dimmed: Bool = false) {
        self.keys = keys
        self.active = active
        self.dimmed = dimmed
    }

    public var body: some View {
        let colors = ThemeColors(themeTokens)
        HStack(spacing: 2) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                Text(key)
                    .font(.system(size: 10.5, weight: .medium, design: .rounded).monospacedDigit())
                    .frame(minWidth: 12)
                    .padding(.horizontal, 3.5)
                    .padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 4)
                        .fill(active ? colors.accent.opacity(0.3) : colors.selection))
                    .foregroundStyle(active ? colors.accent : (dimmed ? colors.tertiaryLabel : colors.value))
            }
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(keys.joined(separator: " "))
    }
}
