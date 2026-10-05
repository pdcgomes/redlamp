import AppKit
import RedlampDesign
import SwiftUI

/// What's New's content, in the welcome's look: the film rises to its logo, the highlights develop
/// in beneath it, and each has a page with its screenshot.
struct WhatsNewView: View {
    let model: WhatsNewModel

    var body: some View {
        ZStack {
            if let player = model.player {
                FilmView(player: player)
                    .opacity(model.filmOpacity)
                    .animation(.easeInOut(duration: 0.3), value: model.filmOpacity)
                    .accessibilityHidden(true)
            }
            Group {
                switch model.step {
                case .film: Color.clear
                case .highlights: HighlightsPage(model: model)
                case let .page(index): ItemPage(model: model, index: index).id(index)
                }
            }
            .transition(.asymmetric(insertion: .identity, removal: .developOut))
        }
        .animation(.timingCurve(0.65, 0, 0.35, 1, duration: 0.67), value: model.step)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Brand.wall.color)
        .foregroundStyle(Brand.paper.color)
        .ignoresSafeArea()
        .focusEffectDisabled()
    }

    /// The feed names SF Symbols; one this macOS doesn't have shows as a sparkle.
    static func symbol(_ name: String) -> String {
        NSImage(systemSymbolName: name, accessibilityDescription: nil) == nil ? "sparkles" : name
    }
}

private struct HighlightsPage: View {
    static let rows = 4
    let model: WhatsNewModel

    var body: some View {
        VStack(spacing: 0) {
            Develop {
                PageTitle(model.title)
            }
            VStack(alignment: .leading, spacing: 16) {
                ForEach(Array(model.items.prefix(Self.rows).enumerated()), id: \.element.id) { index, item in
                    Develop(delay: 0.2 + 0.15 * Double(index)) {
                        Button {
                            model.show(page: index)
                        } label: {
                            Feature(symbol: WhatsNewView.symbol(item.symbol), title: item.title, text: item.summary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                if model.items.count > Self.rows {
                    Develop(delay: 0.2 + 0.15 * Double(Self.rows)) {
                        Text("And \(model.items.count - Self.rows) more")
                            .font(.system(size: 13))
                            .foregroundStyle(Brand.paper.opacity(0.5).color)
                            .padding(.leading, 44)
                    }
                }
            }
            .frame(width: 452, alignment: .leading)
            .padding(.top, 28)
            Spacer(minLength: 0)
            Develop(delay: 0.8) {
                PageButton("Continue", action: model.next)
            }
        }
        .padding(.top, WelcomeView.pageTop)
        .padding(.bottom, 44)
    }
}

/// A highlight: its screenshot, then what it is, with a button that opens it.
private struct ItemPage: View {
    static let screenshot = CGSize(width: 440, height: 275)
    let model: WhatsNewModel
    let index: Int

    private var item: WhatsNewItem {
        model.items[index]
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 36) {
                Develop {
                    Screenshot(image: model.images[item.id], alt: item.image.alt)
                        .frame(width: Self.screenshot.width, height: Self.screenshot.height)
                }
                Develop(delay: 0.2) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("New in \(item.version.short)")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Brand.ring.opacity(0.85).color)
                        Text(item.title)
                            .font(.system(size: 22, weight: .semibold))
                            .accessibilityAddTraits(.isHeader)
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
                                Text(paragraph)
                            }
                        }
                        .font(.system(size: 13.5))
                        .lineSpacing(2.5)
                        .foregroundStyle(Brand.paper.opacity(0.74).color)
                        .tint(Brand.ring.color)
                        .fixedSize(horizontal: false, vertical: true)
                        if let action = item.action {
                            Button(action.title) {
                                model.perform(action)
                            }
                            .buttonStyle(.glass)
                            .padding(.top, 6)
                        }
                    }
                    .frame(width: 340, alignment: .leading)
                }
            }
            .frame(maxHeight: .infinity)
            HStack(spacing: 14) {
                PageDots(count: model.items.count, current: index)
                Spacer()
                Button("Back", action: model.back)
                    .buttonStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(Brand.paper.opacity(0.6).color)
                PageButton(index + 1 < model.items.count ? "Next" : "Done", action: model.next)
            }
            .frame(width: Self.screenshot.width + 36 + 340)
        }
        .padding(.top, 136)
        .padding(.bottom, 36)
    }

    /// Inline Markdown, a paragraph at a time.
    private var paragraphs: [AttributedString] {
        item.body.components(separatedBy: "\n\n").map { paragraph in
            (try? AttributedString(
                markdown: paragraph,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace),
            )) ?? AttributedString(paragraph)
        }
    }
}

private struct Screenshot: View {
    let image: NSImage?
    let alt: String

    var body: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Brand.paper.opacity(0.12).color, lineWidth: 1))
                .accessibilityLabel(alt)
                .accessibilityAddTraits(.isImage)
        } else {
            RoundedRectangle(cornerRadius: 8)
                .fill(Brand.paper.opacity(0.04).color)
                .accessibilityHidden(true)
        }
    }
}

private struct PageDots: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 7) {
            ForEach(0 ..< count, id: \.self) { page in
                Circle()
                    .fill(Brand.paper.opacity(page == current ? 0.85 : 0.25).color)
                    .frame(width: 6, height: 6)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Page \(current + 1) of \(count)")
    }
}
