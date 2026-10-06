import RedlampDesign
import SwiftUI

/// Text to read before going on (a download's terms, a warning), on a faint card in its tone,
/// with what it offers to do below it.
@_spi(Harness) public struct NoticeCard<Actions: View>: View {
    let text: String
    let tone: NoticeTone
    let symbol: String?
    /// Shows a close button at the card's top right.
    let dismiss: (() -> Void)?
    let actions: Actions

    public init(
        _ text: String, tone: NoticeTone, symbol: String? = nil, dismiss: (() -> Void)? = nil,
        @ViewBuilder actions: () -> Actions,
    ) {
        self.text = text
        self.tone = tone
        self.symbol = symbol
        self.dismiss = dismiss
        self.actions = actions()
    }

    public var body: some View {
        let colors = Palette.notice(tone)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: symbol ?? tone.symbol)
                    .font(.system(size: 11))
                    .foregroundStyle(colors.glyph.color)
                Text(text)
                    .font(Theme.labelFont)
                    .foregroundStyle(Theme.value)
                    .fixedSize(horizontal: false, vertical: true)
                if let dismiss {
                    Spacer(minLength: 0)
                    Button(action: dismiss) { Image(systemName: "xmark") }
                        .buttonStyle(.plain)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.secondaryLabel)
                        .help("Dismiss")
                }
            }
            actions
        }
        .padding(Metrics.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Metrics.cardRadius).fill(colors.fill.color))
        .overlay(RoundedRectangle(cornerRadius: Metrics.cardRadius).strokeBorder(colors.border.color))
    }
}

@_spi(Harness) public extension NoticeCard where Actions == EmptyView {
    init(_ text: String, tone: NoticeTone, symbol: String? = nil, dismiss: (() -> Void)? = nil) {
        self.init(text, tone: tone, symbol: symbol, dismiss: dismiss) { EmptyView() }
    }
}
