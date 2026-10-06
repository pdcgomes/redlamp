import AppKit
import RedlampDesign
import SwiftUI

extension HarnessScene {
    static var tokens: HarnessScene {
        HarnessScene(
            id: "tokens",
            title: "Tokens",
            symbol: "paintpalette",
            synopsis: "Colors, type and metrics shared by the SwiftUI and AppKit panels — both columns of the type ramp should be indistinguishable",
            section: .foundations,
        ) {
            TokensScene()
        }
    }
}

private struct TokensScene: View {
    private let colors: [(String, RGBA)] = [
        ("panelBackground", Palette.panelBackground), ("label", Palette.label), ("labelHover", Palette.labelHover),
        ("secondaryLabel", Palette.secondaryLabel), ("tertiaryLabel", Palette.tertiaryLabel),
        ("value", Palette.value), ("divider", Palette.divider), ("track", Palette.track),
        ("trackFill", Palette.trackFill), ("well", Palette.well), ("selection", Palette.selection),
        ("thumb", Palette.thumb), ("thumbStroke", Palette.thumbStroke), ("thumbShadow", Palette.thumbShadow),
        ("editedDot", Palette.editedDot),
        ("accent", Palette.accent.usingColorSpace(.sRGB).map {
            RGBA(red: $0.redComponent, green: $0.greenComponent, blue: $0.blueComponent, alpha: $0.alphaComponent)
        } ?? RGBA(white: 0.5)),
    ]

    private let fonts: [(String, FontSpec)] = [
        ("label", Typography.label), ("value", Typography.value), ("panelTitle", Typography.panelTitle),
        ("section", Typography.section), ("caption", Typography.caption), ("badge", Typography.badge),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SpecimenGroup(
                title: "Palette",
                note: """
                The current theme's tokens, over the panel background. Neutral is the shipping set: greys only, \
                so nothing on an editing surface tints the user's judgment of color. Other themes are under evaluation.
                """,
            ) {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.fixed(120), alignment: .leading), count: 6),
                    spacing: 14,
                ) {
                    ForEach(colors, id: \.0) { name, color in
                        Specimen(caption: name) {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(color.color)
                                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.primary.opacity(0.1)))
                                .frame(width: 100, height: 44)
                        }
                    }
                }
            }

            SpecimenGroup(
                title: "Notices",
                note: "A notice's card, edge and glyph in each tone. Caution is amber in every theme; info takes the theme's foreground.",
            ) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(NoticeTone.allCases, id: \.self) { tone in
                        let colors = Palette.notice(tone)
                        Specimen(caption: tone.rawValue) {
                            RoundedRectangle(cornerRadius: Metrics.cardRadius)
                                .fill(colors.fill.color)
                                .overlay(RoundedRectangle(cornerRadius: Metrics.cardRadius)
                                    .strokeBorder(colors.border.color))
                                .overlay(Image(systemName: tone.symbol).foregroundStyle(colors.glyph.color))
                                .frame(width: 100, height: 44)
                        }
                    }
                }
            }

            SpecimenGroup(
                title: "Type ramp",
                note: "SwiftUI Text on the left, AppKit's CoreText drawing on the right. A difference in weight, spacing or baseline shows up as a mismatch here first.",
            ) {
                Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 10) {
                    ForEach(fonts, id: \.0) { name, font in
                        GridRow {
                            Text(name).font(.caption.monospaced()).foregroundStyle(.tertiary)
                            Text(sample(name)).font(font.font).tracking(font.tracking)
                                .foregroundStyle(Palette.value.color)
                            AppKitSpecimen(width: 200) { TextSpecimenView(text: sample(name), font: font) }
                        }
                    }
                }
            }

            SpecimenGroup(title: "Metrics") {
                Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 4) {
                    ForEach(metrics, id: \.0) { name, value in
                        GridRow {
                            Text(name).font(.caption.monospaced())
                            Text(String(format: "%g pt", value)).font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func sample(_ name: String) -> String {
        switch name {
        case "value": "+0.60  3050  -100"
        case "section": "TONE"
        default: "Highlights Clarity Vibrance"
        }
    }

    private var metrics: [(String, Double)] {
        [
            ("labelWidth", Metrics.labelWidth), ("valueWidth", Metrics.valueWidth), ("rowHeight", Metrics.rowHeight),
            ("rowSpacing", Metrics.rowSpacing), ("panelRowSpacing", Metrics.panelRowSpacing),
            ("panelPadding", Metrics.panelPadding), ("panelHeaderHeight", Metrics.panelHeaderHeight),
            ("controlRowMinHeight", Metrics.controlRowMinHeight), ("thumbSize", Metrics.thumbSize),
            ("trackHeight", Metrics.trackHeight), ("cardRadius", Metrics.cardRadius),
            ("cardPadding", Metrics.cardPadding),
        ].map { ($0.0, Double($0.1)) }
    }
}

/// One line of AppKit-drawn text, for the type ramp.
private final class TextSpecimenView: NSView {
    let text: String
    let font: FontSpec

    init(text: String, font: FontSpec) {
        self.text = text
        self.font = font
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool {
        true
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: TextLine.lineHeight(font))
    }

    override func draw(_: NSRect) {
        TextLine.draw(
            text, font: font, color: Palette.value.nsColor, in: bounds,
            scale: window?.backingScaleFactor ?? 2,
        )
    }
}
